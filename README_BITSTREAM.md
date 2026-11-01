# RV32IM with Victim Cache & Stride Prefetcher &mdash; FPGA Bitstream Guide

**Group:** 14 &nbsp;|&nbsp; **Target Board:** Digilent Nexys A7-100T (`xc7a100tcsg324-1`) &nbsp;|&nbsp; **Toolchain:** AMD Vivado 2022.1+ &nbsp;|&nbsp; **Clock:** 50 MHz CPU / 100 MHz System

This guide describes how to synthesize, implement, and generate the FPGA bitstream for the RV32IM processor with multi-level memory hierarchy (2 KB direct-mapped L1 cache, 4-entry victim cache, hardware stride prefetcher, and hardware performance profiler) on the Digilent Nexys A7-100T.

---

## 1. Top-Level Design Architecture

The FPGA top-level wrapper is `rtl/top/top_fpga.v`:

* **Processor Core (`rtl/core/pipeline.v`)**:
  * 3-stage RV32IM pipeline (IF, ID/EX, MEM/WB) operating at 50 MHz.
  * RV32M hardware multiplier/divider unit (`muldiv.v`) with DSP-accelerated single-cycle multiplication (`MUL_FAST=1`).
  * Dedicated load qualification signals (`dmem_load_pc`, `dmem_is_load`) exported to drive prefetch training.
* **Instruction Memory (`rtl/mem/memory.v`)**:
  * 16 KB single-cycle synchronous dual-port Block RAM initialized from `imem.hex`.
* **Memory Subsystem (`rtl/mem/mem_subsystem.v`)**:
  * **L1 Data Cache (`rtl/mem/l1_cache_controller.v`)**: 2 KB direct-mapped cache, 128 lines &times; 16 bytes, write-back + write-allocate, 0-stall hits.
  * **Victim Cache (`rtl/victim/victim_cache.v`)**: 4-entry fully associative cache with 2-cycle block swap and FIFO replacement (`SW[7]`).
  * **Hardware Stride Prefetcher (`rtl/prefetch/prefetcher.v`)**: 8-entry Reference Prediction Table (RPT), 2-bit confidence state machine, 1-entry prefetch buffer, store coherence snooping, and in-flight demand-miss merging (`SW[8]`).
  * **Main Memory (`rtl/mem/main_memory.v`)**: 16 KB 128-bit wide Block RAM with configurable latency ($N = 1, 10, 100, 200$ cycles).
  * **Hardware Cache Bypass (`SW[2]`)**: Direct un-cached memory access mode for architectural baseline comparison.
* **Hardware Performance Profiler (`rtl/perf/perf_profiler.v`)**:
  * 6 saturating 32-bit hardware event counters (Cycles, Memory Stalls, L1 Accesses, L1 Misses, Victim Cache Hits, Prefetch Hits).
  * Sticky mailbox done-freeze capture (`0x000001F8 = 1`).
  * Dynamic multiplexed 8-digit 7-segment display driver supporting single-metric and dual split-screen visualization.

---

## 2. Board Pinout & User Controls (`constraints/nexys_a7.xdc`)

### Slide Switches (`sw[15:0]`)

| Switch | Pin | Category | Function |
|:---|:---|:---|:---|
| `SW[1:0]` | `L16`, `J15` | Memory Latency | **Main Memory Latency Penalty ($N$)**:<br>&bull; `00`: $N = 1$ cycle<br>&bull; `01`: $N = 10$ cycles<br>&bull; `10`: $N = 100$ cycles<br>&bull; `11`: $N = 200$ cycles |
| `SW[2]` | `M13` | Hierarchy | **Hardware Cache Bypass**:<br>&bull; `0`: L1 Cache Active (cached)<br>&bull; `1`: L1 Cache Bypassed (uncached, all accesses go directly to main memory) |
| `SW[5:3]` | `T18`, `R17`, `R15` | Profiler | **7-Segment Display Metric Selector** (see Section 3 for details) |
| `SW[6]` | `U18` | Clock | **Clock Mode**:<br>&bull; `0`: 50 MHz fast CPU execution<br>&bull; `1`: 1 Hz human slow clock (visual single-stepping) |
| `SW[7]` | `R13` | Hierarchy | **Victim Cache Enable**:<br>&bull; `0`: Disabled (direct L1 miss to prefetcher/main memory)<br>&bull; `1`: Enabled (4-entry victim buffer active) |
| `SW[8]` | `T8` | Hierarchy | **Hardware Stride Prefetcher Enable**:<br>&bull; `0`: Disabled (RPT and buffer held in reset)<br>&bull; `1`: Enabled (8-entry RPT tracking and speculative prefetching active) |
| `SW[11:9]` | `T13`, `R16`, `U8` | Program | **Operation Result Selector** (active when `SW[5:3] = 110`):<br>&bull; `000`: Op 0 Matrix Inversion Result<br>&bull; `001`: Op 1 Vector Dot Product Result<br>&bull; `010`: Op 2 Array Accumulation Result<br>&bull; `011`: Op 3 Strided Transpose Sum Result<br>&bull; `100`: Combined Grand Total Checksum<br>&bull; `101`: Program Done Flag (`0x0001`) |
| `SW[12]` | `H6` | Display | **Dual Split-Screen Display Mode**:<br>&bull; `0`: Standard 32-bit single metric across all 8 digits<br>&bull; `1`: Dual split-screen (Left 4 digits = C Program Output, Right 4 digits = Profiler Counter) |
| `SW[15:13]`| `V10`, `U11`, `U12` | Display | **Left 4-Digit Display Source** (active in Split Mode `SW[12] = 1`):<br>&bull; `000`: Selected C Op Result (tracks `SW[11:9]`)<br>&bull; `001`: Op 0 Matrix Inversion (`0x1F0`)<br>&bull; `010`: Op 1 Vector Dot Product (`0x1F4`)<br>&bull; `011`: Op 2 Array Sum (`0x1E8`)<br>&bull; `100`: Op 3 Strided Transpose (`0x1EC`)<br>&bull; `101`: Grand Total Checksum (`0x1FC`)<br>&bull; `110`: Live Program Counter `PC[15:0]`<br>&bull; `111`: Program Done Flag |

