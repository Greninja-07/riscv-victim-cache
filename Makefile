# =============================================================================
# Makefile for riscv-victim-cache
# =============================================================================

IVERILOG   ?= iverilog
VVP        ?= vvp
PYTHON     ?= python
VIVADO     ?= vivado
TCL_SCRIPT  = scripts/vivado_bitstream.tcl

# Directories
RTL_CORE   = rtl/core
RTL_MEM    = rtl/mem
RTL_VICTIM = rtl/victim
RTL_PERF   = rtl/perf
RTL_TOP    = rtl/top
RTL_PREFETCH = rtl/prefetch
TB_DIR     = tb
SCRIPTS    = scripts

# Simulation binaries and artifacts
SIM_L1     = sim_l1
SIM_MEM    = sim_mem
SIM_CPU    = sim_cpu
SIM_SYSTEM = sim_system
SIM_TOP    = sim_top

.PHONY: all test_all sim_l1 sim_mem sim_prefetcher sim_md sim_cpu test_cpu sim_system sim_top test_benchmarks report bitstream clean help

all: test_all

# Target: sim_l1 - Compile and run L1 Cache Controller unit testbench
sim_l1: $(RTL_MEM)/l1_cache_controller.v $(RTL_MEM)/main_memory.v $(RTL_VICTIM)/victim_cache.v $(TB_DIR)/tb_l1_cache.v
	$(IVERILOG) -g2005 -o $(SIM_L1) $(RTL_MEM)/l1_cache_controller.v $(RTL_MEM)/main_memory.v $(RTL_VICTIM)/victim_cache.v $(TB_DIR)/tb_l1_cache.v
	$(VVP) $(SIM_L1)

# Target: sim_mem - Compile and run Unified Memory Subsystem unit testbench
sim_mem: $(RTL_MEM)/mem_subsystem.v $(RTL_MEM)/l1_cache_controller.v $(RTL_MEM)/main_memory.v $(RTL_VICTIM)/victim_cache.v $(RTL_PREFETCH)/prefetcher.v $(TB_DIR)/tb_mem_subsystem.v
	$(IVERILOG) -g2005 -o $(SIM_MEM) $(RTL_MEM)/mem_subsystem.v $(RTL_MEM)/l1_cache_controller.v $(RTL_MEM)/main_memory.v $(RTL_VICTIM)/victim_cache.v $(RTL_PREFETCH)/prefetcher.v $(TB_DIR)/tb_mem_subsystem.v
	$(VVP) $(SIM_MEM)

# Target: sim_md - Run RV32M hardware multiplier/divider unit tests
sim_md:
	$(PYTHON) $(SCRIPTS)/md_test.py

# Target: sim_cpu - Compile and run RV32M pipelined CPU testbench
sim_cpu: $(RTL_CORE)/pipeline.v $(RTL_CORE)/IF_ID.v $(RTL_CORE)/execute.v $(RTL_CORE)/muldiv.v $(RTL_CORE)/wb.v $(RTL_MEM)/memory.v $(TB_DIR)/tb.v
	$(PYTHON) $(SCRIPTS)/gen_hex.py
	$(IVERILOG) -g2005 -I $(RTL_CORE) -o $(SIM_CPU) $(TB_DIR)/tb.v $(RTL_CORE)/pipeline.v $(RTL_CORE)/IF_ID.v $(RTL_CORE)/execute.v $(RTL_CORE)/muldiv.v $(RTL_CORE)/wb.v $(RTL_MEM)/memory.v
	$(VVP) $(SIM_CPU) +MAXC=2000

# Target: test_cpu - Test CPU with random programs and directed control-flow suite in MUL_FAST=0 and MUL_FAST=1
test_cpu: $(RTL_CORE)/pipeline.v $(RTL_CORE)/IF_ID.v $(RTL_CORE)/execute.v $(RTL_CORE)/muldiv.v $(RTL_CORE)/wb.v $(RTL_MEM)/memory.v $(TB_DIR)/tb.v
	$(IVERILOG) -g2005 -Ptb.FAST=0 -I $(RTL_CORE) -o $(SIM_CPU) $(TB_DIR)/tb.v $(RTL_CORE)/pipeline.v $(RTL_CORE)/IF_ID.v $(RTL_CORE)/execute.v $(RTL_CORE)/muldiv.v $(RTL_CORE)/wb.v $(RTL_MEM)/memory.v
	$(PYTHON) $(SCRIPTS)/sys_test.py $(SIM_CPU) 100
	$(PYTHON) $(SCRIPTS)/directed_cf_test.py $(SIM_CPU)
	$(PYTHON) $(SCRIPTS)/directed_auipc_test.py $(SIM_CPU)
	$(IVERILOG) -g2005 -Ptb.FAST=1 -I $(RTL_CORE) -o $(SIM_CPU) $(TB_DIR)/tb.v $(RTL_CORE)/pipeline.v $(RTL_CORE)/IF_ID.v $(RTL_CORE)/execute.v $(RTL_CORE)/muldiv.v $(RTL_CORE)/wb.v $(RTL_MEM)/memory.v
	$(PYTHON) $(SCRIPTS)/sys_test.py $(SIM_CPU) 100
	$(PYTHON) $(SCRIPTS)/directed_cf_test.py $(SIM_CPU)
	$(PYTHON) $(SCRIPTS)/directed_auipc_test.py $(SIM_CPU)

