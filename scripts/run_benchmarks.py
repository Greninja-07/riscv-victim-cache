#!/usr/bin/env python3
"""
run_benchmarks.py - Automated Performance Benchmarking & Evaluation Suite
Evaluates RV32IM CPU with L1 Data Cache, 4-Entry Victim Cache, and Stride Prefetcher
across configurable memory latencies (N = 1, 10, 100, 200 cycles).
"""

import os
import sys
import subprocess
import shutil

# Ensure UTF-8 output encoding across platforms (e.g. Windows consoles)
if hasattr(sys.stdout, 'reconfigure'):
    try:
        sys.stdout.reconfigure(encoding='utf-8')
    except Exception:
        pass

ROOT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SW_DIR   = os.path.join(ROOT_DIR, "sw")


SIM_BIN  = os.path.join(ROOT_DIR, "sim_system")

WORKLOADS = [
    {
        "name": "array_sum",
        "desc": "Sequential Array Traversal (Locality Test)",
        "expected": 24960,
    },
    {
        "name": "vector_dot",
        "desc": "Vector Dot Product (RV32M MUL + Memory)",
        "expected": 1643,
    },
    {
        "name": "conflict_thrash",
        "desc": "Cache Conflict Thrashing (2KB Stride Collision)",
        "expected": 1440,
    },
    {
        "name": "rw_persistence",
        "desc": "Read-Modify-Write Persistence (Dirty Eviction)",
        "expected": 756,
    },
    {
        "name": "complex_ops",
        "desc": "Matrix Inversion + Vector Dot + Array Sum + Strided Transpose",
        "expected": 900,
    },
    {
        "name": "stride_sum",
        "desc": "Strided Array Sum (Stride 16B across 2.5KB > 2KB L1)",
        "expected": 90160,
    },
    {
        "name": "stride_mixed",
        "desc": "Dual Strided Streams (16B & 32B Strides + RV32M MUL)",
        "expected": 1372800,
    }
]

def compile_sim():
    """Compile the full system simulation executable."""
    cmd = [
        "iverilog", "-g2005",
        f"-I{RTL_DIR}/core",
        f"-I{RTL_DIR}/mem",
        f"-I{RTL_DIR}/perf",
        f"-I{RTL_DIR}/victim",
        f"-I{RTL_DIR}/prefetch",
        "-o", SIM_BIN,
        f"{TB_DIR}/tb_system.v",
        f"{RTL_DIR}/core/pipeline.v",
        f"{RTL_DIR}/core/IF_ID.v",
        f"{RTL_DIR}/core/execute.v",
        f"{RTL_DIR}/core/muldiv.v",
        f"{RTL_DIR}/core/wb.v",
        f"{RTL_DIR}/mem/memory.v",
        f"{RTL_DIR}/mem/l1_cache_controller.v",
        f"{RTL_DIR}/mem/main_memory.v",
        f"{RTL_DIR}/mem/mem_subsystem.v",
        f"{RTL_DIR}/victim/victim_cache.v",
        f"{RTL_DIR}/perf/perf_profiler.v",
        f"{RTL_DIR}/prefetch/prefetcher.v"
    ]
    res = subprocess.run(cmd, cwd=ROOT_DIR, capture_output=True, text=True)
    if res.returncode != 0:
        print("Compilation failed:\n", res.stderr)
        sys.exit(1)

