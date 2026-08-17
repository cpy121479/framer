`timescale 1ns/1ps
module tb_top;
  import uvm_pkg::*;
  import ko_pkg::*;

  logic clk   = 0;
  logic rst_n = 0;

  always #1.6ns clk = ~clk;   // 312.5 MHz

  ko_if u_if(.clk(clk), .rst_n(rst_n));

  // 复位握手：复位完成后置位包级 g_reset_done
  initial begin
    rst_n = 0;
    repeat (5) @(posedge clk);
    rst_n = 1;
    ko_pkg::g_reset_done = 1;
  end

  // 反压源：默认 tready=1；开启 use_tready 时 90% 周期就绪
  always @(posedge clk) begin
    if (ko_pkg::g_tb_cfg.use_tready)
      u_if.tready <= (($urandom % 10) < 9);
    else
      u_if.tready <= 1'b1;
  end

  initial begin
    string wf;
    if ($value$plusargs("WAVE_FILE=%s", wf))
      $dumpfile(wf);
    else
      $dumpfile("wave.vcd");
    $dumpvars(0, tb_top);
  end

  // 旁路信号默认值（首个 KO 之前保持无效，避免波形 X）
  initial begin
    u_if.ko_chan_id = 7'd0;
    u_if.sf_vld = 1'b0; u_if.sf_row = 3'd0; u_if.sf_col = 12'd0; u_if.sf_frame_idx = 16'd0;
    u_if.fg_vld = 1'b0; u_if.fg_row = 3'd0; u_if.fg_col = 12'd0; u_if.fg_frame_idx = 16'd0;
  end

  initial begin
    ko_pkg::g_tb_cfg.vif = u_if;
    // 显式引用测试类，防止 Verilator 当作死代码优化掉
    void'(ko_smoke_test::type_id::get());
    run_test();
  end
endmodule
