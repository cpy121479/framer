#!/usr/bin/env bash
# run_verilator.sh - MSYS2 UCRT64 Verilator 构建并运行 KO 带宽 UVM 平台
# 用法：TESTNAME=ko_smoke_test NUM_FRAMES=100 ODU_TYPE=ODU2 OH_POS=8 WAVE=0 ./run_verilator.sh
set -e
cd "$(dirname "$0")"
export PATH=/ucrt64/bin:/usr/bin:$PATH

TESTNAME=${TESTNAME:-ko_smoke_test}
NUM_FRAMES=${NUM_FRAMES:-100}
ODU_TYPE=${ODU_TYPE:-ODU2}
OH_POS=${OH_POS:-8}
N_SLOTS=${N_SLOTS:-119}
FRAME_PERIOD_US=${FRAME_PERIOD_US:-0}
JITTER_PCT=${JITTER_PCT:-0}
USE_TREADY=${USE_TREADY:-0}
N_CHAN=${N_CHAN:-1}
P_PER_CHAN=${P_PER_CHAN:-0}
CHAN_SKEW=${CHAN_SKEW:-1}
WAVE_FILE=${WAVE_FILE:-wave.vcd}
WAVE=${WAVE:-0}

TOOLS=../tools
UVM_CORE=$TOOLS/uvm-core-main
M_DIR=obj_verilator

TRACE=
if [ "$WAVE" = "1" ]; then TRACE="--trace"; fi

if [ ! -f "$UVM_CORE/src/uvm.sv" ]; then
  echo "错误：未找到 uvm-core，请先复制 uvm_sim/tools 或执行 fetch_uvm_core.ps1" >&2
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

echo "=================================================="
echo "运行：$TESTNAME  NUM_FRAMES=$NUM_FRAMES  ODU=$ODU_TYPE  OH_POS=$OH_POS"
echo "=================================================="
./$M_DIR/simv +UVM_TESTNAME=$TESTNAME +NUM_FRAMES=$NUM_FRAMES \
  +ODU_TYPE=$ODU_TYPE +OH_POS=$OH_POS +N_SLOTS=$N_SLOTS +FRAME_PERIOD_US=$FRAME_PERIOD_US \
  +JITTER_PCT=$JITTER_PCT +USE_TREADY=$USE_TREADY +N_CHAN=$N_CHAN +P_PER_CHAN=$P_PER_CHAN +CHAN_SKEW=$CHAN_SKEW \
  +WAVE_FILE=$WAVE_FILE
