# RV32IM Pipeline with Multi-Level Memory Hierarchy — Victim Cache & Stride Prefetcher

**Group:** 14 &nbsp;|&nbsp; **Board:** Digilent Nexys A7-100T &nbsp;|&nbsp; **Tool:** Vivado / Icarus Verilog &nbsp;|&nbsp; **ISA:** RISC-V RV32IM

---

## Team

| Member | Area | Scope |
| :--- | :--- | :--- |
| **Abhishek Kumar** | L1 Cache & Memory Subsystem | Direct-mapped L1 cache controller, BRAM instantiation, memory interfacing |
| **Manas** | RV32M & Pipeline Hazard Unit | Multiplier/Divider datapath, RV32M execution logic, hazard detection |
| **Soham** | Victim Cache | Fully-associative victim cache, block swap logic, cache bypass routing |
| **Archit** | Stride Prefetcher & Profiler | 8-entry RPT prefetcher, performance counters, 7-segment display driver |

---

## Repository Layout

```
riscv-victim-cache/
├── rtl/
│   ├── core/      pipeline.v  IF_ID.v  execute.v  muldiv.v  wb.v
│   ├── mem/       l1_cache_controller.v  main_memory.v  mem_subsystem.v  memory.v
│   ├── victim/    victim_cache.v
│   ├── prefetch/  prefetcher.v          ← stride prefetcher (8-entry RPT + prefetch buffer)
│   ├── perf/      perf_profiler.v
│   └── top/       top_fpga.v
├── tb/            tb_l1_cache.v  tb_mem_subsystem.v  tb_prefetcher.v  tb_system.v  tb_top_fpga.v
├── scripts/       build_workloads.py  run_benchmarks.py  run_automated_regression.py  ...
├── sw/            *.hex workload files (7 workloads)
├── constraints/   nexys_a7.xdc
├── Makefile
└── README.md
```

---

## Quick Start

```bash
# Full automated regression (5,870 checks)
python scripts/run_automated_regression.py

# Individual targets
make sim_l1          # L1 + Victim Cache unit tests        (41  checks)
make sim_mem         # Memory subsystem unit tests          (22  checks)
make sim_prefetcher  # Stride prefetcher unit tests         (19  checks)
make sim_top         # Nexys A7 top-level board testbench   ( 8  checks)
make sim_system      # Full CPU + cache + profiler sim
make test_benchmarks # 7-workload benchmark suite
make test_cpu        # CPU pipeline random + directed tests (204 checks)
make sim_md          # RV32M mul/div golden model check

make clean
```

---

## Board Switch Map (Nexys A7 `SW[15:0]`)

| Switch | Function | Values |
| :--- | :--- | :--- |
| `SW[1:0]` | Main memory latency N | `00`=1, `01`=10, `10`=100, `11`=200 cycles |
| `SW[2]` | Cache bypass | `0`=cache active, `1`=uncached (bypass) |
| `SW[5:3]` | Profiler display selector | see table below |
| `SW[6]` | Clock mode | `0`=50 MHz run, `1`=1 Hz single-step |
| `SW[7]` | Victim cache enable | `0`=off, `1`=on |
| `SW[8]` | **Stride prefetcher enable** | `0`=off (reset), `1`=on |

**Profiler counter selector (`SW[5:3]`):**

| `SW[5:3]` | Metric displayed |
| :--- | :--- |
| `000` | Total CPU cycles |
| `001` | Memory stall cycles |
| `010` | L1 cache accesses |
| `011` | L1 cache misses |
| `100` | Victim cache hits |
| `101` | Prefetch hits |

**Status LEDs:**  `LED[15]`=done, `LED[14]`=mem-stall, `LED[13:8]`=PC[7:2], `LED[7]`=VC-en, `LED[6]`=slow-clk, `LED[5:3]`=prof-sel, `LED[2]`=bypass, `LED[1:0]`=latency

---

## Architecture

### 1. RV32IM 3-Stage Pipeline (`rtl/core/`)

A classic 3-stage (IF / ID+EX / MEM+WB) pipeline supporting the full RV32I base ISA plus the M-extension (multiply / divide / remainder).

- **IF:** Synchronous BRAM instruction memory, 1-cycle read.
- **ID/EX:** Combinational decode, register file, ALU, branch resolution, RV32M multi-cycle unit (`muldiv.v`). `MUL_FAST=1` uses a single-cycle DSP path.
- **MEM/WB:** Load/store interface to memory subsystem with synchronous read-data register. Exports `dmem_load_pc` (PC of EX-stage load) and `dmem_is_load` to train the prefetcher.

