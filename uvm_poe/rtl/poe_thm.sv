// ============================================================================
// POE THM（线程管理器）行为模型 v5
// - 线程 = 若干 ts，每个 ts = 若干 burst；burst 为 32bit 一种结构两种类型
//   （burst_iv_t / burst_c_t，burst_type 区分，字段重叠复用，见 poe_types_pkg）
// - 保序在 THM：新 KO 报文查自身线程池，同 (stream,cid,pos) 活跃线程（非 IDLE）则
//   存入 8 深报文缓存等待；前序线程释放后按 FIFO 放行；缓存满/线程满反压 ko_rdy
// - 线程状态机：IDLE→READY→ISSUED→DONE（WAIT 并入 ISSUED 打拍）
//   READY ≠ 回 IDLE：回 READY 后可发射下一个 burst（不限同一 ts），bs_pc 跨 ts 连续推进；
//   cur_ts 仅由 cu_done/dma_done 统计推进，一级队列可含 cur_ts 及更靠后 ts 的 burst
// - 建线程时同步生成 CSR 表项（csr_t，th_id 6bit、cw 8×6B），th_stat/cur_ts 与状态机
//   同步；dma_c/cw 暴露给 dma_ctrl / burst_sch（c_task 按 dma_id 查询）
// - pre_read 插队：KO 带 pre_read 时直接注入一条 c_task burst（不建线程/不查保序），
//   靠 burst 队列项 pre 标志区分（th_id 无保留值）；预读接口 pre_mes 4 组，模型占位单路
// - 线程结束（T_DONE）时输出 th_rel_vld/tid，通知 dma_ctrl 兜底归还 C 窗资源
// ============================================================================
module poe_thm #(
  parameter int MAX_THREADS = 64,
  parameter int MAX_TS      = 4,
  parameter int MAX_BURST   = 4,
  parameter int CID_W       = 17,
  parameter int BUF_DEPTH   = 8
) (
  input  logic clk,
  input  logic rst_n,
  // ---- KOA 输入（KO 报文 + 线程描述 + 保序键） ----
  input  logic            ko_vld,
  input  logic [383:0]    ko_data,
  input  logic [2:0]      ko_stream,      // 来源流 0..6
  input  logic [CID_W-1:0] ko_cid,
  input  logic [2:0]      ko_pos,
  input  logic            ko_pre_read,    // KO 带 pre_read：直接插队注入 c_task burst
  input  logic [2:0]      th_ts_cnt,      // 线程 ts 数（1..4）
  input  logic [2:0]      th_bs_cnt,      // 每 ts burst 数（1..4，= ts_len）
  input  logic [2:0]      th_pri,          // 线程 burst 优先级（0 最高，调度依据）
  input  logic [MAX_BURST*32-1:0] th_burst_seq,  // 每 ts 的 burst 模式（4×32bit，各 ts 复用）
  input  logic [7:0]      th_vtsk_c_seq,  // CSR vtsk_c：i/v 任务执行掩码（tsk_id 查询）
  input  logic [7:0]      th_dma_c_seq,   // CSR dma_c：c_task 执行指示（8bit 掩码，对应 cw 8 项）
  input  logic [383:0]    th_cw_seq,      // CSR cw：c_task 操作表（8×6B，条目 48bit）
  output logic            ko_rdy,
  // ---- th_sch：ready_mask / 发射 burst 的 ts / cur_ts / burst ----
  output logic [MAX_THREADS-1:0] ready_mask,        // READY 且未到头线程位图
  output logic [MAX_THREADS*3-1:0] ready_pri,       // 每线程 burst 优先级
  output logic [MAX_THREADS*2-1:0] ready_burst_ts,   // 发射 burst 所属 ts（由 bs_pc 推导）
  output logic [MAX_THREADS*2-1:0] ready_curts,       // 当前 ts（cu_done/dma_done 推进）
  output logic [MAX_THREADS*32-1:0] ready_burst,      // 发射 burst（bs_pc 索引，32bit）
  input  logic            iss_vld0,
  input  logic [5:0]      iss_tid0,
  input  logic            iss_vld1,
  input  logic [5:0]      iss_tid1,
  // ---- CU / dma_ctrl 完成：cur_ts 推进依赖完成统计 ----
  input  logic            cu_done_vld,
  input  logic [5:0]      cu_done_tid,
  input  logic            dma_done_vld,
  input  logic [5:0]      dma_done_tid,
  // ---- burst_sch 二级发射通知（打拍起点，占位） ----
  input  logic            emit_vld,
  input  logic [5:0]      emit_tid,
  // ---- pre_read 插队注入（直接送 c_task burst 到 burst 队列） ----
  input  logic            pre_inj_rdy,
  output logic            pre_inj_vld,
  output logic [5:0]      pre_inj_tid,
  output logic [1:0]      pre_inj_ts,
  output logic [31:0]     pre_inj_burst,
  // ---- CSR 暴露（c_task 按 dma_id 查询）：dma_c → burst_sch/dma_ctrl；cw → dma_ctrl ----
  output logic [MAX_THREADS*8-1:0]   csr_dma_c,
  output logic [MAX_THREADS*384-1:0] csr_cw,
  output logic [7:0]                 pre_dma_c,
  output logic [255:0]               pre_cw,
  // ---- 线程释放通知（→ dma_ctrl 归还该线程 C 窗资源） ----
  output logic            th_rel_vld,
  output logic [5:0]      th_rel_tid
);

  import poe_types_pkg::*;

  typedef enum logic [1:0] { T_IDLE, T_READY, T_ISSUED, T_DONE } state_t;

  // pre_read 插队 burst 无线程归属：th_id 6bit 无保留值，靠 burst 队列项 pre 标志区分

  state_t        th_state  [MAX_THREADS];
  logic [31:0]   th_head   [MAX_THREADS];
  logic [2:0]    th_ts_n   [MAX_THREADS];
  logic [2:0]    th_pri_r  [MAX_THREADS];
  logic [31:0]   th_burst_r [MAX_THREADS][MAX_BURST];  // 每 ts 的 burst 模式（各 ts 复用）
  logic [2:0]    th_stream [MAX_THREADS];
  logic [CID_W-1:0] th_cid [MAX_THREADS];
  logic [2:0]    th_pos    [MAX_THREADS];
  logic [4:0]    th_bs_pc  [MAX_THREADS];   // 应执行 burst 全局流水序号（打拍推进，跨 ts）
  logic [1:0]    th_cur_ts [MAX_THREADS];   // 当前 ts（完成统计推进）
  logic [7:0]    th_wait   [MAX_THREADS];
  logic [2:0]    th_done   [MAX_THREADS];   // 当前 ts 已完成 burst 数
  logic [2:0]    th_need   [MAX_THREADS];   // 当前 ts 实际执行 burst 数（首个 branch 提前）
  csr_t          csr       [MAX_THREADS];
  logic [47:0]   sys_ts_cnt;                // 系统时戳计数（1GHz 拍，48bit）

  // ---- 8 深报文缓存（保序等待） ----
  localparam int KO_W        = 384;
  localparam int ST_W        = 3;
  localparam int TS_W        = 3;
  localparam int BS_W        = 3;
  localparam int PR_W        = 3;
  localparam int BURST_PAT_W = MAX_BURST * BURST_W;
  localparam int DMA_C_W     = 8;
  localparam int CW_W        = 384;
  localparam int PKG_W = KO_W + ST_W + CID_W + 3 + TS_W + BS_W + PR_W
                         + BURST_PAT_W + 8 + DMA_C_W + CW_W;
  localparam int ST_MSB  = PKG_W - 1 - KO_W;
  localparam int CID_MSB = ST_MSB - ST_W;
  localparam int POS_MSB = CID_MSB - CID_W;
  localparam int TS_MSB  = POS_MSB - 3;
  localparam int BS_MSB  = TS_MSB - TS_W;
  localparam int PR_MSB  = BS_MSB - BS_W;
  localparam int BP_MSB  = PR_MSB - PR_W;
  localparam int VTSK_MSB = BP_MSB - BURST_PAT_W;
  localparam int DMA_C_MSB = VTSK_MSB - 8;
  localparam int CW_MSB    = DMA_C_MSB - DMA_C_W;
  logic [PKG_W-1:0] buf_mem [BUF_DEPTH];
  logic [2:0]       buf_head, buf_tail;
  logic [3:0]       buf_cnt;

  // ---- 组合辅助 ----
  function automatic logic key_active(logic [2:0] s, logic [CID_W-1:0] c, logic [2:0] p);
    for (int i = 0; i < MAX_THREADS; i++)
      if (th_state[i] != T_IDLE && th_stream[i] == s && th_cid[i] == c && th_pos[i] == p)
        return 1'b1;
    return 1'b0;
  endfunction

  function automatic int find_idle();
    for (int i = 0; i < MAX_THREADS; i++)
      if (th_state[i] == T_IDLE) return i;
    return -1;
  endfunction

  function automatic logic [31:0] ko_poe_head(logic [383:0] d);
    return d[383:352];
  endfunction

  int busy_cnt;
  logic all_busy;
  logic buf_full, buf_empty;
  logic can_accept;
  logic buf_ok;   // 缓存队头可放行

  always_comb begin
    busy_cnt = 0;
    for (int i = 0; i < MAX_THREADS; i++)
      if (th_state[i] != T_IDLE) busy_cnt++;
    all_busy = (busy_cnt == MAX_THREADS);
  end
  assign buf_full  = (buf_cnt == BUF_DEPTH);
  assign buf_empty = (buf_cnt == 0);
  // pre_read KO 的反压取决于插队注入侧（burst 队列）是否有空间
  assign ko_rdy = ko_pre_read ? pre_inj_rdy : can_accept;

  // 新报文可接受：能建线程（有空槽且同 key 无活跃）或能入缓存（未满）
  always_comb begin
    can_accept = 1'b0;
    if (!all_busy && !key_active(ko_stream, ko_cid, ko_pos)) can_accept = 1'b1;
    if (!buf_full) can_accept = 1'b1;
  end

  // 缓存队头可放行：非空 && 队头 key 无活跃 && 有空槽
  always_comb begin
    buf_ok = 1'b0;
    if (!buf_empty && !all_busy) begin
      if (!key_active(buf_mem[buf_head][ST_MSB -: ST_W],
                      buf_mem[buf_head][CID_MSB -: CID_W],
                      buf_mem[buf_head][POS_MSB -: 3]))
        buf_ok = 1'b1;
    end
  end

  // ---- pre_read 插队：KO 带 pre_read 且注入侧就绪时，直接送一条 c_task burst ----
  // （不建线程、不查保序；dma_id 取 KO 报文低 6bit，pre_dma_c/pre_cw 为独立占位 CSR）
  assign pre_inj_vld  = ko_vld && ko_pre_read && pre_inj_rdy;
  assign pre_inj_tid  = 6'd0;              // pre 无线程归属，靠队列项 pre 标志区分
  assign pre_inj_ts   = 2'd0;
  assign pre_inj_burst = {1'b1,            // st：视为 ts 首个
                          1'b0,            // tr
                          4'd0,            // rev
                          1'b1,            // burst_type：c_task
                          1'b0,            // vld_cu：1 个 task
                          ko_data[2:0],    // dma_id0（占位）
                          1'b1,            // c0：任务有效
                          ko_data[5:3],    // dma_id1（占位）
                          1'b0,            // c1：vld_cu=0 无效
                          8'd1,            // occ_ts0
                          8'd1};           // occ_ts1
  assign pre_dma_c = 8'hFF;                // 占位：pre 任务全部可执行

  // pre CSR cw：tag 取 KO 报文首字节（占位），其余为操作类型占位
  always_comb begin
    pre_cw = '0;
    for (int k = 0; k < 8; k++)
      pre_cw[k*32 +: 8] = ko_data[7:0];
  end

  // ---- CSR 暴露（burst_sch 按 tid+dma_id 查询） ----
  always_comb begin
    for (int i = 0; i < MAX_THREADS; i++) begin
      csr_dma_c[i*8 +: 8]   = csr[i].dma_c;
      csr_cw[i*384 +: 384]  = csr[i].cw;
    end
  end

  // 线程释放通知：T_DONE 拍通知 dma_ctrl 归还该线程 C 窗资源（同拍仅一个，逐拍处理）
  always_comb begin
    th_rel_vld = 1'b0;
    th_rel_tid = '0;
    for (int i = 0; i < MAX_THREADS; i++)
      if (th_state[i] == T_DONE) begin
        th_rel_vld = 1'b1;
        th_rel_tid = i[5:0];
        break;
      end
  end

  // ---- 可发射 / 调度辅助 ----
  always_comb begin
    for (int i = 0; i < MAX_THREADS; i++) begin
      // 可发射：READY 且总流水未到头（跨 ts 连续，队列允许超前 ts 的 burst）
      ready_mask[i] = (th_state[i] == T_READY) &&
                      (th_bs_pc[i] < ({2'b0, th_ts_n[i]} * {2'b0, th_need[i]}));
      ready_pri[i*3 +: 3] = th_pri_r[i];
      ready_burst_ts[i*2 +: 2] = th_bs_pc[i] / th_need[i];
      ready_curts[i*2 +: 2] = th_cur_ts[i];
      ready_burst[i*32 +: 32] = th_burst_r[i][th_bs_pc[i] % th_need[i]];
    end
  end

  // branch 等待随机上限：当拍 READY 线程中当前 burst 为 branch 的数量
  int branch_cnt;
  always_comb begin
    burst_iv_t b;
    branch_cnt = 0;
    for (int i = 0; i < MAX_THREADS; i++) begin
      b = th_burst_r[i][th_bs_pc[i] % th_need[i]];
      if (th_state[i] == T_READY && !b.burst_type && b.branch)
        branch_cnt++;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < MAX_THREADS; i++) begin
        th_state[i]  <= T_IDLE;
        th_head[i]   <= '0;
        th_ts_n[i]   <= '0;
        th_pri_r[i]  <= '0;
        for (int k = 0; k < MAX_BURST; k++) th_burst_r[i][k] <= '0;
        th_stream[i] <= '0;
        th_cid[i]    <= '0;
        th_pos[i]    <= '0;
        th_bs_pc[i]  <= '0;
        th_cur_ts[i] <= '0;
        th_wait[i]   <= '0;
        th_done[i]   <= '0;
        th_need[i]   <= '0;
        csr[i]       <= '0;
      end
      buf_head <= '0;
      buf_tail <= '0;
      buf_cnt  <= '0;
      sys_ts_cnt <= '0;
    end else begin
      // ---- 建线程：缓存放行优先，否则直接到达 ----
      begin
        automatic int t = find_idle();
        automatic int s;
        automatic logic [383:0] d;
        automatic logic [2:0] st;
        automatic logic [CID_W-1:0] c;
        automatic logic [2:0] p;
        automatic logic [2:0] ts, bs;
        automatic logic [2:0] pr;
        automatic logic [BURST_PAT_W-1:0] bp;
        automatic logic [7:0] vtsk, dc;
        automatic logic [255:0] cw;
        logic from_buf;
        from_buf = 1'b0;
        s = -1;
        d = '0; st = 0; c = '0; p = 0; ts = 0; bs = 0; pr = 0;
        bp = '0; vtsk = 0; dc = 0; cw = '0;
        if (buf_ok) begin
          from_buf = 1'b1;
          s = buf_head;
          d = buf_mem[buf_head][383:0];
          st = buf_mem[buf_head][ST_MSB -: ST_W];
          c  = buf_mem[buf_head][CID_MSB -: CID_W];
          p  = buf_mem[buf_head][POS_MSB -: 3];
          ts = buf_mem[buf_head][TS_MSB -: TS_W];
          bs = buf_mem[buf_head][BS_MSB -: BS_W];
          pr = buf_mem[buf_head][PR_MSB -: PR_W];
          bp = buf_mem[buf_head][BP_MSB -: BURST_PAT_W];
          vtsk = buf_mem[buf_head][VTSK_MSB -: 8];
          dc = buf_mem[buf_head][DMA_C_MSB -: DMA_C_W];
          cw = buf_mem[buf_head][CW_MSB -: CW_W];
        end else if (ko_vld && !ko_pre_read && can_accept &&
                     !key_active(ko_stream, ko_cid, ko_pos) && t >= 0) begin
          from_buf = 1'b0;
          d = ko_data; st = ko_stream; c = ko_cid; p = ko_pos;
          ts = th_ts_cnt; bs = th_bs_cnt; pr = th_pri;
          bp = th_burst_seq; vtsk = th_vtsk_c_seq; dc = th_dma_c_seq; cw = th_cw_seq;
        end
        if (t >= 0 && (from_buf || (ko_vld && !ko_pre_read && can_accept &&
                                    !key_active(ko_stream, ko_cid, ko_pos)))) begin
          automatic int need_l = bs;   // 默认本 ts 全部 burst；首个 branch（仅 i/v）提前结束
          automatic burst_iv_t tmp_b;
          for (int k = 0; k < MAX_BURST; k++) begin
            tmp_b = bp[k*BURST_W +: BURST_W];
            if (!tmp_b.burst_type && tmp_b.branch && k < bs) begin
              need_l = k + 1; break;
            end
          end
          th_state[t]  <= T_READY;
          th_head[t]   <= ko_poe_head(d);
          th_ts_n[t]   <= ts;
          th_pri_r[t]  <= pr;
          for (int k = 0; k < MAX_BURST; k++) begin
            tmp_b = bp[k*BURST_W +: BURST_W];
            th_burst_r[t][k] <= tmp_b;
          end
          th_stream[t] <= st;
          th_cid[t]    <= c;
          th_pos[t]    <= p;
          th_bs_pc[t]  <= 5'd0;
          th_cur_ts[t] <= 2'd0;
          th_wait[t]   <= 8'd0;
          th_done[t]   <= 2'd0;
          th_need[t]   <= need_l[2:0];
          // ---- CSR 表项：建线程时同步生成 ----
          csr[t].err     <= 8'd0;
          csr[t].ccr     <= 64'd0;
          csr[t].sys_ts  <= sys_ts_cnt;
          csr[t].th_id   <= t[7:0];
          csr[t].th_stat <= T_READY;
          csr[t].o_mes   <= 8'd0;
          csr[t].cur_ts  <= 8'd0;
          csr[t].vtsk_c  <= vtsk;
          csr[t].dma_c   <= dc;
          csr[t].tw      <= 64'd0;
          csr[t].cw      <= cw;
          if (from_buf) begin
            buf_head <= (buf_head == BUF_DEPTH-1) ? '0 : buf_head + 1'b1;
            buf_cnt  <= buf_cnt - 1'b1;
          end
        end
      end
      // ---- 直接到达入缓存（同 key 活跃时） ----
      if (ko_vld && !ko_pre_read && can_accept &&
          key_active(ko_stream, ko_cid, ko_pos) && !buf_full) begin
        buf_mem[buf_tail] <= {ko_data, ko_stream, ko_cid, ko_pos,
                              th_ts_cnt, th_bs_cnt, th_pri,
                              th_burst_seq, th_vtsk_c_seq, th_dma_c_seq, th_cw_seq};
        buf_tail <= (buf_tail == BUF_DEPTH-1) ? '0 : buf_tail + 1'b1;
        buf_cnt  <= buf_cnt + 1'b1;
      end
      // ---- th_sch 一级发射：进入 ISSUED 并打拍（非 branch 1 拍，branch 1+3+t 拍） ----
      if (iss_vld0 && th_state[iss_tid0] == T_READY &&
          th_bs_pc[iss_tid0] < ({2'b0, th_ts_n[iss_tid0]} * {2'b0, th_need[iss_tid0]})) begin
        burst_iv_t biv;
        biv = th_burst_r[iss_tid0][th_bs_pc[iss_tid0] % th_need[iss_tid0]];
        th_state[iss_tid0] <= T_ISSUED;
        csr[iss_tid0].th_stat <= T_ISSUED;
        if (!biv.burst_type && biv.branch)
          th_wait[iss_tid0] <= 4 + ($urandom % (branch_cnt + 1));   // 1 + 3 + t
        else
          th_wait[iss_tid0] <= 8'd1;                                // 1 拍
      end
      if (iss_vld1 && th_state[iss_tid1] == T_READY &&
          th_bs_pc[iss_tid1] < ({2'b0, th_ts_n[iss_tid1]} * {2'b0, th_need[iss_tid1]})) begin
        burst_iv_t biv;
        biv = th_burst_r[iss_tid1][th_bs_pc[iss_tid1] % th_need[iss_tid1]];
        th_state[iss_tid1] <= T_ISSUED;
        csr[iss_tid1].th_stat <= T_ISSUED;
        if (!biv.burst_type && biv.branch)
          th_wait[iss_tid1] <= 4 + ($urandom % (branch_cnt + 1));
        else
          th_wait[iss_tid1] <= 8'd1;
      end
      // ---- ISSUED 打拍推进 bs_pc（跨 ts 连续，burst 队列允许超前 ts） ----
      for (int i = 0; i < MAX_THREADS; i++) begin
        if (th_state[i] == T_ISSUED) begin
          if (th_wait[i] <= 1) begin
            th_state[i] <= T_READY;
            csr[i].th_stat <= T_READY;
            th_bs_pc[i] <= th_bs_pc[i] + 1'b1;
          end else begin
            th_wait[i] <= th_wait[i] - 1'b1;
          end
        end
      end
      // ---- cu_done：只统计 done / 推进 cur_ts；不改中间状态，避免覆盖 ISSUED ----
      if (cu_done_vld && th_state[cu_done_tid] != T_IDLE &&
                          th_state[cu_done_tid] != T_DONE) begin
        if ({1'b0, th_done[cu_done_tid]} + 4'd1 >= {1'b0, th_need[cu_done_tid]}) begin
          if ({1'b0, th_cur_ts[cu_done_tid]} + 4'd1 >= {1'b0, th_ts_n[cu_done_tid]}) begin
            th_state[cu_done_tid] <= T_DONE;
            csr[cu_done_tid].th_stat <= T_DONE;
          end else begin
            th_cur_ts[cu_done_tid] <= th_cur_ts[cu_done_tid] + 1'b1;
            csr[cu_done_tid].cur_ts <= th_cur_ts[cu_done_tid] + 1'b1;
            th_done[cu_done_tid]   <= 2'd0;
          end
        end else begin
          th_done[cu_done_tid] <= th_done[cu_done_tid] + 1'b1;
        end
      end
      // ---- dma_done：c_task 完成统计（同 cu_done；pre_read 插队 burst 为保留 tid，忽略） ----
      if (dma_done_vld && (dma_done_tid < MAX_THREADS) &&
          th_state[dma_done_tid] != T_IDLE && th_state[dma_done_tid] != T_DONE) begin
        if ({1'b0, th_done[dma_done_tid]} + 4'd1 >= {1'b0, th_need[dma_done_tid]}) begin
          if ({1'b0, th_cur_ts[dma_done_tid]} + 4'd1 >= {1'b0, th_ts_n[dma_done_tid]}) begin
            th_state[dma_done_tid] <= T_DONE;
            csr[dma_done_tid].th_stat <= T_DONE;
          end else begin
            th_cur_ts[dma_done_tid] <= th_cur_ts[dma_done_tid] + 1'b1;
            csr[dma_done_tid].cur_ts <= th_cur_ts[dma_done_tid] + 1'b1;
            th_done[dma_done_tid]   <= 2'd0;
          end
        end else begin
          th_done[dma_done_tid] <= th_done[dma_done_tid] + 1'b1;
        end
      end
      // ---- 释放：DONE 回 IDLE ----
      for (int i = 0; i < MAX_THREADS; i++)
        if (th_state[i] == T_DONE) begin
          th_state[i] <= T_IDLE;
          csr[i].th_stat <= T_IDLE;
        end
      sys_ts_cnt <= sys_ts_cnt + 1'b1;
    end
  end
endmodule
