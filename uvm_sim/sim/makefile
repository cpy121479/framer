#----------------------------------------------------------------------------
# fgOTN UVM 平台 Makefile（在 sim 目录执行）
# 用法：
#   make run SIM=questa TESTNAME=fgotn_smoke_test SEED=1 NUM_FRAMES=10
#   make run SIM=vcs    TESTNAME=fgotn_overhead_test
#   make run SIM=xrun   TESTNAME=fgotn_error_test
#   make verilator      TESTNAME=fgotn_multiframe_test WAVE=1   (本机 Verilator)
#   make wave           TESTNAME=fgotn_smoke_test               (Questa 波形)
#   make clean
#----------------------------------------------------------------------------
SIM        ?= questa
TESTNAME   ?= fgotn_smoke_test
SEED       ?= 1
NUM_FRAMES ?= 10
WAVE       ?= 0

UVM_DIR := ../uvm
TB_DIR  := ../tb
RTL_DIR := ../rtl

.PHONY: compile run wave verilator clean

compile:
	@if [ "$(SIM)" = "questa" ]; then \
	  vlib work && vlog -sv -uvm +incdir+$(UVM_DIR) +incdir+$(TB_DIR) +incdir+$(RTL_DIR) -f filelist.f; \
	elif [ "$(SIM)" = "vcs" ]; then \
	  vcs -sverilog -ntb_opts uvm-1.2 +incdir+$(UVM_DIR) +incdir+$(TB_DIR) +incdir+$(RTL_DIR) -f filelist.f -o simv_vcs; \
	elif [ "$(SIM)" = "xrun" ]; then \
	  xrun -uvm +incdir+$(UVM_DIR) +incdir+$(TB_DIR) +incdir+$(RTL_DIR) -f filelist.f -elaborate; \
	fi

run: compile
	@if [ "$(SIM)" = "questa" ]; then \
	  vsim -c work.tb_top +UVM_TESTNAME=$(TESTNAME) +UVM_TEST_SEED=$(SEED) +NUM_FRAMES=$(NUM_FRAMES) -do "run -all; quit -f"; \
	elif [ "$(SIM)" = "vcs" ]; then \
	  ./simv_vcs +UVM_TESTNAME=$(TESTNAME) +UVM_TEST_SEED=$(SEED) +NUM_FRAMES=$(NUM_FRAMES); \
	elif [ "$(SIM)" = "xrun" ]; then \
	  xrun -R +UVM_TESTNAME=$(TESTNAME) +UVM_TEST_SEED=$(SEED) +NUM_FRAMES=$(NUM_FRAMES); \
	fi

wave: compile
	vsim -c work.tb_top +UVM_TESTNAME=$(TESTNAME) +UVM_TEST_SEED=$(SEED) +NUM_FRAMES=$(NUM_FRAMES) -do "log -r /*; run -all; quit -f"

verilator:
	TESTNAME=$(TESTNAME) SEED=$(SEED) NUM_FRAMES=$(NUM_FRAMES) WAVE=$(WAVE) bash ./run_verilator.sh

clean:
	rm -rf work simv simv_vcs xcelium.d xrun.log obj_verilator wave.vcd
