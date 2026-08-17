//----------------------------------------------------------------------------
// top.sv — 顶层：时钟/复位、接口、DUT stub、UVM 启动
//----------------------------------------------------------------------------
module tb_top;

  import uvm_pkg::*;
  `include "uvm_macros.svh"
  `include "fgotn_pkg.sv"
  import fgotn_pkg::*;

  logic clk   = 0;
  logic rst_n = 0;

  initial forever #5 clk = ~clk;               // 100 MHz
  initial begin
    repeat (3) @(posedge clk);
    rst_n = 1;
  end

  fgotn_if vif(.clk(clk), .rst_n(rst_n));

  fgotn_dut_stub dut (
    .clk   (clk),
    .rst_n (rst_n),
    .tdata (vif.tdata),
    .tvalid(vif.tvalid),
    .tready(vif.tready),
    .tstart(vif.tstart),
    .tend  (vif.tend)
  );

  initial begin
    uvm_config_db#(virtual fgotn_if)::set(null, "uvm_test_top", "vif", vif);
    run_test("fgotn_base_test");
  end

endmodule

// DUT 占位模块：始终 ready 的帧接收侧，仅统计字节/帧数
module fgotn_dut_stub (
  input  logic clk,
  input  logic rst_n,
  input  logic [7:0] tdata,
  input  logic       tvalid,
  output logic       tready,
  input  logic       tstart,
  input  logic       tend
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
