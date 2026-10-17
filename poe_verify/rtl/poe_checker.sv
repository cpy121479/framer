// ============================================================================
// 检查器：以 ts 为粒度比 DUT 与 RM（数据来自平台的**事件总线**）
//   · 平台在 ts_done 拍锁存"该线程"的 RF/CSR 快照（obs_vld 时有效，一拍）；
//     本模块在 obs_vld 拍比较：RF 整份（256B）、CSR 整份（90B，含 0x2 CCR 镜像与 CW 窗）；
//   · 两份平台严格锁步，所以同一事件必须同拍、同 tid、同 ts；
//   · 线程结束时顺带查 CSR 自洽（TH_STAT=DONE）；
//   · 出口 KO 是 DMUX 用 O 窗再生出来的结果：比 DUT vs RM；
//   · EU 错误标志随结果拍有效：DUT vs RM 一致，且本平台示例模型期望 0。
// ============================================================================
import poe_pkg::*;

module poe_checker #(
    parameter int N_THR = 8,      // 线程数
    parameter int TID_W = 3,      // 线程号位宽
    parameter int RF_W  = 2048,   // 每线程 RF 位宽（256B）
    parameter int CSRB  = poe_pkg::CSRB  // 每线程 CSR 字节数（90B）
) (
    input  logic clk,                          // 时钟
    input  logic rst_n,                        // 低有效异步复位
    // ---- DUT 侧事件快照（ts_done 后一拍，平台已锁存）----
    input  logic              obs_vld_dut,     // 快照有效（一拍）
    input  logic [TID_W-1:0]  obs_tid_dut,     // 快照属于哪个线程
    input  logic [3:0]        obs_ts_dut,      // 是哪个 ts
    input  logic [RF_W-1:0]   obs_rf_dut,      // 该线程整份 RF
    input  logic [CSRB*8-1:0] obs_csr_dut,     // 该线程整份 CSR
    // ---- RM 侧事件快照 ----
    input  logic              obs_vld_rm,      // 快照有效（应与 DUT 同拍）
    input  logic [TID_W-1:0]  obs_tid_rm,      // 快照属于哪个线程
    input  logic [3:0]        obs_ts_rm,       // 是哪个 ts
    input  logic [RF_W-1:0]   obs_rf_rm,       // 期望 RF
    input  logic [CSRB*8-1:0] obs_csr_rm,      // 期望 CSR
    // ---- 线程结束（DUT 侧事件）----
    input  logic              thr_done_vld,    // 线程结束（一拍）
    input  logic [TID_W-1:0]  thr_done_tid,    // 结束的线程号
    input  logic [N_THR*8-1:0] th_stat_dut,    // DUT 侧全表 TH_STAT（自洽检查）
    // ---- EU 错误标志（随结果拍有效）----
    input  logic              err_vld_dut,     // DUT 侧有效
    input  logic [3:0]        err_dut,         // DUT 侧错误标志
    input  logic [TID_W-1:0]  err_tid_dut,     // DUT 侧属于哪个线程
    input  logic              err_vld_rm,      // RM 侧有效
    input  logic [3:0]        err_rm,          // RM 侧错误标志
    input  logic [TID_W-1:0]  err_tid_rm,      // RM 侧属于哪个线程
    // ---- 出口 KO（DMUX 再生结果）----
    input  logic              ko_dut_vld,      // DUT 出口 KO 有效（一拍）
    input  logic [383:0]      ko_dut_data,     // DUT 出口 48B
    input  logic [TID_W-1:0]  ko_dut_tid,      // 属于哪个线程
    input  logic              ko_rm_vld,       // RM 出口 KO 有效
    input  logic [383:0]      ko_rm_data,      // 期望 48B
    input  logic [TID_W-1:0]  ko_rm_tid,       // 属于哪个线程
    // ---- 统计 ----
    output int chk_cnt,                        // 完成了几次 ts 比对
    output int err_chk,                        // 完成了几次 EU 错误标志检查
    output int err_cnt                         // 累计错误数
);
    logic             thr_vld;                 // 线程结束事件打一拍后检查
    logic [TID_W-1:0] thr_tid_q;
    // EU 错误标志 / 出口 KO 打一拍对齐后比（两侧同拍有效）
    logic             err_vld_r, err_vld_rm_r;
    logic [3:0]       err_dut_r, err_rm_r;
    logic [TID_W-1:0] err_tid_dut_r, err_tid_rm_r;
    logic             ko_vld, ko_rm_vld_r;
    logic [383:0]     ko_data_r, ko_rm_data_r;
    logic [TID_W-1:0] ko_tid_r, ko_rm_tid_r;
    int               chk_cnt_r, err_cnt_r, ko_cnt_r, ko_err_cnt, err_chk_r;

    assign chk_cnt = chk_cnt_r;
    assign err_chk = err_chk_r;
    assign err_cnt = err_cnt_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            thr_vld <= 1'b0;
            thr_tid_q <= '0;
            chk_cnt_r <= 0; err_cnt_r <= 0;
            ko_vld <= 1'b0; ko_rm_vld_r <= 1'b0; ko_cnt_r <= 0; ko_err_cnt <= 0;
            err_vld_r <= 1'b0; err_vld_rm_r <= 1'b0;
            err_dut_r <= '0; err_rm_r <= '0;
            err_tid_dut_r <= '0; err_tid_rm_r <= '0;
            err_chk_r <= 0;
        end else begin
            thr_vld <= thr_done_vld;
            thr_tid_q <= thr_done_tid;
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

            // ---- EU 错误标志：DUT vs RM 一致，且（示例模型）必须为 0 ----
            if (err_vld_r) begin
                err_chk_r <= err_chk_r + 1;
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

            // ---- ts 粒度：DUT/RM 事件快照逐份比较 ----
            if (obs_vld_dut) begin
                automatic int bad = 0;
                chk_cnt_r <= chk_cnt_r + 1;
                // 打一条 xorshift 便于肉眼对波形/日志
                begin
                    automatic logic [31:0] x = 32'd0;
                    for (int s = 0; s < RF_W/32; s++) x ^= obs_rf_dut[s*32 +: 32];
                    $display("TS_DONE tid=%0d ts=%0d rf_xor=%h", obs_tid_dut, obs_ts_dut, x);
                end
                // 两份平台严格锁步：同一事件必须同拍、同 tid、同 ts
                if (!obs_vld_rm || (obs_tid_dut !== obs_tid_rm) || (obs_ts_dut !== obs_ts_rm)) begin
                    bad++;
                    $display("  CHK_ERR obs 事件不配对：dut(vld=%b tid=%0d ts=%0d) rm(vld=%b tid=%0d ts=%0d)",
                             obs_vld_dut, obs_tid_dut, obs_ts_dut,
                             obs_vld_rm, obs_tid_rm, obs_ts_rm);
                end
                // RF：逐 32bit 槽比
                for (int s = 0; s < RF_W/32; s++)
                    if (obs_rf_dut[s*32 +: 32] !== obs_rf_rm[s*32 +: 32]) bad++;
                // CSR：整份按字节比（0x2 的 CCR 镜像、CW 窗都在里面）
                if (obs_csr_dut !== obs_csr_rm) begin
                    automatic int csr_bad = 0;
                    for (int b = 0; b < CSRB; b++)
                        if (obs_csr_dut[b*8 +: 8] !== obs_csr_rm[b*8 +: 8]) csr_bad++;
                    bad++;
                    $display("  CHK ts=%0d tid=%0d CSR 不符（%0d 字节；0x2 CCR dut=%h rm=%h）",
                             obs_ts_dut, obs_tid_dut, csr_bad,
                             obs_csr_dut[8*int'(A_CCR) +: 16],
                             obs_csr_rm[8*int'(A_CCR) +: 16]);
                end
                if (bad != 0) begin
                    err_cnt_r <= err_cnt_r + 1;
                    $display("CHK_ERR ts=%0d tid=%0d 表不符 %0d 槽/字节", obs_ts_dut, obs_tid_dut, bad);
                end
            end

            // ---- 线程结束：CSR 自洽（TH_STAT=DONE）----
            if (thr_vld) begin
                if (th_stat_dut[thr_tid_q*8 +: 8] !== TH_DONE) begin
                    err_cnt_r <= err_cnt_r + 1;
                    $display("CHK_ERR tid=%0d 线程结束但 TH_STAT=%h（期望 %h）",
                             thr_tid_q, th_stat_dut[thr_tid_q*8 +: 8], TH_DONE);
                end
            end

            // ---- 出口 KO：DUT vs RM（DMUX 再生结果）----
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
