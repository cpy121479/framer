@echo off
setlocal
if "%TESTNAME%"=="" set TESTNAME=ko_smoke_test
if "%NUM_FRAMES%"=="" set NUM_FRAMES=100
if "%OTU_TYPE%"=="" set OTU_TYPE=OTU2
if "%OH_POS%"=="" set OH_POS=16
if "%WAVE%"=="" set WAVE=0
C:\msys64\usr\bin\bash.exe -lc "cd /c/Users/92541/Documents/ChatGPT/framer/uvm_ko_stim/sim && TESTNAME=%TESTNAME% NUM_FRAMES=%NUM_FRAMES% OTU_TYPE=%OTU_TYPE% OH_POS=%OH_POS% WAVE=%WAVE% ./run_verilator.sh"
