// ============================================================================
// poe_mux —— MUX 级（参考模型，功能对齐开发文档 mux_top/mux_shift_conv）
//
//   一条 task（burst）带着 sub_pc 进来：
//     ① 按 sub_pc 读一行 MUX 指令（行布局见 poe_pkg ⑤ 节）；
//     ② 32 个 fetcher 按 11bit 取数指令从 256B RF 取数，拼成 64B 窗：
//          第 k 条 ↔ 窗口第 k 个 2B 槽（slot 0 = 最高 16bit）；
//          **高位序偏移**（文档 data_fetcher）：偏移 off → 高字节 RF[255-off]、低字节 RF[254-off]；
//          mvld=0 全 0、1 只高字节、2/3 两个字节（3 按 2）；
//     ③ 主链 8 条 lane 指令对高 8 个槽（高 16B）做 lane_shifter R4 移位；
//          低 48B（slot 8..31）直通（文档 shifter_stage 的直通段）；
//     ④ 8 条 5bit CCR 指令从本线程 64bit CCR（32×2bit）里各选 1 个码，
//          拼成 16bit（8×2bit）给 EU（文档 ccr_conv）；
//     ⑤ 窗口 + 16bit CCR 交给 EU；回填在 DMUX 里做。
//
//   实现简化：保留 task 级 vld/rdy/done 和按 sub_pc 的 MUX imem，
//   不实现 h_ext/RAM/cbus/beat 流水（这些不影响取数/移位/CCR 的功能结果）。
// ============================================================================
import poe_pkg::*;

