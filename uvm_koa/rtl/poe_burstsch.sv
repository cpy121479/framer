// POE burst_sch（二级发射调度器）：
// - 从 th_sch 的 2 个 burst 队列轮询（rr：q0/q1 交替优先），对队头判断可发射
// - 可发射条件（所有 burst 均须满足）：
//   ① burst.ts == 线程当前 cur_ts（cur_ts 由 cu_done/dma_done 推进，队列中不会出现
//      当前 ts 以前的 burst）；pre_read 插队 burst 无线程归属，跳过本检查
//   ② 不满足"O 窗反压 且 burst 涉及 O 窗操作"（owin_bp=1 时 tr=1 的 burst 阻塞）
// - c_task（burst_type=1）新增条件（不替换公共条件）：按 c0/c1 判任务是否需发 dma_ctrl，
//   需要时查 CSR.dma_c[dma_id] 确认生效（bit=1），需执行任务数 N（0..2）；
//   C 窗资源池可用才放行：cw_fifo_cnt ≥ N 且该线程占用 + N ≤ 4。
//   pre_read 插队 burst 暂不占资源（跳过）。
// - 发射路由：burst_type=0（i/v_task）→ CU/EU；=1（c_task）→ dma_ctrl
//   （操作指令格式见方案文档：vld+th_id+op_type+smc_addr，每拍 ≤4 路）
// - owin_bp 由外部提供（O 窗资源池内部设计后续补充）；C 窗资源池由 dma_ctrl 的
//   256 深 FIFO 实际管理（burst_sch 依据 cw_fifo_cnt / th_res_n 做发射条件）
module poe_burstsch #(
  parameter int MAX_THREADS = 64
) (
  input  logic clk,
  input  logic rst_n,
  // ---- th_sch burst 队列（q0/q1） ----
  input  logic            q0_vld,
  input  logic [5:0]      q0_tid,
  input  logic [1:0]      q0_ts,
  input  logic [31:0]     q0_burst,
  input  logic            q0_pre,
  output logic            q0_ack,
  input  logic            q1_vld,
  input  logic [5:0]      q1_tid,
  input  logic [1:0]      q1_ts,
  input  logic [31:0]     q1_burst,
  input  logic            q1_pre,
  output logic            q1_ack,
  // ---- 线程状态 / CSR / C 窗资源池状态 ----
  input  logic [MAX_THREADS*2-1:0] thread_curts,
  input  logic [MAX_THREADS*8-1:0]   csr_dma_c,
  input  logic [9:0]                 cw_fifo_cnt,
  input  logic [MAX_THREADS*2-1:0]   th_res_n,
  input  logic [7:0]                 pre_dma_c,
  // ---- O 窗反压（资源池设计后续补充） ----
  input  logic            owin_bp,
  // ---- 发射输出：i/v_task → CU/EU；c_task → dma_ctrl（携带 burst） ----
  output logic            emit_cu_vld,
  output logic [5:0]      emit_cu_tid,
  output logic [31:0]     emit_cu_burst,
  input  logic            cu_ack,
  output logic            emit_dma_vld,
  output logic [5:0]      emit_dma_tid,
  output logic [31:0]     emit_dma_burst,
  output logic            emit_dma_pre,   // pre_read 插队 burst（dma_ctrl 不占资源/不回 done）
  input  logic            dma_ack
);

  import poe_types_pkg::*;

  logic       rr;   // 0=q0 优先，1=q1 优先

  // 组合：检查 q0/q1 队头是否可发射（公共条件 + c_task 的资源条件 + 目的端 ack）
  logic emit0_cond, emit1_cond;   // 源侧条件
  logic avail0, avail1;           // 源侧条件 && 目的端可接收
  burst_c_t bc0, bc1;
  logic [7:0]   dma_c0, dma_c1;
  logic [1:0]   need0, need1;
  always_comb begin
    bc0 = q0_burst;
    bc1 = q1_burst;
    // 公共条件：pre 插队跳过 ts 检查；tr=1 受 O 窗反压
    emit0_cond = q0_vld &&
                 (q0_pre || (q0_ts == thread_curts[q0_tid*2 +: 2])) &&
                 !(owin_bp && bc0.tr);
    emit1_cond = q1_vld &&
                 (q1_pre || (q1_ts == thread_curts[q1_tid*2 +: 2])) &&
                 !(owin_bp && bc1.tr);
    // c_task 查询 CSR.dma_c：c0/c1 有效且 dma_c 置位的任务数 N；资源池可用才放行
    if (q0_pre) dma_c0 = pre_dma_c;
    else dma_c0 = csr_dma_c[q0_tid*8 +: 8];
    if (q1_pre) dma_c1 = pre_dma_c;
    else dma_c1 = csr_dma_c[q1_tid*8 +: 8];
    need0 = bc0.vld_cu ? (bc0.c0 & dma_c0[bc0.dma_id0]) + (bc0.c1 & dma_c0[bc0.dma_id1])
                       : (bc0.c0 & dma_c0[bc0.dma_id0]);
    need1 = bc1.vld_cu ? (bc1.c0 & dma_c1[bc1.dma_id0]) + (bc1.c1 & dma_c1[bc1.dma_id1])
                       : (bc1.c0 & dma_c1[bc1.dma_id0]);
    if (bc0.burst_type == 1'b1) begin
      if (!q0_pre)
        emit0_cond = emit0_cond &&
                     (cw_fifo_cnt >= need0) &&
                     ({2'b0, th_res_n[q0_tid*2 +: 2]} + {2'b0, need0} <= 5'd4);
    end
    if (bc1.burst_type == 1'b1) begin
      if (!q1_pre)
        emit1_cond = emit1_cond &&
                     (cw_fifo_cnt >= need1) &&
                     ({2'b0, th_res_n[q1_tid*2 +: 2]} + {2'b0, need1} <= 5'd4);
    end
    // 目的端 ack：i/v → CU；c_task → dma_ctrl
    avail0 = emit0_cond && (bc0.burst_type == 1'b0 ? cu_ack : dma_ack);
    avail1 = emit1_cond && (bc1.burst_type == 1'b0 ? cu_ack : dma_ack);
  end

  // 发射选择：rr 轮询（每拍最多 1 个）
  logic emit;
  logic emit_sel0, emit_sel1;
  logic [5:0] emit_tid_c;
  logic [31:0] emit_burst_c;
  logic emit_pre_c;
  always_comb begin
    emit = 1'b0;
    emit_sel0 = 1'b0;
    emit_sel1 = 1'b0;
    emit_tid_c = 6'd0;
    emit_burst_c = '0;
    emit_pre_c = 1'b0;
    if (avail0 && avail1) begin
      // 都满足：优先 ts 小的（按 ts 顺序）；ts 相同按 rr 轮询
      if (q0_ts < q1_ts) begin
        emit = 1'b1; emit_sel0 = 1'b1;
      end else if (q1_ts < q0_ts) begin
        emit = 1'b1; emit_sel1 = 1'b1;
      end else if (!rr) begin
        emit = 1'b1; emit_sel0 = 1'b1;
      end else begin
        emit = 1'b1; emit_sel1 = 1'b1;
      end
    end else if (avail0) begin
      emit = 1'b1; emit_sel0 = 1'b1;
    end else if (avail1) begin
      emit = 1'b1; emit_sel1 = 1'b1;
    end
    if (emit_sel0) begin
      emit_tid_c = q0_tid;
      emit_burst_c = q0_burst;
      emit_pre_c = q0_pre;
    end else if (emit_sel1) begin
      emit_tid_c = q1_tid;
      emit_burst_c = q1_burst;
      emit_pre_c = q1_pre;
    end
  end

  assign q0_ack = emit && emit_sel0;
  assign q1_ack = emit && emit_sel1;
  burst_c_t emit_bc;
  assign emit_bc = emit_burst_c;
  assign emit_cu_vld  = emit && (emit_bc.burst_type == 1'b0);
  assign emit_cu_tid  = emit_tid_c;
  assign emit_cu_burst = emit_burst_c;
  assign emit_dma_vld = emit && (emit_bc.burst_type == 1'b1);
  assign emit_dma_tid = emit_tid_c;
  assign emit_dma_burst = emit_burst_c;
  assign emit_dma_pre = emit_dma_vld && emit_pre_c;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rr       <= 1'b0;
    end else begin
      // 轮询指针：每次发射后翻转
      if (emit) rr <= ~rr;
    end
  end
endmodule
