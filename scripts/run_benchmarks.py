#!/usr/bin/env python3
"""
run_benchmarks.py - Automated Performance Benchmarking Suite
Evaluates RV32IM CPU with L1 Data Cache vs Uncached Cache-Bypass
across configurable memory latencies (N = 1, 5, 10, 20 cycles).
"""

import os
import sys
import subprocess
import shutil

ROOT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SW_DIR   = os.path.join(ROOT_DIR, "sw")
TB_DIR   = os.path.join(ROOT_DIR, "tb")
RTL_DIR  = os.path.join(ROOT_DIR, "rtl")

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
    }
]

def compile_sim():
    """Compile the full system simulation executable."""
    cmd = [
        "iverilog", "-g2005",
        f"-I{RTL_DIR}/core",
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
        f"{RTL_DIR}/perf/perf_profiler.v"
    ]
    res = subprocess.run(cmd, cwd=ROOT_DIR, capture_output=True, text=True)
    if res.returncode != 0:
        print("Compilation failed:\n", res.stderr)
        sys.exit(1)

def run_workload(name, bypass, latency_code):
    """Setup hex files and run simulation."""
    # Copy workload hex to imem.hex, dmem.hex, and mem128.hex
    shutil.copy(os.path.join(SW_DIR, f"{name}_imem.hex"), os.path.join(ROOT_DIR, "imem.hex"))
    shutil.copy(os.path.join(SW_DIR, f"{name}_dmem.hex"), os.path.join(ROOT_DIR, "dmem.hex"))
    shutil.copy(os.path.join(SW_DIR, f"{name}_mem128.hex"), os.path.join(ROOT_DIR, "mem128.hex"))

    # Also initialize storage in main_memory if needed (main_memory initializes by default)
    cmd = [
        "vvp", SIM_BIN,
        f"+CACHE_BYPASS={bypass}",
        f"+LATENCY={latency_code}",
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
        "hit_rate": None
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
        elif "Status" in line and "SUCCESS" in line:
            metrics["status"] = "PASS"

    return metrics

def main():
    print("=" * 78)
    print("  RISC-V MEMORY HIERARCHY BENCHMARK & EVALUATION SUITE")
    print("  Author: Abhishek Kumar (Group 14)")
    print("=" * 78)

    # First compile build_workloads.py to make sure hex files exist
    subprocess.run(["python3", os.path.join(ROOT_DIR, "scripts", "build_workloads.py")], cwd=ROOT_DIR, check=True)

    print("\n[INFO] Compiling full system simulation...")
    compile_sim()
    print("[INFO] Compilation successful!")

    # Latencies to test: 2'b10 (N=10 default) and 2'b00 (N=1 baseline)
    LATENCIES = [
        (2, 10, "N=10 (Default DRAM)"),
        (0, 1,  "N=1  (Zero-benefit baseline)"),
        (1, 5,  "N=5  (Moderate latency)"),
        (3, 20, "N=20 (High latency)")
    ]

    print("\n" + "=" * 78)
    print("  EXPERIMENT 1: L1 CACHE ENABLED VS CACHE BYPASS (N = 10 cycles)")
    print("=" * 78)

    all_passed = True

    print(f"{'Workload':<18} | {'Mode':<10} | {'Cycles':<8} | {'Stalls':<8} | {'Hits/Miss':<12} | {'Hit Rate':<8} | {'Speedup'}")
    print("-" * 88)

    for wl in WORKLOADS:
        name = wl["name"]
        exp  = wl["expected"]

        # Run with Cache ON (bypass = 0) at N = 10
        m_on = run_workload(name, bypass=0, latency_code=2)
        # Run with Cache BYPASSED (bypass = 1) at N = 10
        m_off = run_workload(name, bypass=1, latency_code=2)

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

    print("\n" + "=" * 78)
    print("  EXPERIMENT 2: LATENCY PENALTY SCALING (N = 1, 5, 10, 20)")
    print("=" * 78)
    print(f"{'Latency Mode':<28} | {'Array Sum (Cache ON)':<22} | {'Array Sum (Bypassed)':<22}")
    print("-" * 78)

    for code, n, label in LATENCIES:
        m_on  = run_workload("array_sum", bypass=0, latency_code=code)
        m_off = run_workload("array_sum", bypass=1, latency_code=code)
        print(f"{label:<28} | {m_on['total_cycles']:<8} cycles (stalls: {m_on['stall_cycles']:<3}) | {m_off['total_cycles']:<8} cycles (stalls: {m_off['stall_cycles']:<3})")

    # Clean temporary hex files
    for f in ["imem.hex", "dmem.hex", SIM_BIN]:
        if os.path.exists(f):
            os.remove(f)

    print("\n" + "=" * 78)
    if all_passed:
        print("  ALL BENCHMARK WORKLOADS VERIFIED & MATCH GOLDEN OUTPUTS! PASS!")
    else:
        print("  SOME TESTS ENCOUNTERED MISMATCHES. CHECK LOGS.")
    print("=" * 78)

if __name__ == "__main__":
    main()