### Push Buttons & Oscillator

| Signal | Pin | Description |
|:---|:---|:---|
| `clk` | `E3` | 100 MHz board oscillator (divided down to 50 MHz for CPU pipeline) |
| `reset` | `N17` | **BTNC** (center pushbutton, active-high, synchronized to `cpu_clk_50m`) |

### Status LEDs (`led[15:0]`)

| LED | Pin | Description |
|:---|:---|:---|
| `LED[15]` | `V11` | Program execution finished (sticky mailbox done-freeze active) |
| `LED[14]` | `V12` | Memory subsystem stall indicator (active during L1 miss / victim swap / refill) |
| `LED[13:8]`| `V14`, `V15`, `T16`, `U14`, `T15`, `V16` | Program Counter bits `pc[7:2]` (shows real-time code execution activity) |
| `LED[7:0]` | `U16`, `U17`, `V17`, `R18`, `N14`, `J13`, `K15`, `H17` | Direct hardware mirror of switch inputs `SW[7:0]` |

---

## 3. 7-Segment Display Modes

The Nexys A7 features an 8-digit multiplexed active-low 7-segment display (`an[7:0]`, `seg[6:0]`, `dp`). Two display modes are supported:

### Mode A: Standard Full 32-Bit Hex Metric (`SW[12] = 0`)
All 8 digits show the selected 32-bit hex value selected by `SW[5:3]`:

| `SW[5:3]` | Metric Displayed | Description |
|:---|:---|:---|
| `000` | **Total CPU Cycles** | Total clock cycles elapsed from reset to program completion |
| `001` | **Memory Stall Cycles** | Clock cycles the CPU pipeline was stalled waiting on memory |
| `010` | **L1 Cache Accesses** | Total load and store operations issued to the L1 cache |
| `011` | **L1 Cache Misses** | Demand misses requiring a refill from victim cache / DRAM |
| `100` | **Victim Cache Hits** | Evicted lines intercepted and swapped back from the victim cache |
| `101` | **Prefetch Hits** | L1 demand misses serviced in $\le 2$ cycles by the prefetch buffer |
| `110` | **Program Result** | C program computational output selected by `SW[11:9]` |

### Mode B: Dual Split-Screen Mode (`SW[12] = 1`)
Displays program data and hardware profiler metrics side-by-side simultaneously:
* **Left 4 Digits (`AN7` &ndash; `AN4`)**: 16-bit program result or execution state, selected by `SW[15:13]`.
* **Right 4 Digits (`AN3` &ndash; `AN0`)**: Lower 16 bits of the selected performance counter (`SW[5:3]`).

---

## 4. Hardware Demonstration Guide

### Preloaded Demonstration Workload
By default, the automated bitstream script copies `sw/conflict_thrash_*.hex` into `imem.hex`, `dmem.hex`, and `mem128.hex`.

### Experiment 1: Evaluating the Victim Cache
1. Set `SW[7] = 1` (Victim Cache ON), `SW[8] = 0` (Prefetcher OFF), `SW[2] = 0` (Cache ON), `SW[1:0] = 01` ($N=10$).
2. Press **BTNC** (`reset`) to run the workload.
3. Observe `LED[15]` turns ON when execution finishes.
4. Set `SW[5:3] = 100` to inspect **Victim Cache Hits** on the 7-segment display.
5. Set `SW[5:3] = 001` to inspect **Memory Stall Cycles**.
6. Switch `SW[7] = 0` (Victim Cache OFF) and press **BTNC** again. Notice the stall cycles increase dramatically as thrashing lines must pay the full $N=10$ penalty.

