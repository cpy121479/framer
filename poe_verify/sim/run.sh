#!/usr/bin/env bash
# 精简版 EU 功能验证平台：构建 + 运行（无 UVM，约 20~40s）
# 用法：cd poe_verify/sim && ./run.sh
set -e
cd "$(dirname "$0")"
export PATH=/ucrt64/bin:/usr/bin:$PATH

TOOLS=../../uvm_poe/tools

verilator --binary --timing -O1 -Wall -Wno-fatal -Wno-DECLFILENAME \
  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD -Wno-UNUSEDSIGNAL \
  -I../rtl -I../eu -I../tb -I/ucrt64/share/verilator/include \
  -CFLAGS "-I/ucrt64/share/verilator/include/vltstd" -LDFLAGS "-lgnurx" \
  -Mdir obj_verilator --top-module tb_top \
  $TOOLS/verilator_link_fixes.cpp \
  -f filelist.f -o simv

./obj_verilator/simv
