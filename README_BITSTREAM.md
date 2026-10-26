# RVM32I FPGA Bitstream Flow

This directory contains the complete Vivado bitstream generation flow for the RVM32I pipelined RISC-V processor on the **Digilent Nexys A7 100T** FPGA board (`xc7a100tcsg324-1`).

## Flow Summary
1. **Top-Level Target**: `top_fpga.v`
   - Incorporates `pipe` CPU, `instr_mem`, and `data_mem`.
   - Divides 100 MHz board clock down to 1 Hz for visual verification on LEDs.
   - Maps lower 16 bits of the Program Counter (`pc_disp`) to board LEDs `led[15:0]`.
2. **Constraints**: `constraints/nexys_a7.xdc`
   - Clock pin `E3` (100 MHz oscillator).
   - Reset button `C12` (CPU_RESETN, active-low).
   - 16 LEDs `led[0]` to `led[15]`.
3. **Synthesis & Implementation**:
   - Executes full top-level synthesis, physical optimization, placement, routing, and generates `top_fpga.bit`.

## Generating the Bitstream
### Method 1: Using the Batch Script (Windows)
Double-click `build_bitstream.bat` or run:
```bat
build_bitstream.bat
```

### Method 2: Using Make (Linux / Git Bash)
```bash
make bitstream
```

### Method 3: Direct Vivado Command
```bash
vivado -mode batch -source scripts/vivado_bitstream.tcl
```
