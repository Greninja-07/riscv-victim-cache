#!/usr/bin/env python3
"""
run_benchmarks.py - Automated 4-Tier Architectural Ablation & Performance Suite
Evaluates RV32IM CPU across:
  0. Uncached Baseline (Cache Bypass = 1, VC = 0, Prefetcher = 0)
  1. L1 Cache Only     (Cache Bypass = 0, VC = 0, Prefetcher = 0)
  2. L1 + Victim Cache (Cache Bypass = 0, VC = 1, Prefetcher = 0)
  3. L1 + VC + Pref    (Cache Bypass = 0, VC = 1, Prefetcher = 1)
"""

import os
import sys
import subprocess
import shutil

if hasattr(sys.stdout, 'reconfigure'):
    try:
        sys.stdout.reconfigure(encoding='utf-8')
    except Exception:
        pass

ROOT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SW_DIR   = os.path.join(ROOT_DIR, "sw")
TB_DIR   = os.path.join(ROOT_DIR, "tb")
RTL_DIR  = os.path.join(ROOT_DIR, "rtl")
SIM_BIN  = os.path.join(ROOT_DIR, "sim_system")

WORKLOADS = [
    {
        "name": "array_sum",
        "desc": "Sequential Array Traversal (Spatial Locality)",
        "expected": 24960,
    },
    {
        "name": "vector_dot",
        "desc": "Vector Dot Product (RV32M MUL + Sequential Streams)",
        "expected": 1643,
    },
    {
        "name": "conflict_thrash",
        "desc": "Cache Conflict Thrashing (2KB Set-Collision Ping-Pong)",
        "expected": 1440,
    },
    {
        "name": "rw_persistence",
        "desc": "Read-Modify-Write Persistence (Dirty Eviction + Swap)",
        "expected": 756,
    },
    {
        "name": "complex_ops",
        "desc": "Matrix Inv + Vector Dot + Array Sum + Strided Transpose",
        "expected": 900,
    },
    {
        "name": "stride_sum",
        "desc": "Strided Array Sum (16B Stride across 2.5KB > 2KB L1)",
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

def run_workload(name, bypass, latency_code, vc_en=1, prefetch_en=0):
    """Setup hex files and run simulation for a specific switch configuration."""
    shutil.copy(os.path.join(SW_DIR, f"{name}_imem.hex"), os.path.join(ROOT_DIR, "imem.hex"))
    shutil.copy(os.path.join(SW_DIR, f"{name}_dmem.hex"), os.path.join(ROOT_DIR, "dmem.hex"))
    shutil.copy(os.path.join(SW_DIR, f"{name}_mem128.hex"), os.path.join(ROOT_DIR, "mem128.hex"))

    cmd = [
        "vvp", SIM_BIN,
        f"+CACHE_BYPASS={bypass}",
        f"+VC_EN={vc_en}",
        f"+PREFETCH_EN={prefetch_en}",
        f"+LATENCY={latency_code}",
        "+MAXC=500000"
    ]
    res = subprocess.run(cmd, cwd=ROOT_DIR, capture_output=True, text=True)
    out = res.stdout

    metrics = {
        "status": "FAIL",
        "result": None,
        "total_cycles": 0,
        "stall_cycles": 0,
        "l1_accesses": 0,
        "l1_hits": 0,
        "l1_misses": 0,
        "hit_rate": 0.0,
        "victim_hits": 0,
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
        elif "Victim Hits" in line:
            metrics["victim_hits"] = int(line.split(":")[-1].strip())
        elif "Prefetch Hits" in line:
            metrics["prefetch_hits"] = int(line.split(":")[-1].strip())
        elif "Status" in line and "SUCCESS" in line:
            metrics["status"] = "PASS"

    return metrics

def compute_amat(m, ref_accesses):
    """Compute effective Average Memory Access Time (AMAT) in cycles."""
    acc = m["l1_accesses"] if m["l1_accesses"] > 0 else ref_accesses
    if acc <= 0:
        return 1.0
    return 1.0 + (float(m["stall_cycles"]) / float(acc))

def main():
    print("=" * 106)
    print("  RISC-V MEMORY HIERARCHY COMPARATIVE ABLATION STUDY (L1 CACHE + VICTIM CACHE + STRIDE PREFETCHER)")
    print("  Group 14 | Target: Digilent Nexys A7-100T (RV32IM 3-Stage Pipeline)")
    print("=" * 106)

    subprocess.run([sys.executable, os.path.join(ROOT_DIR, "scripts", "build_workloads.py")], cwd=ROOT_DIR, check=True)
    compile_sim()

    all_passed = True
    summary_rows = []

    # =========================================================================
    # SECTION 1: 4-TIER COMPARATIVE ABLATION STUDY AT REALISTIC DRAM (N = 100)
    # =========================================================================
    lat_code = 2  # 2'b10 -> N = 100 cycles
    lat_val  = 100

    for idx, wl in enumerate(WORKLOADS, 1):
        name = wl["name"]
        desc = wl["desc"]
        exp  = wl["expected"]

        # Run all 4 hardware switch configurations
        m_byp  = run_workload(name, bypass=1, latency_code=lat_code, vc_en=0, prefetch_en=0)
        m_l1   = run_workload(name, bypass=0, latency_code=lat_code, vc_en=0, prefetch_en=0)
        m_vc   = run_workload(name, bypass=0, latency_code=lat_code, vc_en=1, prefetch_en=0)
        m_full = run_workload(name, bypass=0, latency_code=lat_code, vc_en=1, prefetch_en=1)

        runs = [m_byp, m_l1, m_vc, m_full]
        ok = all(r["status"] == "PASS" and r["result"] == exp for r in runs)
        if not ok:
            all_passed = False
            status_str = f"FAIL (Expected {exp})"
        else:
            status_str = f"{exp} (PASS)"

        ref_acc = m_l1["l1_accesses"]
        c_byp, c_l1, c_vc, c_full = [r["total_cycles"] for r in runs]
        s_byp, s_l1, s_vc, s_full = [r["stall_cycles"] for r in runs]

        amat_byp  = compute_amat(m_byp,  ref_acc)
        amat_l1   = compute_amat(m_l1,   ref_acc)
        amat_vc   = compute_amat(m_vc,   ref_acc)
        amat_full = compute_amat(m_full, ref_acc)

        # Speedups relative to L1-Only Baseline (and vs Uncached)
        sp_byp_vs_l1  = (c_l1 / c_byp)  if c_byp  > 0 else 1.0
        sp_vc_vs_l1   = (c_l1 / c_vc)   if c_vc   > 0 else 1.0
        sp_full_vs_l1 = (c_l1 / c_full) if c_full > 0 else 1.0
        sp_full_vs_byp= (c_byp / c_full)if c_full > 0 else 1.0

        stall_red_byp = ((s_byp - s_full) / s_byp * 100.0) if s_byp > 0 else 0.0

        print(f"\n" + "=" * 106)
        print(f"  WORKLOAD {idx}/{len(WORKLOADS)}: {name:<16} | {desc}")
        print(f"  DRAM Latency: N = {lat_val} Cycles (SW[1:0] = 2'b10)  |  Golden Result: {status_str}")
        print("=" * 106)
        print(f"  {'Hardware Configuration':<29} | {'Total Cyc':>9} | {'Stall Cyc':>9} | {'L1 Hit %':>8} | {'VC Hits':>7} | {'PF Hits':>7} | {'AMAT (cyc)':>10} | {'Speedup':>12}")
        print("-" * 106)
        print(f"  {'0. Uncached Bypass (SW=1,0,0)':<29} | {c_byp:>9} | {s_byp:>9} | {'0.0 %':>8} | {0:>7} | {0:>7} | {amat_byp:>10.2f} | {sp_byp_vs_l1:>11.2f}x")
        print(f"  {'1. L1 Cache Only   (SW=0,0,0)':<29} | {c_l1:>9} | {s_l1:>9} | {m_l1['hit_rate']:>6.1f} % | {0:>7} | {0:>7} | {amat_l1:>10.2f} | {'1.00x (Base)':>12}")
        print(f"  {'2. L1 + Victim     (SW=0,1,0)':<29} | {c_vc:>9} | {s_vc:>9} | {m_vc['hit_rate']:>6.1f} % | {m_vc['victim_hits']:>7} | {0:>7} | {amat_vc:>10.2f} | {sp_vc_vs_l1:>11.2f}x")
        print(f"  {'3. L1 + VC + Pref  (SW=0,1,1)':<29} | {c_full:>9} | {s_full:>9} | {m_full['hit_rate']:>6.1f} % | {m_full['victim_hits']:>7} | {m_full['prefetch_hits']:>7} | {amat_full:>10.2f} | {sp_full_vs_l1:>11.2f}x")
        print("-" * 106)
        print(f"  -> Enhancement Gain (vs L1-Only) : {sp_full_vs_l1:.2f}x faster ({s_l1 - s_full:,} stall cycles eliminated, AMAT: {amat_l1:.2f} -> {amat_full:.2f} cyc)")
        print(f"  -> Hierarchy Gain   (vs Bypass)  : {sp_full_vs_byp:.2f}x faster ({stall_red_byp:.1f}% total memory stall reduction)")
        print("=" * 106)

        summary_rows.append({
            "name": name,
            "c_byp": c_byp,
            "c_l1": c_l1,
            "c_vc": c_vc,
            "c_full": c_full,
            "amat_l1": amat_l1,
            "amat_full": amat_full,
            "sp_vc": sp_vc_vs_l1,
            "sp_full_l1": sp_full_vs_l1,
            "sp_full_byp": sp_full_vs_byp
        })

    # =========================================================================
    # SECTION 2: EXECUTIVE SUMMARY TABLE ACROSS ALL WORKLOADS (N = 100)
    # =========================================================================
    print("\n" + "=" * 106)
    print("  EXECUTIVE SUMMARY TABLE (DRAM LATENCY N = 100 CYCLES)")
    print("=" * 106)
    print(f"  {'Workload':<16} | {'Bypass Cyc':>10} | {'L1-Only Cyc':>11} | {'L1+VC Cyc':>10} | {'Full Cyc':>9} | {'AMAT (L1->Full)':>16} | {'vs L1-Only':>10} | {'vs Bypass':>9}")
    print("-" * 106)
    for r in summary_rows:
        amat_str = f"{r['amat_l1']:>5.1f} -> {r['amat_full']:>4.1f}"
        print(f"  {r['name']:<16} | {r['c_byp']:>10} | {r['c_l1']:>11} | {r['c_vc']:>10} | {r['c_full']:>9} | {amat_str:>16} | {r['sp_full_l1']:>9.2f}x | {r['sp_full_byp']:>8.2f}x")
    print("=" * 106)

    # Clean temporary hex and binary artifacts
    for f in ["imem.hex", "dmem.hex", "mem128.hex", SIM_BIN]:
        if os.path.exists(f):
            try:
                os.remove(f)
            except Exception:
                pass

    if all_passed:
        print("\n  [STATUS] ALL 7 WORKLOADS x 4 CONFIGURATIONS PASSED & MATCHED GOLDEN OUTPUTS!\n")
    else:
        print("\n  [STATUS] SOME WORKLOADS FAILED VERIFICATION. CHECK LOGS ABOVE.\n")
        sys.exit(1)

if __name__ == "__main__":
    main()