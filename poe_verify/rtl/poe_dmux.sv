// ============================================================================
// poe_dmux —— DMUX 级（参考模型，功能对齐开发文档 dmux_top/mux_shift_div）
//
//   在 EU 结果拍（eu_done && tid 匹配）按同一行 MUX 指令做三件事：
//     ① **主链写回 RF**：
//          - 高 8 个 2B 槽先按 8 条 lane 指令做 lane_shifter R4 的**逆操作**；
//          - slot 8..31 直通（文档 shifter_stage 的直通段）；
//          - 32 个 fetcher 按原 11bit 指令把 slot k deposit 回 RF：
//              偏移 off → 高字节 RF[255-off]、低字节 RF[254-off]（高位序）；
//              mvld=0 不写、1 只写高字节、2/3 写两个字节（3 按 2）；
//              只写 lane 逆变换掩码内的位，其余位保持 RF 原值（内部合并，不输出 mask）。
//     ② **CCR 放回**：EU 写回的 16bit（8×2bit）按 8 条 5bit 指令 deposit 成 64bit
//          （32×2bit，未选中位置 0；不做 ccr_mask 门控）；同时给 bank 一个 16bit 镜像
//          写 CSR 0x2 供验证侧比对。
//     ③ **O 链**：高 4 个槽先按 4 条 lane 指令做逆变换（slot 4..15 直通），
//          16 个 fetcher 以 slot k 为源、按 O 指令的偏移 deposit 到 32B O 窗
//          （高位序：偏移 off → O 字节 index off）；每个 task 重新生成，不跨 task 累积。
//          线程最后一条 task 完成时输出 KO = {O 窗 32B, 入口 KO 低 16B}。
//
//   简化：DMUX 是纯组合（无时钟/复位/状态）；数据/掩码合并在内部完成，不向平台暴露
//   data+mask 端口；不实现 beat 流水（这些不影响功能结果）。
// ============================================================================
import poe_pkg::*;

