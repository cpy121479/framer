// ============================================================================
// 精简版 EU 功能验证平台 —— 顶层（RTL 自检版，不开 UVM 的 30 秒冒烟）
//
//                ko（KO 48B）+ pre_read（随路，只透传不消费）
//                        |（同一个激励，广播给两个平台）
//          +-------------+-------------+
//          v                           v
//   poe_platform(IS_RM=0)       poe_platform(IS_RM=1)
//   thr_pool + 每线程CSR/RF +    thr_pool + 每线程CSR/RF +
//   poe_eu_dut（共享一份）        poe_eu_rm（共享一份，RM）
//          |                           |
//          +--------> poe_checker <----+   ts 粒度：RF 逐槽 + CCR；出口 KO：DUT vs RM
//
// 两份平台完全对称、互不可见；DUT 侧输出才是被验对象，RM 侧只提供期望值。
// burst 指令存储是 ROM（poe_burst_imem 内部 initial 拼镜像），微指令 bank 仍需预载（在 EU 内部）。
// ============================================================================
module poe_verify_top #(
    parameter int N_THR  = 8,      // 线程数
    parameter int TID_W  = 3,      // 线程号位宽
    parameter int RF_W   = 2048,   // 每线程 RF 表位宽（256B = 64 槽 × 32bit）
    parameter int TS_MAX = 16,     // burst 指令存储行数（最长程序）
    parameter int TS_W   = 4,      // ts 行号位宽
    parameter int N_BURST= 8       // 每 ts 最多 burst 数
) (
    input  logic             clk,             // 时钟
    input  logic             rst_n,           // 低有效异步复位
    // ---- 激励：KO 报文 + csr 预发射口 ----
    input  logic             ko_vld,          // 入口 KO 有效
    output logic             ko_rdy,          // 两侧平台都 ready 才为 1
    input  logic [383:0]     ko_data,         // 48B 报文
    input  logic             pre_vld,         // csr 预发射口有效（KO 建线程拍）
    input  logic [TID_W-1:0] pre_thid,        // 预写哪个线程的 CW 窗
    input  logic [PRE_N-1:0] pre_strb,        // 4 个表项各自一位
    input  logic [PRE_N*CW_W-1:0] pre_data,   // 表项 e = pre_data[e*CW_W +: CW_W]
    // ---- 微指令预载（两级 bank 在 EU 内部；burst 存储是 ROM 不需要）----
    input  logic             imem_we,         // bank 写使能
    input  logic [0:0]       imem_saddr,      // 0=s0 1=s1
    input  logic [3:0]       imem_waddr,      // 行号 = sub_pc
    input  logic [63:0]      imem_wdata,      // 一行 = {lane0, lane1}
    // ---- MUX 指令存储预载（与微指令画像配套）----
    input  logic                 mux_imem_we,      // 写使能
    input  logic [MUX_AW-1:0]    mux_imem_waddr,   // 行号 = sub_pc
    input  logic [MUX_ROW_W-1:0] mux_imem_wdata,   // 一行 = 32 条 × 11bit
    // ---- DUT 出口 KO（被验对象）----
    output logic             out_vld,
    output logic [383:0]     out_data,
    output logic [TID_W-1:0] out_tid,
    // ---- DUT 事件 / 观测 ----
    output logic             ts_done_vld,     // ts 边界（校验点）
    output logic [TID_W-1:0] ts_done_tid,
    output logic [TS_W-1:0]  ts_done_idx,
    output logic             thr_done_vld,    // 线程结束
    output logic [TID_W-1:0] thr_done_tid,
    output logic             busy,            // 有线程在跑
    output logic [7:0]       ct_skip_cnt,     // 跳过的 c_task 条数
    output int               chk_cnt,         // 已完成的 ts 比对次数
    output int               err_chk,         // 已完成的 EU 错误标志检查次数
    output int               err_cnt,         // 累计错误数
    // ---- DUT 侧观测事件总线（ts_done 后一拍锁存；替代原来的全表快照）----
    output logic             obs_vld,         // 快照有效（一拍）
    output logic [TID_W-1:0] obs_tid,         // 属于哪个线程
    output logic [TS_W-1:0]  obs_ts,          // 对应哪个 ts
    output logic [RF_W-1:0]  obs_rf,          // 该线程整份 RF（256B）
    output logic [CSRB*8-1:0] obs_csr         // 该线程整份 CSR（90B）
);
    logic             ko_rdy_dut, ko_rdy_rm;   // 两侧各自 ready
    logic             out_vld_rm;              // RM 出口 KO 有效
    logic [383:0]     out_data_rm;             // RM 出口报文
    logic [TID_W-1:0] out_tid_rm;              // RM 出口线程号
    logic [3:0]       err_dut, err_rm;         // 两侧 EU 错误标志
    logic             err_vld_dut, err_vld_rm; // 两侧错误标志有效拍
    logic [TID_W-1:0] err_tid_dut, err_tid_rm; // 两侧错误标志对应线程
    logic [N_THR*8-1:0] th_stat_dut;           // DUT 侧 TH_STAT（线程结束自洽检查）
    logic             obs_vld_rm;              // RM 侧观测快照有效
    logic [TID_W-1:0] obs_tid_rm;              // RM 侧快照线程号
    logic [TS_W-1:0]  obs_ts_rm;               // RM 侧快照 ts
    logic [RF_W-1:0]  obs_rf_rm;               // RM 侧快照 RF
    logic [CSRB*8-1:0] obs_csr_rm;             // RM 侧快照 CSR

    // ---- DUT 平台：控制流来源；出口 KO / 事件是被验对象 ----
    poe_platform #(
        .IS_RM(1'b0), .N_THR(N_THR), .TID_W(TID_W), .RF_W(RF_W),
        .TS_MAX(TS_MAX), .TS_W(TS_W), .N_BURST(N_BURST)
    ) u_plat_dut (
        .clk(clk),
        .rst_n(rst_n),
        .ko_vld(ko_vld),
        .ko_rdy(ko_rdy_dut),
        .ko_data(ko_data),
        .pre_vld(pre_vld),                     // csr 预发射口：与 KO 一起广播给两侧
        .pre_thid(pre_thid),
        .pre_strb(pre_strb),
        .pre_data(pre_data),
        .imem_we(imem_we),
        .imem_saddr(imem_saddr),
        .imem_waddr(imem_waddr),
        .imem_wdata(imem_wdata),
        .mux_imem_we(mux_imem_we),             // MUX 指令存储预载
        .mux_imem_waddr(mux_imem_waddr),
        .mux_imem_wdata(mux_imem_wdata),
        .out_vld(out_vld),
        .out_data(out_data),
        .out_tid(out_tid),
        .ts_done_vld(ts_done_vld),
        .ts_done_tid(ts_done_tid),
        .ts_done_idx(ts_done_idx),
        .thr_done_vld(thr_done_vld),
        .thr_done_tid(thr_done_tid),
        .busy(busy),
        .ct_skip_cnt(ct_skip_cnt),
        .err_out(err_dut),
        .eu_err_vld(err_vld_dut),
        .eu_err_tid(err_tid_dut),
        .obs_vld(obs_vld),           // 观测事件总线（DUT 侧，ts_done 后一拍）
        .obs_tid(obs_tid),
        .obs_ts(obs_ts),
        .obs_rf(obs_rf),
        .obs_csr(obs_csr),
        .th_stat_flat(th_stat_dut)
    );

    // ---- RM 平台：同一个激励；只回刷自己的表 ----
    poe_platform #(
        .IS_RM(1'b1), .N_THR(N_THR), .TID_W(TID_W), .RF_W(RF_W),
        .TS_MAX(TS_MAX), .TS_W(TS_W), .N_BURST(N_BURST)
    ) u_plat_rm (
        .clk(clk),
        .rst_n(rst_n),
        .ko_vld(ko_vld),
        .ko_rdy(ko_rdy_rm),
        .ko_data(ko_data),
        .pre_vld(pre_vld),
        .pre_thid(pre_thid),
        .pre_strb(pre_strb),
        .pre_data(pre_data),
        .imem_we(imem_we),
        .imem_saddr(imem_saddr),
        .imem_waddr(imem_waddr),
        .imem_wdata(imem_wdata),
        .mux_imem_we(mux_imem_we),
        .mux_imem_waddr(mux_imem_waddr),
        .mux_imem_wdata(mux_imem_wdata),
        .out_vld(out_vld_rm),
        .out_data(out_data_rm),
        .out_tid(out_tid_rm),
        .ts_done_vld(),
        .ts_done_tid(),
        .ts_done_idx(),
        .thr_done_vld(),
        .thr_done_tid(),
        .busy(),
        .ct_skip_cnt(),
        .err_out(err_rm),
        .eu_err_vld(err_vld_rm),
        .eu_err_tid(err_tid_rm),
        .obs_vld(obs_vld_rm),        // RM 侧观测事件总线（给检查器做期望值）
        .obs_tid(obs_tid_rm),
        .obs_ts(obs_ts_rm),
        .obs_rf(obs_rf_rm),
        .obs_csr(obs_csr_rm),
        .th_stat_flat()
    );

    // 两侧都 ready 才算接受这个 KO（同一个 driver 广播，必须同时收）
    assign ko_rdy = ko_rdy_dut & ko_rdy_rm;

    // ---- 检查器：ts 粒度比两张表；出口 KO 比 DUT vs RM ----
    poe_checker #(.N_THR(N_THR), .TID_W(TID_W), .RF_W(RF_W)) u_chk (
        .clk(clk),
        .rst_n(rst_n),
        .obs_vld_dut(obs_vld),
        .obs_tid_dut(obs_tid),
        .obs_ts_dut(obs_ts),
        .obs_rf_dut(obs_rf),
        .obs_csr_dut(obs_csr),
        .obs_vld_rm(obs_vld_rm),
        .obs_tid_rm(obs_tid_rm),
        .obs_ts_rm(obs_ts_rm),
        .obs_rf_rm(obs_rf_rm),
        .obs_csr_rm(obs_csr_rm),
        .thr_done_vld(thr_done_vld),
        .thr_done_tid(thr_done_tid),
        .th_stat_dut(th_stat_dut),
        .err_vld_dut(err_vld_dut),                 // EU 错误标志（边界契约的一部分）
        .err_dut(err_dut),
        .err_tid_dut(err_tid_dut),
        .err_vld_rm(err_vld_rm),
        .err_rm(err_rm),
        .err_tid_rm(err_tid_rm),
        .ko_dut_vld(out_vld),
        .ko_dut_data(out_data),
        .ko_dut_tid(out_tid),
        .ko_rm_vld(out_vld_rm),
        .ko_rm_data(out_data_rm),
        .ko_rm_tid(out_tid_rm),
        .chk_cnt(chk_cnt),
        .err_chk(err_chk),
        .err_cnt(err_cnt)
    );
endmodule
