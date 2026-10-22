// ============================================================================
// poe_mux —— MUX 级：RF 取数 + MXS 移位 + MXCC 选 CSR（线程池 ↔ EU 之间）
//
//   一条 task（burst）带着 sub_pc 进来：
//     ① 按 sub_pc 读一行 MUX 指令（行布局见 poe_pkg 的 ⑤ 节）；
//     ② **取数组**从该线程 256B RF 取 0~2B 填进 64B 操作数窗口的对应 2B 槽：
//          第 k 条 ↔ 窗口第 k 个 2B 槽，**slot 0 = 最高 16bit**（win[511:496]）；
//          先取的字节放槽的高 8bit（mvld=2 → 槽[15:8]=RF[off]、槽[7:0]=RF[off+1]）；
//          mvld=0 的槽保持 0（= 不取数）；
//     ③ **移位组**（MXS）把该槽里的字段提取出来左对齐（语义见 poe_pkg::mxs_align）：
//          这样 EU 看到的就是"已经按指令对齐好"的操作数；
//     ④ **MXCC** 从该线程 32B CCR 表里选 2B（[0]→高字节、[1]→低字节）给 EU 当 CSR；
//     ⑤ 窗口 + 2B CSR 交给 EU；EU 结果连同当前 task 的上下文（tid/pc/last）交给 DMUX，
//        **回写 RF / 回填 CCR / 再生 KO 都在 DMUX 里做**（本模块不回写）。
//
//   偏移来源（单条取数指令 [10] i 控制）：
//     i=0 → CSR MUX_PTR（0x16，8×8bit 表）里按 src_ptr 低 3bit 选一个字节偏移
//     i=1 → [7:0] 直接当字节偏移
//
//   画像约束（由 MUX 指令表保证，本模块不做检查）：
//     · 同一行内不会有两个取数指令覆盖同一个 RF 字节（不重叠）；
//     · mvld=2 时 off ≤ 254（不会越过 256B RF 边界）。
// ============================================================================
import poe_pkg::*;