def run_workload(name, bypass, latency_code, prefetch_en=0):
    """Setup hex files and run simulation."""
    shutil.copy(os.path.join(SW_DIR, f"{name}_imem.hex"), os.path.join(ROOT_DIR, "imem.hex"))
    shutil.copy(os.path.join(SW_DIR, f"{name}_dmem.hex"), os.path.join(ROOT_DIR, "dmem.hex"))
    shutil.copy(os.path.join(SW_DIR, f"{name}_mem128.hex"), os.path.join(ROOT_DIR, "mem128.hex"))

    cmd = [
        "vvp", SIM_BIN,
        f"+CACHE_BYPASS={bypass}",
        f"+LATENCY={latency_code}",
        f"+PREFETCH_EN={prefetch_en}",
        "+MAXC=100000"
    ]
    res = subprocess.run(cmd, cwd=ROOT_DIR, capture_output=True, text=True)
    out = res.stdout

    # Parse results
    metrics = {
        "status": "FAIL",
        "result": None,
        "total_cycles": None,
        "stall_cycles": None,
        "l1_accesses": None,
        "l1_hits": None,
        "l1_misses": None,
        "hit_rate": None,
        "prefetch_hits": 0
    }
    for line in out.splitlines():
        line = line.strip()
        if "Mailbox Result" in line:
            parts = line.split(":")
            if len(parts) > 1:
                metrics["result"] = int(parts[1].split("(")[-1].replace(")", "").strip())
        elif "Total Cycles" in line:
            metrics["total_cycles"] = int(line.split(":")[-1].strip())
        elif "Mem Stall Cycles" in line:
            metrics["stall_cycles"] = int(line.split(":")[-1].strip())
        elif "L1 Accesses" in line:
            metrics["l1_accesses"] = int(line.split(":")[-1].strip())
        elif "L1 Hits" in line:
            metrics["l1_hits"] = int(line.split(":")[-1].strip())
        elif "L1 Misses" in line:
            metrics["l1_misses"] = int(line.split(":")[-1].strip())
        elif "L1 Hit Rate" in line:
            metrics["hit_rate"] = float(line.split(":")[-1].replace("%", "").strip())
        elif "Prefetch Hits" in line:
            metrics["prefetch_hits"] = int(line.split(":")[-1].strip())
        elif "Status" in line and "SUCCESS" in line:
            metrics["status"] = "PASS"

    return metrics

