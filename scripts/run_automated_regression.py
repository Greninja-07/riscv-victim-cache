#!/usr/bin/env python3
"""
Automated Master Regression Runner
Project: RV32I Memory Hierarchy Enhancement with Victim Cache & Prefetcher (Group 14)
Author: Abhishek Kumar

Runs the entire test suite in automated batch mode, aggregates test results,
and outputs an executive verification scorecard.
"""

import subprocess
import time
import sys
import os
import shutil

ROOT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
PYTHON = sys.executable

TEST_SUITES = [
    {
        "name": "L1 Cache & 4-Entry Victim Cache Unit Tests",
        "target": "sim_l1",
        "cmd": ["make", "sim_l1"],
        "expect_str": "STATUS: L1 + VICTIM CACHE PASSED 100% OF TESTS!",
        "item_count": 41,
    },
    {
        "name": "Unified Memory Subsystem Unit Tests (mem_subsystem.v)",
        "target": "sim_mem",
        "cmd": ["make", "sim_mem"],
        "expect_str": "STATUS: ALL SUBSYSTEM TESTS PASSED SUCCESSFULLY!",
        "item_count": 22,
    },
    {
        "name": "Hardware Stride Prefetcher Unit Tests (tb_prefetcher.v)",
        "target": "sim_prefetcher",
        "cmd": ["make", "sim_prefetcher"],
        "expect_str": "STATUS: ALL PREFETCHER TESTS PASSED SUCCESSFULLY!",
        "item_count": 19,
    },
    {
        "name": "RV32M Hardware Multiplier/Divider Verification",
        "target": "sim_md",
        "cmd": ["make", "sim_md"],
        "expect_str": "total mismatches: 0",
        "item_count": 5568,
    },
    {
        "name": "CPU Pipeline Random & Directed Program Suite (FAST=0 & 1)",
        "target": "test_cpu",
        "cmd": ["make", "test_cpu"],
        "expect_str": "Directed AUIPC test PASSED on sim_cpu!",
        "item_count": 204,  # 100 random FAST=0 + 100 random FAST=1 + 4 directed tests
    },
    {
        "name": "Full Integrated System Simulation (CPU + L1 + VC + Profiler)",
        "target": "sim_system",
        "cmd": ["make", "sim_system"],
        "expect_str": "Status           : SUCCESS (Mailbox Done Flag Asserted)",
        "item_count": 1,
    },
    {
        "name": "Digilent Nexys A7-100T Top-Level Hardware Integration (top_fpga.v)",
        "target": "sim_top",
        "cmd": ["make", "sim_top"],
        "expect_str": "ALL TOP FPGA HARDWARE INTERFACES VERIFIED SUCCESSFULLY! PASS!",
        "item_count": 8,  # LEDs, done flag, PC, anodes, cathodes, profiler modes
    },
    {
        "name": "Workload Benchmark Suite (array_sum, vector_dot, conflict, rw)",
        "target": "test_benchmarks",
        "cmd": ["make", "test_benchmarks"],
        "expect_str": "ALL 7 WORKLOADS x 4 CONFIGURATIONS PASSED",
        "item_count": 7,
    },
]

