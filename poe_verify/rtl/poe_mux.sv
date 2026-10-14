// ============================================================================
// poe_mux —— RF 取数 MUX 阶段（线程池 ↔ EU 之间）
//
//   一条 task（burst）带着 sub_pc 进来：
//     ① 按 sub_pc 读一行 MUX 指令（32 条 × 11bit），逐条解码出 (offset, mvld)；
//     ② 用这 32 条指令从该线程 256B RF 里取数，拼成 **64B 操作数窗口**：
//          第 k 条指令（fetcher k）固定对应窗口的 2B 槽，**且 fetcher 0 = 最高 16bit**
//          （打包序与 mux_shift_conv 规格一致：fetcher k → win[511-16k -: 16]）；
//          槽内低字节先：mvld=2 → 槽低字节=RF[off]、槽高字节=RF[off+1]；
//          mvld=1 → 只填槽低字节；mvld=0 → 该槽保持 0。
//     ③ 窗口交给 EU；EU 处理完还回 64B 结果；
//     ④ 用**同一行 32 条指令**把结果反向散射回 RF 原偏移（覆盖写、无写使能、
//        一个 task 写一次），未被覆盖的字节保持原值；
//     ⑤ 回写落表之后，才向线程池回 task_done。
//
//   偏移来源（单条指令 [10] i 控制）：
//     i=0 → CSR MUX_PTR（0x16，8×8bit 表）里按 src_ptr 低 3bit 选一个字节偏移
//     i=1 → [7:0] 直接当字节偏移
//
//   画像约束（由 MUX 指令表保证，本模块不做检查）：
//     · 同一行内不会有两个条指令覆盖同一个 RF 字节（不重叠）；
//     · mvld=2 时 offset ≤ 254（不会越过 256B RF 边界）。
// ============================================================================
import poe_pkg::*;

module poe_mux #(
    parameter int TID_W = 6,             // 线程号位宽
    parameter int RF_W  = 2048,          // 每线程 RF 位宽（256B）
    parameter int CSRB  = poe_pkg::CSRB, // 每线程 CSR 字节数
    parameter int N_INS = MUX_INS_N,     // 一行 MUX 指令条数（32）
    parameter int INS_W = MUX_INS_W,     // 单条指令位宽（11）
    parameter int AW    = MUX_AW,        // 行号位宽（= sub_pc）
    parameter int WIN_W = poe_pkg::WIN_W // EU 操作数窗口位宽（512 = 64B）
) (
    input  logic             clk,
    input  logic             rst_n,
    // ---- 来自线程池的 task ----
    input  logic             task_vld,       // 一条 task 有效
    input  logic [TID_W-1:0] task_tid,       // 属于哪个线程
    input  logic [AW-1:0]    task_sub_pc,    // 微指令行号（= MUX 指令行号）
    input  logic             task_last,      // 本 task 是该线程最后一条
    output logic             task_rdy,       // MUX 能收（空闲）
    // ---- MUX 指令存储读口 ----
    output logic [AW-1:0]          mux_rd_addr,
    input  logic [N_INS*INS_W-1:0] mux_row,
    // ---- RF（bank）：读整份 / 回写整份 ----
    output logic [TID_W-1:0] rf_rd_tid,      // 要读哪个线程的 RF
    input  logic [RF_W-1:0]  rf_rd,          // 该线程整份 256B RF
    output logic             mux_rf_we,      // 回写请求（一拍）
    output logic [TID_W-1:0] mux_rf_tid,     // 回写哪个线程
    output logic [RF_W-1:0]  mux_rf_wdata,   // 回写后的整份 RF
    // ---- CSR 快照（读 MUX_PTR）----
    output logic [TID_W-1:0]  csr_rtid,
    input  logic [CSRB*8-1:0] csr_snap,
    // ---- 到 EU ----
    output logic             win_vld,        // 窗口有效
    output logic [TID_W-1:0] win_tid,        // 属于哪个线程
    output logic [AW-1:0]    win_sub_pc,     // 微指令行号
    output logic             win_last,       // 本 task 是线程最后一条（透传给 EU 壳）
    output logic [WIN_W-1:0] win_data,       // 64B 操作数窗口
    input  logic             win_rdy,        // EU 能否收
    input  logic             eu_done,        // EU 结果有效
    input  logic [TID_W-1:0] eu_done_tid,    // 结果属于哪个线程
    input  logic [WIN_W-1:0] win_out,        // EU 处理后的 64B 窗口
    // ---- 回线程池：一条 task 真正做完（RF 已回写）----
    output logic             task_done,
    output logic [TID_W-1:0] task_done_tid
);
    typedef enum logic [1:0] { M_IDLE, M_PRESENT, M_RUN } st_e;
    st_e              st;
    logic [TID_W-1:0] tid_q;                 // 当前 task 的线程号
    logic [AW-1:0]    pc_q;                  // 当前 task 的 sub_pc
    logic             last_q;                // 当前 task 是不是线程最后一条
    logic [7:0]       off_q  [N_INS];        // 32 条指令解出的 RF 字节偏移
    logic [1:0]       mvld_q [N_INS];        // 32 条指令的 mvld
    logic [7:0]       off_c  [N_INS];        // 组合解码（收 task 那一拍锁存）
    logic [1:0]       mvld_c [N_INS];
    logic [WIN_W-1:0] win_c;                 // 组出的 64B 窗口
    logic [RF_W-1:0]  wb_c;                  // 反向散射后的整份 RF
    logic             done_r;                // 回池子的完成脉冲
    logic [TID_W-1:0] done_tid_r;

    // ---- 单条指令解码 ----
    function automatic logic [7:0] mux_off(input logic [INS_W-1:0] ins,
                                           input logic [CSRB*8-1:0] snap);
