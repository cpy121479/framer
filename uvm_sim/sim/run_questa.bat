@echo off
rem One-click compile+run for Questa/ModelSim (vlog/vsim must be in PATH)
rem Usage: run_questa.bat [TESTNAME] [SEED] [NUM_FRAMES]
setlocal
if "%1"=="" (set TESTNAME=fgotn_smoke_test) else (set TESTNAME=%1)
if "%2"=="" (set SEED=1) else (set SEED=%2)
if "%3"=="" (set NUM_FRAMES=10) else (set NUM_FRAMES=%3)

if exist work rmdir /s /q work
vlib work
if defined UVM_HOME (
  vlog -sv +incdir+%UVM_HOME%\src %UVM_HOME%\src\uvm_pkg.sv +incdir+..\uvm +incdir+..\tb +incdir+..\rtl -f filelist.f
) else (
  vlog -sv -uvm +incdir+..\uvm +incdir+..\tb +incdir+..\rtl -f filelist.f
)
vsim -c work.tb_top +UVM_TESTNAME=%TESTNAME% +UVM_TEST_SEED=%SEED% +NUM_FRAMES=%NUM_FRAMES% -do "run -all; quit -f"
endlocal
