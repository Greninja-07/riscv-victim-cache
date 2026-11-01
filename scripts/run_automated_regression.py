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
import re

TEST_SUITES = [
    {
        "name": "L1 Cache & 4-Entry Victim Cache Unit Tests",
        "cmd": ["make", "sim_l1"],
        "expect_str": "STATUS: L1 + VICTIM CACHE PASSED 100% OF TESTS!",
        "item_count": 41,
    },
    {
        "name": "Unified Memory Subsystem Unit Tests (mem_subsystem.v)",
        "cmd": ["make", "sim_mem"],
        "expect_str": "STATUS: ALL SUBSYSTEM TESTS PASSED SUCCESSFULLY!",
        "item_count": 22,
    },
    {
        "name": "Hardware Stride Prefetcher Unit Tests (tb_prefetcher.v)",
        "cmd": ["make", "sim_prefetcher"],
        "expect_str": "STATUS: ALL PREFETCHER TESTS PASSED SUCCESSFULLY!",
        "item_count": 19,
    },
    {
        "name": "RV32M Hardware Multiplier/Divider Verification",
        "cmd": ["make", "sim_md"],
        "expect_str": "total mismatches: 0",
        "item_count": 5568,
    },
    {
        "name": "CPU Pipeline Random & Directed Program Suite (FAST=0 & 1)",
        "cmd": ["make", "test_cpu"],
        "expect_str": "Directed AUIPC test PASSED on sim_cpu!",
        "item_count": 204,  # 100 random FAST=0 + 100 random FAST=1 + 4 directed tests
    },
    {
        "name": "Full Integrated System Simulation (CPU + L1 + VC + Profiler)",
        "cmd": ["make", "sim_system"],
        "expect_str": "Status           : SUCCESS (Mailbox Done Flag Asserted)",
        "item_count": 1,
    },
    {
        "name": "Digilent Nexys A7-100T Top-Level Hardware Integration (top_fpga.v)",
        "cmd": ["make", "sim_top"],
        "expect_str": "ALL TOP FPGA HARDWARE INTERFACES VERIFIED SUCCESSFULLY! PASS!",
        "item_count": 8,  # LEDs, done flag, PC, anodes, cathodes, profiler modes
    },
    {
        "name": "Workload Benchmark Suite (array_sum, vector_dot, conflict, rw)",
        "cmd": ["make", "test_benchmarks"],
        "expect_str": "ALL BENCHMARK WORKLOADS VERIFIED & MATCH GOLDEN OUTPUTS! PASS!",
        "item_count": 7,
    },
]

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

        elapsed = time.time() - suite_start
        output = proc.stdout
        passed = (proc.returncode == 0) and (suite["expect_str"] in output)

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
