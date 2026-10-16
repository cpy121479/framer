// ============================================================================
// pool_smoke_tb —— 线程池多线程冒烟（池级，不依赖平台 / EU 外壳）
//
// 验什么：
//   ① 槽位分配：6 个 KO → tid 0..5（每拍只受理一个，取最小空闲槽）
//   ② 优先级调度：先扣住 EU（task_rdy=0）让 6 个线程全部就位，再放行；
//      观察发射顺序 = 每个发射点都取 (pri 最小, 同 pri age 最小)
//   ③ 不抢占：假 EU 一条 task 占用 EU_LAT 拍，占用期间不再收新 task
//   ④ 多 ts：每线程跑 2 个 ts（ts0 + 跳转落点 ts3）→ 共 4 条 task
//   ⑤ 出口 KO：由（假）DMUX 直出（真平台里是 DMUX 用 O 窗再生）；池子收"已发出 + 已取走"
//      两个信息后才释放槽位，且出口 KO 的低 16B 原样保持入口 KO 的低 16B
//
// 期望顺序（确定性）：严格优先级 + 不抢占 ⇒ 高优先级线程只要有下一条 task 要发，
//   就在每个发射点压住低优先级线程；两个线程的 done 相差 1 拍时，发射序列会交错：
//     tid5/3（pri 0/1）16 条 → tid1/4（pri 3，老 1 先）8 条 → tid0/2（pri 5/7）8 条
//   同 pri 的 tid1(age1)/tid4(age4)：第一个发射点是 tid1 先，之后两者交错。
//
// 程序镜像用 poe_burst_imem 内部初始化（每线程例化一份 = 组合多读口）：
//   ts0：2 条 i/v burst（br=0）
//   ts1：br=1（被阻塞；占位实现直接跳到 jump_target=3）
//   ts3：2 条 i/v burst + is_last
// ============================================================================
`timescale 1ns/1ps
module pool_smoke_tb;
    import poe_pkg::*;

    localparam int N_THR   = 8;    // 冒烟用 8 个线程槽（够看清调度）
    localparam int TID_W   = 3;    // 线程号位宽
    localparam int TS_W    = 4;    // ts 行号位宽
    localparam int N_BURST = 8;    // 每 ts 最多 burst 数
    localparam int N_KO    = 6;    // 冒烟 KO 数
    localparam int N_TASK_PER_THR = 4;   // ts0 两条 + ts3 两条
    localparam int EU_LAT  = 12;   // 假 EU 一条 task 占用的拍数
    localparam int TASK_TOTAL = N_KO * N_TASK_PER_THR;
    localparam int TS_DONE_TOTAL = N_KO * 2;   // 每线程 2 个 ts 边界

    logic clk;
    logic rst_n = 1'b0;
    initial clk = 1'b0;
    always #0.5ns clk = ~clk;

    // ========================================================================
    // 池接口
    // ========================================================================
    logic                  ko_vld = 1'b0;          // 入口 KO 有效
    logic                  ko_rdy;                 // 池有空闲槽
    logic [383:0]          ko_data = '0;           // 48B KO 报文
    logic [N_THR*TS_W-1:0] rd_ts_flat;             // 每线程取指行号
    logic [N_THR*TD_ROW_W-1:0] row_flat;           // 每线程当拍取回的整行
    logic                  alloc;                  // 建线程脉冲
    logic [TID_W-1:0]      alloc_tid;              // 建到哪个槽
    logic [15:0]           alloc_base_ts;          // 程序基址（写 CSR 0xc PC_INTER）
    logic                  csr_we;                 // 线程侧 CSR 写使能
    logic [TID_W-1:0]      csr_wtid;               // CSR 写哪个线程
    logic [6:0]            csr_waddr;              // CSR 字节地址
    logic [2:0]            csr_ww;                 // CSR 写位宽码
    logic [383:0]          csr_wdata;              // CSR 写数据
    logic                  task_vld;               // task 出口有效
    logic [TID_W-1:0]      task_tid;               // task 属于哪个线程
    logic [3:0]            task_sub_pc;            // 微指令行号（示例 EU 只吃 4bit）
    logic                  task_last;              // 本 task 是该线程最后一条
    logic                  task_rdy;               // 假 EU 能否收
    logic                  eu_done;                // 假 EU 完成脉冲
    logic [TID_W-1:0]      eu_done_tid;            // 完成 pulse 属于哪个线程
    logic [N_THR*8-1:0]    th_stat_flat;           // 每线程 TH_STAT（假 EU 代写，池子只读）
    // 出口 KO 由 DMUX 直出（本冒烟用"假 DMUX"在结果拍给一拍脉冲）；池子只收"已发出/已取走"
    logic                  ko_sent_vld;            // 出口 KO 已发出（假 DMUX 给）
    logic [TID_W-1:0]      ko_sent_tid;            // 属于哪个线程
    logic                  out_rdy = 1'b1;         // 冒烟里下游一直能收
    logic [N_THR*KO_LO_W-1:0] ko_lo_flat;          // 入口 KO 低 16B（每线程一份，给 DMUX 再生 KO）
    logic                  ts_done_vld;            // 一个 ts 结束（单拍）
    logic [TID_W-1:0]      ts_done_tid;            // 哪个线程
    logic [TS_W-1:0]       ts_done_idx;            // 第几个 ts
    logic                  thr_done_vld;           // 线程结束（单拍）
    logic [TID_W-1:0]      thr_done_tid;           // 哪个线程
    logic                  busy;                   // 还有线程在跑
    logic [6:0]            active_cnt;             // 活跃线程数
    logic [7:0]            ct_skip_cnt;            // 跳过的 c_task 数

    poe_thr_pool #(
        .N_THR  (N_THR),    // 线程槽位数
        .TID_W  (TID_W),    // 线程号位宽
        .TS_W   (TS_W),     // ts 行号位宽
        .N_BURST(N_BURST)   // 每 ts 最多 burst 数
    ) u_pool (
        .clk             (clk),             // 1GHz 时钟
        .rst_n           (rst_n),           // 低有效异步复位
        .ko_vld          (ko_vld),          // 入口 KO 有效
        .ko_rdy          (ko_rdy),          // 池能否收
        .ko_data         (ko_data),         // 48B KO 报文
        .rd_ts_flat      (rd_ts_flat),      // 每线程取指行号（组合）
        .row_flat        (row_flat),        // 每线程取回整行（组合）
        .alloc           (alloc),           // 建线程脉冲
        .alloc_tid       (alloc_tid),       // 建到哪个槽
        .alloc_base_ts   (alloc_base_ts),   // 程序基址
        .csr_we          (csr_we),          // CSR 写使能
        .csr_wtid        (csr_wtid),        // CSR 写线程号
        .csr_waddr       (csr_waddr),       // CSR 写地址
        .csr_ww          (csr_ww),          // CSR 写位宽码
        .csr_wdata       (csr_wdata),       // CSR 写数据
        .task_vld        (task_vld),        // task 出口有效
        .task_tid        (task_tid),        // task 属于哪个线程
        .task_sub_pc     (task_sub_pc),     // 微指令行号
        .task_last       (task_last),       // 本 task 是该线程最后一条
        .task_rdy        (task_rdy),        // 假 EU 能否收
        .eu_done         (eu_done),         // 假 EU 完成
        .eu_done_tid     (eu_done_tid),     // 完成属于哪个线程
        .th_stat_flat    (th_stat_flat),    // 线程结束状态（EU 写，池子读）
        .ko_sent_vld     (ko_sent_vld),     // 出口 KO 已发出（由 DMUX 直出，池子只收事件）
        .ko_sent_tid     (ko_sent_tid),     // 属于哪个线程
        .out_rdy         (out_rdy),         // 下游能否收
        .ko_lo_flat      (ko_lo_flat),      // 入口 KO 低 16B（出口 KO 原样保持那部分）
        .ts_done_vld     (ts_done_vld),     // ts 结束脉冲
        .ts_done_tid     (ts_done_tid),     // ts 事件线程号
        .ts_done_idx     (ts_done_idx),     // ts 事件序号
        .thr_done_vld    (thr_done_vld),    // 线程结束脉冲
        .thr_done_tid    (thr_done_tid),    // 结束的线程号
        .busy            (busy),            // 还有线程在跑
        .active_cnt      (active_cnt),      // 活跃线程数
        .ct_skip_cnt     (ct_skip_cnt)      // 跳过的 c_task 数
    );

    // ========================================================================
    // 宏指令存储：一个模块 + 每个线程一个组合读口（行为模型的多读口取指）
    // ========================================================================
    poe_burst_imem #(
        .N_THR (N_THR),   // 读口数 = 线程槽位数
        .TS_MAX(16),      // 行数 = 一个线程最多 16 个 ts
        .TS_W  (TS_W)     // 行号位宽
    ) u_mem (
        .rd_ts_flat(rd_ts_flat),   // 每线程取指行号
        .row_flat  (row_flat)      // 每线程当拍返回的整行
    );

    // ========================================================================
    // 假 EU：所有线程共用，一条 task 占用 EU_LAT 拍，占满期间不收新 task
    // ========================================================================
    logic             eu_ready = 1'b0;   // 激励放行前一直扣住 EU
    logic             eu_busy;
    logic [TID_W-1:0] eu_tid;
    logic [4:0]       eu_cnt;
    logic             eu_done_r;
    logic             eu_last;            // 当前占用的这条 task 是不是线程最后一条
    logic [7:0]       th_stat_q [N_THR];  // 模拟 CSR 0xa：EU 写完，池子读

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            eu_busy   <= 1'b0;
            eu_tid    <= '0;
            eu_cnt    <= '0;
            eu_done_r <= 1'b0;
            eu_last   <= 1'b0;
            for (int t = 0; t < N_THR; t++) th_stat_q[t] <= 8'h01;   // 建线程后 RUN
        end else begin
            eu_done_r <= 1'b0;                      // 完成是单拍脉冲
            if (!eu_busy) begin
                if (task_vld && task_rdy) begin     // 收下一条 task
                    eu_busy <= 1'b1;
                    eu_tid  <= task_tid;
                    eu_last <= task_last;
                    eu_cnt  <= '0;
                end
            end else if (eu_cnt == EU_LAT-1) begin  // 占用期满 → 回 done
                eu_busy   <= 1'b0;
                eu_done_r <= 1'b1;
                if (eu_last) th_stat_q[eu_tid] <= TH_DONE;   // 末条 task：模拟 EU 写 TH_STAT=DONE
            end else begin
                eu_cnt <= eu_cnt + 5'd1;
            end
        end
    end

    always_comb
        for (int t = 0; t < N_THR; t++)
            th_stat_flat[t*8 +: 8] = th_stat_q[t];

    assign task_rdy    = eu_ready && !eu_busy;   // 假 EU 一次只收一条
    assign eu_done     = eu_done_r;
    assign eu_done_tid = eu_tid;

    // ---- 假 DMUX：结果拍 + 末条 task → 出口 KO 直出（一拍脉冲），与真实 DMUX 同拍 ----
    //   真实 DMUX 的出口 KO = { O 窗 32B, 入口 KO 低 16B }；本冒烟只关心"事件 + 低 16B 原样"，
    //   高 32B 用入口报文的低 32B 凑数（内容不在本模块的检查范围内）。
    logic [383:0] out_data_r;
    assign ko_sent_vld = eu_done_r && eu_last;
    assign ko_sent_tid = eu_tid;
    assign out_data_r  = {ko_lo_flat[eu_tid*KO_LO_W +: KO_LO_W],
                          ko_lo_flat[eu_tid*KO_LO_W +: KO_LO_W]};

    // ========================================================================
    // 激励：每拍一个 KO，全部就位后再放行 EU
    // ========================================================================
    logic [2:0] pri_in = '0;             // 当前 send_ko 的 PRI
    logic [2:0] pri_of_tid [N_THR];      // 每个槽的 PRI（alloc 时锁存）
    logic [KO_LO_W-1:0] ko_lo_of_tid [N_THR];  // 每个槽的入口 KO 低 16B（alloc 时锁存）
    logic [7:0] n_alloc;                 // 已建线程数

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            n_alloc <= '0;
        end else if (alloc) begin
            pri_of_tid[alloc_tid] <= pri_in;                       // 记住这个槽的优先级
            ko_lo_of_tid[alloc_tid] <= ko_data[KO_LO_LSB +: KO_LO_W];  // 记住入口 KO 低 16B
            n_alloc               <= n_alloc + 8'd1;
        end
    end

    task automatic send_ko(input logic [2:0] pri, input logic [7:0] da);
        logic [383:0] d;
        wait (ko_rdy);                  // 有空闲槽才发
        @(negedge clk);                 // 低电平驱动，避开 posedge 竞争
        d = '0;
        d[KO_DA_LSB +: 8]   = da;       // 行1 DA
        d[KO_SA_LSB +: 8]   = 8'hB2;    // 行1 SA
        d[KO_PRI_LSB +: 3]  = pri;      // 行1 PRI（0 最高）
        d[KO_HEAD_LSB +: 8] = 8'd0;     // 行2 POE_HEAD = 程序基址 0（低 8bit 即可）
        pri_in  = pri;
        ko_data = d;
        ko_vld  = 1'b1;
        @(negedge clk);                 // 中间跨过一个 posedge：池已受理
        ko_vld  = 1'b0;
    endtask

    // ========================================================================
    // 观测
    // ========================================================================
    logic [TID_W-1:0] got_order [TASK_TOTAL];   // 全部 task 的 tid 发射顺序
    logic             ko_lo_ok;           // 出口 KO 低 16B 是否原样保持入口值
    int n_task, n_tsdone, n_thrdone, n_out;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            n_task <= 0; n_tsdone <= 0; n_thrdone <= 0; n_out <= 0;
            ko_lo_ok <= 1'b1;
        end else begin
            if (task_vld && task_rdy) begin
                if (n_task < TASK_TOTAL) got_order[n_task] <= task_tid;
                $display("TASK      #%0d tid=%0d pri=%0d sub_pc=%0d @%0t",
                         n_task, task_tid, pri_of_tid[task_tid], task_sub_pc, $time);
                n_task <= n_task + 1;
            end
            if (ts_done_vld) begin
                $display("TS_DONE   tid=%0d idx=%0d @%0t", ts_done_tid, ts_done_idx, $time);
                n_tsdone <= n_tsdone + 1;
            end
            if (thr_done_vld) begin
                $display("THR_DONE  tid=%0d @%0t", thr_done_tid, $time);
                n_thrdone <= n_thrdone + 1;
            end
            // 出口 KO 由（假）DMUX 直出：池子只看"已发出"事件
            if (ko_sent_vld) begin
                $display("OUT_KO    tid=%0d @%0t", ko_sent_tid, $time);
                n_out <= n_out + 1;
                if (out_data_r[KO_LO_LSB +: KO_LO_W] !== ko_lo_of_tid[ko_sent_tid]) ko_lo_ok <= 1'b0;
            end
        end
    end

    // ========================================================================
    // 主流程
    // ========================================================================
    int      i;
    logic    ok;
    logic [TID_W-1:0] exp_order [TASK_TOTAL];

    initial begin
        // pri0/1 两组把 EU 占住；同 pri 的老线程先拿到第一个发射点，之后两者交错
        exp_order = '{3'd5, 3'd3, 3'd5, 3'd3, 3'd5, 3'd3, 3'd5, 3'd3,
                      3'd1, 3'd4, 3'd1, 3'd4, 3'd1, 3'd4, 3'd1, 3'd4,
                      3'd0, 3'd2, 3'd0, 3'd2, 3'd0, 3'd2, 3'd0, 3'd2};

        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        // KO0..KO5 的 PRI 依次 5/3/7/1/3/0 → tid0..tid5；全部就位后再放行 EU
        send_ko(3'd5, 8'h10);
        send_ko(3'd3, 8'h11);
        send_ko(3'd7, 8'h12);
        send_ko(3'd1, 8'h13);
        send_ko(3'd3, 8'h14);
        send_ko(3'd0, 8'h15);
        wait (n_alloc == N_KO);

        @(negedge clk);
        eu_ready = 1'b1;                    // 6 个线程已就位 → 开始按优先级发射

        wait (n_thrdone == N_KO);           // 等所有线程跑完
        repeat (4) @(posedge clk);

        ok = (n_task     == TASK_TOTAL)     &&
             (n_tsdone   == TS_DONE_TOTAL)  &&
             (n_thrdone  == N_KO)           &&
             (n_out      == N_KO)           &&
             (ct_skip_cnt == 8'd0)          &&
             (busy == 1'b0) && (active_cnt == 7'd0) &&   // 所有槽都已释放（KO 取走后）
             ko_lo_ok;
        for (i = 0; i < TASK_TOTAL; i++)
            if (got_order[i] !== exp_order[i]) ok = 1'b0;

        if (ok) begin
            $display("POOL_SMOKE_PASS  task=%0d ts_done=%0d thr_done=%0d out_ko=%0d ct_skip=%0d",
                     n_task, n_tsdone, n_thrdone, n_out, ct_skip_cnt);
            $finish;
        end else begin
            $display("POOL_SMOKE_FAIL  task=%0d ts_done=%0d thr_done=%0d out_ko=%0d ct_skip=%0d ko_lo_ok=%0b busy=%0b",
                     n_task, n_tsdone, n_thrdone, n_out, ct_skip_cnt, ko_lo_ok, busy);
            for (i = 0; i < TASK_TOTAL; i++)
                $display("  got_order[%0d]=%0d expected=%0d", i, got_order[i], exp_order[i]);
            $fatal(1, "pool smoke failed");
        end
    end

    // 超时保护：正常约 300 拍，20 万拍足够
    initial begin
        #200000;
        $display("POOL_SMOKE_TIMEOUT busy=%0b active=%0d n_task=%0d n_thrdone=%0d",
                 busy, active_cnt, n_task, n_thrdone);
        $fatal(1, "pool smoke timeout");
    end
endmodule
