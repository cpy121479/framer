// ============================================================================
// poe_thr_pool —— 多线程线程池（v1）
//
// 需求（已确认）：
//   · 不抢占：正在跑的线程不被打断，只在"下一个发射点"按规则重选
//   · 最多 N_THR=64 个线程同时活跃（TID_W=6）
//   · 调度：pri 小优先（= KO 报文行1 的 PRI，0 最高）；同级取 age 最小（最老）
//   · 出口 KO 被真正取走（out_rdy）后才释放线程槽
//
// 结构（三块）：
//   ① per-thread 状态数组：t_st / t_cur / t_bid / t_pri / t_age / t_ko ...
//   ② 一套共享资源仲裁：每拍只服务**一个请求**（RQ_TASK / RQ_CSR / RQ_EVENT / RQ_KO），
//      所有请求统一按 (pri, age) 排序 —— 而不是每种资源各写一套仲裁
//   ③ "每个状态产生什么请求"的 case（T_ISS 发 task、T_TSEND 发 ts_done+写 CUR_TS ...）
//
// 取指：行为模型，多读口组合读（row_flat 每线程一拍返回整行），因此没有取指状态、
//       也不需要每线程取指缓存。真实 RTL 若 ROM 端口受限，只需改 poe_burst_imem。
//
// CUR_TS：t_cur 是线程引擎的取指指针（唯一权威），同拍镜像写 CSR 0xe 供校验/观测；
//         bank 只存副本，不回读，因此这里没有"取指绕一圈 CSR 再回来"的延迟。
//         末 ts 不再推进：线程结束时 CUR_TS 停在最后一个 ts（不写 t_cur+1）。
// 事件：ts_done / thr_done 只在被服务的下一拍各拉高**一拍**，避免仲裁排队时重复计数。
//
// 占位（接真实 EU 后替换，平台其它部分不动）：
//   · br=1 的 ts 阻塞后"总是跳"，跳转落点取自镜像行的 jump_target 字段
//   · c_task（bt=1）不发 EU，直接跳过并计数（等 SMC 通路）
//   注意：跳转落点那一行的头 burst 必须是 br=0，否则会再次阻塞（占位实现的限制）
// ============================================================================
import poe_pkg::*;