**Timing:** 50 MHz target, WNS = +4.22 ns (Fmax ≈ 63 MHz).

---

### 2. L1 Data Cache (`rtl/mem/l1_cache_controller.v`)

| Parameter | Value |
| :--- | :--- |
| Size | 2 KB |
| Organisation | Direct-mapped, 128 lines × 16 B |
| Address bits | Tag [31:11], Index [10:4], Word [3:2], Byte [1:0] |
| Write policy | Write-back + write-allocate |
| Hit latency | 0 stall cycles |
| Refill bus | 128-bit block, req/ack handshake |
| FPGA storage | Inferred BRAM (`ram_style = "block"`) |

**FSM states:** `IDLE → WRITE_BACK → WB_WAIT → ALLOCATE → RESP`

Exposes a 128-bit eviction bus (`victim_evict_valid / addr / data`) to feed the victim cache on dirty evictions.

---

### 3. Victim Cache (`rtl/victim/victim_cache.v`)

4-entry fully-associative buffer that catches lines evicted from L1, preventing the compulsory re-fetch cost on conflict misses.

- **Replacement:** FIFO.
- **Swap latency:** 2 stall cycles (victim line ↔ L1 line swap).
- **Enable:** `SW[7]` (runtime enable, no re-synthesis needed).

---

### 4. Hardware Stride Data Prefetcher (`rtl/prefetch/prefetcher.v`)

A speculative hardware prefetcher that detects constant-stride load patterns and pre-fetches the next cache line into a dedicated buffer before the CPU requests it.

#### Design Summary

| Parameter | Value |
| :--- | :--- |
| RPT entries | 8, direct-indexed by `load_pc[4:2]` |
| PC tag bits | 10 (`load_pc[14:5]`) |
| Stride register | 16-bit signed |
| Confidence FSM | 2-bit saturating: INIT → TRANSIENT → STEADY → NO_PRED |
| Prefetch buffer | 4 entries (fully-associative FIFO), 128-bit line + 28-bit tag + valid |
| Prefetch degree | 2 lines (+1 and +2 strides ahead) |
| Enable | `SW[8]` — when 0, tables held in reset, bus is transparent pass-through |

#### Hierarchy Lookup Order

```
CPU load → L1 cache (0 stalls) → Victim cache (2 stalls)
                                → Prefetch buffer (≤ 2 stalls)
                                → Main memory (N+2 stalls)
```

#### Key Design Decisions

- **No cache pollution:** speculative lines live in the prefetch buffer, not L1, until demanded.
- **Lowest-priority arbiter:** only issues to main memory when L1 FSM is idle and no demand miss or store writeback is pending.
- **In-flight demand merge:** if a CPU miss arrives for the same line that is being speculatively fetched, the prefetch is counted as a hit and no extra memory transaction is issued.
- **Store coherence:** stores snoop the prefetch buffer tag; a tag match invalidates the buffered line immediately to prevent stale reads.
- **Boundary guard:** targets outside the 16 KB data memory window are silently dropped.
- **Timing:** all inputs/outputs are registered; tag comparison does not sit on the critical stall path.

#### Module Port Reference

```
prefetcher #(ADDR_WIDTH=32, DATA_WIDTH=128, PF_ENTRIES=4, RPT_ENTRIES=8, PREFETCH_DEGREE=2)

  Control
    clk, rst
    prefetch_en   [1]    SW[8] — 0 = held in reset
    cache_bypass  [1]    SW[2] — 1 = prefetcher idle

  Training (from pipeline EX stage)
    is_load       [1]    asserted when EX-stage instruction is a load
    load_pc       [32]   PC of that load
    load_addr     [32]   effective data address
    load_stall    [1]    training gated while pipeline is stalled

  Store coherence
    store_valid   [1]    store commit strobe
    store_addr    [32]   store address

  L1 status
    l1_idle       [1]    L1 FSM in IDLE state
    l1_tag_hit    [1]    suppresses prefetch if target already in L1

  L1 ↔ Prefetcher bus (prefetcher sits between L1 and main memory)
    l1_mem_req    [1]  → demand miss request from L1
    l1_mem_we     [1]  → demand write-enable
    l1_mem_addr   [32] → demand address
    l1_mem_wdata  [128]→ demand write data
    l1_mem_rdata  [128]← refill data (muxed: prefetch buffer or DRAM)
    l1_mem_ack    [1]  ← acknowledge to L1

  Main memory bus
    main_mem_req  [1]  → request to main_memory
    main_mem_we   [1]  → write-enable
    main_mem_addr [32] → address (demand or speculative)
    main_mem_wdata[128]→ write data
    main_mem_rdata[128]← read data
    main_mem_ack  [1]  ← acknowledge from main_memory

  Profiler
    prefetch_hit  [1]  → pulses once per prefetch-buffer or merge hit
```

