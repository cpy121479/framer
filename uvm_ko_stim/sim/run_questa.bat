@echo off
rem run_questa.bat <testname> <seed> <num_frames>  （本机未装 Questa，脚本按标准流程提供）
set TESTNAME=%1
set SEED=%2
set NUM_FRAMES=%3
if "%TESTNAME%"=="" set TESTNAME=ko_smoke_test
if "%SEED%"=="" set SEED=1
if "%NUM_FRAMES%"=="" set NUM_FRAMES=100
vlib work
vlog -sv -uvm +incdir+..\uvm +incdir+..\tb ..\tb\ko_if.sv ..\uvm\ko_pkg.sv ..\tb\tb_top.sv
vsim -c -do "run -all; quit" +UVM_TESTNAME=%TESTNAME% +NUM_FRAMES=%NUM_FRAMES% +OH_POS=%OH_POS% work.tb_top