def main():
    print("=" * 88)
    print("  RISC-V MEMORY HIERARCHY BENCHMARK & EVALUATION SUITE")
    print("  Author: Group 14 (Abhishek Kumar, Soham, Archit, Manas)")
    print("=" * 88)

    # First compile build_workloads.py to make sure hex files exist
    subprocess.run([sys.executable, os.path.join(ROOT_DIR, "scripts", "build_workloads.py")], cwd=ROOT_DIR, check=True)

    print("\n[INFO] Compiling full system simulation...")
    compile_sim()
    print("[INFO] Compilation successful!")

    # Dynamic switch latencies (SW[1:0]):
    LATENCIES = [
        (0, 1,   "N=1   (Zero-benefit baseline)"),
        (1, 10,  "N=10  (L2-like latency)"),
        (2, 100, "N=100 (Default DRAM latency)"),
        (3, 200, "N=200 (High latency penalty)")
    ]

    all_passed = True

    # -------------------------------------------------------------------------
    # EXPERIMENT 1: L1 Cache ON vs Bypassed (N = 10 cycles)
    # -------------------------------------------------------------------------
    print("\n" + "=" * 88)
    print("  EXPERIMENT 1: L1 CACHE ENABLED VS CACHE BYPASS (N = 10 cycles, Prefetch OFF)")
    print("=" * 88)
    print(f"{'Workload':<18} | {'Mode':<10} | {'Cycles':<8} | {'Stalls':<8} | {'Hits/Miss':<12} | {'Hit Rate':<8} | {'Speedup'}")
    print("-" * 88)

    for wl in WORKLOADS:
        name = wl["name"]
        exp  = wl["expected"]

        m_on  = run_workload(name, bypass=0, latency_code=1, prefetch_en=0)
        m_off = run_workload(name, bypass=1, latency_code=1, prefetch_en=0)

        # Check correctness
        if m_on["result"] != exp or m_off["result"] != exp:
            print(f"[FAIL] {name}: Expected {exp}, got on={m_on['result']}, off={m_off['result']}")
            all_passed = False
            continue

        c_on = m_on["total_cycles"]
        c_off = m_off["total_cycles"]
        speedup = ((c_off - c_on) / c_off) * 100.0 if c_off else 0.0

        hits_str = f"{m_on['l1_hits']}/{m_on['l1_misses']}"
        hr_str = f"{m_on['hit_rate']:.1f}%" if m_on['hit_rate'] is not None else "N/A"

        print(f"{name:<18} | Cache ON   | {c_on:<8} | {m_on['stall_cycles']:<8} | {hits_str:<12} | {hr_str:<8} | Reference")
        print(f"{'':<18} | Bypassed   | {c_off:<8} | {m_off['stall_cycles']:<8} | {'Bypassed':<12} | {'0.0%':<8} | {speedup:+.1f}% cycles saved")
        print("-" * 88)

    # -------------------------------------------------------------------------
    # EXPERIMENT 2: Latency Penalty Scaling (N = 1, 10, 100, 200)
    # -------------------------------------------------------------------------
    print("\n" + "=" * 88)
    print("  EXPERIMENT 2: LATENCY PENALTY SCALING (N = 1, 10, 100, 200)")
    print("=" * 88)
    print(f"{'Latency Mode':<28} | {'Array Sum (Cache ON)':<22} | {'Array Sum (Bypassed)':<22}")
    print("-" * 88)

    for code, n, label in LATENCIES:
        m_on  = run_workload("array_sum", bypass=0, latency_code=code, prefetch_en=0)
        m_off = run_workload("array_sum", bypass=1, latency_code=code, prefetch_en=0)
        print(f"{label:<28} | {m_on['total_cycles']:<8} cycles (stalls: {m_on['stall_cycles']:<3}) | {m_off['total_cycles']:<8} cycles (stalls: {m_off['stall_cycles']:<3})")

    # -------------------------------------------------------------------------
    # EXPERIMENT 3: Stride Prefetcher Evaluation (Deliverable F)
    # Prefetcher OFF (SW[8]=0) vs Prefetcher ON (SW[8]=1) across all N
    # -------------------------------------------------------------------------
    print("\n" + "=" * 88)
    print("  EXPERIMENT 3: HARDWARE STRIDE PREFETCHER EVALUATION (OFF vs ON across Latencies)")
    print("=" * 88)

    for code, n, label in LATENCIES:
        print(f"\n--- Memory Latency N = {n} Cycles ({label.strip()}) ---")
        print(f"{'Workload':<16} | {'PF Mode':<7} | {'Cycles':<7} | {'Stalls':<7} | {'L1 Miss':<7} | {'PF Hits':<7} | {'Stall Red%':<10} | {'Cycle Red%'}")
        print("-" * 88)

        for wl in WORKLOADS:
            name = wl["name"]
            exp  = wl["expected"]

            m_off = run_workload(name, bypass=0, latency_code=code, prefetch_en=0)
            m_on  = run_workload(name, bypass=0, latency_code=code, prefetch_en=1)

            # Functional correctness check across ON vs OFF vs Golden
            if m_off["result"] != exp or m_on["result"] != exp:
                print(f"[FAIL] {name}: Golden={exp}, got OFF={m_off['result']}, ON={m_on['result']}")
                all_passed = False
                continue

            c_off = m_off["total_cycles"]
            c_on  = m_on["total_cycles"]
            s_off = m_off["stall_cycles"]
            s_on  = m_on["stall_cycles"]

            stall_red = ((s_off - s_on) / s_off) * 100.0 if s_off > 0 else 0.0
            cycle_red = ((c_off - c_on) / c_off) * 100.0 if c_off > 0 else 0.0

            pf_hits = m_on["prefetch_hits"]

            print(f"{name:<16} | OFF     | {c_off:<7} | {s_off:<7} | {m_off['l1_misses']:<7} | {0:<7} | {'-':<10} | Reference")
            print(f"{'':<16} | ON      | {c_on:<7} | {s_on:<7} | {m_on['l1_misses']:<7} | {pf_hits:<7} | {stall_red:>+7.1f} %  | {cycle_red:>+7.1f} %")
            print("-" * 88)

    # Clean temporary hex files
    for f in ["imem.hex", "dmem.hex", "mem128.hex", SIM_BIN]:
        if os.path.exists(f):
            try:
                os.remove(f)
            except Exception:
                pass

    print("\n" + "=" * 88)
    if all_passed:
        print("  ALL BENCHMARK WORKLOADS VERIFIED & MATCH GOLDEN OUTPUTS! PASS!")
    else:
        print("  SOME TESTS ENCOUNTERED MISMATCHES. CHECK LOGS.")
    print("=" * 88)

if __name__ == "__main__":
    main()