module poe_mux #(
    parameter int TID_W = 6,              // 线程号位宽
    parameter int RF_W  = 2048,           // 每线程 RF 位宽（256B）
    parameter int CSRB  = poe_pkg::CSRB,  // 每线程 CSR 字节数
    parameter int N_INS = MUX_INS_N,      // 32 个 fetcher
    parameter int INS_W = MUX_INS_W,      // 取数指令位宽（11）
    parameter int AW    = MUX_AW,         // 行号位宽（= sub_pc）
    parameter int WIN_W = poe_pkg::WIN_W, // EU 操作数窗口位宽（512 = 64B）
    parameter int CCR_W = poe_pkg::CCR_W  // 每线程 CCR 向量位宽（64 = 32×2bit）
) (
    input  logic             clk,             // 时钟
    input  logic             rst_n,           // 低有效异步复位
    input  logic             task_vld,        // 一条 task 有效
    input  logic [TID_W-1:0] task_tid,        // 属于哪个线程
    input  logic [AW-1:0]    task_sub_pc,     // MUX 指令行号
    input  logic             task_last,       // 本 task 是线程最后一条
    input  logic             task_ts_last,    // 本 task 是本 ts 最后一条
    input  logic             task_br,         // 本 ts 头 burst 的 br
    input  logic [AW-1:0]    task_jump,       // 本 ts 的 jump_target
    output logic             task_rdy,        // MUX 能收（空闲）
    output logic [AW-1:0]        mux_rd_addr, // 读哪一行
    input  logic [MUX_ROW_W-1:0] mux_row,     // 该行整行指令
    output logic [TID_W-1:0] rf_rd_tid,       // 读哪个线程的 RF
    input  logic [RF_W-1:0]  rf_rd,           // 该线程整份 RF
    output logic [TID_W-1:0] ccr_rtid,        // 读哪个线程的 CCR 向量
    input  logic [CCR_W-1:0] ccr_rd,          // 该线程 64bit CCR
    output logic [TID_W-1:0] csr_rtid,        // 读哪个线程的 CSR
    input  logic [CSRB*8-1:0] csr_snap,       // 该线程 CSR 快照（读 MUX_PTR）
    // ---- 到 EU ----
    output logic             win_vld,         // 窗口有效
    output logic [TID_W-1:0] win_tid,         // 属于哪个线程
    output logic [AW-1:0]    win_sub_pc,      // 行号
    output logic             win_last,        // 本 task 是线程最后一条
    output logic             win_ts_last,     // 本 task 是本 ts 最后一条
    output logic             win_br,          // 本 ts 头 burst 的 br
    output logic [AW-1:0]    win_jump,        // 本 ts 的 jump_target
    output logic [WIN_W-1:0] win_data,        // 64B 窗
    output logic [15:0]      win_ccr,         // 8×2bit CCR（16bit）
    input  logic             win_rdy,         // EU 能否收
    input  logic             eu_done,         // EU 结果有效
    input  logic [TID_W-1:0] eu_done_tid,     // 结果属于哪个线程
    // ---- 当前 task 上下文（给 DMUX）----
    output logic [TID_W-1:0] ctx_tid,         // 当前 task 线程号
    output logic [AW-1:0]    ctx_pc,          // 当前 task 行号（给 DMUX 指令存储读口）
    output logic             ctx_last,        // 当前 task 是否线程最后一条
    // ---- 回线程池 ----
    output logic             task_done,       // 一条 task 做完
    output logic [TID_W-1:0] task_done_tid    // 完成属于哪个线程
);
    typedef enum logic [1:0] { M_IDLE, M_PRESENT, M_RUN } st_e;
    st_e              st;
    logic [TID_W-1:0] tid_q;
    logic [AW-1:0]    pc_q;
    logic             last_q;
    logic             ts_last_q;
    logic             br_q;
    logic [AW-1:0]    jump_q;
    logic             done_r;
    logic [TID_W-1:0] done_tid_r;
    logic [WIN_W-1:0] win_c;
    logic [15:0]      ccr_c;

    // ---- 32 个 fetcher → 64B 窗；slot 0..7 再做主链 lane 移位 ----
    always_comb begin
        win_c = '0;
        for (int k = 0; k < N_INS; k++) begin
            win_c[WIN_W-16*(k+1) +: 16] =
                fetch_word(rf_rd,
                           mux_off(mux_row[MF_FET_LSB + INS_W*k +: INS_W], csr_snap),
                           mux_mvld(mux_row[MF_FET_LSB + INS_W*k +: INS_W]));
            if (k < LANE_N)
                win_c[WIN_W-16*(k+1) +: 16] =
                    lane_fwd(win_c[WIN_W-16*(k+1) +: 16],
                             mux_row[MF_LANE_LSB + LANE_W*k +: LANE_W]);
        end
        ccr_c = ccr_extract(ccr_rd, mux_row[MF_CCR_LSB +: CCR_INS_N*CCR_INS_W]);
    end

    // 只在锁存后的 task 上取指/读 RF/CCR/CSR（M_IDLE 不再预取）
    assign task_rdy     = (st == M_IDLE);
    assign mux_rd_addr  = pc_q;
    assign rf_rd_tid    = tid_q;
    assign ccr_rtid     = tid_q;
    assign csr_rtid     = tid_q;
    assign win_vld      = (st == M_PRESENT);
    assign win_tid      = tid_q;
    assign win_sub_pc   = pc_q;
    assign win_last     = last_q;
    assign win_ts_last  = ts_last_q;
    assign win_br       = br_q;
    assign win_jump     = jump_q;
    assign win_data     = win_c;
    assign win_ccr      = ccr_c;
    assign ctx_tid      = tid_q;
    assign ctx_pc       = pc_q;
    assign ctx_last     = last_q;
    assign task_done    = done_r;
    assign task_done_tid= done_tid_r;

    // ---- 状态机：收 task → 递窗口给 EU → 等 EU 结果 ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= M_IDLE;
            tid_q <= '0;
            pc_q <= '0;
            last_q <= 1'b0;
            ts_last_q <= 1'b0;
            br_q <= 1'b0;
            jump_q <= '0;
            done_r <= 1'b0;
            done_tid_r <= '0;
        end else begin
            done_r <= 1'b0;
            case (st)
                M_IDLE: if (task_vld) begin
                    st     <= M_PRESENT;
                    tid_q  <= task_tid;
                    pc_q   <= task_sub_pc;
                    last_q <= task_last;
                    ts_last_q <= task_ts_last;
                    br_q   <= task_br;
                    jump_q <= task_jump;
                end
                M_PRESENT: if (win_rdy) st <= M_RUN;
                M_RUN: if (eu_done && (eu_done_tid == tid_q)) begin
                    st         <= M_IDLE;
                    done_r     <= 1'b1;
                    done_tid_r <= tid_q;
                end
                default: st <= M_IDLE;
            endcase
        end
    end
endmodule
