// ============================================================================
// poe_thr_pool —— 多线程线程池（v1）
//
// 需求（已确认）：
//   · 不抢占：正在跑的线程不被打断，只在"下一个发射点"按规则重选
//   · 最多 N_THR=64 个线程同时活跃（TID_W=6）
//   · 调度：pri 小优先（= KO 报文行1 的 PRI，0 最高）；同级取 age 最小（最老）
//   · 出口 KO 由 DMUX 直出（本模块不再拼报文）；本模块只收"出口 KO 已发出"事件
//     （ko_sent_vld/ko_sent_tid）与"被取走"（out_rdy），**两者都满足才释放线程槽**
//
// 结构（三块）：
//   ① per-thread 状态数组：t_st / t_ts_idx / t_bid / t_pri / t_age / t_ko ...
//   ② 一套共享资源仲裁：每拍只服务**一个请求**（RQ_TASK / RQ_EVENT / RQ_KO），
//      所有请求统一按 (pri, age) 排序 —— 而不是每种资源各写一套仲裁
//   ③ "每个状态产生什么请求"的 case（T_ISS 发 task、T_TSEND 发 ts_done ...）
//
// 取指：行为模型，多读口组合读（row_flat 每线程一拍返回整行），因此没有取指状态、
//       也不需要每线程取指缓存。真实 RTL 若 ROM 端口受限，只需改 poe_burst_imem。
//
// CUR_TS/TH_STAT：**CSR 是唯一权威，由 EU 壳在 ts 结束/线程结束时写**；线程池只读：
//   · 取指行号 = base_ts + CSR.CUR_TS；
//   · T_TSEND 发 ts_done 后读 CSR.TH_STAT：DONE → T_DONE，否则用新的 CUR_TS 取下一个 ts；
//   · 线程池不再写任何 CSR 表项。
// 事件：ts_done / thr_done 只在被服务的下一拍各拉高**一拍**，避免仲裁排队时重复计数。
//
// 占位（接真实 EU 后替换，平台其它部分不动）：
//   · br=1 的 ts **先正常执行完本 ts**；ts 最后一条 task 带 br/jump_target 给 EU，
//     由 EU 在结果拍写 CSR.CUR_TS（占位：br ? jump_target : cur_ts+1）；
//     下一个 ts 在 EU 刷新 CUR_TS 前不执行（池子读 CSR 的新值）
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
    // ---- task 出口（共享 EU，单口）----
    output logic             task_vld,
    output logic [TID_W-1:0] task_tid,
    output logic [3:0]       task_sub_pc,       // 示例 EU 只吃 4bit（真实 sub_pc 8bit）
    output logic             task_last,         // 本 task 是该线程最后一条（EU 壳据此占位写 TH_STAT）
    output logic             task_ts_last,      // 本 task 是本 ts 最后一条（EU 壳据此写 CUR_TS）
    output logic             task_br,           // 本 ts 头 burst 的 br
    output logic [TS_W-1:0]  task_jump,         // 本 ts 的 jump_target（br 时用）
    input  logic             task_rdy,
    input  logic             eu_done,
    input  logic [TID_W-1:0] eu_done_tid,
    // ---- CSR 观测（线程结束由 EU 写 TH_STAT，池子只看不写）----
    input  logic [N_THR*8-1:0] th_stat_flat,    // 每线程 TH_STAT（EU 写，池子读）
    input  logic [N_THR*8-1:0] cur_ts_flat,     // 每线程 CUR_TS（EU 写，池子读）
    // ---- 出口 KO：由 DMUX 直出，池子只收"已发出/已取走"两个信息 ----
    input  logic             ko_sent_vld,     // 出口 KO 已发出（DMUX 的 out_vld，一拍）
    input  logic [TID_W-1:0] ko_sent_tid,     // 属于哪个线程
    input  logic             out_rdy,         // 出口 KO 被下游取走（下游能收）
    // ---- 入口 KO 低 16B（出口 KO 的这部分原样保持，交给 DMUX 再生）----
    output logic [N_THR*KO_LO_W-1:0] ko_lo_flat,  // 每线程 128bit：tid*KO_LO_W +: KO_LO_W
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
    typedef enum logic [2:0] { T_IDLE, T_ISS, T_WAIT, T_TSEND, T_DONE, T_OUT } t_st_e;
    localparam logic [2:0] RQ_NONE = 3'd0, RQ_TASK = 3'd1, RQ_EVENT = 3'd2, RQ_KO = 3'd3;
    localparam int BIDX_W = $clog2(N_BURST);   // burst 下标位宽（N_BURST=8 → 3bit）

    t_st_e           t_st   [N_THR];   // 每线程状态
    logic [1:0]      t_ph   [N_THR];   // 多请求状态的相位（0/1）
    logic [TS_W-1:0]  t_base[N_THR];   // 程序基址（KO 行2 POE_HEAD 的低 TS_W 位 = 宏指令存储行号）
    logic [TS_W-1:0] t_ts_idx[N_THR]; // 本 ts 的序号（ts_done 事件用；取指用 CSR.CUR_TS）
    logic [3:0]      t_n    [N_THR];  // 本 ts 的有效 burst 条数（CUR_TS 刷新后行会变，必须锁存）
    logic            t_ld   [N_THR];  // 本 ts 的行元数据是否已锁存（每个 ts 先锁一拍）
    logic [3:0]      t_bid  [N_THR];   // 本 ts 已发到第几条 burst
    logic [2:0]      t_pri  [N_THR];   // 线程优先级（0 最高）
    logic [15:0]     t_age  [N_THR];   // 进入顺序号（同级取最小 = 最老）
    logic [383:0]    t_ko   [N_THR];   // 入口报文（出口回写用）
    logic            t_ko_sent [N_THR];// 该线程的出口 KO 是否已由 DMUX 发出
    logic [15:0]     age_cnt;          // 线程进入计数
    logic [7:0]      ct_skip;          // 全平台 c_task 跳过总数

    // ---- 每线程取指行（组合读）与字段切片 ----
    logic [3:0]       r_n    [N_THR];              // 本 ts burst 条数
    logic             r_last [N_THR];              // 本 ts 是否末 ts
    logic [TS_W-1:0]  r_jt   [N_THR];              // 跳转落点（镜像字段）
    logic [BURST_W-1:0] r_b  [N_THR][N_BURST];     // 本 ts 的 8 条 burst

    always_comb begin
        for (int t = 0; t < N_THR; t++) begin
            // 取指行号 = 程序基址 + CSR.CUR_TS（CSR 是唯一权威，由 EU 写）
            rd_ts_flat[t*TS_W +: TS_W] = t_base[t] + cur_ts_flat[t*8 +: TS_W];
            r_n[t]    = row_flat[t*TD_ROW_W + TD_N_LSB  +: 4];
            r_last[t] = row_flat[t*TD_ROW_W + TD_LAST];
            r_jt[t]   = row_flat[t*TD_ROW_W + TD_JTGT_LSB +: TS_W];
            for (int b = 0; b < N_BURST; b++)
                r_b[t][b] = row_flat[t*TD_ROW_W + TD_B_LSB + b*BURST_W +: BURST_W];
        end
    end

    // ---- 每个状态产生什么请求（组合）----
    logic [2:0] t_rq [N_THR];

    always_comb begin
        for (int t = 0; t < N_THR; t++) begin
            t_rq[t] = RQ_NONE;
            case (t_st[t])
                T_ISS: begin
                    if (t_ld[t] && t_bid[t] < t_n[t] && !r_b[t][t_bid[t][BIDX_W-1:0]][BF_BT])
                        t_rq[t] = RQ_TASK;   // i/v 才发 EU；c_task 在时序里直接跳过
                    // c_task：不发 EU，在时序里直接跳过
                end
                T_TSEND: begin
                    if (t_ph[t] == 2'd0) t_rq[t] = RQ_EVENT;  // 先发 ts_done；CUR_TS 已由 EU 写
                end
                T_DONE: begin
                    // 线程结束由 EU 写 CSR 0xa TH_STAT=DONE（占位：将来由微指令写）；
                    // 池子只等它到，再发 thr_done 事件。
                    if (th_stat_flat[t*8 +: 8] == TH_DONE) t_rq[t] = RQ_EVENT;
                end
                // 出口 KO 已发出 → 申请"取走"（下游 out_rdy 恒 1）；没发出就继续等
                T_OUT:   t_rq[t] = t_ko_sent[t] ? RQ_KO : RQ_NONE;
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
    // 本 task 是线程最后一条 = 末 ts（r_last）的最后一条 burst
    assign task_last   = task_vld && r_last[sel_tid] && (t_bid[sel_tid] == (t_n[sel_tid] - 4'd1));
    // 本 task 是本 ts 最后一条（包括线程最后一条）：EU 据此写 CUR_TS/TH_STAT
    assign task_ts_last= task_vld && (t_bid[sel_tid] == (t_n[sel_tid] - 4'd1));
    assign task_br     = task_vld && r_b[sel_tid][0][BF_ST] && r_b[sel_tid][0][BF_BR];
    assign task_jump   = r_jt[sel_tid];

    // 事件是**寄存单拍脉冲**：仲裁排队时请求会保持，直接用组合输出会被重复采样。
    logic             ts_done_p, thr_done_p;
    logic [TID_W-1:0] ts_done_tid_r, thr_done_tid_r;
    logic [TS_W-1:0]  ts_done_idx_r;
    assign ts_done_vld  = ts_done_p;
    assign ts_done_tid  = ts_done_tid_r;
    assign ts_done_idx  = ts_done_idx_r;
    assign thr_done_vld = thr_done_p;
    assign thr_done_tid = thr_done_tid_r;

    // 入口 KO 低 16B 的扁平导出：出口 KO 的这部分**原样保持入口值**（高 32B 由 DMUX 用 O 窗再生）
    always_comb begin
        for (int t = 0; t < N_THR; t++)
            ko_lo_flat[t*KO_LO_W +: KO_LO_W] = t_ko[t][KO_LO_LSB +: KO_LO_W];
    end

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
                t_ts_idx[t] <= '0;
                t_n[t]      <= '0;
                t_ld[t]     <= 1'b0;
                t_bid[t]  <= '0;
                t_pri[t]  <= '0;
                t_age[t]  <= '0;
                t_ko[t]   <= '0;
                t_ko_sent[t] <= 1'b0;
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
                        if (!t_ld[t]) begin
                            t_ts_idx[t] <= cur_ts_flat[t*8 +: TS_W];   // 锁存本 ts 序号（供 ts_done）
                            t_n[t] <= r_n[t];                          // 锁存本 ts 条数
                            t_ld[t] <= 1'b1;
                        end else if (t_bid[t] >= t_n[t]) begin
                            t_ph[t] <= 2'd0;
                            t_st[t] <= T_TSEND;
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
                    // ts 边界：先发 ts_done；CUR_TS/TH_STAT 已由 EU 在 ts 最后一条 task 写回
                    T_TSEND: begin
                        if (t_ph[t] == 2'd0) begin
                            if (served && (sel_rq == RQ_EVENT)) begin
                                t_ph[t]       <= 2'd1;
                                ts_done_p     <= 1'b1;
                                ts_done_tid_r <= t[TID_W-1:0];
                                ts_done_idx_r <= t_ts_idx[t];
                            end
                        end else begin
                            // 读 EU 已刷新的 CSR：DONE 收线程，否则用新 CUR_TS 取下一个 ts
                            t_ph[t]  <= 2'd0;
                            t_bid[t] <= '0;
                            t_ld[t]  <= 1'b0;
                            if (th_stat_flat[t*8 +: 8] == TH_DONE)
                                t_st[t] <= T_DONE;
                            else
                                t_st[t] <= T_ISS;
                        end
                    end
                    // 线程结束：等 EU 写完 TH_STAT=DONE，发 thr_done 事件
                    T_DONE: begin
                        if (served && (sel_rq == RQ_EVENT)) begin
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

            // ①.5 出口 KO 由 DMUX 直出：收到"已发出"就记下来，T_OUT 才允许释放槽位
            if (ko_sent_vld) t_ko_sent[ko_sent_tid] <= 1'b1;

            // ② 受理 KO：建线程（alloc 走 bank 专用通路，不影响 CSR 请求仲裁）
            //   必须放在 per-thread 循环**之后**：新线程本拍旧状态还是 T_IDLE，
            //   循环里的 default 会写 t_st<=T_IDLE；这里的 NBA 后写才不会被覆盖。
            if (ko_vld && free_vld) begin
                t_st[free_tid]   <= T_ISS;
                t_ph[free_tid]   <= 2'd0;
                t_base[free_tid] <= ko_data[KO_HEAD_LSB +: TS_W];
                t_ts_idx[free_tid] <= '0;
                t_n[free_tid]      <= '0;
                t_ld[free_tid]     <= 1'b0;
                t_bid[free_tid]  <= '0;
                t_pri[free_tid]  <= ko_data[KO_PRI_LSB +: KO_PRI_W];   // KO 行1 PRI，0 最高
                t_age[free_tid]  <= age_cnt;
                t_ko[free_tid]   <= ko_data;
                t_ko_sent[free_tid] <= 1'b0;                          // 新线程：出口 KO 还没发
                age_cnt          <= age_cnt + 16'd1;
            end
        end
    end
endmodule
