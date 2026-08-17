@echo off
rem Windows wrapper: invoke run_verilator.sh via MSYS2 bash
setlocal
set BASH=C:\msys64\usr\bin\bash.exe
if not exist "%BASH%" (
  echo MSYS2 bash not found: %BASH%
  exit /b 1
)
if "%TESTNAME%"=="" set TESTNAME=fgotn_smoke_test
if "%SEED%"=="" set SEED=1
if "%NUM_FRAMES%"=="" set NUM_FRAMES=10
if "%WAVE%"=="" set WAVE=0
"%BASH%" -lc "cd \"$(cygpath -u '%~dp0')\" && TESTNAME=$TESTNAME SEED=$SEED NUM_FRAMES=$NUM_FRAMES WAVE=$WAVE ./run_verilator.sh"
endlocal
