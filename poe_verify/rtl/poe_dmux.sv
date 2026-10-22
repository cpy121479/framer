// ============================================================================
// poe_dmux —— DMUX 级：EU 结果回填 + O 窗累积 + 出口 KO 再生
//
//   在 EU 结果拍（eu_done）干三件事，全部用**同一行 MUX 指令**（按该 task 的 sub_pc 索引）：
//     ① **RF 回填**（每个 task 一次）：
//          逆 MXS：把 2B 槽里左对齐的 field0/field1 送回源 16bit 的原位；
//          再按取数指令的 mvld 逆方向回填到 RF 原偏移（mvld=2 回填 2B、mvld=1 回填高字节）；
//          **只回填被指令选中/搬过的位**（用 MXS 掩码掩掉），没被指令碰过的位保持 RF 原值；
//     ② **CCR 回填**（每个 task 一次）：EU 写回的 2B 填到 32B CCR 表里 MXCC 选中的两个字节
//          （[0] 位置 ← 高字节、[1] 位置 ← 低字节），同时由 bank 镜像进 CSR 0x2 供比对；
//     ③ **O 窗累积**（每个 task 一次）：按 ④/⑤ 两组指令，从 EU 处理后的 64B 窗取数、
//          逆 MXS 后填进该线程 32B O 窗（第 m 条 ↔ O 窗第 m 个 2B，m=0 最高；不回填的位为 0）；
//          线程最后一条 task 完成时**再生出口 KO**：
//              出口 KO 48B = { O 窗 32B（放高 32B）, 入口 KO 低 16B（原样保持） }
//          —— DA/SA 对调与透传作废，以 O 窗再生为准；KO 由本模块直出（out_vld/out_data/out_tid）。
//
//   O 窗每线程一份，建线程（alloc）时清零；只有本模块写它，别处不碰。
// ============================================================================
import poe_pkg::*;