module poe_mux #(
    parameter int TID_W = 6,              // 线程号位宽
    parameter int RF_W  = 2048,           // 每线程 RF 位宽（256B）
    parameter int CSRB  = poe_pkg::CSRB,  // 每线程 CSR 字节数
    parameter int N_INS = MUX_INS_N,      // 一行取数/移位组条数（32）
    parameter int INS_W = MUX_INS_W,      // 取数指令位宽（11）
    parameter int AW    = MUX_AW,         // 行号位宽（= sub_pc）
    parameter int WIN_W = poe_pkg::WIN_W, // EU 操作数窗口位宽（512 = 64B）
    parameter int CCR_W = poe_pkg::CCR_W  // 每线程 CCR 表位宽（256 = 32B）
) (
    input  logic             clk,             // 时钟
    input  logic             rst_n,           // 低有效异步复位
    // ---- 来自线程池的 task ----
    input  logic             task_vld,        // 一条 task 有效
    input  logic [TID_W-1:0] task_tid,        // 属于哪个线程
    input  logic [AW-1:0]    task_sub_pc,     // 微指令行号（= MUX 指令行号）
    input  logic             task_last,       // 本 task 是该线程最后一条
    output logic             task_rdy,        // MUX 能收（空闲）
    // ---- MUX 指令存储读口 ----
    output logic [AW-1:0]        mux_rd_addr, // 读哪一行（= sub_pc）
    input  logic [MUX_ROW_W-1:0] mux_row,     // 该行整行指令
    // ---- RF（bank）：整份读（DMUX 回写也用同一份原值做掩码保护）----
    output logic [TID_W-1:0] rf_rd_tid,       // 要读哪个线程的 RF
    input  logic [RF_W-1:0]  rf_rd,           // 该线程整份 256B RF
    // ---- CCR 表（bank）：MXCC 选 2B ----
    output logic [TID_W-1:0]  ccr_rtid,       // 要读哪个线程的 CCR 表
    input  logic [CCR_W-1:0]  ccr_rd,         // 该线程整份 32B CCR 表
    // ---- CSR 快照（读 MUX_PTR）----
    output logic [TID_W-1:0]  csr_rtid,       // 要读哪个线程的 CSR
    input  logic [CSRB*8-1:0] csr_snap,       // 该线程 CSR 全表快照
    // ---- 到 EU ----
    output logic             win_vld,         // 窗口有效
    output logic [TID_W-1:0] win_tid,         // 属于哪个线程
    output logic [AW-1:0]    win_sub_pc,      // 微指令行号
    output logic             win_last,        // 本 task 是线程最后一条（透传给 EU 壳）
    output logic [WIN_W-1:0] win_data,        // 64B 操作数窗口
    output logic [15:0]      win_ccr,         // MXCC 选出的 2B CSR（CCR）给 EU
    input  logic             win_rdy,         // EU 能否收
    input  logic             eu_done,         // EU 结果有效
    input  logic [TID_W-1:0] eu_done_tid,     // 结果属于哪个线程
    // ---- 当前 task 上下文（给 DMUX 做回填 / O 窗 / KO 再生；指令行由 MUX 读出后共用）----
    output logic [TID_W-1:0] ctx_tid,         // 当前 task 的线程号
    output logic             ctx_last,        // 当前 task 是否线程最后一条
    // ---- 回线程池：一条 task 真正做完（RF/CCR 已由 DMUX 落表）----
    output logic             task_done,
    output logic [TID_W-1:0] task_done_tid
);
    typedef enum logic [1:0] { M_IDLE, M_PRESENT, M_RUN } st_e;
    st_e              st;                     // 当前状态
    logic [TID_W-1:0] tid_q;                  // 当前 task 的线程号
    logic [AW-1:0]    pc_q;                   // 当前 task 的 sub_pc
    logic             last_q;                 // 当前 task 是不是线程最后一条
    logic             done_r;                 // 回池子的完成脉冲
    logic [TID_W-1:0] done_tid_r;             // 完成脉冲的线程号
    logic [WIN_W-1:0] win_c;                  // 组合组出的 64B 窗口
    logic [15:0]      ccr_c;                  // 组合选出的 2B CSR

    // ---- 一个 2B 槽：取数（0~2B）→ 槽内 16bit → 按 MXS 左对齐 ----
    function automatic logic [15:0] lane_of(input logic [INS_W-1:0]  ins,
                                            input logic [MXS_W-1:0] mxs,
                                            input logic [RF_W-1:0]  rfr,
                                            input logic [CSRB*8-1:0] snap);
        automatic logic [1:0]  mv;    // 取几个字节
        automatic logic [7:0]  of;    // 字节偏移
        automatic logic [15:0] raw;   // 取到的 16bit（高字节 = 先取的字节）
        mv  = mux_mvld(ins);
        of  = mux_off(ins, snap);
        raw = 16'd0;
        if ((mv == 2'd2) && (int'(of) <= 254))
            raw = {rfr[8*int'(of) +: 8], rfr[8*int'(of) + 8 +: 8]};   // 先取的字节在高 8bit
        else if (mv == 2'd1)
            raw = {rfr[8*int'(of) +: 8], 8'd0};                       // 取 1B 放高 8bit
        lane_of = (mv == 2'd0) ? 16'd0 : mxs_align(raw, mxs);
    endfunction

    // ---- MXCC：从 32B CCR 表选 2B（[0]→高字节、[1]→低字节）----
    function automatic logic [15:0] ccr_pick(input logic [MUX_ROW_W-1:0] row,
                                             input logic [CCR_W-1:0]    tab);
        automatic logic [4:0] a0, a1;
        a0 = row[MF_MXCC_LSB +: MXCC_W];
        a1 = row[MF_MXCC_LSB + MXCC_W +: MXCC_W];
        ccr_pick = {tab[8*int'(a0) +: 8], tab[8*int'(a1) +: 8]};
    endfunction

    // ---- 组 64B 窗口（按 ①/② 两组字段；mvld=0 的槽保持 0）----
    always_comb begin
        win_c = '0;
        for (int k = 0; k < N_INS; k++)
            if (mux_mvld(mux_row[MF_FET_LSB + INS_W*k +: INS_W]) != 2'd0)
                win_c[WIN_W-16*(k+1) +: 16] =
                    lane_of(mux_row[MF_FET_LSB + INS_W*k +: INS_W],
                            mux_row[MF_MXS_LSB + MXS_W*k +: MXS_W],
                            rf_rd, csr_snap);
        ccr_c = ccr_pick(mux_row, ccr_rd);
    end

    // ---- 组合输出 ----
    assign task_rdy     = (st == M_IDLE);
    assign mux_rd_addr  = (st == M_IDLE) ? task_sub_pc : pc_q;
    assign rf_rd_tid    = (st == M_IDLE) ? task_tid    : tid_q;
    assign ccr_rtid     = (st == M_IDLE) ? task_tid    : tid_q;
    assign csr_rtid     = (st == M_IDLE) ? task_tid    : tid_q;
    assign win_vld      = (st == M_PRESENT);
    assign win_tid      = tid_q;
    assign win_sub_pc   = pc_q;
    assign win_last     = last_q;
    assign win_data     = win_c;
    assign win_ccr      = ccr_c;
    assign ctx_tid      = tid_q;
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
            done_r <= 1'b0;
            done_tid_r <= '0;
        end else begin
            done_r <= 1'b0;                       // 完成脉冲只给一拍
            case (st)
                // 收 task（task_rdy = 本状态）
                M_IDLE: if (task_vld) begin
                    st     <= M_PRESENT;
                    tid_q  <= task_tid;
                    pc_q   <= task_sub_pc;
                    last_q <= task_last;
                end
                // 把窗口递给 EU，等它收下
                M_PRESENT: if (win_rdy) st <= M_RUN;
                // 等 EU 结果：结果拍上 DMUX 用同一行指令回填 RF/CCR（组合写口），
                // 因此本拍就能向池子报 task_done（bank 当拍落表）。
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
