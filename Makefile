# Makefile for RVM32I Bitstream Generation
VIVADO ?= vivado
TCL_SCRIPT = scripts/vivado_bitstream.tcl

.PHONY: all bitstream clean help

all: bitstream

bitstream:
	@echo "==> Running Vivado Bitstream Generation Flow..."
	$(VIVADO) -mode batch -nojournal -nolog -source $(TCL_SCRIPT)

clean:
	@echo "==> Cleaning generated logs, temporary files, and reports..."
	rm -rf .Xil/ reports/ *.log *.jou *.dcp *.bit fsm_encoding.os

help:
	@echo "Available targets:"
	@echo "  make bitstream  - Synthesize, implement, and generate top_fpga.bit"
	@echo "  make clean      - Remove Vivado temporary files and output artifacts"
