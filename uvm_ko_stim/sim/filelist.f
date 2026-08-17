// KO 带宽 UVM 平台编译文件清单（编译顺序即依赖顺序）
// uvm.sv / uvm_dpi.cc / verilator_link_fixes.cpp 由 run 脚本在命令行传入
../tb/ko_if.sv
../uvm/ko_pkg.sv
../tb/tb_top.sv
