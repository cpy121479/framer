// ============================================================================
// KOA 行为模型 v5：5×SBUF + RR+SP 调度
// 结构（对应方案图）：
// - 5 个独立 SBUF（EXT/INS/ALM/UART_EXT/UART_INS，深度 SBUF_DEPTH=2560），
//   每个 SBUF 的存储按优先级拆成 8 个队列（pri 0..7，0 最高）：
//     EXT_SBUF      <- OH_EXT + APS_EXT（多写 1 读）
//     INS_SBUF      <- OH_INS + APS_INS（多写 1 读）
//     ALM_SBUF      <- ALM
//     UART_EXT_SBUF <- UART_EXT
//     UART_INS_SBUF <- UART_INS
// - 业务源报文直接写入对应 SBUF 的 pri 段（无输入仲裁），SBUF 深度吸收突发；
//   反压只在对应段满时拉低（per-plane rdy）。同段同拍多写时按固定顺序：
//   APS 平面（编号小优先）固定优先于 OH 平面，OH 让位。
// - 调度（输出，每拍 1 条）：先按优先级高低选组（SP，组号 0..7）；
//   同优先级组内对 5 个 SBUF 轮询（rr_ptr 每拍推进），取最先非空的队列出队。
// - 输出：out_vld + 48B + out_pri(组号) + out_src(组号) + out_stream/cid/pos
//   （保序键 stream+cid+pos 供 THM 使用；pri 随路传入决定段）。
// ============================================================================
module koa #(
  parameter int NUM_OH_PLANES   = 4,    // fgOTN 开销流平面数（OH_EXT/OH_INS 各 N）
  parameter int NUM_X2X_PLANES  = 8,    // X2X 平面数（APS_EXT/APS_INS/ALM 各 N）
  parameter int CID_W           = 17,   // 通道号位宽（1 时隙粒度）
  parameter int POS_W           = 3,    // 开销位置位宽（OH 0..7 / APS 0 / ALM 0..3）
  parameter int KO_W            = 384,  // KO 报文位宽（48B）
  parameter int SBUF_DEPTH      = 2560  // 每个 SBUF 总深度（地址拆成 8 个 pri 队列）
) (
  input  logic                                  clk,
  input  logic                                  rst_n,
  // ---- fgOTN：OH_EXT / OH_INS（开销提取 / 下插，各 NUM_OH_PLANES 平面）----
  input  logic [NUM_OH_PLANES-1:0]               oh_e_vld,
  input  logic [NUM_OH_PLANES*KO_W-1:0]          oh_e_data,
  input  logic [NUM_OH_PLANES*3-1:0]             oh_e_pri,
  input  logic [NUM_OH_PLANES*CID_W-1:0]         oh_e_cid,
  input  logic [NUM_OH_PLANES*POS_W-1:0]         oh_e_pos,
  output logic [NUM_OH_PLANES-1:0]               oh_e_rdy,
  input  logic [NUM_OH_PLANES-1:0]               oh_i_vld,
  input  logic [NUM_OH_PLANES*KO_W-1:0]          oh_i_data,
  input  logic [NUM_OH_PLANES*3-1:0]             oh_i_pri,
  input  logic [NUM_OH_PLANES*CID_W-1:0]         oh_i_cid,
  input  logic [NUM_OH_PLANES*POS_W-1:0]         oh_i_pos,
  output logic [NUM_OH_PLANES-1:0]               oh_i_rdy,
  // ---- X2X：APS_EXT / APS_INS / ALM（各 NUM_X2X_PLANES 平面）----
  input  logic [NUM_X2X_PLANES-1:0]              aps_e_vld,
  input  logic [NUM_X2X_PLANES*KO_W-1:0]         aps_e_data,
  input  logic [NUM_X2X_PLANES*3-1:0]            aps_e_pri,
  input  logic [NUM_X2X_PLANES*CID_W-1:0]        aps_e_cid,
  input  logic [NUM_X2X_PLANES*POS_W-1:0]        aps_e_pos,
  output logic [NUM_X2X_PLANES-1:0]              aps_e_rdy,
  input  logic [NUM_X2X_PLANES-1:0]              aps_i_vld,
  input  logic [NUM_X2X_PLANES*KO_W-1:0]         aps_i_data,
  input  logic [NUM_X2X_PLANES*3-1:0]            aps_i_pri,
  input  logic [NUM_X2X_PLANES*CID_W-1:0]        aps_i_cid,
  input  logic [NUM_X2X_PLANES*POS_W-1:0]        aps_i_pos,
  output logic [NUM_X2X_PLANES-1:0]              aps_i_rdy,
  input  logic [NUM_X2X_PLANES-1:0]              alm_vld,
  input  logic [NUM_X2X_PLANES*KO_W-1:0]         alm_data,
  input  logic [NUM_X2X_PLANES*3-1:0]            alm_pri,
  input  logic [NUM_X2X_PLANES*CID_W-1:0]        alm_cid,
  input  logic [NUM_X2X_PLANES*POS_W-1:0]        alm_pos,
  output logic [NUM_X2X_PLANES-1:0]              alm_rdy,
  // ---- 串口：UART_EXT / UART_INS（无 cid/pos，直连）----
  input  logic                                   u_e_vld,
  input  logic [KO_W-1:0]                        u_e_data,
  input  logic [2:0]                             u_e_pri,
  output logic                                   u_e_rdy,
  input  logic                                   u_i_vld,
  input  logic [KO_W-1:0]                        u_i_data,
  input  logic [2:0]                             u_i_pri,
  output logic                                   u_i_rdy,
  // ---- KO 输出（→ THM，寄存一拍）----
  output logic                                   out_vld,
  output logic [KO_W-1:0]                        out_data,
  output logic [2:0]                             out_pri,
  output logic [2:0]                             out_src,
  output logic [2:0]                             out_stream,
  output logic [CID_W-1:0]                       out_cid,
  output logic [POS_W-1:0]                       out_pos
);

  // SBUF 编号：0=EXT 1=INS 2=ALM 3=UART_EXT 4=UART_INS
  localparam int N_SBUF       = 5;
  localparam int PRI_Q_DEPTH  = SBUF_DEPTH / 8;   // 每个 pri 段深度（=320）
  localparam int PTR_W        = $clog2(PRI_Q_DEPTH);
  localparam int PKG_W        = 3 + CID_W + POS_W + KO_W;  // {stream, cid, pos, data}

  // ---- 5×SBUF × 8 段存储（每段独立 FIFO）----
  logic [PKG_W-1:0] sbuf_mem [N_SBUF][8][PRI_Q_DEPTH];
  logic [PTR_W-1:0] sbuf_head [N_SBUF][8];
  logic [PTR_W-1:0] sbuf_tail [N_SBUF][8];
  logic [PTR_W:0]   sbuf_cnt  [N_SBUF][8];
  logic             wr_any    [N_SBUF][8];  // 本拍各 (SBUF,pri) 段是否有写入被接受

  // ---- 写入接受（组合）：每段每拍接受 1 条；同段多写时 APS 平面固定优先于 OH ----
  // 段号 = 报文 pri（0..7，随路传入）；rdy = 对应平面本拍被接受
  logic [NUM_OH_PLANES-1:0]  oh_e_acc, oh_i_acc;
  logic [NUM_X2X_PLANES-1:0] aps_e_acc, aps_i_acc, alm_acc;
  logic u_e_acc, u_i_acc;

  // 段内最小有效平面（同流同 pri 内编号小优先；pri 为 8 平面×3bit 打包）
  function automatic logic plane_first(logic [7:0] vld, int i, logic [23:0] pri, int g);
    for (int k = 0; k < i; k++)
      if (vld[k] && pri[k*3 +: 3] == g) return 1'b0;
    return 1'b1;
  endfunction

  always_comb begin
    // APS 先算：同段内 APS 固定靠前（优先于 OH）
    for (int i = 0; i < NUM_X2X_PLANES; i++) begin
      automatic logic [2:0] g = aps_e_pri[i*3 +: 3];
      aps_e_acc[i] = aps_e_vld[i] && plane_first(aps_e_vld, i, aps_e_pri, g)
                     && (sbuf_cnt[0][g] < PRI_Q_DEPTH);
      g = aps_i_pri[i*3 +: 3];
      aps_i_acc[i] = aps_i_vld[i] && plane_first(aps_i_vld, i, aps_i_pri, g)
                     && (sbuf_cnt[1][g] < PRI_Q_DEPTH);
      g = alm_pri[i*3 +: 3];
      alm_acc[i]   = alm_vld[i]   && plane_first(alm_vld, i, alm_pri, g)
                     && (sbuf_cnt[2][g] < PRI_Q_DEPTH);
    end
    // OH：同段已有 APS 被接受时让位（APS 固定靠前）
    for (int i = 0; i < NUM_OH_PLANES; i++) begin
      automatic logic [2:0] g = oh_e_pri[i*3 +: 3];
      automatic logic aps_win;
      aps_win = 1'b0;
      for (int k = 0; k < NUM_X2X_PLANES; k++)
        if (aps_e_acc[k] && (aps_e_pri[k*3 +: 3] == g)) aps_win = 1'b1;
      oh_e_acc[i] = oh_e_vld[i] && plane_first(oh_e_vld, i, oh_e_pri, g) &&
                    !aps_win && (sbuf_cnt[0][g] < PRI_Q_DEPTH);
    end
    for (int i = 0; i < NUM_OH_PLANES; i++) begin
      automatic logic [2:0] g = oh_i_pri[i*3 +: 3];
      automatic logic aps_win;
      aps_win = 1'b0;
      for (int k = 0; k < NUM_X2X_PLANES; k++)
        if (aps_i_acc[k] && (aps_i_pri[k*3 +: 3] == g)) aps_win = 1'b1;
      oh_i_acc[i] = oh_i_vld[i] && plane_first(oh_i_vld, i, oh_i_pri, g) &&
                    !aps_win && (sbuf_cnt[1][g] < PRI_Q_DEPTH);
    end
    // UART_EXT → SBUF(3)，段=u_e_pri；UART_INS → SBUF(4)，段=u_i_pri
    u_e_acc = u_e_vld && (sbuf_cnt[3][u_e_pri] < PRI_Q_DEPTH);
    u_i_acc = u_i_vld && (sbuf_cnt[4][u_i_pri] < PRI_Q_DEPTH);

    // wr_any：各 (SBUF,pri) 段本拍接受的写入（acc 已保证同段最多 1 条）
    for (int s = 0; s < N_SBUF; s++)
      for (int g = 0; g < 8; g++) wr_any[s][g] = 1'b0;
    for (int i = 0; i < NUM_OH_PLANES; i++) begin
      wr_any[0][oh_e_pri[i*3 +: 3]] |= oh_e_acc[i];
      wr_any[1][oh_i_pri[i*3 +: 3]] |= oh_i_acc[i];
    end
    for (int i = 0; i < NUM_X2X_PLANES; i++) begin
      wr_any[0][aps_e_pri[i*3 +: 3]] |= aps_e_acc[i];
      wr_any[1][aps_i_pri[i*3 +: 3]] |= aps_i_acc[i];
      wr_any[2][alm_pri[i*3 +: 3]]   |= alm_acc[i];
    end
    wr_any[3][u_e_pri] = u_e_acc;
    wr_any[4][u_i_pri] = u_i_acc;
  end
  // rdy = 本拍接受（组合，随 vld/段未满变化）
  assign oh_e_rdy  = oh_e_acc;
  assign oh_i_rdy  = oh_i_acc;
  assign aps_e_rdy = aps_e_acc;
  assign aps_i_rdy = aps_i_acc;
  assign alm_rdy   = alm_acc;
  assign u_e_rdy   = u_e_acc;
  assign u_i_rdy   = u_i_acc;

  // ---- 读侧：SP 选最高非空 pri 组（组号最小），组内 5 SBUF 轮询（rr_ptr 每拍推进）----
  logic [2:0] rr_ptr;
  logic [2:0] sel_grp;
  logic [2:0] sel_sbuf;
  logic       rd_valid;
  always_comb begin
    sel_grp  = 3'd7;
    rd_valid = 1'b0;
    for (int g = 0; g < 8; g++) begin
      for (int s = 0; s < N_SBUF; s++)
        if (sbuf_cnt[s][g] != 0) begin
          sel_grp  = g[2:0];
          rd_valid = 1'b1;
          break;
        end
      if (rd_valid) break;
    end
    sel_sbuf = rr_ptr;
    if (rd_valid)
      for (int k = 0; k < N_SBUF; k++)
        if (sbuf_cnt[(rr_ptr + k) % N_SBUF][sel_grp] != 0) begin
          sel_sbuf = (rr_ptr + k) % N_SBUF;
          break;
        end
  end

  // ---- 主时序：写入（直写 SBUF 段）+ SP/RR 出队 + 输出寄存（一拍）----
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int s = 0; s < N_SBUF; s++)
        for (int g = 0; g < 8; g++) begin
          sbuf_head[s][g] <= '0;
          sbuf_tail[s][g] <= '0;
          sbuf_cnt[s][g]  <= '0;
        end
      rr_ptr <= '0;
      out_vld <= 1'b0;
      out_data <= '0;
      out_pri  <= 3'd0;
      out_src  <= 3'd0;
      out_stream <= 3'd0;
      out_cid  <= '0;
      out_pos  <= '0;
    end else begin
      // ---- 写入：各流按接受（acc）直写对应 SBUF 段（mem + tail）----
      // OH_EXT → EXT_SBUF(0)，段=oh_e_pri[i]
      for (int i = 0; i < NUM_OH_PLANES; i++)
        if (oh_e_acc[i]) begin
          automatic logic [2:0] g = oh_e_pri[i*3 +: 3];
          sbuf_mem[0][g][sbuf_tail[0][g]] <= {3'd0, oh_e_cid[i*CID_W +: CID_W],
                                              oh_e_pos[i*POS_W +: POS_W],
                                              oh_e_data[i*KO_W +: KO_W]};
          sbuf_tail[0][g] <= (sbuf_tail[0][g] == PRI_Q_DEPTH-1) ? '0 : sbuf_tail[0][g] + 1'b1;
        end
      // OH_INS → INS_SBUF(1)，段=oh_i_pri[i]
      for (int i = 0; i < NUM_OH_PLANES; i++)
        if (oh_i_acc[i]) begin
          automatic logic [2:0] g = oh_i_pri[i*3 +: 3];
          sbuf_mem[1][g][sbuf_tail[1][g]] <= {3'd1, oh_i_cid[i*CID_W +: CID_W],
                                              oh_i_pos[i*POS_W +: POS_W],
                                              oh_i_data[i*KO_W +: KO_W]};
          sbuf_tail[1][g] <= (sbuf_tail[1][g] == PRI_Q_DEPTH-1) ? '0 : sbuf_tail[1][g] + 1'b1;
        end
      // APS_EXT → EXT_SBUF(0)，段=aps_e_pri[i]
      for (int i = 0; i < NUM_X2X_PLANES; i++)
        if (aps_e_acc[i]) begin
          automatic logic [2:0] g = aps_e_pri[i*3 +: 3];
          sbuf_mem[0][g][sbuf_tail[0][g]] <= {3'd2, aps_e_cid[i*CID_W +: CID_W],
                                              aps_e_pos[i*POS_W +: POS_W],
                                              aps_e_data[i*KO_W +: KO_W]};
          sbuf_tail[0][g] <= (sbuf_tail[0][g] == PRI_Q_DEPTH-1) ? '0 : sbuf_tail[0][g] + 1'b1;
        end
      // APS_INS → INS_SBUF(1)，段=aps_i_pri[i]
      for (int i = 0; i < NUM_X2X_PLANES; i++)
        if (aps_i_acc[i]) begin
          automatic logic [2:0] g = aps_i_pri[i*3 +: 3];
          sbuf_mem[1][g][sbuf_tail[1][g]] <= {3'd3, aps_i_cid[i*CID_W +: CID_W],
                                              aps_i_pos[i*POS_W +: POS_W],
                                              aps_i_data[i*KO_W +: KO_W]};
          sbuf_tail[1][g] <= (sbuf_tail[1][g] == PRI_Q_DEPTH-1) ? '0 : sbuf_tail[1][g] + 1'b1;
        end
      // ALM → ALM_SBUF(2)，段=alm_pri[i]
      for (int i = 0; i < NUM_X2X_PLANES; i++)
        if (alm_acc[i]) begin
          automatic logic [2:0] g = alm_pri[i*3 +: 3];
          sbuf_mem[2][g][sbuf_tail[2][g]] <= {3'd4, alm_cid[i*CID_W +: CID_W],
                                              alm_pos[i*POS_W +: POS_W],
                                              alm_data[i*KO_W +: KO_W]};
          sbuf_tail[2][g] <= (sbuf_tail[2][g] == PRI_Q_DEPTH-1) ? '0 : sbuf_tail[2][g] + 1'b1;
        end
      // UART_EXT → SBUF(3)，段=u_e_pri
      if (u_e_acc) begin
        sbuf_mem[3][u_e_pri][sbuf_tail[3][u_e_pri]] <= {3'd5, '0, 3'd0, u_e_data};
        sbuf_tail[3][u_e_pri] <= (sbuf_tail[3][u_e_pri] == PRI_Q_DEPTH-1) ? '0 : sbuf_tail[3][u_e_pri] + 1'b1;
      end
      // UART_INS → SBUF(4)，段=u_i_pri
      if (u_i_acc) begin
        sbuf_mem[4][u_i_pri][sbuf_tail[4][u_i_pri]] <= {3'd6, '0, 3'd0, u_i_data};
        sbuf_tail[4][u_i_pri] <= (sbuf_tail[4][u_i_pri] == PRI_Q_DEPTH-1) ? '0 : sbuf_tail[4][u_i_pri] + 1'b1;
      end

      // ---- 读：SP/RR 选中段出队（head + out 拆包）----
      if (rd_valid) begin
        sbuf_head[sel_sbuf][sel_grp] <= (sbuf_head[sel_sbuf][sel_grp] == PRI_Q_DEPTH-1)
                                        ? '0 : sbuf_head[sel_sbuf][sel_grp] + 1'b1;
        out_vld    <= 1'b1;
        out_pri    <= sel_grp;
        out_src    <= sel_grp;
        out_stream <= sbuf_mem[sel_sbuf][sel_grp][sbuf_head[sel_sbuf][sel_grp]][PKG_W-1:PKG_W-3];
        out_cid    <= sbuf_mem[sel_sbuf][sel_grp][sbuf_head[sel_sbuf][sel_grp]][PKG_W-4-:CID_W];
        out_pos    <= sbuf_mem[sel_sbuf][sel_grp][sbuf_head[sel_sbuf][sel_grp]][PKG_W-4-CID_W-:POS_W];
        out_data   <= sbuf_mem[sel_sbuf][sel_grp][sbuf_head[sel_sbuf][sel_grp]][KO_W-1:0];
      end else begin
        out_vld <= 1'b0;
      end

      // ---- cnt 合并更新：写 +1 / 读 -1（同段同拍写读净 0，避免双 NBA 覆盖漂移）----
      for (int s = 0; s < N_SBUF; s++)
        for (int g = 0; g < 8; g++)
          sbuf_cnt[s][g] <= sbuf_cnt[s][g]
                            + (wr_any[s][g] ? 1'b1 : 1'b0)
                            - ((rd_valid && (sel_sbuf == s) && (sel_grp == g)) ? 1'b1 : 1'b0);

      // rr 指针每拍推进（同优先级 5 路轮询）
      rr_ptr <= (rr_ptr == N_SBUF-1) ? '0 : rr_ptr + 1'b1;
    end
  end
endmodule
