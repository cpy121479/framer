@echo off
setlocal
if "%TESTNAME%"=="" set TESTNAME=koa_smoke_test
if "%RUN_US%"=="" set RUN_US=200
if "%N_OH_PLANES%"=="" set N_OH_PLANES=4
if "%N_X2X_PLANES%"=="" set N_X2X_PLANES=8
if "%UART_MPPS%"=="" set UART_MPPS=60
if "%WAVE%"=="" set WAVE=0
C:\msys64\usr\bin\bash.exe -lc "cd /c/Users/92541/Documents/ChatGPT/framer/uvm_poe/sim && TESTNAME=%TESTNAME% RUN_US=%RUN_US% N_OH_PLANES=%N_OH_PLANES% N_X2X_PLANES=%N_X2X_PLANES% UART_MPPS=%UART_MPPS% WAVE=%WAVE% ./run_verilator.sh"