def run_native_target(target):
    """Fallback runner when host 'make' crashes or is unavailable."""
    output = []
    
    def run_step(cmd_args):
        p = subprocess.run(cmd_args, cwd=ROOT_DIR, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        output.append(p.stdout or "")
        return p.returncode

    if target == "sim_l1":
        rc = run_step(["iverilog", "-g2005", "-o", "sim_l1", "rtl/mem/l1_cache_controller.v", "rtl/mem/main_memory.v", "rtl/victim/victim_cache.v", "tb/tb_l1_cache.v"])
        if rc == 0:
            rc = run_step(["vvp", "sim_l1"])
        return rc, "\n".join(output)

    elif target == "sim_mem":
        rc = run_step(["iverilog", "-g2005", "-o", "sim_mem", "rtl/mem/mem_subsystem.v", "rtl/mem/l1_cache_controller.v", "rtl/mem/main_memory.v", "rtl/victim/victim_cache.v", "rtl/prefetch/prefetcher.v", "tb/tb_mem_subsystem.v"])
        if rc == 0:
            rc = run_step(["vvp", "sim_mem"])
        return rc, "\n".join(output)

    elif target == "sim_prefetcher":
        rc = run_step(["iverilog", "-g2005", "-Wall", "-o", "sim_prefetcher", "rtl/prefetch/prefetcher.v", "rtl/mem/main_memory.v", "tb/tb_prefetcher.v"])
        if rc == 0:
            rc = run_step(["vvp", "sim_prefetcher"])
        return rc, "\n".join(output)

    elif target == "sim_md":
        rc = run_step([PYTHON, "scripts/md_test.py"])
        return rc, "\n".join(output)

    elif target == "test_cpu":
        rc = run_step(["iverilog", "-g2005", "-Ptb.FAST=0", "-I", "rtl/core", "-o", "sim_cpu", "tb/tb.v", "rtl/core/pipeline.v", "rtl/core/IF_ID.v", "rtl/core/execute.v", "rtl/core/muldiv.v", "rtl/core/wb.v", "rtl/mem/memory.v"])
        if rc == 0: rc = run_step([PYTHON, "scripts/sys_test.py", "sim_cpu", "100"])
        if rc == 0: rc = run_step([PYTHON, "scripts/directed_cf_test.py", "sim_cpu"])
        if rc == 0: rc = run_step([PYTHON, "scripts/directed_auipc_test.py", "sim_cpu"])
        if rc == 0: rc = run_step(["iverilog", "-g2005", "-Ptb.FAST=1", "-I", "rtl/core", "-o", "sim_cpu", "tb/tb.v", "rtl/core/pipeline.v", "rtl/core/IF_ID.v", "rtl/core/execute.v", "rtl/core/muldiv.v", "rtl/core/wb.v", "rtl/mem/memory.v"])
        if rc == 0: rc = run_step([PYTHON, "scripts/sys_test.py", "sim_cpu", "100"])
        if rc == 0: rc = run_step([PYTHON, "scripts/directed_cf_test.py", "sim_cpu"])
        if rc == 0: rc = run_step([PYTHON, "scripts/directed_auipc_test.py", "sim_cpu"])
        return rc, "\n".join(output)

    elif target == "sim_system":
        run_step([PYTHON, "scripts/build_workloads.py"])
        shutil.copy(os.path.join(ROOT_DIR, "sw/array_sum_imem.hex"), os.path.join(ROOT_DIR, "imem.hex"))
        shutil.copy(os.path.join(ROOT_DIR, "sw/array_sum_dmem.hex"), os.path.join(ROOT_DIR, "dmem.hex"))
        shutil.copy(os.path.join(ROOT_DIR, "sw/array_sum_mem128.hex"), os.path.join(ROOT_DIR, "mem128.hex"))
        rc = run_step(["iverilog", "-g2005", "-I", "rtl/core", "-I", "rtl/mem", "-I", "rtl/perf", "-I", "rtl/victim", "-I", "rtl/prefetch", "-I", "rtl/uart", "-o", "sim_system",
                      "tb/tb_system.v", "rtl/core/pipeline.v", "rtl/core/IF_ID.v", "rtl/core/execute.v", "rtl/core/muldiv.v", "rtl/core/wb.v",
                      "rtl/mem/memory.v", "rtl/mem/mem_subsystem.v", "rtl/mem/l1_cache_controller.v", "rtl/mem/main_memory.v",
                      "rtl/victim/victim_cache.v", "rtl/perf/perf_profiler.v", "rtl/prefetch/prefetcher.v", "rtl/uart/uart_tx.v", "rtl/uart/uart_reporter.v"])
        if rc == 0:
            rc = run_step(["vvp", "sim_system", "+LATENCY=2", "+CACHE_BYPASS=0", "+MAXC=50000"])
        return rc, "\n".join(output)

    elif target == "sim_top":
        run_step([PYTHON, "scripts/build_workloads.py"])
        shutil.copy(os.path.join(ROOT_DIR, "sw/array_sum_imem.hex"), os.path.join(ROOT_DIR, "imem.hex"))
        shutil.copy(os.path.join(ROOT_DIR, "sw/array_sum_dmem.hex"), os.path.join(ROOT_DIR, "dmem.hex"))
        shutil.copy(os.path.join(ROOT_DIR, "sw/array_sum_mem128.hex"), os.path.join(ROOT_DIR, "mem128.hex"))
        rc = run_step(["iverilog", "-g2005", "-I", "rtl/core", "-I", "rtl/mem", "-I", "rtl/perf", "-I", "rtl/victim", "-I", "rtl/top", "-I", "rtl/prefetch", "-I", "rtl/uart", "-o", "sim_top",
                      "tb/tb_top_fpga.v", "rtl/top/top_fpga.v", "rtl/core/pipeline.v", "rtl/core/IF_ID.v", "rtl/core/execute.v", "rtl/core/muldiv.v", "rtl/core/wb.v",
                      "rtl/mem/memory.v", "rtl/mem/mem_subsystem.v", "rtl/mem/l1_cache_controller.v", "rtl/mem/main_memory.v",
                      "rtl/victim/victim_cache.v", "rtl/perf/perf_profiler.v", "rtl/prefetch/prefetcher.v", "rtl/uart/uart_tx.v", "rtl/uart/uart_reporter.v"])
        if rc == 0:
            rc = run_step(["vvp", "sim_top"])
        return rc, "\n".join(output)

    elif target == "test_benchmarks":
        run_step([PYTHON, "scripts/build_workloads.py"])
        rc = run_step([PYTHON, "scripts/run_benchmarks.py"])
        return rc, "\n".join(output)

    return 1, f"Unknown target {target}"

def run_regression():
    start_total = time.time()
    print("=" * 80)
    print("  AUTOMATED COMPREHENSIVE REGRESSION SUITE (Group 14)")
    print("  Target: RV32IM CPU + L1 Cache + 4-Entry Victim Cache + Nexys A7 FPGA")
    print(f"  Execution Timestamp: {time.strftime('%Y-%m-%d %H:%M:%S')}")
    print("=" * 80)

    results = []
    total_checks_passed = 0
    total_checks_failed = 0

    for idx, suite in enumerate(TEST_SUITES, 1):
        print(f"\n[{idx}/{len(TEST_SUITES)}] Running {suite['name']}...")
        suite_start = time.time()

        proc = subprocess.run(
            suite["cmd"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True
        )

        output = proc.stdout or ""
        rc = proc.returncode
        
        # If make crashed (e.g. 0xc0000008), fallback to native Python runner
        if rc != 0 and ("Exception caught" in output or "make.exe" in output):
            rc, output = run_native_target(suite.get("target"))

        elapsed = time.time() - suite_start
        passed = (rc == 0) and (suite["expect_str"] in output)

        if passed:
            print(f"      Status: [PASS] ({elapsed:.2f}s)")
            total_checks_passed += suite["item_count"]
            results.append({
                "name": suite["name"],
                "status": "PASS",
                "elapsed": elapsed,
                "checks": suite["item_count"],
                "output": output
            })
        else:
            print(f"      Status: [FAIL] ({elapsed:.2f}s)")
            total_checks_failed += 1
            print("--- Output excerpt ---")
            lines = output.strip().split("\n")
            for line in lines[-20:]:
                print(f"  {line}")
            results.append({
                "name": suite["name"],
                "status": "FAIL",
                "elapsed": elapsed,
                "checks": 0,
                "output": output
            })

    total_time = time.time() - start_total

    print("\n" + "=" * 80)
    print("  AUTOMATED REGRESSION SCORECARD")
    print("=" * 80)
    print(f"{'Test Suite':<60} | {'Checks':<8} | {'Status':<6} | {'Time':<6}")
    print("-" * 80)
    for r in results:
        status_str = f"PASS" if r["status"] == "PASS" else "FAIL"
        print(f"{r['name']:<60} | {r['checks']:<8} | {status_str:<6} | {r['elapsed']:>5.2f}s")
    print("-" * 80)
    print(f"TOTAL AUTOMATED CHECKS: {total_checks_passed} PASSED | {total_checks_failed} FAILED")
    print(f"TOTAL EXECUTION TIME  : {total_time:.2f} seconds")
    print("=" * 80)

    if total_checks_failed == 0:
        print("\n>>> OVERALL REGRESSION RESULT: 100% AUTOMATED PASS <<<\n")
        return 0
    else:
        print("\n>>> OVERALL REGRESSION RESULT: FAILURES DETECTED <<<\n")
        return 1

if __name__ == "__main__":
    sys.exit(run_regression())
