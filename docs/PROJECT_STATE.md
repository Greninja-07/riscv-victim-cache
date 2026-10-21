# Project state (as of Mon 19 Oct 2026)

**Project:** Memory hierarchy enhancement of a 3-stage RV32IM core (Group 14).
Board: Nexys A7-100T (XC7A100T). Tools: Vivado 2025.2, iverilog + python3 in WSL.
Team: Manas (core/hazard/L1 integration), Abhishek (L1, main_memory, bypass),
Soham (C workloads, victim cache), Archit (perf_profiler, top_fpga, prefetcher).
Repo: github.com/Greninja-07/riscv-victim-cache

## Scope tiers
- Commitment: RV32M, configurable-latency memory (N=1/10/100/200), 2 KB direct-mapped
  L1 D-cache, unified stall, perf counters + 7-seg.
- Goal: 4-entry victim cache + swap + on/off switch.
- Stretch: stride prefetcher (8 entries, PC-indexed) + on/off switch, latency sweep.
- Prof's rules rule: >=5 C workloads, FPGA demo (2.5 marks), >=20 commits/member,
  timing diagram >=25 cycles x2 scenarios, every member writes >=1 HW module.

## Layout
rtl/core (pipeline.v, IF_ID.v, execute.v, wb.v, muldiv.v, opcode.vh),
rtl/mem (memory.v, main_memory.v, l1_cache_controller.v), rtl/top (top_fpga.v),
tb/, scripts/, sw/, constraints/nexys_a7.xdc, docs/. `scratch/` is gitignored.

## Core facts (verified)
- 3 stages: IF_ID / execute / wb. Instruction memory is synchronous, `instruction`
  is combinational (do NOT register it: adds a 4th stage, shifts branch targets +4).
- Forwarding: WB->EX mux in pipeline.v; load-use needs no bubble with data_mem.
- stall_n is active-low (0 = hold, 1 = update); registers update on `else if (stall_n)`.
- MUL_FAST=1 default: MUL/MULH* = 1 cycle, DIV/REM = 33 cycles. 4 DSP48E1.
- AUIPC supported. ECALL/EBREAK/FENCE not (software avoids them).
- Reset: core active-low; l1_cache_controller and main_memory active-high.
  Board pin reset = BTNC (N17), active-high at the pin, core gets ~reset.
- Memories: MEM_BYTES parameter, default 16384. main_memory is 128-bit blocks,
  INIT_FILE loaded via $readmemh, format {word3,word2,word1,word0};
  scripts/pack_hex128.py converts. data_mem still uses per-byte bypass (may not infer BRAM).
- L1: 14 tests pass; clean miss = N+2 stalls, dirty miss ~2N+4; data array read is
  combinational (will not infer BRAM; LUTRAM/FF, update resource table).
- Fixed bugs (all on main): stall_n polarity, registered-instruction (+4 branch),
  JAL/JALR link write blocked by !wb_stall, multi-driven wb_branch/wb_branch_nxt.

## Verification
`make test_all` (run in WSL, must pass before every merge): L1 tb (14), md_test
(5,568 vectors/mode), sys_test (100 random programs per MUL_FAST mode),
directed_cf_test, directed_auipc_test. sys_test has no JAL/JALR/backward branches
(directed test covers one of each).

## Vivado (out-of-context, core only, 50 MHz, routed)
WNS +4.216 ns, WHS +0.121, ~2,170 LUT, 1,443 FF, 4 DSP, 0 critical warnings.
Worst path: id_ex src reg -> reg read mux -> 2 DSP48E1 -> carry chain -> muldiv ph.
100 MHz would fail. Reports: docs/reports/. Run:
`cd scratch; vivado -mode batch -source D:\riscv-victim-cache\scripts\vivado_timing.tcl`
(PATH: D:\AMDDesignTools\2025.2\Vivado\bin).

## Conventions / gotchas
- PowerShell: no `&&`; one command per line. Tests run via `wsl bash -c "cd /mnt/d/riscv-victim-cache && make test_all"`.
- Keep file line endings (check `git diff --stat` stays small; `git ls-files --eol`).
- Small commits, no squashing, `git merge --no-ff`, one branch per feature.
- Agent reports must label claims VERIFIED BY SIMULATION / VIVADO LOG / REASONED FROM CODE;
  past agent audits contained misreadings, so verify before acting.

## Open items
1. Manas: wire L1 into pipeline (combine cpu_stall with md_stall/branch stalls; hit = 0
   stall; keep request stable while stalled). Gate 1: Tue 21 Oct sim; Gate 2: Fri 24 Oct FPGA.
2. Abhishek: cache-bypass switch, victim-fill/swap port + prefetch port (freeze by 21 Oct),
   run workloads at N=1/10/100/200 cache on/off.
3. Soham: sw/ toolchain (-march=rv32im -mabi=ilp32 -mcmodel=medlow -fno-pic -mno-relax
   -nostdlib, custom crt0, linker for 16 KB, elf->hex), 5 workloads, victim_cache.v + tb.
4. Archit: perf_profiler.v (6x32-bit counters: cycles, stall cycles, L1 access, L1 miss,
   victim hits, prefetch hits; done-freeze; 7-seg hex driver) + tb; new 50 MHz top level
   (BUFGCE-gated run/step, synchronized reset, switches, 7-seg; extend xdc from Digilent
   master XDC, don't guess pins); prefetcher Python model, then RTL after L1 ports freeze.
5. Status Report 25 Oct, Mini Demo 27 Oct, near-final 1 Nov, final 5 Nov, demo 7-8 Nov.
6. Update resource table with real numbers (L1 data array/tags in LUTRAM/FF).