module poe_thr_pool #(
    parameter int N_THR  = 64,   // 同时活跃线程数上限
    parameter int TID_W  = 6,    // 线程号位宽
    parameter int TS_W   = 4,    // ts 行号位宽
    parameter int N_BURST= 8     // 每 ts 最多 burst 数
) (
    input  logic             clk,
    input  logic             rst_n,
    // ---- KO 入口（一个 KO = 一个线程）----
    input  logic             ko_vld,
    output logic             ko_rdy,
    input  logic [383:0]     ko_data,
    // ---- 取指：每线程一个组合读口 ----
    output logic [N_THR*TS_W-1:0] rd_ts_flat,   // 每线程取指行号 = base_ts + cur_ts
    input  logic [N_THR*TD_ROW_W-1:0] row_flat, // 每线程当拍拿到的整行（256bit/线程）
    // ---- 建线程（bank 的专用 alloc 通路）----
    output logic             alloc,
    output logic [TID_W-1:0] alloc_tid,
    output logic [15:0]      alloc_base_ts,
    // ---- CSR 写口（单口）----
    output logic             csr_we,
    output logic [TID_W-1:0] csr_wtid,
    output logic [6:0]       csr_waddr,
    output logic [2:0]       csr_ww,
    output logic [383:0]     csr_wdata,
    // ---- task 出口（共享 EU，单口）----
    output logic             task_vld,
    output logic [TID_W-1:0] task_tid,
    output logic [3:0]       task_sub_pc,       // 示例 EU 只吃 4bit（真实 sub_pc 8bit）
    input  logic             task_rdy,
    input  logic             eu_done,
    input  logic [TID_W-1:0] eu_done_tid,
    // ---- 出口 KO（单口）----
    output logic             out_vld,
    output logic [383:0]     out_data,
    output logic [TID_W-1:0] out_tid,
    input  logic             out_rdy,
    // ---- 事件（单口）----
    output logic             ts_done_vld,
    output logic [TID_W-1:0] ts_done_tid,
    output logic [TS_W-1:0]  ts_done_idx,
    output logic             thr_done_vld,
    output logic [TID_W-1:0] thr_done_tid,
    // ---- 观测 ----
    output logic             busy,
    output logic [6:0]       active_cnt,
    output logic [7:0]       ct_skip_cnt
);
    // ---- 状态与请求类型 ----
    typedef enum logic [2:0] { T_IDLE, T_ISS, T_WAIT, T_TSEND, T_BRWAIT, T_DONE, T_OUT } t_st_e;
    localparam logic [2:0] RQ_NONE = 3'd0, RQ_TASK = 3'd1, RQ_CSR = 3'd2, RQ_EVENT = 3'd3, RQ_KO = 3'd4;
    localparam int BIDX_W = $clog2(N_BURST);   // burst 下标位宽（N_BURST=8 → 3bit）

    t_st_e           t_st   [N_THR];   // 每线程状态
    logic [1:0]      t_ph   [N_THR];   // 多请求状态的相位（0/1）
    logic [TS_W-1:0]  t_base[N_THR];   // 程序基址（KO 行2 POE_HEAD 的低 TS_W 位 = 宏指令存储行号）
    logic [TS_W-1:0] t_cur  [N_THR];   // 线程自己的 ts 指针
    logic [3:0]      t_bid  [N_THR];   // 本 ts 已发到第几条 burst
    logic [2:0]      t_pri  [N_THR];   // 线程优先级（0 最高）
    logic [15:0]     t_age  [N_THR];   // 进入顺序号（同级取最小 = 最老）
    logic [383:0]    t_ko   [N_THR];   // 入口报文（出口回写用）
    logic [15:0]     age_cnt;          // 线程进入计数
    logic [7:0]      ct_skip;          // 全平台 c_task 跳过总数

    // ---- 每线程取指行（组合读）与字段切片 ----
    logic [3:0]       r_n    [N_THR];              // 本 ts burst 条数
    logic             r_last [N_THR];              // 本 ts 是否末 ts
    logic [TS_W-1:0]  r_jt   [N_THR];              // 跳转落点（镜像字段）
    logic [BURST_W-1:0] r_b  [N_THR][N_BURST];     // 本 ts 的 8 条 burst

    always_comb begin
        for (int t = 0; t < N_THR; t++) begin
            rd_ts_flat[t*TS_W +: TS_W] = t_base[t] + t_cur[t];      // 取指行号
            r_n[t]    = row_flat[t*TD_ROW_W + TD_N_LSB  +: 4];
            r_last[t] = row_flat[t*TD_ROW_W + TD_LAST];
            r_jt[t]   = row_flat[t*TD_ROW_W + TD_JTGT_LSB +: TS_W];
            for (int b = 0; b < N_BURST; b++)
                r_b[t][b] = row_flat[t*TD_ROW_W + TD_B_LSB + b*BURST_W +: BURST_W];
        end
    end

    // ---- 每个状态产生什么请求（组合）----
    logic [2:0] t_rq [N_THR];
    logic [6:0] t_csr_a  [N_THR];      // CSR 写地址
    logic [2:0] t_csr_w  [N_THR];      // CSR 写位宽码
    logic [15:0] t_csr_d [N_THR];      // CSR 写数据（TH_STAT / CUR_TS 都是小字段）

    always_comb begin
        for (int t = 0; t < N_THR; t++) begin
            t_rq[t]    = RQ_NONE;
            t_csr_a[t] = A_CUR_TS;
            t_csr_w[t] = W8;
            t_csr_d[t] = {{(16-TS_W){1'b0}}, t_cur[t]};
            case (t_st[t])
                T_ISS: begin
                    if (t_bid[t] >= r_n[t])            t_rq[t] = RQ_NONE;   // 本 ts 发完 → 转 T_TSEND
                    else if (!r_b[t][t_bid[t][BIDX_W-1:0]][BF_BT]) t_rq[t] = RQ_TASK;   // i/v 才发 EU
                    // c_task：不发 EU，在时序里直接跳过
                end
                T_TSEND: begin
                    if (t_ph[t] == 2'd0) t_rq[t] = RQ_EVENT;                 // 先发 ts_done
                    else if (!r_last[t]) begin
                        t_rq[t]    = RQ_CSR;                                 // 再写 CUR_TS = 下一个
                        t_csr_a[t] = A_CUR_TS;
                        t_csr_w[t] = W8;
                        t_csr_d[t] = {{(16-TS_W){1'b0}}, t_cur[t] + 1'b1};
                    end
                    // 末 ts：不再推进 CUR_TS（线程结束时停在最后一个 ts），直接转 T_DONE
                end
                T_BRWAIT: begin
                    t_rq[t]    = RQ_CSR;                                     // 阻塞后刷新 CUR_TS = 跳转落点
                    t_csr_a[t] = A_CUR_TS;
                    t_csr_w[t] = W8;
                    t_csr_d[t] = {{(16-TS_W){1'b0}}, r_jt[t]};
                end
                T_DONE: begin
                    if (t_ph[t] == 2'd0) begin
                        t_rq[t]    = RQ_CSR;                                 // 先写 TH_STAT=DONE
                        t_csr_a[t] = A_TH_STAT;
                        t_csr_d[t] = {8'd0, TH_DONE};
                    end else begin
                        t_rq[t] = RQ_EVENT;                                  // 再发 thr_done
                    end
                end
                T_OUT:   t_rq[t] = RQ_KO;                                    // 出口 KO 被取走才释放槽
                default: t_rq[t] = RQ_NONE;
            endcase
        end
    end

    // ---- 空闲槽：取最小空闲 tid（确定、可对账）----
    logic             free_vld;
    logic [TID_W-1:0] free_tid;
    always_comb begin
        free_vld = 1'b0; free_tid = '0;
        for (int t = N_THR-1; t >= 0; t--)
            if (t_st[t] == T_IDLE) begin free_vld = 1'b1; free_tid = t[TID_W-1:0]; end
    end
    assign ko_rdy         = free_vld;
    assign alloc          = ko_vld && free_vld;
    assign alloc_tid      = free_tid;
    // KO 行2 POE_HEAD 是 4B 地址；本平台的宏指令镜像只有 TS_MAX 行，取低 TS_W 位当行号。
    // 建线程同拍把该地址写进 CSR 0xc PC_INTER（bank 的 alloc 通路），保持 16bit 字段宽度。
    assign alloc_base_ts  = {{(16-TS_W){1'b0}}, ko_data[KO_HEAD_LSB +: TS_W]};

    // ---- 共享资源仲裁：每拍只服务一个请求，按 (pri 小, age 小) ----
    logic             sel_vld;
    logic [TID_W-1:0] sel_tid;
    logic [2:0]       sel_rq;
    always_comb begin
        automatic logic [2:0]  best_pri = '1;
        automatic logic [15:0] best_age = '1;
        sel_vld = 1'b0; sel_tid = '0; sel_rq = RQ_NONE;
        for (int t = 0; t < N_THR; t++) begin
            if (t_rq[t] != RQ_NONE) begin
                if (!sel_vld || (t_pri[t] < best_pri) ||
                    ((t_pri[t] == best_pri) && (t_age[t] < best_age))) begin
                    sel_vld  = 1'b1;
                    sel_tid  = t[TID_W-1:0];
                    sel_rq   = t_rq[t];
                    best_pri = t_pri[t];
                    best_age = t_age[t];
                end
            end
        end
    end

    // ---- 共享端口（由被选中的请求驱动）----
    assign task_vld    = sel_vld && (sel_rq == RQ_TASK);
    assign task_tid    = sel_tid;
    assign task_sub_pc = r_b[sel_tid][t_bid[sel_tid][BIDX_W-1:0]][BF_SUBPC_LSB +: 4];

    assign csr_we      = sel_vld && (sel_rq == RQ_CSR);
    assign csr_wtid    = sel_tid;
    assign csr_waddr   = t_csr_a[sel_tid];
    assign csr_ww      = t_csr_w[sel_tid];
    assign csr_wdata   = {368'd0, t_csr_d[sel_tid]};

    // 事件是**寄存单拍脉冲**：仲裁排队时请求会保持，直接用组合输出会被重复采样。
    logic             ts_done_p, thr_done_p;
    logic [TID_W-1:0] ts_done_tid_r, thr_done_tid_r;
    logic [TS_W-1:0]  ts_done_idx_r;
    assign ts_done_vld  = ts_done_p;
    assign ts_done_tid  = ts_done_tid_r;
    assign ts_done_idx  = ts_done_idx_r;
    assign thr_done_vld = thr_done_p;
    assign thr_done_tid = thr_done_tid_r;

    assign out_vld     = sel_vld && (sel_rq == RQ_KO);
    assign out_tid     = sel_tid;
    // 出口 KO：行1 的 DA/SA 对调，DP 与行2~6 原样（字段定义见 poe_pkg 的 KO_* 表）
    assign out_data    = {t_ko[sel_tid][KO_SA_LSB +: 8],   // [383:376] ← 原 SA
                          t_ko[sel_tid][KO_DP_LSB +: 8],   // [375:368] ← 原 DP
                          t_ko[sel_tid][KO_DA_LSB +: 8],   // [367:360] ← 原 DA
                          t_ko[sel_tid][359:320],          // [359:320] ← 行1 低 5B 原样
                          t_ko[sel_tid][319:0]};           // [319:0]   ← 行2~6 原样

    // ---- 观测量 ----
    logic [6:0] act_cnt;
    always_comb begin
        act_cnt = '0;
        for (int t = 0; t < N_THR; t++) if (t_st[t] != T_IDLE) act_cnt = act_cnt + 7'd1;
    end
    assign active_cnt  = act_cnt;
    assign busy        = (act_cnt != 7'd0);
    assign ct_skip_cnt = ct_skip;

    // ---- 状态推进（每线程一个 case；"served" = 本拍我的请求被仲裁器服务）----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int t = 0; t < N_THR; t++) begin
                t_st[t]   <= T_IDLE;
                t_ph[t]   <= 2'd0;
                t_base[t] <= '0;
                t_cur[t]  <= '0;
                t_bid[t]  <= '0;
                t_pri[t]  <= '0;
                t_age[t]  <= '0;
                t_ko[t]   <= '0;
            end
            age_cnt <= '0;
            ct_skip <= '0;
            ts_done_p <= 1'b0;   thr_done_p <= 1'b0;
            ts_done_tid_r <= '0; thr_done_tid_r <= '0; ts_done_idx_r <= '0;
        end else begin
            // 事件默认拉低 → 每次被服务只产生一拍脉冲
            ts_done_p  <= 1'b0;
            thr_done_p <= 1'b0;

            // ① 逐线程推进
            for (int t = 0; t < N_THR; t++) begin
                automatic logic served = sel_vld && (sel_tid == t[TID_W-1:0]);
                case (t_st[t])
                    // 发本 ts 的 burst：i/v 发 EU；c_task 跳过；发完转 T_TSEND
                    T_ISS: begin
                        if (t_bid[t] >= r_n[t]) begin
                            t_ph[t] <= 2'd0;
                            t_st[t] <= T_TSEND;
                        // 本 ts 头 burst 的 br=1：本 ts 被阻塞（等上个 ts 的结果刷新 CUR_TS）。
                        // 放在发 task 之前判，保证 br 行一条 burst 都不会误发。
                        end else if (t_bid[t] == 4'd0 && r_b[t][0][BF_ST] && r_b[t][0][BF_BR]) begin
                            t_st[t] <= T_BRWAIT;
                        end else if (r_b[t][t_bid[t][BIDX_W-1:0]][BF_BT]) begin
                            // c_task 本版不发 EU（等 SMC 通路），跳过并计数
                            t_bid[t] <= t_bid[t] + 4'd1;
                            ct_skip  <= ct_skip + 8'd1;
                        end else if (served && (sel_rq == RQ_TASK) && task_rdy) begin
                            t_bid[t] <= t_bid[t] + 4'd1;
                            t_st[t]  <= T_WAIT;
                        end
                    end
                    // 等 EU 执行完（按 tid 分发）
                    T_WAIT: begin
                        if (eu_done && (eu_done_tid == t[TID_W-1:0])) t_st[t] <= T_ISS;
                    end
                    // ts 边界：先发 ts_done 事件，再写 CUR_TS；末 ts → T_DONE
                    T_TSEND: begin
                        if (t_ph[t] == 2'd0) begin
                            if (served && (sel_rq == RQ_EVENT)) begin
                                t_ph[t]       <= 2'd1;
                                ts_done_p     <= 1'b1;
                                ts_done_tid_r <= t[TID_W-1:0];
                                ts_done_idx_r <= t_cur[t];
                            end
                        end else if (served && (sel_rq == RQ_CSR)) begin
                            // 进入下一个 ts：CUR_TS 推进 + bid 归零（否则会从"上个 ts 的条数"继续数）
                            t_cur[t] <= t_cur[t] + 1'b1;   // 取指指针（唯一权威）
                            t_ph[t]  <= 2'd0;
                            t_bid[t] <= '0;
                            t_st[t]  <= T_ISS;
                        end else if (r_last[t]) begin
                            // 末 ts：CUR_TS 保持不动，直接收线程
                            t_ph[t]  <= 2'd0;
                            t_bid[t] <= '0;
                            t_st[t]  <= T_DONE;
                        end
                    end
                    // br=1 的 ts：阻塞后刷新 CUR_TS（占位：总是跳到 jump_target）
                    T_BRWAIT: begin
                        if (served && (sel_rq == RQ_CSR)) begin
                            t_cur[t] <= r_jt[t];
                            t_bid[t] <= '0;
                            t_st[t]  <= T_ISS;
                        end
                    end
                    // 线程结束：写 TH_STAT=DONE，再发 thr_done
                    T_DONE: begin
                        if (t_ph[t] == 2'd0) begin
                            if (served && (sel_rq == RQ_CSR)) t_ph[t] <= 2'd1;
                        end else if (served && (sel_rq == RQ_EVENT)) begin
                            t_ph[t]        <= 2'd0;
                            t_st[t]        <= T_OUT;
                            thr_done_p     <= 1'b1;
                            thr_done_tid_r <= t[TID_W-1:0];
                        end
                    end
                    // 出口 KO 被取走 → 释放槽位
                    T_OUT: begin
                        if (served && (sel_rq == RQ_KO) && out_rdy) t_st[t] <= T_IDLE;
                    end
                    default: t_st[t] <= T_IDLE;
                endcase
            end

            // ② 受理 KO：建线程（alloc 走 bank 专用通路，不影响 CSR 请求仲裁）
            //   必须放在 per-thread 循环**之后**：新线程本拍旧状态还是 T_IDLE，
            //   循环里的 default 会写 t_st<=T_IDLE；这里的 NBA 后写才不会被覆盖。
            if (ko_vld && free_vld) begin
                t_st[free_tid]   <= T_ISS;
                t_ph[free_tid]   <= 2'd0;
                t_base[free_tid] <= ko_data[KO_HEAD_LSB +: TS_W];
                t_cur[free_tid]  <= '0;
                t_bid[free_tid]  <= '0;
                t_pri[free_tid]  <= ko_data[KO_PRI_LSB +: KO_PRI_W];   // KO 行1 PRI，0 最高
                t_age[free_tid]  <= age_cnt;
                t_ko[free_tid]   <= ko_data;
                age_cnt          <= age_cnt + 16'd1;
            end
        end
    end
endmodule
