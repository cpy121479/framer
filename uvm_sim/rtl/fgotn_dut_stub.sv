//----------------------------------------------------------------------------
// fgotn_dut_stub.sv - fgOTN DUT 占位模块（帧接收侧）
// 恒拉 tready，统计接收字节数与帧数；后续可替换为真实 RTL。
//----------------------------------------------------------------------------
module fgotn_dut_stub (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [7:0]  tdata,
  input  logic        tvalid,
  output logic        tready,
  input  logic        tstart,
  input  logic        tend
);

  logic [31:0] byte_cnt;
  logic [15:0] frame_cnt;

  assign tready = 1'b1;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      byte_cnt  <= '0;
      frame_cnt <= '0;
    end else if (tvalid && tready) begin
      byte_cnt <= byte_cnt + 1;
      if (tstart) frame_cnt <= frame_cnt + 1;
    end
  end

endmodule
