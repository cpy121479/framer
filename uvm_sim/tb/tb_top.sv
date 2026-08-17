//----------------------------------------------------------------------------
// tb_top.sv - 顶层：时钟/复位、接口、DUT 占位、UVM 启动
//----------------------------------------------------------------------------
module tb_top;

  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import fgotn_pkg::*;

  logic clk   = 0;
  logic rst_n = 0;

  initial forever #5 clk = ~clk;               // 100 MHz
  initial begin
    repeat (5) @(posedge clk);
    rst_n = 1;
    fgotn_pkg::g_reset_done = 1;               // 复位完成握手：test 等待该标志再发激励
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

  // 波形：+WAVE 时输出 wave.vcd（Verilator 需 --trace 构建）
  initial begin
    if ($test$plusargs("WAVE")) begin
      $dumpfile("wave.vcd");
      $dumpvars(0, tb_top);
    end
  end

  initial begin
    // 兼容说明：Verilator 下从模块 initial 以 null 上下文写 config_db 可能取不到，
    // 因此同时填充全局握手对象 g_tb_cfg（含 vif），组件在 config_db 失败时回退读取。
    fgotn_pkg::g_tb_cfg = fgotn_agent_config::type_id::create("g_tb_cfg");
    fgotn_pkg::g_tb_cfg.vif = vif;
    uvm_config_db#(virtual fgotn_if)::set(null, "uvm_test_top", "vif", vif);
    run_test();                                // 时间 0 启动，测试名由 +UVM_TESTNAME 决定
  end

  // 兼容说明：Verilator 会把仅由 +UVM_TESTNAME 字符串引用的测试类当作死代码裁掉，
  // 这里显式引用全部测试类，保证 +UVM_TESTNAME 可选中任意测试。
  initial begin
    void'(fgotn_smoke_test::type_id::get());
    void'(fgotn_overhead_test::type_id::get());
    void'(fgotn_error_test::type_id::get());
    void'(fgotn_multiframe_test::type_id::get());
  end

endmodule