module poe_dmux #(
    parameter int TID_W = 6,               // 线程号位宽
    parameter int N_THR = 64,              // 线程数（每线程一份 O 窗）
    parameter int RF_W  = 2048,            // 每线程 RF 位宽（256B）
    parameter int CSRB  = poe_pkg::CSRB,   // 每线程 CSR 字节数（读 MUX_PTR）
    parameter int N_INS = MUX_INS_N,       // 取数/移位组条数（32）
    parameter int INS_W = MUX_INS_W,       // 取数指令位宽（11）
    parameter int O_INS = O_INS_N,         // O 路条数（16）
    parameter int WIN_W = poe_pkg::WIN_W,  // EU 操作数窗口位宽（512 = 64B）
    parameter int O_WIN_W = poe_pkg::O_WIN_W // 每线程 O 窗位宽（256 = 32B）
) (
    input  logic             clk,             // 时钟
    input  logic             rst_n,           // 低有效异步复位
    // ---- 建线程（清该线程的 O 窗）----
    input  logic             alloc,           // 建线程脉冲
    input  logic [TID_W-1:0] alloc_tid,       // 建到哪个槽
    // ---- 当前 task 上下文（来自 MUX 的状态寄存）----
    input  logic             eu_done,         // EU 结果有效
    input  logic [TID_W-1:0] eu_done_tid,     // 结果属于哪个线程
    input  logic [TID_W-1:0] ctx_tid,         // 当前 task 的线程号
    input  logic             ctx_last,        // 当前 task 是否线程最后一条
    // ---- MUX 指令行（与 MUX 同一行：按 ctx_pc 读出的 mux_row）----
    input  logic [MUX_ROW_W-1:0] row,
    // ---- EU 结果 + 该线程原值与 CSR 快照 ----
    input  logic [WIN_W-1:0]  win_out,        // EU 处理后的 64B 窗
    input  logic [15:0]       ccr_out,        // EU 写回的 2B CSR（= CCR）
    input  logic [RF_W-1:0]   rf_rd,          // 该线程当前 RF（做掩码保护用）
    input  logic [CSRB*8-1:0] csr_snap,       // 该线程 CSR 快照（读 MUX_PTR）
    input  logic [KO_LO_W-1:0] ko_lo,         // 入口 KO 低 16B（出口原样保持）
    // ---- RF 回填（bank）----
    output logic             rf_we,           // 回填请求（一拍）
    output logic [TID_W-1:0] rf_tid,          // 回填哪个线程
    output logic [RF_W-1:0]  rf_wdata,        // 回填后的整份 RF
    // ---- CCR 回填（bank：写 32B 表两个字节 + 镜像 CSR 0x2）----
    output logic             ccr_we,          // 回填请求（一拍）
    output logic [TID_W-1:0] ccr_tid,         // 回填哪个线程
    output logic [4:0]       ccr_a0,          // 高字节落在 CCR 表哪个字节（MXCC[0]）
    output logic [4:0]       ccr_a1,          // 低字节落在哪个字节（MXCC[1]）
    output logic [15:0]      ccr_wdata,       // 要写回的 2B（高字节 → ccr_a0、低字节 → ccr_a1）
    // ---- 出口 KO（DMUX 直出：线程结束才再生）----
    output logic             out_vld,         // 出口 KO 有效（一拍）
    output logic [383:0]     out_data,        // 出口 48B 报文
    output logic [TID_W-1:0] out_tid          // 出口 KO 属于哪个线程
);
    logic [O_WIN_W-1:0] o_win [N_THR];        // 每线程 O 窗（32B），只有本模块写
    logic [O_WIN_W-1:0] o_next;               // 本 task 处理后的 O 窗
    logic               task_go;              // 本拍就是"当前 task 的 EU 结果拍"

    assign task_go = eu_done && (eu_done_tid == ctx_tid);

    // ---- ① RF 回填：逆 MXS + 逆取数（掩码保护）----
    always_comb begin
        automatic logic [INS_W-1:0]  ins;
        automatic logic [MXS_W-1:0]  mxs;
        automatic logic [1:0]        mv;
        automatic logic [7:0]        of;
        automatic logic [15:0]       val, msk, orig, newv;
        rf_wdata = rf_rd;                                     // 没被指令碰过的字节保持原值
        for (int k = 0; k < N_INS; k++) begin
            ins = row[MF_FET_LSB + INS_W*k +: INS_W];
            mxs = row[MF_MXS_LSB + MXS_W*k +: MXS_W];
            mv  = mux_mvld(ins);
            of  = mux_off(ins, csr_snap);
            if ((mv != 2'd0) && !((mv == 2'd2) && (int'(of) > 254))) begin
                orig = {rf_rd[8*int'(of) +: 8], rf_rd[8*int'(of) + 8 +: 8]};
                mxs_unshift(win_out[WIN_W-16*(k+1) +: 16], mxs, val, msk);
                if (mv == 2'd1) msk &= 16'hFF00;              // mvld=1：只有高字节是搬过的
                newv = (orig & ~msk) | (val & msk);
                // 回填：RF[of] = 16bit 的高字节（先取的字节），RF[of+1] = 低字节
                if (mv == 2'd2) begin
                    rf_wdata[8*int'(of) +: 8]     = newv[15:8];
                    rf_wdata[8*int'(of) + 8 +: 8] = newv[7:0];
                end else begin
                    rf_wdata[8*int'(of) +: 8]     = newv[15:8];     // mvld=1：只回填高字节
                end
            end
        end
    end

    // ---- ③ O 窗：本 task 的下一态（④ 取数 + ⑤ 逆 MXS，不回填的位为 0）----
    always_comb begin
        automatic logic [INS_W-1:0]  ins;
        automatic logic [MXS_W-1:0]  mxs;
        automatic logic [1:0]        mv;
        automatic logic [7:0]        of;
        automatic logic [15:0]       raw, val, msk;
        o_next = o_win[ctx_tid];
        for (int m = 0; m < O_INS; m++) begin
            ins = row[MF_OFET_LSB + INS_W*m +: INS_W];
            mxs = row[MF_OMXS_LSB + MXS_W*m +: MXS_W];
            mv  = mux_mvld(ins);
            of  = mux_off(ins, csr_snap);                     // 64B 窗内的字节偏移（只用低 6bit）
            if (mv != 2'd0) begin
                raw = 16'd0;
                if ((mv == 2'd2) && (int'(of[5:0]) <= 62))
                    raw = {win_out[8*int'(of[5:0]) +: 8], win_out[8*int'(of[5:0]) + 8 +: 8]};
                else if (mv == 2'd1)
                    raw = {win_out[8*int'(of[5:0]) +: 8], 8'd0};
                mxs_unshift(raw, mxs, val, msk);
                if (mv == 2'd1) msk &= 16'hFF00;
                o_next[O_WIN_W-16*(m+1) +: 16] = val & msk;   // O 窗第 m 个 2B（m=0 最高）
            end
        end
    end

    // ---- ② CCR 回填（EU 的 2B → MXCC 选中的两个字节）----
    assign ccr_a0    = row[MF_MXCC_LSB +: MXCC_W];             // 高字节落点
    assign ccr_a1    = row[MF_MXCC_LSB + MXCC_W +: MXCC_W];    // 低字节落点
    assign ccr_wdata = ccr_out;

    // ---- 出口 KO：{ O 窗 32B 放高 32B, 入口 KO 低 16B 原样 } ----
    assign out_vld  = task_go && ctx_last;
    assign out_data = {o_next[O_WIN_W-1:0], ko_lo};
    assign out_tid  = ctx_tid;

    // ---- 写使能 ----
    assign rf_we   = task_go;
    assign rf_tid  = ctx_tid;
    assign ccr_we  = task_go;
    assign ccr_tid = ctx_tid;

    // ---- O 窗时序：结果拍累积；建线程清零（后写优先）----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int t = 0; t < N_THR; t++) o_win[t] <= '0;
        end else begin
            if (task_go) o_win[ctx_tid] <= o_next;
            if (alloc)   o_win[alloc_tid] <= '0;
        end
    end
endmodule
