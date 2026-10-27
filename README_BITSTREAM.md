# RVM32I with Victim Cache & Profiler &mdash; FPGA Bitstream Generation Guide

This guide details the Vivado bitstream generation flow for the RV32IM processor with 2 KB L1 data cache, 4-entry victim cache, and hardware performance profiler on the **Digilent Nexys A7 100T** FPGA board (`xc7a100tcsg324-1`).

---

## 1. Top-Level Design Architecture
* **Top-Level Target**: `rtl/top/top_fpga.v`
  * **Processor Core**: 3-stage pipelined RV32IM with single-cycle DSP multiplier (`MUL_FAST=1`).
  * **Instruction Memory**: 16 KB BRAM initialized with demo workload.
  * **Memory Subsystem** (`rtl/mem/mem_subsystem.v`):
    * 2 KB direct-mapped L1 data cache (`l1_cache_controller.v`).
    * 4-entry fully associative victim cache (`victim_cache.v`) with 2-cycle block swap refill.
    * Configurable latency main memory (`main_memory.v`).
  * **Performance Profiler & 7-Segment Driver** (`rtl/perf/perf_profiler.v`):
    * 6x 32-bit saturating hardware event counters.
    * Sticky mailbox done-freeze capture (`0x000001F8 = 1`).
    * Multiplexed 8-digit 7-segment hex display.

---

## 2. Board Pinout & User Controls (`constraints/nexys_a7.xdc`)

### Controls & Switches
| Signal | Pin | Function |
|---|---|---|
| `clk` | `E3` | 100 MHz board oscillator |
| `reset` | `N17` | **BTNC** (center pushbutton, active-high, synchronized internally) |
| `sw[7]` | `R13` | **Victim Cache Enable**: `1` = Enabled, `0` = Disabled |
| `sw[6]` | `U18` | **Clock Speed**: `0` = 50 MHz fast execution, `1` = 1 Hz human stepping |
| `sw[5:3]` | `R17`, `R15`, `M13` | **7-Segment Display Counter Selector**: <br>&bull; `000`: Total Cycles<br>&bull; `001`: Memory Stall Cycles<br>&bull; `010`: L1 Cache Accesses<br>&bull; `011`: L1 Cache Misses<br>&bull; `100`: **Victim Cache Hits**<br>&bull; `101`: Prefetch Hits |
| `sw[2]` | `M13` | **Hardware Cache Bypass**: `0` = L1 enabled, `1` = Uncached |
| `sw[1:0]` | `L16`, `J15` | **Memory Latency Penalty**: `00` = N=1, `01` = N=10, `10` = N=100, `11` = N=200 |

### Status LEDs (`led[15:0]`)
| LED | Pin | Description |
|---|---|---|
| `led[15]` | `V11` | Program execution finished (sticky done-freeze active) |
| `led[14]` | `V12` | Memory subsystem stall in progress |
| `led[13:8]`| `V14`, `V15`, `T16`, `U14`, `T15`, `V16` | Program Counter bits `pc[7:2]` |
| `led[7:0]` | &mdash; | Real-time mirror of active slide switch configurations |

---

## 3. Generating the Bitstream

### Default Preloaded Workload
By default, the automated flow preloads the **`conflict_thrash`** benchmark (`sw/conflict_thrash_*.hex`). When running on board:
1. Turn `SW[7] = 1` (Victim Cache ON) and observe the 7-segment display on `SW[5:3] = 100` showing victim cache hits intercepting thrashing lines.
2. Turn `SW[7] = 0` (Victim Cache OFF) and observe stall cycles (`SW[5:3] = 001`) spike due to full DRAM penalties.

### Method 1: Using the Batch Script (Windows)
Double-click `build_bitstream.bat` or run:
```bat
build_bitstream.bat
```

### Method 2: Using Make (Linux / WSL / Git Bash)
```bash
make bitstream
```

### Method 3: Direct Vivado Batch Mode
```bash
vivado -mode batch -nojournal -nolog -source scripts/vivado_bitstream.tcl
```

Output bitstream is written to: `top_fpga.bit`.
Comprehensive reports are saved in: `reports/`.
