# =============================================================================
# Makefile for riscv-victim-cache
# =============================================================================

IVERILOG ?= iverilog
VVP      ?= vvp
PYTHON   ?= python3

# Directories
RTL_CORE = rtl/core
RTL_MEM  = rtl/mem
RTL_TOP  = rtl/top
TB_DIR   = tb
SCRIPTS  = scripts

# Simulation binaries and artifacts
SIM_L1   = sim_l1
SIM_CPU  = sim_cpu

.PHONY: all test_all sim_l1 sim_md sim_cpu test_cpu clean

all: test_all

# Target: sim_l1 - Compile and run L1 Cache Controller unit testbench
sim_l1: $(RTL_MEM)/l1_cache_controller.v $(RTL_MEM)/main_memory.v $(TB_DIR)/tb_l1_cache.v
	$(IVERILOG) -g2005 -o $(SIM_L1) $(RTL_MEM)/l1_cache_controller.v $(RTL_MEM)/main_memory.v $(TB_DIR)/tb_l1_cache.v
	$(VVP) $(SIM_L1)

# Target: sim_md - Run RV32M hardware multiplier/divider unit tests
sim_md:
	$(PYTHON) $(SCRIPTS)/md_test.py

# Target: sim_cpu - Compile and run RV32M pipelined CPU testbench
sim_cpu: $(RTL_CORE)/pipeline.v $(RTL_CORE)/IF_ID.v $(RTL_CORE)/execute.v $(RTL_CORE)/muldiv.v $(RTL_CORE)/wb.v $(RTL_MEM)/memory.v $(TB_DIR)/tb.v
	$(PYTHON) $(SCRIPTS)/gen_hex.py
	$(IVERILOG) -g2005 -I $(RTL_CORE) -o $(SIM_CPU) $(TB_DIR)/tb.v $(RTL_CORE)/pipeline.v $(RTL_CORE)/IF_ID.v $(RTL_CORE)/execute.v $(RTL_CORE)/muldiv.v $(RTL_CORE)/wb.v $(RTL_MEM)/memory.v
	$(VVP) $(SIM_CPU) +MAXC=2000

# Target: test_cpu - Test CPU with 100 random programs in MUL_FAST=0 and MUL_FAST=1
test_cpu: $(RTL_CORE)/pipeline.v $(RTL_CORE)/IF_ID.v $(RTL_CORE)/execute.v $(RTL_CORE)/muldiv.v $(RTL_CORE)/wb.v $(RTL_MEM)/memory.v $(TB_DIR)/tb.v
	$(IVERILOG) -g2005 -Ptb.FAST=0 -I $(RTL_CORE) -o $(SIM_CPU) $(TB_DIR)/tb.v $(RTL_CORE)/pipeline.v $(RTL_CORE)/IF_ID.v $(RTL_CORE)/execute.v $(RTL_CORE)/muldiv.v $(RTL_CORE)/wb.v $(RTL_MEM)/memory.v
	$(PYTHON) $(SCRIPTS)/sys_test.py $(SIM_CPU) 100
	$(IVERILOG) -g2005 -Ptb.FAST=1 -I $(RTL_CORE) -o $(SIM_CPU) $(TB_DIR)/tb.v $(RTL_CORE)/pipeline.v $(RTL_CORE)/IF_ID.v $(RTL_CORE)/execute.v $(RTL_CORE)/muldiv.v $(RTL_CORE)/wb.v $(RTL_MEM)/memory.v
	$(PYTHON) $(SCRIPTS)/sys_test.py $(SIM_CPU) 100

# Target: test_all - Run all simulation suites
test_all: sim_l1 sim_md sim_cpu test_cpu

# Target: clean - Remove simulation executables, dumps, and temporary files
clean:
	rm -f $(SIM_L1) $(SIM_CPU) md0 md1
	rm -f waveform.vcd md_vec.txt imem.hex dmem.hex
	rm -rf __pycache__ $(SCRIPTS)/__pycache__