// i=0：从 CSR MUX_PTR（0x16）里按 src_ptr 低 3bit 选一个字节偏移；i=1：[7:0] 就是偏移
        mux_off = ins[MI_I_LSB] ? ins[MI_PTR_LSB +: 8]
                                : snap[8*int'(A_MUX_PTR) + 8*ins[MI_PTR_LSB +: 3] +: 8];
    endfunction
    function automatic logic [1:0] mux_mvld(input logic [INS_W-1:0] ins);
        mux_mvld = ins[MI_MVLD_LSB +: 2];
    endfunction

    always_comb begin
        for (int k = 0; k < N_INS; k++) begin
            off_c[k]  = mux_off (mux_row[INS_W*k +: INS_W], csr_snap);
            mvld_c[k] = mux_mvld(mux_row[INS_W*k +: INS_W]);
        end
    end

    // ---- 组 64B 窗口（用锁存下来的 32 条指令 + 该线程 RF）----
    always_comb begin
        win_c = '0;                                     // mvld=0 的槽保持 0
        for (int k = 0; k < N_INS; k++) begin
            if ((mvld_q[k] == 2'd2) && (off_q[k] <= 8'd254))
                win_c[WIN_W-16*(k+1) +: 16] = rf_rd[8*off_q[k] +: 16];  // fetcher k → 高端第 k 个 2B 槽
            else if (mvld_q[k] == 2'd1)
                win_c[WIN_W-16*(k+1) +: 8]  = rf_rd[8*off_q[k] +: 8];   // 只填槽低字节
        end
    end

    // ---- 反向散射：把 EU 的 64B 结果按同一行指令写回 RF 原偏移 ----
    always_comb begin
        wb_c = rf_rd;                                   // 未被覆盖的字节保持原值
        for (int k = 0; k < N_INS; k++) begin
            if ((mvld_q[k] == 2'd2) && (off_q[k] <= 8'd254))
                wb_c[8*off_q[k] +: 16] = win_out[WIN_W-16*(k+1) +: 16];
            else if (mvld_q[k] == 2'd1)
                wb_c[8*off_q[k] +: 8]  = win_out[WIN_W-16*(k+1) +: 8];
        end
    end

    // ---- 组合输出 ----
    assign task_rdy     = (st == M_IDLE);
    assign mux_rd_addr  = (st == M_IDLE) ? task_sub_pc : pc_q;
    assign rf_rd_tid    = (st == M_IDLE) ? task_tid    : tid_q;
    assign csr_rtid     = (st == M_IDLE) ? task_tid    : tid_q;
    assign win_vld      = (st == M_PRESENT);
    assign win_tid      = tid_q;
    assign win_sub_pc   = pc_q;
    assign win_last     = last_q;
    assign win_data     = win_c;
    assign mux_rf_we    = (st == M_RUN) && eu_done && (eu_done_tid == tid_q);
    assign mux_rf_tid   = tid_q;
    assign mux_rf_wdata = wb_c;
    assign task_done    = done_r;
    assign task_done_tid= done_tid_r;

    // ---- 状态机 ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= M_IDLE; tid_q <= '0; pc_q <= '0; last_q <= 1'b0;
            done_r <= 1'b0; done_tid_r <= '0;
            for (int k = 0; k < N_INS; k++) begin
                off_q[k]  <= '0;
                mvld_q[k] <= '0;
            end
        end else begin
            done_r <= 1'b0;                              // 完成脉冲只给一拍
            case (st)
                // 收 task：当拍锁存解码结果（task_rdy = 本状态）
                M_IDLE: if (task_vld) begin
                    st     <= M_PRESENT;
                    tid_q  <= task_tid;
                    pc_q   <= task_sub_pc;
                    last_q <= task_last;
                    for (int k = 0; k < N_INS; k++) begin
                        off_q[k]  <= off_c[k];
                        mvld_q[k] <= mvld_c[k];
                    end
                end
                // 把窗口递给 EU，等它收下
                M_PRESENT: if (win_rdy) st <= M_RUN;
                // 等 EU 结果 → 当拍反向散射回写（下一拍 RF 已落表），并回池子 done
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
