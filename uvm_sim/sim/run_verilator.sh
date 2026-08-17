#!/usr/bin/env bash
#----------------------------------------------------------------------------
# run_verilator.sh - 用 MSYS2 UCRT64 的 Verilator 5.050 构建并运行 UVM 平台
# 用法（在 sim 目录或任意目录执行均可）：
#   TESTNAME=fgotn_smoke_test NUM_FRAMES=10 SEED=1 WAVE=0 ./run_verilator.sh
# 依赖：MSYS2 + mingw-w64-ucrt-x86_64-{verilator,gcc,libgnurx,libsystre}
#      以及 tools/uvm-core-main（Accellera uvm-core，已按 Verilator 打补丁）
#----------------------------------------------------------------------------
set -e

cd "$(dirname "$0")"

export PATH=/ucrt64/bin:/usr/bin:$PATH

TESTNAME=${TESTNAME:-fgotn_smoke_test}
SEED=${SEED:-1}
NUM_FRAMES=${NUM_FRAMES:-10}
WAVE=${WAVE:-0}

TOOLS=../tools
UVM_CORE=$TOOLS/uvm-core-main
M_DIR=obj_verilator

TRACE=
if [ "$WAVE" = "1" ]; then
  TRACE="--trace"
fi

if [ ! -f "$UVM_CORE/src/uvm.sv" ]; then
  echo "错误：未找到 uvm-core（$UVM_CORE/src/uvm.sv），请先执行 tools/fetch_uvm_core.ps1" >&2
  exit 1
fi

verilator --timing --binary -O1 --build-jobs 4 $TRACE \
  --top-module tb_top -Wno-fatal -Wno-SYMRSVDWORD \
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
echo "运行测试：$TESTNAME  SEED=$SEED  NUM_FRAMES=$NUM_FRAMES"
echo "=================================================="
./$M_DIR/simv +UVM_TESTNAME=$TESTNAME +UVM_TEST_SEED=$SEED +NUM_FRAMES=$NUM_FRAMES $([ "$WAVE" = "1" ] && echo +WAVE)
