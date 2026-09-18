// ============================================================================
// POE 平台（DUT 侧 / RM 侧各一份，端口完全一样）
//
//   KO+pre_read 激励（同一个 driver 在顶层广播给两份）
//        |            \
//        v             v
//   poe_thr_pool（多线程池）取 ts 行 → 逐条 burst 发 task（sub_pc）→ **一份共享 EU**（所有线程共用）
//        |                                        |
//        +-- poe_thread_bank（每线程一份 CSR + RF）--+
//        |
//        +-- 出口 KO（DA/SA 对调）+ ts_done/thr_done 事件 + 两张表快照（供比对）
//
// IS_RM=0 → 平台内是 poe_eu_dut（真实 EU 的替换点，控制流来源）
// IS_RM=1 → 平台内是 poe_eu_rm （参考模型，只回刷自己的表供比对）
// 两侧完全对称：同一个 KO 进两次，各自跑自己的线程/CSR/RF，谁也看不到谁。
// ============================================================================
module poe_platform #(
    parameter bit IS_RM  = 1'b0,   // 0 = 本平台用 poe_eu_dut（DUT 侧）；1 = 用 poe_eu_rm（RM 侧）
    parameter int N_THR  = 64,     // 线程数：CSR/RF 表的份数（tid 0..N_THR-1）
    parameter int TID_W  = 6,      // 线程号位宽；N_THR=64 → 6bit
    parameter int RF_W   = 2048,   // 每线程 RF 表位宽；256B = 64 槽 × 32bit
    parameter int EU_RF_W = 1024,  // 送/收 EU 的 RF 视图（示例 EU 128B；接真实 256B EU 时 = RF_W）
    parameter int TS_MAX = 16,     // 宏指令存储行数（一行 = 一个 ts），即最长程序
    parameter int TS_W   = 4,      // ts 行号位宽；TS_MAX=16 → 4bit
    parameter int N_BURST= 8       // 一个 ts 最多几条 burst（宏指令存储一行能放 8 条）
) (
    input  logic             clk,             // 1GHz 时钟
    input  logic             rst_n,           // 低有效异步复位
    // ---- 激励：KO 报文 ----
    input  logic             ko_vld,          // 入口 KO 有效（一个 KO = 一个线程）
    output logic             ko_rdy,          // 平台能否收：线程状态机 IDLE
    input  logic [383:0]     ko_data,         // 48B 报文：行1 DA/DP/SA/SP/TYPE/PRI/SN/B-E-LBO；行2 POE_HEAD(程序基址)+MEM_HEAD
    // ---- 激励：csr 预发射口（KO 建线程拍预写 CW 窗低 4 表项；每拍 ≤1，无握手）----
    //   1bit vld + 线程号 + 4bit 表项掩码 + 4×44bit 数据；与 KO 同拍进入。
    input  logic             pre_vld,         // 预发射口有效（建线程拍）
    input  logic [TID_W-1:0] pre_thid,        // 预写哪个线程的 CW 窗
    input  logic [PRE_N-1:0] pre_strb,        // 每个表项一位（低 4 项）
    input  logic [PRE_N*CW_W-1:0] pre_data,   // 表项 e = pre_data[e*CW_W +: CW_W]
    // ---- 微指令存储预载（两级 bank 在 EU 内部）----
    input  logic             imem_we,         // 微指令 bank 写使能
    input  logic [0:0]       imem_saddr,      // 选哪一级 bank：0=s0（x0..x15），1=s1（x8..x31）
    input  logic [3:0]       imem_waddr,      // 行号 = sub_pc 的低 4bit
    input  logic [63:0]      imem_wdata,      // 一行内容：{lane0 指令, lane1 指令}
    // ---- 出口 KO（线程结束后由回刷逻辑给出）----
    output logic             out_vld,         // 出口 KO 有效（一拍）
    output logic [383:0]     out_data,        // 出口 48B 报文
    output logic [TID_W-1:0] out_tid,         // 出口 KO 属于哪个线程
    // ---- 事件（供 UVM monitor / checker 采样）----
    output logic             ts_done_vld,     // 一个 ts 的 burst 全部完成（校验点，一拍）
    output logic [TID_W-1:0] ts_done_tid,     // 该事件属于哪个线程
    output logic [TS_W-1:0]  ts_done_idx,     // 刚结束的 ts 序号（0 起）
    output logic             thr_done_vld,    // 线程结束（TH_STAT=DONE，一拍）
    output logic [TID_W-1:0] thr_done_tid,    // 结束的线程号
    output logic             busy,            // 平台上还有线程在跑
    output logic [7:0]       ct_skip_cnt,     // 被跳过的 c_task 条数（本版 c_task 未实现）
    output logic [3:0]       err_out,         // EU 回传的按线程错误标志（跨级冲突/越界写）
    // ---- 两张表（观测/比对用，扁平化：按 tid 切片）----
    output logic [N_THR*RF_W-1:0] rf_flat,    // 每线程 RF：tid*RF_W +: RF_W
    output logic [N_THR*72*8-1:0] csr_flat,   // 每线程 CSR 全表（按字节）：tid*576 +: 576
    output logic [N_THR*32-1:0]   ccr_flat,   // 每线程 CCR（= EU 的 mstatus 低 16bit）：tid*32 +: 16
    output logic [N_THR*8-1:0]    th_stat_flat, // 每线程 TH_STAT：tid*8 +: 8
    output logic [N_THR*8-1:0]    cur_ts_flat   // 每线程 CUR_TS（程序指针）：tid*8 +: 8
);
    logic [N_THR*TS_W-1:0]     rd_ts_flat;   // 每线程取指行号（池组合输出）
    logic [N_THR*TD_ROW_W-1:0] row_flat;     // 每线程当拍取回的整行（存储组合输出）
    logic             alloc;                 // 建线程脉冲
    logic [TID_W-1:0] alloc_tid;             // 建到哪个槽
    logic [15:0]      alloc_base_ts;         // 程序基址（写 CSR 0xc PC_INTER）
    logic             csr_we;                // 线程侧 CSR 写使能
    logic [TID_W-1:0] csr_wtid;              // CSR 写哪个线程
    logic [6:0]       csr_waddr;             // CSR 字节地址
    logic [2:0]       csr_ww;                // CSR 写位宽码
    logic [383:0]     csr_wdata;             // CSR 写数据
    logic             task_vld;              // task 出口有效
    logic [TID_W-1:0] task_tid;              // task 属于哪个线程
    logic [3:0]       task_sub_pc;           // 微指令行号（EU 用它取一行微指令）
    logic             task_rdy;              // EU 能否收
    logic             eu_done;               // EU 完成脉冲
    logic [TID_W-1:0] eu_done_tid;           // 完成属于哪个线程
    logic [EU_RF_W-1:0] rf_rd, eu_rf_out;    // 送 EU 的 RF 视图 / EU 回刷的 RF 视图
    logic [127:0]     rmw_rd, eu_rmw_out;    // 送 EU 的 CSR / EU 回刷的 CSR
    logic [31:0]      eu_wo_out;             // EU 只写口（本版只计数）
    logic [0:0]       eu_wo_fwe;             // EU 只写使能

    // ---- 宏指令存储（= burst 存储，只读 ROM；每个线程一个组合读口）----
    poe_burst_imem #(
        .N_THR (N_THR),    // 读口数 = 线程数
        .TS_MAX(TS_MAX),   // 行数（最长程序）
        .TS_W  (TS_W)      // ts 行号位宽
    ) u_burst_imem (
        .rd_ts_flat(rd_ts_flat),   // 每线程取指行号 = 程序基址 + CUR_TS
        .row_flat  (row_flat)      // 每线程当拍返回的整行
    );

    // ---- 线程池：建线程 / 取指 / 发 task / 推进 CUR_TS / 出口 KO ----
    poe_thr_pool #(
        .N_THR  (N_THR),    // 线程槽位数
        .TID_W  (TID_W),    // 线程号位宽
        .TS_W   (TS_W),     // ts 行号位宽
        .N_BURST(N_BURST)   // 每 ts 最多 burst 数
    ) u_thr (
        .clk             (clk),
        .rst_n           (rst_n),
        .ko_vld          (ko_vld),
        .ko_rdy          (ko_rdy),
        .ko_data         (ko_data),
        .rd_ts_flat      (rd_ts_flat),
        .row_flat        (row_flat),
        .alloc           (alloc),
        .alloc_tid       (alloc_tid),
        .alloc_base_ts   (alloc_base_ts),
        .csr_we          (csr_we),
        .csr_wtid        (csr_wtid),
        .csr_waddr       (csr_waddr),
        .csr_ww          (csr_ww),
        .csr_wdata       (csr_wdata),
        .task_vld        (task_vld),
        .task_tid        (task_tid),
        .task_sub_pc     (task_sub_pc),
        .task_rdy        (task_rdy),
        .eu_done         (eu_done),
        .eu_done_tid     (eu_done_tid),
        .out_vld         (out_vld),
        .out_data        (out_data),
        .out_tid         (out_tid),
        .out_rdy         (1'b1),   // 出口 KO 当拍交给 monitor/checker，视为已被取走
        .ts_done_vld     (ts_done_vld),
        .ts_done_tid     (ts_done_tid),
        .ts_done_idx     (ts_done_idx),
        .thr_done_vld    (thr_done_vld),
        .thr_done_tid    (thr_done_tid),
        .busy            (busy),
        .active_cnt      (),       // 活跃线程数只在池级冒烟里用，平台用 busy 就够
        .ct_skip_cnt     (ct_skip_cnt)
    );

    logic [63:0] ro_regs_w;   // 只读 CSR 组 {mcycle,minstret}（本版给 0），两侧 EU 共用
    logic [N_THR*72*8-1:0] csr_flat_w;   // CSR 全表（按字节），来自 poe_thread_bank

    // ---- 每线程一份 CSR + RF（EU 是所有线程共享的一份，见下）----
    poe_thread_bank #(.N_THR(N_THR), .TID_W(TID_W), .RF_W(RF_W), .EU_RF_W(EU_RF_W)) u_bank (
        .clk(clk),
        .rst_n(rst_n),
        .alloc(alloc),
        .alloc_tid(alloc_tid),
        .alloc_base_ts(alloc_base_ts),
        .eu_done(eu_done),
        .eu_done_tid(eu_done_tid),
        .eu_rf_out(eu_rf_out),
        .eu_rmw_out(eu_rmw_out),
        .eu_wo_fwe(eu_wo_fwe),
        .pre_we(pre_vld),          // 预发射口：与 KO 同拍，预写 CW 窗低 4 表项
        .pre_tid(pre_thid),
        .pre_strb(pre_strb),
        .pre_data(pre_data),
        .csr_we(csr_we),
        .csr_wtid(csr_wtid),
        .csr_waddr(csr_waddr),
        .csr_ww(csr_ww),
        .csr_wdata(csr_wdata),
        .csr_rtid('0),
        .csr_raddr(7'd0),
        .csr_rw(3'd0),
        .csr_rdata(),
        .eu_rd_tid(task_tid),
        .rf_rdata(rf_rd),
        .rmw_rdata(rmw_rd),
        .ro_regs(ro_regs_w),
        .rf_flat(rf_flat),
        .csr_flat(csr_flat_w)
    );

    // CSR 全表直出到端口（验证侧按地址表切）；另外切出 ccr/th_stat/cur_ts 三个常用字段
    // 供 RTL 自检检查器与 TB 使用。
    assign csr_flat = csr_flat_w;
    always_comb begin
        for (int t = 0; t < N_THR; t++) begin
            // 小端：低字节在低地址（0x2 CCR / 0x9 TH_STAT / 0xe CUR_TS）
            ccr_flat[t*32 +: 16]   = {csr_flat_w[(t*72 + 3)*8 +: 8],
                                      csr_flat_w[(t*72 + 2)*8 +: 8]};
            th_stat_flat[t*8 +: 8] = csr_flat_w[(t*72 + 9)*8 +: 8];
            cur_ts_flat[t*8 +: 8]  = csr_flat_w[(t*72 + 14)*8 +: 8];
        end
    end

    // ---- 一份共享 EU（DUT 或 RM；端口契约相同）----
    generate
        if (IS_RM) begin : g_rm
            poe_eu_rm #(.RF_W(EU_RF_W), .TID_W(TID_W)) u_eu (
                .clk(clk),
                .rst_n(rst_n),
                .task_vld(task_vld),
                .task_tid(task_tid),
                .task_sub_pc(task_sub_pc),
                .task_rdy(task_rdy),
                .rf_in(rf_rd),
                .rf_out(eu_rf_out),
                .rf_we(),
                .rmw_in(rmw_rd),
                .rmw_out(eu_rmw_out),
                .ro_regs(ro_regs_w),
                .wo_out(eu_wo_out),
                .wo_fwe(eu_wo_fwe),
                .err_out(err_out),
                .done(eu_done),
                .done_tid(eu_done_tid),
                .imem_we(imem_we),
                .imem_saddr(imem_saddr),
                .imem_waddr(imem_waddr),
                .imem_wdata(imem_wdata)
            );
        end else begin : g_dut
            poe_eu_dut #(.RF_W(EU_RF_W), .TID_W(TID_W)) u_eu (
                .clk(clk),
                .rst_n(rst_n),
                .task_vld(task_vld),
                .task_tid(task_tid),
                .task_sub_pc(task_sub_pc),
                .task_rdy(task_rdy),
                .rf_in(rf_rd),
                .rf_out(eu_rf_out),
                .rf_we(),
                .rmw_in(rmw_rd),
                .rmw_out(eu_rmw_out),
                .ro_regs(ro_regs_w),
                .wo_out(eu_wo_out),
                .wo_fwe(eu_wo_fwe),
                .err_out(err_out),
                .done(eu_done),
                .done_tid(eu_done_tid),
                .imem_we(imem_we),
                .imem_saddr(imem_saddr),
                .imem_waddr(imem_waddr),
                .imem_wdata(imem_wdata)
            );
        end
    endgenerate
endmodule
