#!/usr/bin/env bash
# 线程池多线程冒烟（池级，不依赖 EU / 平台；约 20s 编译 + 1s 仿真）
# 用法：cd poe_verify/sim && ./run_pool_smoke.sh
set -e
cd "$(dirname "$0")"
export PATH=/ucrt64/bin:/usr/bin:$PATH

TOOLS=../../uvm_poe/tools

verilator --binary --timing -O1 -Wall -Wno-fatal -Wno-DECLFILENAME \
  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD -Wno-UNUSEDSIGNAL -Wno-SYNCASYNCNET \
  -I../rtl -I../eu -I../tb -I/ucrt64/share/verilator/include \
  -CFLAGS "-I/ucrt64/share/verilator/include/vltstd" -LDFLAGS "-lgnurx" \
  -Mdir obj_pool_smoke --top-module pool_smoke_tb \
  $TOOLS/verilator_link_fixes.cpp \
  -f filelist_pool_smoke.f -o simv

./obj_pool_smoke/simv