# Target: sim_system - Compile full-system CPU + L1 + Profiler testbench
sim_system:
	$(PYTHON) $(SCRIPTS)/build_workloads.py
	$(PYTHON) -c "import shutil; shutil.copy('sw/array_sum_imem.hex', 'imem.hex'); shutil.copy('sw/array_sum_dmem.hex', 'dmem.hex'); shutil.copy('sw/array_sum_mem128.hex', 'mem128.hex')"
	$(IVERILOG) -g2005 -I $(RTL_CORE) -I $(RTL_MEM) -I $(RTL_PERF) -I $(RTL_VICTIM) -I $(RTL_PREFETCH) -o $(SIM_SYSTEM) \
		$(TB_DIR)/tb_system.v \
		$(RTL_CORE)/pipeline.v $(RTL_CORE)/IF_ID.v $(RTL_CORE)/execute.v $(RTL_CORE)/muldiv.v $(RTL_CORE)/wb.v \
		$(RTL_MEM)/memory.v $(RTL_MEM)/mem_subsystem.v $(RTL_MEM)/l1_cache_controller.v $(RTL_MEM)/main_memory.v \
		$(RTL_VICTIM)/victim_cache.v $(RTL_PERF)/perf_profiler.v $(RTL_PREFETCH)/prefetcher.v
	$(VVP) $(SIM_SYSTEM) +LATENCY=2 +CACHE_BYPASS=0 +MAXC=50000

# Target: sim_top - Compile and run top-level Nexys A7 FPGA hardware testbench
sim_top:
	$(PYTHON) $(SCRIPTS)/build_workloads.py
	$(PYTHON) -c "import shutil; shutil.copy('sw/array_sum_imem.hex', 'imem.hex'); shutil.copy('sw/array_sum_dmem.hex', 'dmem.hex'); shutil.copy('sw/array_sum_mem128.hex', 'mem128.hex')"
	$(IVERILOG) -g2005 -I $(RTL_CORE) -I $(RTL_MEM) -I $(RTL_PERF) -I $(RTL_VICTIM) -I $(RTL_TOP) -I $(RTL_PREFETCH) -o $(SIM_TOP) \
		$(TB_DIR)/tb_top_fpga.v \
		$(RTL_TOP)/top_fpga.v \
		$(RTL_CORE)/pipeline.v $(RTL_CORE)/IF_ID.v $(RTL_CORE)/execute.v $(RTL_CORE)/muldiv.v $(RTL_CORE)/wb.v \
		$(RTL_MEM)/memory.v $(RTL_MEM)/mem_subsystem.v $(RTL_MEM)/l1_cache_controller.v $(RTL_MEM)/main_memory.v \
		$(RTL_VICTIM)/victim_cache.v $(RTL_PERF)/perf_profiler.v $(RTL_PREFETCH)/prefetcher.v
	$(VVP) $(SIM_TOP)

# Target: sim_prefetcher - Compile and run Stride Prefetcher unit testbench
sim_prefetcher: $(RTL_PREFETCH)/prefetcher.v $(RTL_MEM)/main_memory.v $(TB_DIR)/tb_prefetcher.v
	$(IVERILOG) -g2005 -Wall -o sim_prefetcher $(RTL_PREFETCH)/prefetcher.v $(RTL_MEM)/main_memory.v $(TB_DIR)/tb_prefetcher.v
	$(VVP) sim_prefetcher

# Target: test_benchmarks - Run complete benchmark suite across workloads and cache configurations
test_benchmarks:
	$(PYTHON) $(SCRIPTS)/build_workloads.py
	$(PYTHON) $(SCRIPTS)/run_benchmarks.py

# Target: test_all - Run all simulation suites
test_all: sim_l1 sim_mem sim_prefetcher sim_md sim_cpu test_cpu sim_system sim_top test_benchmarks

# Target: report - Generate executive terminal verification & performance report
report:
	$(PYTHON) $(SCRIPTS)/report_summary.py

# Target: bitstream - Synthesize, implement, and generate top_fpga.bit
bitstream:
	@echo "==> Running Vivado Bitstream Generation Flow for top_fpga..."
	$(VIVADO) -mode batch -nojournal -nolog -source $(TCL_SCRIPT)

# Target: clean - Remove simulation executables, dumps, and temporary files
clean:
	rm -f $(SIM_L1) $(SIM_MEM) $(SIM_CPU) $(SIM_SYSTEM) $(SIM_TOP) md0 md1
	rm -f waveform.vcd md_vec.txt imem.hex dmem.hex mem128.hex perf_profiler.vcd
	rm -rf __pycache__ $(SCRIPTS)/__pycache__
	rm -rf .Xil/ reports/ *.log *.jou *.dcp *.bit *.bin fsm_encoding.os .cache/

help:
	@echo "Available targets:"
	@echo "  make test_all        - Run all simulation suites (L1, Mem, MD, CPU, System, Top, Benchmarks)"
	@echo "  make sim_l1          - Run L1 cache controller unit testbench"
	@echo "  make sim_mem         - Run Unified Memory Subsystem unit testbench"
	@echo "  make sim_cpu         - Run RV32M pipelined CPU testbench"
	@echo "  make test_cpu        - Run randomized CPU tests and directed test suites"
	@echo "  make sim_system      - Run full-system CPU + L1 + Profiler testbench"
	@echo "  make sim_top         - Run Nexys A7 FPGA hardware testbench"
	@echo "  make test_benchmarks - Run all benchmark workloads"
	@echo "  make bitstream       - Synthesize, implement, and generate top_fpga.bit"
	@echo "  make clean           - Remove simulation artifacts, Vivado temporary files and reports"
