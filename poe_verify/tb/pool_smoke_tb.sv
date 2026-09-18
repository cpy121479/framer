// ============================================================================
// pool_smoke_tb —— 线程池多线程冒烟（池级，不依赖平台 / EU 外壳）
//
// 验什么：
//   ① 槽位分配：6 个 KO → tid 0..5（每拍只受理一个，取最小空闲槽）
//   ② 优先级调度：先扣住 EU（task_rdy=0）让 6 个线程全部就位，再放行；
//      观察发射顺序 = 每个发射点都取 (pri 最小, 同 pri age 最小)
//   ③ 不抢占：假 EU 一条 task 占用 EU_LAT 拍，占用期间不再收新 task
//   ④ 多 ts：每线程跑 2 个 ts（ts0 + 跳转落点 ts3）→ 共 4 条 task
//   ⑤ 出口 KO：DA/SA 对调，且每条线程的出口 KO 都能对回自己的入口 KO
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
    logic                  task_rdy;               // 假 EU 能否收
    logic                  eu_done;                // 假 EU 完成脉冲
    logic [TID_W-1:0]      eu_done_tid;            // 完成 pulse 属于哪个线程
    logic                  out_vld;                // 出口 KO 有效
    logic [383:0]          out_data;               // 出口 48B 报文
    logic [TID_W-1:0]      out_tid;                // 出口 KO 属于哪个线程
    logic                  out_rdy = 1'b1;         // 冒烟里下游一直能收
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
        .task_rdy        (task_rdy),        // 假 EU 能否收
        .eu_done         (eu_done),         // 假 EU 完成
        .eu_done_tid     (eu_done_tid),     // 完成属于哪个线程
        .out_vld         (out_vld),         // 出口 KO 有效
        .out_data        (out_data),        // 出口报文
        .out_tid         (out_tid),         // 出口 KO 线程号
        .out_rdy         (out_rdy),         // 下游能否收
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

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            eu_busy   <= 1'b0;
            eu_tid    <= '0;
            eu_cnt    <= '0;
            eu_done_r <= 1'b0;
        end else begin
            eu_done_r <= 1'b0;                      // 完成是单拍脉冲
            if (!eu_busy) begin
                if (task_vld && task_rdy) begin     // 收下一条 task
                    eu_busy <= 1'b1;
                    eu_tid  <= task_tid;
                    eu_cnt  <= '0;
                end
            end else if (eu_cnt == EU_LAT-1) begin  // 占用期满 → 回 done
                eu_busy   <= 1'b0;
                eu_done_r <= 1'b1;
            end else begin
                eu_cnt <= eu_cnt + 5'd1;
            end
        end
    end

    assign task_rdy    = eu_ready && !eu_busy;   // 假 EU 一次只收一条
    assign eu_done     = eu_done_r;
    assign eu_done_tid = eu_tid;

    // ========================================================================
    // 激励：每拍一个 KO，全部就位后再放行 EU
    // ========================================================================
    logic [2:0] pri_in = '0;             // 当前 send_ko 的 PRI
    logic [2:0] pri_of_tid [N_THR];      // 每个槽的 PRI（alloc 时锁存）
    logic [7:0] da_of_tid  [N_THR];      // 每个槽的入口 DA（alloc 时锁存）
    logic [7:0] sa_of_tid  [N_THR];      // 每个槽的入口 SA（alloc 时锁存）
    logic [7:0] n_alloc;                 // 已建线程数

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            n_alloc <= '0;
        end else if (alloc) begin
            pri_of_tid[alloc_tid] <= pri_in;                       // 记住这个槽的优先级
            da_of_tid[alloc_tid]  <= ko_data[KO_DA_LSB +: 8];      // 记住入口 DA
            sa_of_tid[alloc_tid]  <= ko_data[KO_SA_LSB +: 8];      // 记住入口 SA
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
    logic             da_sa_ok;           // 出口 KO 的 DA/SA 对调检查
    int n_task, n_tsdone, n_thrdone, n_out;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            n_task <= 0; n_tsdone <= 0; n_thrdone <= 0; n_out <= 0;
            da_sa_ok <= 1'b1;
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
            if (out_vld && out_rdy) begin
                $display("OUT_KO    tid=%0d @%0t", out_tid, $time);
                n_out <= n_out + 1;
                if (out_data[KO_DA_LSB +: 8] !== sa_of_tid[out_tid]) da_sa_ok <= 1'b0;
                if (out_data[KO_SA_LSB +: 8] !== da_of_tid[out_tid]) da_sa_ok <= 1'b0;
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
             da_sa_ok;
        for (i = 0; i < TASK_TOTAL; i++)
            if (got_order[i] !== exp_order[i]) ok = 1'b0;

        if (ok) begin
            $display("POOL_SMOKE_PASS  task=%0d ts_done=%0d thr_done=%0d out_ko=%0d ct_skip=%0d",
                     n_task, n_tsdone, n_thrdone, n_out, ct_skip_cnt);
            $finish;
        end else begin
            $display("POOL_SMOKE_FAIL  task=%0d ts_done=%0d thr_done=%0d out_ko=%0d ct_skip=%0d da_sa_ok=%0b",
                     n_task, n_tsdone, n_thrdone, n_out, ct_skip_cnt, da_sa_ok);
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