#### Cycle-Accurate Timing Trace (stride +16 B, N = 10)

```
Cycle  0  reset released; SW[8]=1; RPT cleared; pf_valid=0
Cycle  1  Load @ 0x0200 — L1 miss, CPU stalls, DRAM req issued
Cycle 11  DRAM ack; L1 refills 0x200; stall released
Cycle 12  RPT[0]: last_addr=0x0200, stride=0, conf=INIT
Cycle 13  Load @ 0x0210 — L1 miss, CPU stalls, DRAM req issued
Cycle 23  DRAM ack; L1 refills 0x210
Cycle 24  RPT[0]: stride=+16, conf still INIT (first observation)
Cycle 25  Load @ 0x0220 — L1 miss, CPU stalls, DRAM req issued
Cycle 35  DRAM ack; L1 refills 0x220
Cycle 36  RPT[0]: stride confirmed, conf → TRANSIENT
Cycle 37  Load @ 0x0230 — L1 miss, CPU stalls, DRAM req issued
Cycle 47  DRAM ack; L1 refills 0x230
Cycle 48  RPT[0]: stride confirmed again, conf → STEADY
           prediction fires: target = 0x0230 + 16 = 0x0240
Cycle 49  L1 idle → speculative DRAM req @ 0x0240, inflight=1
Cycles 50–58  prefetch in flight; CPU executes next instructions
Cycle 59  DRAM ack; pf_valid=1, pf_tag=0x0000024, line cached
Cycle 60  Load @ 0x0240 — L1 tag miss
           → prefetch buffer hit (l1_hit_pf_buf=1)
           → l1_mem_ack asserted immediately, prefetch_hit strobed
Cycle 61  L1 RESP state; line written into L1
Cycle 62  Load 5 retires — 2 stall cycles total vs 12 without prefetcher
```

---

### 5. Performance Profiler (`rtl/perf/perf_profiler.v`)

Six 32-bit saturating counters, selectable on the 8-digit 7-segment display via `SW[5:3]`:

| Counter | Signal |
| :--- | :--- |
| 0 | Total CPU cycles |
| 1 | Memory stall cycles |
| 2 | L1 accesses |
| 3 | L1 misses |
| 4 | Victim cache hits |
| 5 | **Prefetch hits** |

---

## Benchmark Results

All numbers from `python scripts/run_benchmarks.py`. Baseline = prefetcher off (`SW[8]=0`).

### L1 Cache vs Bypass (N = 100 cycles)

```
Workload         Mode       Cycles   Stalls   Hit Rate   Speedup
array_sum        Cache ON    3,563    1,734    93.4 %     —
                 Bypassed   28,347   26,518     —        +87.4 %
vector_dot       Cache ON    2,103    1,734    74.2 %     —
                 Bypassed    7,303    6,934     —        +71.2 %
conflict_thrash  Cache ON      511      366     2.9 %     —
                 Bypassed    3,815    3,670     —        +86.6 %
rw_persistence   Cache ON      662      512    81.5 %     —
                 Bypassed    3,914    3,764     —        +83.1 %
```

### Latency Scaling — array_sum

```
N    Cache ON             Bypassed
  1  1,880 cy (51  stalls)   2,607 cy ( 778 stalls)
 10  2,033 cy (204 stalls)   4,947 cy (3118 stalls)
100  3,563 cy (1734 stalls) 28,347 cy (26518 stalls)
200  5,263 cy (3434 stalls) 54,347 cy (52518 stalls)
```

### Stride Prefetcher — N = 10 cycles

```
Workload        PF    Cycles  Stalls  PF Hits  Stall ↓    Speedup
stride_sum      OFF   3,067   1,932      —       —          —
                ON    1,978     843    312      −56 %      +35 %
stride_mixed    OFF   2,269   1,548      —       —          —
                ON    1,669     948    120      −39 %      +26 %
complex_ops     OFF     649     243      —       —          —
                ON      619     213      6      −12 %       +5 %
array_sum       OFF   2,033     204      —       —          —
                ON    2,033     204     30        0 %        0 %   ← baseline invariant ✓
```

> All 5 original workloads produce **cycle-for-cycle identical results** when `SW[8]=0`.  
> Golden values: `array_sum=24960`, `vector_dot=1643`, `conflict_thrash=1440`, `rw_persistence=756`, `complex_ops=900`, `stride_sum=90160`, `stride_mixed=1372800`.

---

## Quantitative Targets vs Measured

