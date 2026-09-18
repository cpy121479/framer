#!/usr/bin/env bash
# UVM 版运行（复用 uvm_poe/tools/uvm-core-main）
# 用法：cd poe_verify/sim && TESTNAME=poe_base_test ./run_uvm.sh
set -e
cd "$(dirname "$0")"
export PATH=/ucrt64/bin:/usr/bin:$PATH

TESTNAME=${TESTNAME:-poe_base_test}
TOOLS=../../uvm_poe/tools
UVM_CORE=$TOOLS/uvm-core-main
M_DIR=obj_uvm

verilator --timing --binary -O1 --build-jobs 4 \
  --top-module uvm_tb_top -Wno-fatal -Wno-SYMRSVDWORD -Wno-TIMESCALEMOD \
  -Wno-COVERIGN -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-CASTCONST -Wno-REALCVT \
  -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY -Wno-VARHIDDEN \
  -CFLAGS "-I/ucrt64/share/verilator/include/vltstd -DDPI_DLLISPEC= -DPLI_DLLISPEC=" \
  -LDFLAGS "-lgnurx" \
  -I../uvm -I../tb -I../rtl -I../eu -I$UVM_CORE/src \
  --Mdir $M_DIR \
  $UVM_CORE/src/uvm.sv $UVM_CORE/src/dpi/uvm_dpi.cc \
  $TOOLS/verilator_link_fixes.cpp \
  -f filelist_uvm.f -o simv

./$M_DIR/simv +UVM_TESTNAME=$TESTNAME +UVM_VERBOSITY=UVM_LOW
