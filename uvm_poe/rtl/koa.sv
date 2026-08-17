// ============================================================================
// KOA 行为模型 v4（保序移入 THM，KOA 仅做输入仲裁 + 8 组 RR+SP 调度）
//
// 职责：
// - 收 7 条 KO 输入流（5 条 fgOTN/X2X 带 cid/pos，2 条串口不带），每拍仲裁选 1 条；
// - 报文按 pri（0..7，0 最高）进入 8 个优先级队列（每队列深度 QUEUE_DEPTH）；
// - 每拍输出 1 条：组间 SP（选最高非空组，即组号最小 = 优先级最高），组内 FIFO
//   （先到先出，等效 RR），输出带 out_pri/out_src(组号)/out_stream(来源流)，
//   供下游 THM 做保序（保序键 = stream+cid+pos）。
//
// 接口约定：
// - 输入侧 vld/rdy 握手：vld=1 且 rdy=1 才入队；7 路共享同一反压判决
//   （目标优先级队列未满即可写）。
// - 多平面流（OH/APS/ALM）按平面展开打包：data[KO_W-1:0] 为平面 i 的报文、
//   pri[i*3 +: 3] 为平面 i 的优先级，cid/pos 同理；同流多平面同时有效时取编号小者。
// - 输出侧无 rdy（THM 每拍必收）；输出寄存一拍。
// ============================================================================
module koa #(
  parameter int NUM_OH_PLANES   = 4,   // fgOTN 开销流平面数（OH_EXT/OH_INS 各 N）
  parameter int NUM_X2X_PLANES  = 8,   // X2X 平面数（APS_EXT/APS_INS/ALM 各 N）
  parameter int CID_W           = 17,  // 通道号位宽（1 时隙粒度）
  parameter int POS_W           = 3,   // 开销位置位宽（OH 0..7 / APS 0 / ALM 0..3）
  parameter int KO_W            = 384, // KO 报文位宽（48B）
  parameter int QUEUE_DEPTH     = 16   // 每个优先级队列深度
) (
  input  logic                                  clk,
  input  logic                                  rst_n,
  // ---- fgOTN：OH_EXT / OH_INS（开销提取 / 下插，各 NUM_OH_PLANES 平面） ----
  input  logic [NUM_OH_PLANES-1:0]               oh_e_vld,   // 各平面有效
  input  logic [NUM_OH_PLANES*KO_W-1:0]          oh_e_data,  // 各平面 KO 报文（48B）
  input  logic [NUM_OH_PLANES*3-1:0]             oh_e_pri,   // 各平面优先级（0 最高）
  input  logic [NUM_OH_PLANES*CID_W-1:0]         oh_e_cid,   // 各平面通道号
  input  logic [NUM_OH_PLANES*POS_W-1:0]         oh_e_pos,   // 各平面开销位置
  output logic [NUM_OH_PLANES-1:0]               oh_e_rdy,   // 各平面可写
  input  logic [NUM_OH_PLANES-1:0]               oh_i_vld,   // 各平面有效（下插）
  input  logic [NUM_OH_PLANES*KO_W-1:0]          oh_i_data,  // 各平面 KO 报文
  input  logic [NUM_OH_PLANES*3-1:0]             oh_i_pri,   // 各平面优先级
  input  logic [NUM_OH_PLANES*CID_W-1:0]         oh_i_cid,   // 各平面通道号
  input  logic [NUM_OH_PLANES*POS_W-1:0]         oh_i_pos,   // 各平面开销位置
  output logic [NUM_OH_PLANES-1:0]               oh_i_rdy,   // 各平面可写
  // ---- X2X：APS_EXT / APS_INS / ALM（各 NUM_X2X_PLANES 平面） ----
  input  logic [NUM_X2X_PLANES-1:0]              aps_e_vld,   // X2X APS 提取
  input  logic [NUM_X2X_PLANES*KO_W-1:0]         aps_e_data,
  input  logic [NUM_X2X_PLANES*3-1:0]            aps_e_pri,
  input  logic [NUM_X2X_PLANES*CID_W-1:0]        aps_e_cid,
  input  logic [NUM_X2X_PLANES*POS_W-1:0]        aps_e_pos,
  output logic [NUM_X2X_PLANES-1:0]              aps_e_rdy,
  input  logic [NUM_X2X_PLANES-1:0]              aps_i_vld,   // X2X APS 下插
  input  logic [NUM_X2X_PLANES*KO_W-1:0]         aps_i_data,
  input  logic [NUM_X2X_PLANES*3-1:0]            aps_i_pri,
  input  logic [NUM_X2X_PLANES*CID_W-1:0]        aps_i_cid,
  input  logic [NUM_X2X_PLANES*POS_W-1:0]        aps_i_pos,
  output logic [NUM_X2X_PLANES-1:0]              aps_i_rdy,
  input  logic [NUM_X2X_PLANES-1:0]              alm_vld,     // X2X ALM
  input  logic [NUM_X2X_PLANES*KO_W-1:0]         alm_data,
  input  logic [NUM_X2X_PLANES*3-1:0]            alm_pri,
  input  logic [NUM_X2X_PLANES*CID_W-1:0]        alm_cid,
  input  logic [NUM_X2X_PLANES*POS_W-1:0]        alm_pos,
  output logic [NUM_X2X_PLANES-1:0]              alm_rdy,
  // ---- 串口：UART_EXT / UART_INS（无 cid/pos，直连） ----
  input  logic                                   u_e_vld,     // 串口提取
  input  logic [KO_W-1:0]                        u_e_data,
  input  logic [2:0]                             u_e_pri,
  output logic                                   u_e_rdy,
  input  logic                                   u_i_vld,     // 串口下插
  input  logic [KO_W-1:0]                        u_i_data,
  input  logic [2:0]                             u_i_pri,
  output logic                                   u_i_rdy,
  // ---- KO 输出（→ THM，寄存一拍，无 rdy） ----
  output logic                                   out_vld,     // 输出有效
  output logic [KO_W-1:0]                        out_data,    // KO 报文（48B）
  output logic [2:0]                             out_pri,     // 优先级（=出队组号）
  output logic [2:0]                             out_src,     // 优先级组号 0..7
  output logic [2:0]                             out_stream,  // 来源流 0..6（THM 保序用）
  output logic [CID_W-1:0]                       out_cid,     // 通道号（串口为 0）
  output logic [POS_W-1:0]                       out_pos,     // 开销位置（串口为 0）
  // ---- 接收确认（→ monitor/scoreboard：本拍实际入队的报文） ----
  // 与握手 vld/rdy 无关，直接反映 DUT 实际接收，避免测试平台采样时序歧义
  output logic                                   ack_vld,     // 本拍有报文入队
  output logic [2:0]                             ack_stream,  // 入队报文来源流
  output logic [2:0]                             ack_pri,     // 入队报文优先级
  output logic [KO_W-1:0]                        ack_data,    // 入队报文数据（48B）
  output logic [CID_W-1:0]                       ack_cid,     // 入队报文通道号
  output logic [POS_W-1:0]                       ack_pos      // 入队报文开销位置
);

  // 队列项打包：{stream[3], cid[CID_W], pos[POS_W], data[KO_W]}，高位为 stream，
  // 出队时按位域拆回各输出
  localparam int PKG_W = 3 + CID_W + POS_W + KO_W;
  localparam int PTR_W = $clog2(QUEUE_DEPTH);   // 队列指针位宽

  // ---- 8 个优先级队列（组号 = 优先级，0 最高） ----
  logic [PKG_W-1:0] q_mem [8][QUEUE_DEPTH];
  logic [PTR_W-1:0] q_head [8];   // 组内读指针（FIFO 队头）
  logic [PTR_W-1:0] q_tail [8];   // 组内写指针（FIFO 队尾）
  logic [PTR_W:0]   q_cnt  [8];   // 各组报文计数（满/空判断）

  // ---- 输入仲裁：7 流 → 单条报文 {stream, cid, pos, pri, data} ----
  // 流优先级（仲裁优先级，与报文 pri 无关）：OH_EXT > OH_INS > APS_EXT > APS_INS
  // > ALM > UART_EXT > UART_INS；同流多平面取编号小者
  // stream 编号：0=OH_EXT, 1=OH_INS, 2=APS_EXT, 3=APS_INS, 4=ALM,
  //              5=UART_EXT, 6=UART_INS（THM 保序键的一部分）
  logic        w_vld;
  logic [2:0]  w_stream;
  logic [2:0]  w_pri;
  logic [CID_W-1:0] w_cid;
  logic [POS_W-1:0] w_pos;
  logic [KO_W-1:0]  w_data;
  int w_q;   // 目标优先级队列
  logic [2:0] w_sel_plane;   // 仲裁选中流的平面号（串口恒 0；仅选中流 rdy 拉高）

  always_comb begin
    w_vld = 1'b0;
    w_stream = 3'd0; w_pri = 3'd0; w_cid = '0; w_pos = '0; w_data = '0;
    w_sel_plane = 3'd0;
    for (int i = 0; i < NUM_OH_PLANES; i++)
      if (!w_vld && oh_e_vld[i]) begin
        w_vld = 1'b1; w_stream = 3'd0; w_sel_plane = i[2:0];
        w_pri = oh_e_pri[i*3 +: 3]; w_data = oh_e_data[i*KO_W +: KO_W];
        w_cid = oh_e_cid[i*CID_W +: CID_W]; w_pos = oh_e_pos[i*POS_W +: POS_W];
      end
    for (int i = 0; i < NUM_OH_PLANES; i++)
      if (!w_vld && oh_i_vld[i]) begin
        w_vld = 1'b1; w_stream = 3'd1; w_sel_plane = i[2:0];
        w_pri = oh_i_pri[i*3 +: 3]; w_data = oh_i_data[i*KO_W +: KO_W];
        w_cid = oh_i_cid[i*CID_W +: CID_W]; w_pos = oh_i_pos[i*POS_W +: POS_W];
      end
    for (int i = 0; i < NUM_X2X_PLANES; i++)
      if (!w_vld && aps_e_vld[i]) begin
        w_vld = 1'b1; w_stream = 3'd2; w_sel_plane = i[2:0];
        w_pri = aps_e_pri[i*3 +: 3]; w_data = aps_e_data[i*KO_W +: KO_W];
        w_cid = aps_e_cid[i*CID_W +: CID_W]; w_pos = aps_e_pos[i*POS_W +: POS_W];
      end
    for (int i = 0; i < NUM_X2X_PLANES; i++)
      if (!w_vld && aps_i_vld[i]) begin
        w_vld = 1'b1; w_stream = 3'd3; w_sel_plane = i[2:0];
        w_pri = aps_i_pri[i*3 +: 3]; w_data = aps_i_data[i*KO_W +: KO_W];
        w_cid = aps_i_cid[i*CID_W +: CID_W]; w_pos = aps_i_pos[i*POS_W +: POS_W];
      end
    for (int i = 0; i < NUM_X2X_PLANES; i++)
      if (!w_vld && alm_vld[i]) begin
        w_vld = 1'b1; w_stream = 3'd4; w_sel_plane = i[2:0];
        w_pri = alm_pri[i*3 +: 3]; w_data = alm_data[i*KO_W +: KO_W];
        w_cid = alm_cid[i*CID_W +: CID_W]; w_pos = alm_pos[i*POS_W +: POS_W];
      end
    if (!w_vld && u_e_vld) begin
      w_vld = 1'b1; w_stream = 3'd5; w_sel_plane = 3'd0;
      w_pri = u_e_pri; w_data = u_e_data; w_cid = '0; w_pos = '0;
    end
    if (!w_vld && u_i_vld) begin
      w_vld = 1'b1; w_stream = 3'd6; w_sel_plane = 3'd0;
      w_pri = u_i_pri; w_data = u_i_data; w_cid = '0; w_pos = '0;
    end
    w_q = int'(w_pri);
  end

  // ---- 输入反压：per-stream 选通（仅仲裁选中的流/平面拉高 rdy） ----
  // 仲裁每拍只收 1 条；未选中的流 rdy=0、vld 保持，等后续拍选中 → 不丢报文。
  // 选中流若目标优先级队列满（can_write=0），本拍也不收（反压），vld 保持。
  logic can_write;
  assign can_write = (w_q >= 0) && (q_cnt[w_q] != QUEUE_DEPTH);
  always_comb begin
    for (int i = 0; i < NUM_OH_PLANES; i++)
      oh_e_rdy[i] = can_write && w_vld && (w_stream == 3'd0) && (w_sel_plane == i[2:0]);
    for (int i = 0; i < NUM_OH_PLANES; i++)
      oh_i_rdy[i] = can_write && w_vld && (w_stream == 3'd1) && (w_sel_plane == i[2:0]);
    for (int i = 0; i < NUM_X2X_PLANES; i++)
      aps_e_rdy[i] = can_write && w_vld && (w_stream == 3'd2) && (w_sel_plane == i[2:0]);
    for (int i = 0; i < NUM_X2X_PLANES; i++)
      aps_i_rdy[i] = can_write && w_vld && (w_stream == 3'd3) && (w_sel_plane == i[2:0]);
    for (int i = 0; i < NUM_X2X_PLANES; i++)
      alm_rdy[i]   = can_write && w_vld && (w_stream == 3'd4) && (w_sel_plane == i[2:0]);
    u_e_rdy = can_write && w_vld && (w_stream == 3'd5);
    u_i_rdy = can_write && w_vld && (w_stream == 3'd6);
  end

  // ---- 读侧：SP 选最高非空组（组号最小 = 优先级最高），组内 FIFO 出队 ----
  logic [2:0] sel_grp;
  logic       rd_valid;
  always_comb begin
    sel_grp = 3'd7;   // 默认无有效组
    rd_valid = 1'b0;
    for (int g = 0; g < 8; g++)
      if (q_cnt[g] != 0 && !rd_valid) begin   // 从组 0 开始找第一个非空组
        sel_grp = g;
        rd_valid = 1'b1;
      end
  end

  // ---- q_cnt 合并更新：同拍写读同一组时净 0（避免"读覆盖写"导致计数漂移） ----
  logic [PTR_W:0] q_cnt_n [8];
  always_comb begin
    for (int g = 0; g < 8; g++) begin
      q_cnt_n[g] = q_cnt[g];
      if (w_vld && can_write && (w_q == g)) q_cnt_n[g] = q_cnt_n[g] + 1'b1;  // 本拍入队
      if (rd_valid && (sel_grp == g))       q_cnt_n[g] = q_cnt_n[g] - 1'b1;  // 本拍出队
    end
  end

  // ---- 主时序：写队列 + SP 出队 + 输出寄存（一拍） ----
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int g = 0; g < 8; g++) begin
        q_head[g] <= '0;
        q_tail[g] <= '0;
        q_cnt[g]  <= '0;
      end
      out_vld <= 1'b0;
      out_data <= '0;
      out_pri  <= 3'd0;
      out_src  <= 3'd0;
      out_stream <= 3'd0;
      out_cid  <= '0;
      out_pos  <= '0;
      ack_vld <= 1'b0;
      ack_stream <= 3'd0;
      ack_pri  <= 3'd0;
      ack_data <= '0;
      ack_cid  <= '0;
      ack_pos  <= '0;
    end else begin
      // 写：仲裁选中的报文入目标优先级队列（vld && rdy）
      if (w_vld && can_write) begin
        q_mem[w_q][q_tail[w_q]] <= {w_stream, w_cid, w_pos, w_data};  // 打包入队
        q_tail[w_q] <= (q_tail[w_q] == QUEUE_DEPTH-1) ? '0 : q_tail[w_q] + 1'b1;
        // 接收确认（寄存一拍，沿后稳定）
        ack_vld    <= 1'b1;
        ack_stream <= w_stream;
        ack_pri    <= w_pri;
        ack_data   <= w_data;
        ack_cid    <= w_cid;
        ack_pos    <= w_pos;
      end else begin
        ack_vld <= 1'b0;
      end
      // 读：SP 选中的组出队（组内 FIFO），输出拆包
      if (rd_valid) begin
        q_head[sel_grp] <= (q_head[sel_grp] == QUEUE_DEPTH-1) ? '0 : q_head[sel_grp] + 1'b1;
        out_vld    <= 1'b1;
        out_pri    <= sel_grp;                                        // 组号即优先级
        out_src    <= sel_grp;
        out_stream <= q_mem[sel_grp][q_head[sel_grp]][PKG_W-1:PKG_W-3];     // 拆 stream
        out_cid    <= q_mem[sel_grp][q_head[sel_grp]][PKG_W-4-:CID_W];      // 拆 cid
        out_pos    <= q_mem[sel_grp][q_head[sel_grp]][PKG_W-4-CID_W-:POS_W]; // 拆 pos
        out_data   <= q_mem[sel_grp][q_head[sel_grp]][KO_W-1:0];            // 拆 data
      end else begin
        out_vld <= 1'b0;
      end
      // q_cnt 统一更新（写/读合并，同拍同组净 0）
      for (int g = 0; g < 8; g++)
        q_cnt[g] <= q_cnt_n[g];
    end
  end
endmodule
