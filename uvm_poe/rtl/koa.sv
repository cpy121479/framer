// KOA 行为模型 v4（保序移入 THM，KOA 仅做输入仲裁 + 8 组 RR+SP 调度）
// - 输入 7 条 KO 流（5 条 fgOTN/X2X 带 cid/pos，2 条串口不带）
// - 报文按 pri（0..7，0 最高）进入 8 个优先级队列（深度 QUEUE_DEPTH）
// - 调度：组间 SP（选最高非空组），组内 FIFO 出队（先到先出 = RR 等效），每拍输出 1 条
// - 输出：out_vld + 48B + out_pri + out_src(组号) + out_stream(0..6，供 THM 保序)
module koa #(
  parameter int NUM_OH_PLANES   = 4,
  parameter int NUM_X2X_PLANES  = 8,
  parameter int CID_W           = 17,
  parameter int POS_W           = 3,
  parameter int KO_W            = 384,
  parameter int QUEUE_DEPTH     = 16
) (
  input  logic                                  clk,
  input  logic                                  rst_n,
  // ---- fgOTN：OH_EXT / OH_INS ----
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
  // ---- X2X：APS_EXT / APS_INS / ALM ----
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
  // ---- 串口：UART_EXT / UART_INS（无 cid/pos） ----
  input  logic                                   u_e_vld,
  input  logic [KO_W-1:0]                        u_e_data,
  input  logic [2:0]                             u_e_pri,
  output logic                                   u_e_rdy,
  input  logic                                   u_i_vld,
  input  logic [KO_W-1:0]                        u_i_data,
  input  logic [2:0]                             u_i_pri,
  output logic                                   u_i_rdy,
  // ---- KO 输出 ----
  output logic                                   out_vld,
  output logic [KO_W-1:0]                        out_data,
  output logic [2:0]                             out_pri,
  output logic [2:0]                             out_src,   // 优先级组号 0..7
  output logic [2:0]                             out_stream, // 来源流 0..6
  output logic [CID_W-1:0]                       out_cid,
  output logic [POS_W-1:0]                       out_pos
);

  localparam int PKG_W = 3 + CID_W + POS_W + KO_W;   // {stream, cid, pos, data}
  localparam int PTR_W = $clog2(QUEUE_DEPTH);

  // ---- 8 个优先级队列 ----
  logic [PKG_W-1:0] q_mem [8][QUEUE_DEPTH];
  logic [PTR_W-1:0] q_head [8];
  logic [PTR_W-1:0] q_tail [8];
  logic [PTR_W:0]   q_cnt  [8];

  // ---- 输入仲裁：7 流 → 单条报文 {stream, cid, pos, pri, data} ----
  // 流优先级（仲裁优先级，与报文 pri 无关）：OH_EXT > OH_INS > APS_EXT > APS_INS
  // > ALM > UART_EXT > UART_INS；同流多平面取编号小者
  logic        w_vld;
  logic [2:0]  w_stream;
  logic [2:0]  w_pri;
  logic [CID_W-1:0] w_cid;
  logic [POS_W-1:0] w_pos;
  logic [KO_W-1:0]  w_data;
  int w_q;   // 目标优先级队列

  always_comb begin
    w_vld = 1'b0;
    w_stream = 3'd0; w_pri = 3'd0; w_cid = '0; w_pos = '0; w_data = '0;
    for (int i = 0; i < NUM_OH_PLANES; i++)
      if (!w_vld && oh_e_vld[i]) begin
        w_vld = 1'b1; w_stream = 3'd0;
        w_pri = oh_e_pri[i*3 +: 3]; w_data = oh_e_data[i*KO_W +: KO_W];
        w_cid = oh_e_cid[i*CID_W +: CID_W]; w_pos = oh_e_pos[i*POS_W +: POS_W];
      end
    for (int i = 0; i < NUM_OH_PLANES; i++)
      if (!w_vld && oh_i_vld[i]) begin
        w_vld = 1'b1; w_stream = 3'd1;
        w_pri = oh_i_pri[i*3 +: 3]; w_data = oh_i_data[i*KO_W +: KO_W];
        w_cid = oh_i_cid[i*CID_W +: CID_W]; w_pos = oh_i_pos[i*POS_W +: POS_W];
      end
    for (int i = 0; i < NUM_X2X_PLANES; i++)
      if (!w_vld && aps_e_vld[i]) begin
        w_vld = 1'b1; w_stream = 3'd2;
        w_pri = aps_e_pri[i*3 +: 3]; w_data = aps_e_data[i*KO_W +: KO_W];
        w_cid = aps_e_cid[i*CID_W +: CID_W]; w_pos = aps_e_pos[i*POS_W +: POS_W];
      end
    for (int i = 0; i < NUM_X2X_PLANES; i++)
      if (!w_vld && aps_i_vld[i]) begin
        w_vld = 1'b1; w_stream = 3'd3;
        w_pri = aps_i_pri[i*3 +: 3]; w_data = aps_i_data[i*KO_W +: KO_W];
        w_cid = aps_i_cid[i*CID_W +: CID_W]; w_pos = aps_i_pos[i*POS_W +: POS_W];
      end
    for (int i = 0; i < NUM_X2X_PLANES; i++)
      if (!w_vld && alm_vld[i]) begin
        w_vld = 1'b1; w_stream = 3'd4;
        w_pri = alm_pri[i*3 +: 3]; w_data = alm_data[i*KO_W +: KO_W];
        w_cid = alm_cid[i*CID_W +: CID_W]; w_pos = alm_pos[i*POS_W +: POS_W];
      end
    if (!w_vld && u_e_vld) begin
      w_vld = 1'b1; w_stream = 3'd5;
      w_pri = u_e_pri; w_data = u_e_data; w_cid = '0; w_pos = '0;
    end
    if (!w_vld && u_i_vld) begin
      w_vld = 1'b1; w_stream = 3'd6;
      w_pri = u_i_pri; w_data = u_i_data; w_cid = '0; w_pos = '0;
    end
    w_q = int'(w_pri);
  end

  // ---- 输入反压：目标优先级队列未满 ----
  logic can_write;
  assign can_write = (w_q >= 0) && (q_cnt[w_q] != QUEUE_DEPTH);
  assign oh_e_rdy  = {NUM_OH_PLANES{can_write}};
  assign oh_i_rdy  = {NUM_OH_PLANES{can_write}};
  assign aps_e_rdy = {NUM_X2X_PLANES{can_write}};
  assign aps_i_rdy = {NUM_X2X_PLANES{can_write}};
  assign alm_rdy   = {NUM_X2X_PLANES{can_write}};
  assign u_e_rdy   = can_write;
  assign u_i_rdy   = can_write;

  // ---- 读侧：SP 选最高非空组（组号最小），组内 FIFO 出队 ----
  logic [2:0] sel_grp;
  logic       rd_valid;
  always_comb begin
    sel_grp = 3'd7;
    rd_valid = 1'b0;
    for (int g = 0; g < 8; g++)
      if (q_cnt[g] != 0 && !rd_valid) begin
        sel_grp = g;
        rd_valid = 1'b1;
      end
  end

  // ---- 输出（寄存一拍） ----
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
    end else begin
      // 写：入对应优先级队列
      if (w_vld && can_write) begin
        q_mem[w_q][q_tail[w_q]] <= {w_stream, w_cid, w_pos, w_data};
        q_tail[w_q] <= (q_tail[w_q] == QUEUE_DEPTH-1) ? '0 : q_tail[w_q] + 1'b1;
        q_cnt[w_q]  <= q_cnt[w_q] + 1'b1;
      end
      // 读：SP 出队（组内 FIFO）
      if (rd_valid) begin
        q_head[sel_grp] <= (q_head[sel_grp] == QUEUE_DEPTH-1) ? '0 : q_head[sel_grp] + 1'b1;
        q_cnt[sel_grp]  <= q_cnt[sel_grp] - 1'b1;
        out_vld    <= 1'b1;
        out_pri    <= sel_grp;
        out_src    <= sel_grp;
        out_stream <= q_mem[sel_grp][q_head[sel_grp]][PKG_W-1:PKG_W-3];
        out_cid    <= q_mem[sel_grp][q_head[sel_grp]][PKG_W-4-:CID_W];
        out_pos    <= q_mem[sel_grp][q_head[sel_grp]][PKG_W-4-CID_W-:POS_W];
        out_data   <= q_mem[sel_grp][q_head[sel_grp]][KO_W-1:0];
      end else begin
        out_vld <= 1'b0;
      end
    end
  end
endmodule
