// ============================================================================
// POE 平台（DUT 侧 / RM 侧各一份，端口完全一样）
//
//   KO 48B + csr 预发射口（同一个 driver 在顶层广播给两份）
//        |
//        v
//   poe_thr_pool（多线程池）：建线程 → 按 CUR_TS 取 ts 行 → 逐条 burst 发 task(sub_pc)
//        |
//        v
//   poe_mux（RF 取数）：按 sub_pc 读 MUX 指令行 → 从该线程 256B RF 取数组 64B 窗口
//        |                                   ^  读 MUX_PTR(CSR 0x16)
//        v                                   |
//   poe_eu_dut / poe_eu_rm（共享一份）—— 64B 窗口进，64B 结果出 + CSR 写（CCR/TH_STAT…）
//        |                                   |
//        +--> 结果按同一行 MUX 指令反向散射回 RF（bank）
//        |
//        +-- 出口 KO（DA/SA 对调）+ ts_done/thr_done 事件 + 两张表快照（供比对）
//
// IS_RM=0 → 用 poe_eu_dut（真实 EU 的替换点）；IS_RM=1 → 用 poe_eu_rm（参考模型）
// 两侧完全对称：同一个 KO 进两次，各自跑自己的线程/CSR/RF，谁也看不到谁。
// ============================================================================
module poe_platform #(
    parameter bit IS_RM  = 1'b0,   // 0 = 本平台用 poe_eu_dut（DUT 侧）；1 = 用 poe_eu_rm（RM 侧）
    parameter int N_THR  = 64,     // 线程数：CSR/RF 表的份数（tid 0..N_THR-1）
    parameter int TID_W  = 6,      // 线程号位宽；N_THR=64 → 6bit
    parameter int RF_W   = 2048,   // 每线程 RF 表位宽；256B = 64 槽 × 32bit
    parameter int WIN_W  = 512,    // 送 EU 的操作数窗口位宽；64B
    parameter int TS_MAX = 16,     // 宏指令存储行数（一行 = 一个 ts），即最长程序
    parameter int TS_W   = 4,      // ts 行号位宽；TS_MAX=16 → 4bit
    parameter int N_BURST= 8       // 一个 ts 最多几条 burst（宏指令存储一行能放 8 条）
) (
    input  logic             clk,             // 1GHz 时钟
    input  logic             rst_n,           // 低有效异步复位
    // ---- 激励：KO 报文 ----
    input  logic             ko_vld,          // 入口 KO 有效（一个 KO = 一个线程）
    output logic             ko_rdy,          // 平台能否收：线程池有空闲槽
    input  logic [383:0]     ko_data,         // 48B 报文：行1 DA/DP/SA/SP/TYPE/PRI/SN/B-E-LBO；行2 POE_HEAD(程序基址)+MEM_HEAD
    // ---- 激励：csr 预发射口（KO 建线程拍预写 CW 窗低 4 表项；每拍 ≤1，无握手）----
    input  logic             pre_vld,         // 预发射口有效（建线程拍）
    input  logic [TID_W-1:0] pre_thid,        // 预写哪个线程的 CW 窗
    input  logic [PRE_N-1:0] pre_strb,        // 每个表项一位（低 4 项）
    input  logic [PRE_N*CW_W-1:0] pre_data,   // 表项 e = pre_data[e*CW_W +: CW_W]
    // ---- 预载：EU 内两级微指令 bank ----
    input  logic             imem_we,         // 微指令 bank 写使能
    input  logic [0:0]       imem_saddr,      // 选哪一级 bank：0=s0，1=s1
    input  logic [3:0]       imem_waddr,      // 行号 = sub_pc 的低 4bit
    input  logic [63:0]      imem_wdata,      // 一行内容：{lane0 指令, lane1 指令}
    // ---- 预载：MUX 指令存储 ----
    input  logic             mux_imem_we,     // MUX 指令存储写使能
    input  logic [MUX_AW-1:0] mux_imem_waddr, // 行号 = sub_pc
    input  logic [MUX_ROW_W-1:0] mux_imem_wdata, // 一行 = 32 条 × 11bit
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
    output logic [3:0]       err_out,         // EU 回传的按线程错误标志
    output logic             eu_err_vld,      // EU 错误标志有效拍（= EU 结果拍）
    output logic [TID_W-1:0] eu_err_tid,      // 错误属于哪个线程
    // ---- 两张表（观测/比对用，扁平化：按 tid 切片）----
    output logic [N_THR*RF_W-1:0] rf_flat,    // 每线程 RF：tid*RF_W +: RF_W
    output logic [N_THR*CSRB*8-1:0] csr_flat, // 每线程 CSR 全表（按字节）：tid*CSRB*8 +: CSRB*8
    output logic [N_THR*32-1:0]   ccr_flat,   // 每线程 CCR（= EU 的 mstatus 低 16bit）：tid*32 +: 16
    output logic [N_THR*8-1:0]    th_stat_flat, // 每线程 TH_STAT：tid*8 +: 8
    output logic [N_THR*8-1:0]    cur_ts_flat   // 每线程 CUR_TS（程序指针）：tid*8 +: 8
);
    // ---- 宏指令存储（= burst 存储）----
    logic [N_THR*TS_W-1:0]     rd_ts_flat;   // 每线程取指行号（池组合输出）
    logic [N_THR*TD_ROW_W-1:0] row_flat;     // 每线程当拍取回的整行

    // ---- 线程池 ↔ MUX / bank ----
    logic             alloc;                 // 建线程脉冲
    logic [TID_W-1:0] alloc_tid;             // 建到哪个槽
    logic [15:0]      alloc_base_ts;         // 程序基址（写 CSR 0xc PC_INTER）
    logic             csr_we;                // 线程侧 CSR 写使能（当前只写 CUR_TS）
    logic [TID_W-1:0] csr_wtid;              // CSR 写哪个线程
    logic [6:0]       csr_waddr;             // CSR 字节地址
    logic [2:0]       csr_ww;                // CSR 写位宽码
    logic [383:0]     csr_wdata;             // CSR 写数据
    logic             task_vld;              // 池发出的 task 有效
    logic [TID_W-1:0] task_tid;              // task 属于哪个线程
    logic [3:0]       task_sub_pc;           // 微指令行号（= MUX 指令行号）
    logic             task_last;             // 本 task 是该线程最后一条
    logic             task_rdy;              // MUX 能否收（回池）
    logic             mux_task_done;         // MUX 完成一条 task（RF 已回写）
    logic [TID_W-1:0] mux_task_done_tid;     // 完成属于哪个线程

    // ---- MUX ---- 
    logic [MUX_AW-1:0]    mux_rd_addr;       // MUX 指令行号
    logic [MUX_ROW_W-1:0] mux_row;           // MUX 指令行
    logic [TID_W-1:0]     mux_rf_rd_tid;     // MUX 要读哪个线程的 RF
    logic [RF_W-1:0]      mux_rf_rd;         // 该线程整份 RF
    logic                 mux_rf_we;         // MUX 回写 RF（一拍）
    logic [TID_W-1:0]     mux_rf_tid;        // 回写哪个线程
    logic [RF_W-1:0]      mux_rf_wdata;      // 回写后的整份 RF
    logic [TID_W-1:0]     mux_csr_rtid;      // MUX 要读哪个线程的 CSR
    logic [WIN_W-1:0]     mux_win_data;      // 组好的 64B 窗口
    logic                 mux_win_vld;       // 窗口有效
    logic [TID_W-1:0]     mux_win_tid;       // 窗口属于哪个线程
    logic [3:0]           mux_win_sub_pc;    // 微指令行号
    logic                 mux_win_last;      // 本 task 是线程最后一条
    logic                 mux_win_rdy;       // EU 能否收窗口

    // ---- EU ----
    logic             eu_done;               // EU 结果有效
    logic [TID_W-1:0] eu_done_tid;           // 结果属于哪个线程
    logic [WIN_W-1:0] eu_win_out;            // EU 处理后的 64B 窗口
    logic             eu_csr_we;             // EU 侧 POE CSR 写（通用口）
    logic [TID_W-1:0] eu_csr_wtid;           //   写哪个线程
    logic [6:0]       eu_csr_waddr;          //   写地址
    logic [2:0]       eu_csr_ww;             //   写位宽码
    logic [383:0]     eu_csr_wdata;          //   写数据

    logic [N_THR*CSRB*8-1:0] csr_flat_w;     // CSR 全表（按字节），来自 poe_thread_bank

    // ---- 宏指令存储（只读 ROM；每线程一个组合读口）----
    poe_burst_imem #(
        .N_THR (N_THR),    // 读口数 = 线程数
        .TS_MAX(TS_MAX),   // 行数（最长程序）
        .TS_W  (TS_W)      // ts 行号位宽
    ) u_burst_imem (
        .rd_ts_flat(rd_ts_flat),   // 每线程取指行号 = 程序基址 + CUR_TS
        .row_flat  (row_flat)      // 每线程当拍返回的整行
    );

    // ---- 线程池：建线程 / 取指 / 发 task / 出口 KO ----
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
        .task_last       (task_last),
        .task_rdy        (task_rdy),          // 由 MUX 给
        .eu_done         (mux_task_done),     // 一条 task 真正做完（RF 已回写）
        .eu_done_tid     (mux_task_done_tid),
        .th_stat_flat    (th_stat_flat),      // 线程结束由 EU 写 TH_STAT，池子只读
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

    // ---- 每线程一份 CSR + RF ----
    poe_thread_bank #(.N_THR(N_THR), .TID_W(TID_W), .RF_W(RF_W)) u_bank (
        .clk(clk),
        .rst_n(rst_n),
        .alloc(alloc),
        .alloc_tid(alloc_tid),
        .alloc_base_ts(alloc_base_ts),
        .mux_rf_we(mux_rf_we),          // MUX 回写整份 RF
        .mux_rf_tid(mux_rf_tid),
        .mux_rf_wdata(mux_rf_wdata),
        .eu_csr_we(eu_csr_we),          // EU 侧 CSR 写（CCR/MUX_PTR/TH_STAT 都走这里）
        .eu_csr_wtid(eu_csr_wtid),
        .eu_csr_waddr(eu_csr_waddr),
        .eu_csr_ww(eu_csr_ww),
        .eu_csr_wdata(eu_csr_wdata),
        .pre_we(pre_vld),               // 预发射口：建线程拍预写 CW 窗低 4 表项
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
        .rf_rd_tid(mux_rf_rd_tid),      // MUX 读整份 RF
        .rf_rd(mux_rf_rd),
        .rf_flat(rf_flat),
        .csr_flat(csr_flat_w)
    );

    // ---- MUX 指令存储（TB/test 预载，与微指令画像配套）----
    poe_mux_imem #(
        .ROWS (TS_MAX),     // 行数与 EU 微指令 bank 对齐
        .AW   (MUX_AW),     // 行号位宽
        .ROW_W(MUX_ROW_W)   // 32×11bit
    ) u_mux_imem (
        .clk     (clk),
        .rd_addr (mux_rd_addr),
        .rd_row  (mux_row),
        .we      (mux_imem_we),
        .waddr   (mux_imem_waddr),
        .wdata   (mux_imem_wdata)
    );

    // ---- MUX：RF 取数 + 反向散射回写 ----
    poe_mux #(
        .TID_W(TID_W), .RF_W(RF_W), .WIN_W(WIN_W)
    ) u_mux (
        .clk           (clk),
        .rst_n         (rst_n),
        .task_vld      (task_vld),
        .task_tid      (task_tid),
        .task_sub_pc   (task_sub_pc),
        .task_last     (task_last),
        .task_rdy      (task_rdy),
        .mux_rd_addr   (mux_rd_addr),
        .mux_row       (mux_row),
        .rf_rd_tid     (mux_rf_rd_tid),
        .rf_rd         (mux_rf_rd),
        .mux_rf_we     (mux_rf_we),
        .mux_rf_tid    (mux_rf_tid),
        .mux_rf_wdata  (mux_rf_wdata),
        .csr_rtid      (mux_csr_rtid),
        .csr_snap      (csr_flat_w[mux_csr_rtid*CSRB*8 +: CSRB*8]),
        .win_vld       (mux_win_vld),
        .win_tid       (mux_win_tid),
        .win_sub_pc    (mux_win_sub_pc),
        .win_last      (mux_win_last),
        .win_data      (mux_win_data),
        .win_rdy       (mux_win_rdy),
        .eu_done       (eu_done),
        .eu_done_tid   (eu_done_tid),
        .win_out       (eu_win_out),
        .task_done     (mux_task_done),
        .task_done_tid (mux_task_done_tid)
    );

    // CSR 全表直出到端口（验证侧按地址表切）；另外切出 ccr/th_stat/cur_ts 三个常用字段
    assign csr_flat = csr_flat_w;
    // EU 的错误标志随结果波前同拍有效（契约见 poe_eu_rm 文件头）
    assign eu_err_vld = eu_done;
    assign eu_err_tid = eu_done_tid;
    always_comb begin
        for (int t = 0; t < N_THR; t++) begin
            // 小端：低字节在低地址（0x2 CCR / 0xa TH_STAT / 0xf CUR_TS）
            ccr_flat[t*32 +: 16]   = {csr_flat_w[(t*CSRB + int'(A_CCR) + 1)*8 +: 8],
                                      csr_flat_w[(t*CSRB + int'(A_CCR))*8 +: 8]};
            th_stat_flat[t*8 +: 8] = csr_flat_w[(t*CSRB + int'(A_TH_STAT))*8 +: 8];
            cur_ts_flat[t*8 +: 8]  = csr_flat_w[(t*CSRB + int'(A_CUR_TS))*8 +: 8];
        end
    end

    // ---- 一份共享 EU（DUT 或 RM；端口契约相同）----
    generate
        if (IS_RM) begin : g_rm
            poe_eu_rm #(.WIN_W(WIN_W), .TID_W(TID_W)) u_eu (
                .clk(clk),
                .rst_n(rst_n),
                .task_vld(mux_win_vld),
                .task_tid(mux_win_tid),
                .task_sub_pc(mux_win_sub_pc),
                .task_last(mux_win_last),
                .task_rdy(mux_win_rdy),
                .win_in(mux_win_data),
                .win_out(eu_win_out),
                .win_we(),
                .csr_snap(csr_flat_w[mux_win_tid*CSRB*8 +: CSRB*8]),
                .csr_we(eu_csr_we),
                .csr_wtid(eu_csr_wtid),
                .csr_waddr(eu_csr_waddr),
                .csr_ww(eu_csr_ww),
                .csr_wdata(eu_csr_wdata),
                .err_out(err_out),
                .done(eu_done),
                .done_tid(eu_done_tid),
                .imem_we(imem_we),
                .imem_saddr(imem_saddr),
                .imem_waddr(imem_waddr),
                .imem_wdata(imem_wdata)
            );
        end else begin : g_dut
            poe_eu_dut #(.WIN_W(WIN_W), .TID_W(TID_W)) u_eu (
                .clk(clk),
                .rst_n(rst_n),
                .task_vld(mux_win_vld),
                .task_tid(mux_win_tid),
                .task_sub_pc(mux_win_sub_pc),
                .task_last(mux_win_last),
                .task_rdy(mux_win_rdy),
                .win_in(mux_win_data),
                .win_out(eu_win_out),
                .win_we(),
                .csr_snap(csr_flat_w[mux_win_tid*CSRB*8 +: CSRB*8]),
                .csr_we(eu_csr_we),
                .csr_wtid(eu_csr_wtid),
                .csr_waddr(eu_csr_waddr),
                .csr_ww(eu_csr_ww),
                .csr_wdata(eu_csr_wdata),
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