### Experiment 2: Evaluating the Stride Prefetcher
To demonstrate hardware prefetch speedups on strided access patterns:
1. Copy the strided benchmark hex files to the root directory before running bitstream generation:
   ```powershell
   Copy-Item sw\stride_sum_imem.hex imem.hex
   Copy-Item sw\stride_sum_dmem.hex dmem.hex
   Copy-Item sw\stride_sum_mem128.hex mem128.hex
   ```
2. Generate and download the bitstream.
3. Set `SW[8] = 0` (Prefetcher OFF), `SW[7] = 1` (VC ON), `SW[1:0] = 01` ($N=10$). Press **BTNC**.
   * Note total cycles (`SW[5:3] = 000`) and stall cycles (`SW[5:3] = 001`).
4. Set `SW[8] = 1` (Prefetcher ON). Press **BTNC**.
   * Check **Prefetch Hits** (`SW[5:3] = 101`).
   * Observe **~56% reduction in memory stall cycles** and **~35% overall execution speedup**.

---

## 5. Generating the Bitstream

### Prerequisites
* AMD Vivado 2020.2 or newer installed (`vivado` in `PATH`, or default install path `D:\AMDDesignTools\2025.2\Vivado\bin`).

### Method 1: Using Windows Batch Script
Double-click `build_bitstream.bat` or run from PowerShell / Command Prompt:
```cmd
build_bitstream.bat
```

### Method 2: Using Make (Linux / WSL / Git Bash)
```bash
make bitstream
```

### Method 3: Direct Vivado Batch Execution
```cmd
vivado -mode batch -nojournal -nolog -source scripts/vivado_bitstream.tcl
```

### Outputs
* **Bitstream:** `top_fpga.bit`
* **Implementation Reports:** `reports/`
  * `reports/post_synth_utilization.rpt` &mdash; Post-synthesis resource utilization
  * `reports/utilization.rpt` &mdash; Post-implementation hierarchical resource utilization
  * `reports/timing_summary.rpt` &mdash; Worst Negative Slack (WNS) and setup/hold timing analysis
  * `reports/drc_report.rpt` &mdash; Design rule check verification

---

## 6. Resource Utilization & Timing Closure

The complete processor and memory hierarchy is budgeted for the Nexys A7-100T Artix-7 device (`xc7a100tcsg324-1`):

| Resource | Nexys A7-100T Available | System Budget | Expected Utilization | % of Device |
|:---|:---|:---|:---|:---|
| **LUTs** | 63,400 | $\le 15\%$ (9,510) | ~4,200 | ~6.6% |
| **Registers (FF)** | 126,800 | $\le 15\%$ (19,020) | ~3,200 | ~2.5% |
| **Block RAM (RAMB36)** | 135 | $\le 15\%$ (20) | 16.5 | 12.2% |
| **DSP48E1 Slices** | 240 | $\le 8$ slices | 4 | 1.7% |

### Module-Level Hardware Budgets

| Module | Purpose | Estimated LUTs | Estimated FFs | BRAM Blocks |
|:---|:---|:---|:---|:---|
| `pipeline.v` + `muldiv.v` | 3-stage RV32IM core + DSP multiplier | ~2,200 | ~1,600 | 0 |
| `l1_cache_controller.v` | 2 KB direct-mapped L1 cache controller | ~600 | ~400 | 1 (Tag + Data) |
| `victim_cache.v` | 4-entry fully associative victim cache | ~350 | ~300 | 0 (Registers) |
| `prefetcher.v` | 8-entry RPT + 1-entry prefetch buffer | ~450 | ~420 | 0 (Registers) |
| `main_memory.v` | Configurable latency memory controller | ~150 | ~100 | 15.5 |
| `perf_profiler.v` | 6x 32-bit counters + 7-segment driver | ~400 | ~350 | 0 |

### Timing Closure
* **Target CPU Clock:** 50.0 MHz ($T_{\text{clk}} = 20.0\,\text{ns}$).
* **Timing Performance:** Worst Negative Slack (WNS) $\ge +3.0\,\text{ns}$ ($F_{\text{max}} \approx 60\text{--}63\,\text{MHz}$).
* **Critical Path:** EX-stage ALU operand forwarding to memory address generation. The prefetcher lookup and training are fully registered and do not create new timing-critical paths.

---

## 7. Programming the FPGA Board

1. Connect the Nexys A7-100T to your PC using a micro-USB cable (PROG / UART port `J6`).
2. Power on the board using the slide power switch (`SW0` near power jack).
3. Open Vivado Hardware Manager:
   ```cmd
   vivado -mode tcl
   ```
   ```tcl
   open_hw_manager
   connect_hw_server
   open_hw_target
   set_property PROGRAM.FILE {top_fpga.bit} [current_hw_device]
   program_hw_devices [current_hw_device]
   close_hw_manager
   ```
4. Verify `LED[7:0]` mirrors the initial switch positions, and the 7-segment display lights up.
5. Press **BTNC** (`reset`) to initiate program execution.