| Goal | Target | Measured | Status |
| :--- | :--- | :--- | :--- |
| L1 hit rate (sequential) | ≥ 85 % | **93.4 %** | ✅ exceeded |
| Cycle reduction vs bypass (N=100) | ≥ 40 % | **87.4 %** | ✅ exceeded |
| Victim swap latency | ≤ 2 cycles | **2 cycles** | ✅ met |
| Prefetch buffer hit latency | ≤ 2 cycles | **2 cycles** | ✅ met |
| Stall reduction on strided workload | ≥ 40 % | **56.4 %** | ✅ exceeded |
| SW[8]=0 baseline invariance | 0 cycle diff | **0 cycle diff** | ✅ met |
| Automated regression | 100 % pass | **5,870 / 5,870** | ✅ met |
| Prefetcher LUT budget | ≤ 600 LUT | **~410 LUT (est.)** | ✅ met |
| System timing WNS | ≥ 0 ns @ 50 MHz | **+4.22 ns** | ✅ met |

---

## Regression Scorecard

```
================================================================================
  python scripts/run_automated_regression.py
================================================================================
Suite                                                Checks   Status   Time
--------------------------------------------------------------------------------
L1 Cache & Victim Cache unit tests                     41      PASS    0.69 s
Memory Subsystem unit tests                            22      PASS    0.33 s
Stride Prefetcher unit tests                           19      PASS    0.26 s
RV32M Multiplier/Divider verification                5568      PASS    1.30 s
CPU pipeline random + directed suite (FAST=0,1)       204      PASS   20.94 s
Full system sim (CPU + L1 + VC + Profiler)              1      PASS    0.65 s
Nexys A7 top-level board testbench                      8      PASS    0.62 s
7-workload benchmark suite                              7      PASS   16.00 s
--------------------------------------------------------------------------------
TOTAL  5,870 PASSED | 0 FAILED      total time: 40.78 s
================================================================================
```

---

## Vivado Integration

**Files to add as design sources:**

```tcl
read_verilog [list \
  rtl/core/opcode.vh  rtl/core/IF_ID.v  rtl/core/execute.v \
  rtl/core/muldiv.v   rtl/core/wb.v     rtl/core/pipeline.v \
  rtl/mem/memory.v    rtl/mem/main_memory.v \
  rtl/mem/l1_cache_controller.v  rtl/victim/victim_cache.v \
  rtl/mem/mem_subsystem.v  rtl/prefetch/prefetcher.v \
  rtl/perf/perf_profiler.v  rtl/top/top_fpga.v \
]
read_xdc constraints/nexys_a7.xdc
```

Run the full batch flow:

```bash
vivado -mode batch -source scripts/vivado_bitstream.tcl
```

**Expected resource footprint (Artix-7 xc7a100tcsg324-1):**

| Resource | Baseline | + Prefetcher | Budget |
| :--- | :--- | :--- | :--- |
| Slice LUTs | 1,944 (3.1 %) | ~2,354 (3.7 %) | ≤ 15 % |
| Slice Regs | 1,443 (1.1 %) | ~1,948 (1.5 %) | ≤ 15 % |
| BRAM tiles | 5 (3.7 %) | 5 (3.7 %) | ≤ 15 % |
| DSP48E1 | 4 (1.7 %) | 4 (1.7 %) | ≤ 8 |

**Timing:** WNS = +4.22 ns at 50 MHz (Fmax ≈ 63 MHz). Adding the prefetcher is not expected to create a new critical path — all its inputs/outputs are registered.

> [!WARNING]
> Vivado looks for `$readmemh` files relative to `<project>.runs/synth_1`. Add `imem.hex`, `dmem.hex`, and `mem128.hex` as **Memory Initialization Files** in the design sources panel, or copy them into the run directory before synthesis, otherwise BRAM initialisation will be skipped silently.

---

## FPGA Demo Guide

**Setup:** `SW[7]=1` (VC on), `SW[8]=1` (prefetcher on), `SW[1:0]=10` (N=100), `SW[2]=0` (cache on), `SW[6]=0` (50 MHz).  
Press **BTNC** to reset.

1. **Show cache speedup** — `SW[5:3]=000` (total cycles): ~3,563 with cache vs ~28,347 bypassed (`SW[2]=1`).
2. **Show prefetcher hits** — load a strided workload; `SW[5:3]=101` shows the prefetch hit counter climbing.
3. **Step through execution** — `SW[6]=1` (1 Hz), watch `LED[13:8]` advance one PC per second.
4. **Split-screen mode** — `SW[12]=1` shows the C-program result on the left four digits and the selected profiler metric on the right four digits simultaneously.