module poe_dmux #(
    parameter int TID_W = 6,
    parameter int RF_W  = 2048,
    parameter int CSRB  = poe_pkg::CSRB,
    parameter int N_INS = MUX_INS_N,
    parameter int INS_W = MUX_INS_W,
    parameter int O_INS = O_INS_N,
    parameter int WIN_W = poe_pkg::WIN_W,
    parameter int O_WIN_W = poe_pkg::O_WIN_W,
    parameter int CCR_W = poe_pkg::CCR_W
) (
    input  logic             eu_done,         // EU 结果有效
    input  logic [TID_W-1:0] eu_done_tid,     // 结果属于哪个线程
    input  logic [TID_W-1:0] ctx_tid,         // 当前 task 线程号
    input  logic             ctx_last,        // 当前 task 是否线程最后一条
    input  logic [MUX_ROW_W-1:0] row,         // 同一行 MUX 指令
    input  logic [WIN_W-1:0]  win_out,        // EU 处理后的 64B 窗
    input  logic [15:0]       ccr_out,        // EU 写回的 16bit（8×2bit）
    input  logic [RF_W-1:0]   rf_rd,          // 该线程当前 RF（原值）
    input  logic [CSRB*8-1:0] csr_snap,       // 该线程 CSR（读 MUX_PTR）
    input  logic [KO_LO_W-1:0] ko_lo,         // 入口 KO 低 16B
    // ---- RF 回填 ----
    output logic             rf_we,
    output logic [TID_W-1:0] rf_tid,
    output logic [RF_W-1:0]  rf_wdata,
    // ---- CCR 回填（64bit 表 + 16bit 镜像）----
    output logic             ccr_we,
    output logic [TID_W-1:0] ccr_tid,
    output logic [CCR_W-1:0] ccr_wdata,
    output logic [15:0]      ccr_mirror,
    // ---- 出口 KO（DMUX 直出）----
    output logic             out_vld,
    output logic [383:0]     out_data,
    output logic [TID_W-1:0] out_tid
);
    logic             task_go;
    logic [15:0]      main_val [N_INS];   // 主链逆 lane 后的数据（slot k）
    logic [15:0]      main_msk [N_INS];   // 主链逆 lane 后的有效位掩码
    logic [15:0]      o_val    [O_INS];   // O 链逆 lane 后的数据（slot k）
    logic [15:0]      o_msk    [O_INS];   // O 链逆 lane 后的有效位掩码
    logic [O_WIN_W-1:0] o_next;           // 本 task 生成的 32B O 窗

    assign task_go = eu_done && (eu_done_tid == ctx_tid);

    // ---- 主链/O 链的 lane 逆变换（高 8 / 高 4 槽；其余直通）----
    always_comb begin
        for (int k = 0; k < N_INS; k++) begin
            if (k < LANE_N) begin
                lane_rev(win_out[WIN_W-16*(k+1) +: 16],
                         row[MF_LANE_LSB + LANE_W*k +: LANE_W],
                         main_val[k], main_msk[k]);
            end else begin
                main_val[k] = win_out[WIN_W-16*(k+1) +: 16];
                main_msk[k] = 16'hFFFF;
            end
        end
        for (int k = 0; k < O_INS; k++) begin
            if (k < O_LANE_N) begin
                lane_rev(win_out[WIN_W-16*(k+1) +: 16],
                         row[MF_OLANE_LSB + LANE_W*k +: LANE_W],
                         o_val[k], o_msk[k]);
            end else begin
                o_val[k] = win_out[WIN_W-16*(k+1) +: 16];
                o_msk[k] = 16'hFFFF;
            end
        end
    end

    // ---- ① 主链 fetch deposit：slot k → RF[255-off]/RF[254-off] ----
    always_comb begin
        automatic logic [1:0]  mv;
        automatic logic [7:0]  of;
        automatic logic [15:0] msk;
        automatic int hi_idx, lo_idx;
        rf_wdata = rf_rd;
        for (int k = 0; k < N_INS; k++) begin
            mv = mux_mvld(row[MF_FET_LSB + INS_W*k +: INS_W]);
            of = mux_off(row[MF_FET_LSB + INS_W*k +: INS_W], csr_snap);
            if (mv != 2'd0) begin
                msk = main_msk[k];
                if (mv == 2'd1) msk &= 16'hFF00;
                hi_idx = 255 - int'(of);
                lo_idx = 254 - int'(of);
                rf_wdata[8*hi_idx +: 8] =
                    (rf_rd[8*hi_idx +: 8] & ~msk[15:8]) |
                    (main_val[k][15:8] & msk[15:8]);
                if ((mv == 2'd2 || mv == 2'd3) && (lo_idx >= 0))
                    rf_wdata[8*lo_idx +: 8] =
                        (rf_rd[8*lo_idx +: 8] & ~msk[7:0]) |
                        (main_val[k][7:0] & msk[7:0]);
            end
        end
    end

    // ---- ② CCR deposit：16bit → 64bit ----
    assign ccr_wdata  = ccr_deposit(ccr_out, row[MF_CCR_LSB +: CCR_INS_N*CCR_INS_W]);
    assign ccr_mirror = ccr_out;

    // ---- ③ O 链：slot k 为源，按 O 指令偏移 deposit 到 32B O 窗 ----
    always_comb begin
        automatic logic [1:0]  mv;
        automatic logic [7:0]  of;
        automatic logic [15:0] msk;
        automatic int hi_idx, lo_idx;
        o_next = '0;
        for (int k = 0; k < O_INS; k++) begin
            mv = mux_mvld(row[MF_OFET_LSB + INS_W*k +: INS_W]);
            of = mux_off(row[MF_OFET_LSB + INS_W*k +: INS_W], csr_snap);
            if ((mv != 2'd0) && (int'(of) < O_WIN_B)) begin
                msk = o_msk[k];
                if (mv == 2'd1) msk &= 16'hFF00;
                hi_idx = O_WIN_B - 1 - int'(of);
                lo_idx = O_WIN_B - 2 - int'(of);
                o_next[8*hi_idx +: 8] =
                    (o_next[8*hi_idx +: 8] & ~msk[15:8]) |
                    (o_val[k][15:8] & msk[15:8]);
                if ((mv == 2'd2 || mv == 2'd3) && (lo_idx >= 0))
                    o_next[8*lo_idx +: 8] =
                        (o_next[8*lo_idx +: 8] & ~msk[7:0]) |
                        (o_val[k][7:0] & msk[7:0]);
            end
        end
    end

    // ---- 写使能 / 出口 ----
    assign rf_we   = task_go;
    assign rf_tid  = ctx_tid;
    assign ccr_we  = task_go;
    assign ccr_tid = ctx_tid;
    assign out_vld = task_go && ctx_last;
    assign out_data= {o_next, ko_lo};
    assign out_tid = ctx_tid;
endmodule
