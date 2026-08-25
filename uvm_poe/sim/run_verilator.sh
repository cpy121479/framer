#!/usr/bin/env bash
# run_verilator.sh - MSYS2 UCRT64 Verilator 构建并运行 KOA 调度 UVM 平台
# 用法：TESTNAME=koa_smoke_test RUN_US=200 N_PLANES=4 UART_MPPS=120 WAVE=1 ./run_verilator.sh
set -e
cd "$(dirname "$0")"
export PATH=/ucrt64/bin:/usr/bin:$PATH

TESTNAME=${TESTNAME:-koa_smoke_test}
RUN_US=${RUN_US:-200}
N_OH_PLANES=${N_OH_PLANES:-4}
OH_SLOTS=${OH_SLOTS:-9520}
OH_PLANE_SKEW=${OH_PLANE_SKEW:-1}
N_X2X_PLANES=${N_X2X_PLANES:-8}
X2X_SLOTS=${X2X_SLOTS:-9520}
X2X_PLANE_SKEW=${X2X_PLANE_SKEW:-1}
N_CH=${N_CH:-8}
UART_MPPS=${UART_MPPS:-60}
WAVE_FILE=${WAVE_FILE:-wave.vcd}
WAVE=${WAVE:-0}
# benchmark 场景参数：SEED（$urandom 种子）/ TPL_MASK（可选模板位掩码，bit i=Ti）/
# BENCH_TAG（结果行标签）/ MEAS_SKIP（测量窗口跳过的预热拍数）/
# RW_MODE（读写返回模式：0=SMC 写10-20/读70-80 拍，1=L1 写5-10/读10-15 拍）/
# PRE_OCC（pre_read 占据 ts 数，默认 3，范围 1..4）
SEED=${SEED:-}
TPL_MASK=${TPL_MASK:-}
BENCH_TAG=${BENCH_TAG:-bench}
MEAS_SKIP=${MEAS_SKIP:-2000}
RW_MODE=${RW_MODE:-}
PRE_OCC=${PRE_OCC:-}

TOOLS=../tools
UVM_CORE=$TOOLS/uvm-core-main
M_DIR=obj_verilator

TRACE=
if [ "$WAVE" = "1" ]; then TRACE="--trace"; fi

if [ ! -f "$UVM_CORE/src/uvm.sv" ]; then
  echo "错误：未找到 uvm-core，请先复制 tools 或执行 fetch_uvm_core.ps1" >&2
  exit 1
fi

verilator --timing --binary -O1 --build-jobs 4 $TRACE \
  --top-module tb_top -Wno-fatal -Wno-SYMRSVDWORD \
  -Wno-TIMESCALEMOD \
  -Wno-COVERIGN -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-CASTCONST -Wno-REALCVT \
  -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
  -CFLAGS "-I/ucrt64/share/verilator/include/vltstd -DDPI_DLLISPEC= -DPLI_DLLISPEC=" \
  -LDFLAGS "-lgnurx" \
  -I../uvm -I../tb -I../rtl -I$UVM_CORE/src \
  --Mdir $M_DIR \
  $UVM_CORE/src/uvm.sv \
  $UVM_CORE/src/dpi/uvm_dpi.cc \
  $TOOLS/verilator_link_fixes.cpp \
  -f filelist.f -o simv

SEED_ARG=""
if [ -n "$SEED" ]; then SEED_ARG="+verilator+seed+$SEED +BENCH_SEED=$SEED"; fi
TPL_ARG=""
if [ -n "$TPL_MASK" ]; then TPL_ARG="+TPL_MASK=$TPL_MASK"; fi
RW_ARG=""
if [ -n "$RW_MODE" ]; then RW_ARG="+RW_MODE=$RW_MODE"; fi
PRE_ARG=""
if [ -n "$PRE_OCC" ]; then PRE_ARG="+PRE_OCC=$PRE_OCC"; fi

echo "=================================================="
echo "运行：$TESTNAME  RUN_US=$RUN_US  OH=$N_OH_PLANES x$OH_SLOTS  X2X=$N_X2X_PLANES x$X2X_SLOTS  UART=$UART_MPPS"
echo "      SEED=${SEED:-默认}  TPL_MASK=${TPL_MASK:-全开}  RW_MODE=${RW_MODE:-0(SMC)}  PRE_OCC=${PRE_OCC:-3}  TAG=$BENCH_TAG  MEAS_SKIP=$MEAS_SKIP"
echo "=================================================="
./$M_DIR/simv +UVM_TESTNAME=$TESTNAME +RUN_US=$RUN_US \
  +N_OH_PLANES=$N_OH_PLANES +OH_SLOTS=$OH_SLOTS +OH_PLANE_SKEW=$OH_PLANE_SKEW \
  +N_X2X_PLANES=$N_X2X_PLANES +X2X_SLOTS=$X2X_SLOTS +X2X_PLANE_SKEW=$X2X_PLANE_SKEW \
  +N_CH=$N_CH +UART_MPPS=$UART_MPPS +WAVE_FILE=$WAVE_FILE \
  +BENCH_TAG=$BENCH_TAG +MEAS_SKIP=$MEAS_SKIP $SEED_ARG $TPL_ARG $RW_ARG $PRE_ARG
