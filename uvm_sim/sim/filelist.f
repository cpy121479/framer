// fgOTN UVM 平台编译文件清单（编译顺序即依赖顺序）
// 说明：RTL -> 接口 -> 包 -> 测试类 -> 顶层
../rtl/fgotn_dut_stub.sv
../tb/fgotn_if.sv
../uvm/fgotn_pkg.sv
../uvm/tests/fgotn_base_test.sv
../uvm/tests/fgotn_smoke_test.sv
../uvm/tests/fgotn_overhead_test.sv
../uvm/tests/fgotn_error_test.sv
../uvm/tests/fgotn_multiframe_test.sv
../tb/tb_top.sv
