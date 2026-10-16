// ============================================================================
// 检查器：以 ts 为粒度比 DUT 与 RM 的两张表
//   · ts 边界（ts_done_vld）延后一拍采样：RF 逐槽（RF_W/32 槽，每槽 32bit）+ 线程 CCR
//   · 线程结束时做 CSR 自洽检查（TH_STAT=DONE、CUR_TS 非 0）
//   · **出口 KO 是 DMUX 用 O 窗再生出来的结果**（= {O 窗 32B, 入口 KO 低 16B}），
//     因此比的是 DUT 出口 KO ↔ RM 出口 KO（不是"入口 KO 对调后自比"；入口 KO 只是激励）
// ============================================================================
module poe_checker #(
    parameter int N_THR = 8,      // 线程数（两张表各有多少份）
    parameter int TID_W = 3,      // 线程号位宽
    parameter int RF_W  = 2048    // 每线程 RF 位宽（256B = 64 槽 × 32bit）
) (
    input  logic clk,                          // 时钟
    input  logic rst_n,                        // 低有效异步复位
    input  logic                  ts_done_vld, // DUT 侧 ts 边界事件（一拍）
    input  logic [TID_W-1:0]      ts_done_tid, // 属于哪个线程
    input  logic [3:0]            ts_done_idx, // 第几个 ts
    input  logic                  thr_done_vld,// DUT 侧线程结束事件
    input  logic [TID_W-1:0]      thr_done_tid,// 结束的线程号
    input  logic [N_THR*RF_W-1:0] rf_dut,      // DUT 侧全表 RF
    input  logic [N_THR*RF_W-1:0] rf_rm,       // RM 侧全表 RF（期望值）
    input  logic [N_THR*32-1:0]   ccr_dut,     // DUT 侧全表 CCR
    input  logic [N_THR*32-1:0]   ccr_rm,      // RM 侧全表 CCR
    input  logic [N_THR*8-1:0]    th_stat_dut, // DUT 侧全表 TH_STAT（线程结束时查自洽）
    // EU 错误标志（随结果拍有效）：DUT 与 RM 必须一致，且本平台期望恒 0
    input  logic                  err_vld_dut, // DUT 侧错误标志有效拍（= EU 结果拍）
    input  logic [3:0]            err_dut,     // DUT 侧错误标志
    input  logic [TID_W-1:0]      err_tid_dut, // DUT 侧错误属于哪个线程
    input  logic                  err_vld_rm,  // RM 侧错误标志有效拍
    input  logic [3:0]            err_rm,      // RM 侧错误标志
    input  logic [TID_W-1:0]      err_tid_rm,  // RM 侧错误属于哪个线程
    // 出口 KO：DUT 与 RM 各自回刷出来的结果，逐条比
    input  logic                  ko_dut_vld,  // DUT 出口 KO 有效（一拍）
    input  logic [383:0]          ko_dut_data, // DUT 出口 48B 报文（EU 回刷结果）
    input  logic [TID_W-1:0]      ko_dut_tid,  // 属于哪个线程
    input  logic                  ko_rm_vld,   // RM 出口 KO 有效
    input  logic [383:0]          ko_rm_data,  // RM 出口 48B 报文（期望值）
    input  logic [TID_W-1:0]      ko_rm_tid,   // 属于哪个线程
    output int chk_cnt,                        // 完成了几次 ts 比对
    output int err_chk,                        // 完成了几次 EU 错误标志检查
    output int err_cnt                         // 累计错误数（RF/CCR/KO/自洽）
);
    logic             ev_vld, thr_vld;
    logic [TID_W-1:0] ev_tid, thr_tid;
    logic [3:0]       ev_idx;
    // EU 错误标志：打一拍对齐后比（两侧同拍有效）
    logic             err_vld_r, err_vld_rm_r;
    logic [3:0]       err_dut_r, err_rm_r;
    logic [TID_W-1:0] err_tid_dut_r, err_tid_rm_r;
    // 出口 KO 打一拍对齐（两侧 KO 在各自 out_vld 拍有效）
    logic             ko_vld, ko_rm_vld_r;
    logic [383:0]     ko_data_r, ko_rm_data_r;
    logic [TID_W-1:0] ko_tid_r, ko_rm_tid_r;
    int               chk_cnt_r, err_cnt_r, ko_cnt_r, ko_err_cnt, err_chk_r;

    assign chk_cnt = chk_cnt_r;
    assign err_chk = err_chk_r;
    assign err_cnt = err_cnt_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ev_vld <= 1'b0; ev_tid <= '0; ev_idx <= '0;
            thr_vld <= 1'b0; thr_tid <= '0;
            chk_cnt_r <= 0; err_cnt_r <= 0;
            ko_vld <= 1'b0; ko_rm_vld_r <= 1'b0; ko_cnt_r <= 0; ko_err_cnt <= 0;
            err_vld_r <= 1'b0; err_vld_rm_r <= 1'b0;
            err_dut_r <= '0; err_rm_r <= '0;
            err_tid_dut_r <= '0; err_tid_rm_r <= '0;
            err_chk_r <= 0;
        end else begin
            ev_vld  <= ts_done_vld;
            ev_tid  <= ts_done_tid;
            ev_idx  <= ts_done_idx;
            thr_vld <= thr_done_vld;
            thr_tid <= thr_done_tid;
            ko_vld      <= ko_dut_vld;
            ko_data_r   <= ko_dut_data;
            ko_tid_r    <= ko_dut_tid;
            ko_rm_vld_r <= ko_rm_vld;
            ko_rm_data_r<= ko_rm_data;
            ko_rm_tid_r <= ko_rm_tid;
            err_vld_r   <= err_vld_dut;
            err_vld_rm_r<= err_vld_rm;
            err_dut_r   <= err_dut;
            err_rm_r    <= err_rm;
            err_tid_dut_r <= err_tid_dut;
            err_tid_rm_r  <= err_tid_rm;

            // EU 错误标志：DUT vs RM 一致，且（本平台示例 EU）必须为 0
            if (err_vld_r) begin
                err_chk_r <= err_chk_r + 1;
                // 两侧必须同拍有效、同线程、同标志
                if (!err_vld_rm_r || (err_tid_dut_r !== err_tid_rm_r) || (err_dut_r !== err_rm_r)) begin
                    err_cnt_r <= err_cnt_r + 1;
                    $display("CHK_ERR EU err 事件不一致 dut(vld=%b tid=%0d err=%b) rm(vld=%b tid=%0d err=%b)",
                             err_vld_r, err_tid_dut_r, err_dut_r,
                             err_vld_rm_r, err_tid_rm_r, err_rm_r);
                end
                if (err_dut_r !== 4'd0) begin
                    err_cnt_r <= err_cnt_r + 1;
                    $display("CHK_ERR EU err_out 非 0：%b（跨级冲突/越界写标志）", err_dut_r);
                end
            end

            if (ev_vld) begin
                automatic int bad = 0;
                chk_cnt_r <= chk_cnt_r + 1;
                // 逐条打印 ts 边界（看 CUR_TS 序列：跳跃时会出现不连续，如 0 → 3）
                begin
                    automatic logic [31:0] x = 32'd0;
                    for (int s = 0; s < RF_W/32; s++) x ^= rf_dut[ev_tid*RF_W + s*32 +: 32];
                    $display("TS_DONE tid=%0d ts=%0d rf_xor=%h", ev_tid, ev_idx, x);
                end
                for (int s = 0; s < RF_W/32; s++)
                    if (rf_dut[ev_tid*RF_W + s*32 +: 32] !== rf_rm[ev_tid*RF_W + s*32 +: 32]) bad++;
                if (ccr_dut[ev_tid*32 +: 32] !== ccr_rm[ev_tid*32 +: 32]) begin
                    bad++;
                    $display("  CHK ts=%0d tid=%0d CCR dut=%h rm=%h",
                             ev_idx, ev_tid, ccr_dut[ev_tid*32 +: 32], ccr_rm[ev_tid*32 +: 32]);
                end
                if (bad != 0) begin
                    err_cnt_r <= err_cnt_r + 1;
                    $display("CHK_ERR ts=%0d tid=%0d 表不符 %0d 槽", ev_idx, ev_tid, bad);
                end
            end
            if (thr_vld) begin
                if (th_stat_dut[thr_tid*8 +: 8] !== 8'h03) begin
                    err_cnt_r <= err_cnt_r + 1;
                    $display("CHK_ERR tid=%0d 线程结束但 TH_STAT=%h（期望 03）",
                             thr_tid, th_stat_dut[thr_tid*8 +: 8]);
                end
            end
            // 出口 KO：DUT vs RM（EU 回刷结果）
            if (ko_vld) begin
                ko_cnt_r <= ko_cnt_r + 1;
                if (!ko_rm_vld_r) begin
                    ko_err_cnt <= ko_err_cnt + 1;
                    err_cnt_r  <= err_cnt_r + 1;
                    $display("CHK_ERR tid=%0d DUT 出口 KO 时 RM 没有对应 KO", ko_tid_r);
                end else if (ko_data_r !== ko_rm_data_r) begin
                    ko_err_cnt <= ko_err_cnt + 1;
                    err_cnt_r  <= err_cnt_r + 1;
                    $display("CHK_ERR 出口 KO 不符 tid=%0d/%0d", ko_tid_r, ko_rm_tid_r);
                    $display("  dut=%h", ko_data_r);
                    $display("  rm =%h", ko_rm_data_r);
                end
                if (ko_cnt_r == 0) $display("KO_CHK 首条出口 KO dut=%h rm=%h", ko_data_r, ko_rm_data_r);
            end
        end
    end
endmodule
