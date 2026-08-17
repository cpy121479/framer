SHELL := /usr/bin/env bash
SIM ?= verilator
TESTNAME ?= ko_smoke_test
NUM_FRAMES ?= 100

.PHONY: run clean

run:
	TESTNAME=$(TESTNAME) NUM_FRAMES=$(NUM_FRAMES) ./run_verilator.sh

clean:
	rm -rf obj_verilator simv wave.vcd
