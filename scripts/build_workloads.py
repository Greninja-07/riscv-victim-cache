#!/usr/bin/env python3
"""
build_workloads.py - Generate RISC-V workloads and hex initialization files
for Memory Subsystem & L1 Cache evaluation.

Workloads:
1. array_sum: Sequential array traversal testing spatial locality hits (target >= 85% hit rate).
2. vector_dot: Vector dot product combining RV32M MUL with dual array memory streaming.
3. conflict_thrash: Multi-array conflict thrashing (strided by 2KB, L1 set collision).
4. rw_persistence: Read-modify-write array testing dirty block allocation and persistence.
5. matrix_mult: Matrix multiplication kernel combining nested loops, MUL, and strided accesses.
"""

import os
import sys

# Add scripts directory to path to import asm and pack_hex128
sys.path.insert(0, os.path.dirname(__file__))
import asm
from pack_hex128 import pack_words_to_128

SW_DIR = os.path.join(os.path.dirname(__file__), "..", "sw")
os.makedirs(SW_DIR, exist_ok=True)

NUM_WORDS = 4096      # 16 KB total memory
NUM_BLOCKS = 1024     # 1024 x 16-byte blocks

def write_hex_files(name, instructions, dmem_words):
    """Write IMEM, DMEM, and 128-bit packed memory files."""
    # Write imem.hex (4096 words, padded with NOP = 0x00000013)
    imem_words = list(instructions)
    if len(imem_words) < NUM_WORDS:
        imem_words.extend([0x00000013] * (NUM_WORDS - len(imem_words)))
    
    imem_path = os.path.join(SW_DIR, f"{name}_imem.hex")
    with open(imem_path, "w") as f:
        for w in imem_words[:NUM_WORDS]:
            f.write(f"{w & 0xffffffff:08x}\n")
            
    # Write dmem.hex (4096 words)
    dmem_full = list(dmem_words)
    if len(dmem_full) < NUM_WORDS:
        dmem_full.extend([0x00000000] * (NUM_WORDS - len(dmem_full)))
        
    dmem_path = os.path.join(SW_DIR, f"{name}_dmem.hex")
    with open(dmem_path, "w") as f:
        for w in dmem_full[:NUM_WORDS]:
            f.write(f"{w & 0xffffffff:08x}\n")
            
    # Write 128-bit packed hex for main_memory ($readmemh)
    blocks = pack_words_to_128(dmem_full[:NUM_WORDS], num_blocks=NUM_BLOCKS)
    mem128_path = os.path.join(SW_DIR, f"{name}_mem128.hex")
    with open(mem128_path, "w") as f:
        for b in blocks:
            f.write(f"{b}\n")
            
    print(f"Generated workload '{name}': {len(instructions)} instructions, {len(dmem_words)} data words.")


def build_array_sum():
    """
    Workload 1: Sequential Array Sum
    Traverses an array of 64 words (256 bytes) multiple times in a loop.
    Spatial locality test: 1 miss followed by 3 hits per cache line.
    Accumulates sum into x10 and writes result to mailbox address 0x000001FC.
    """
    # Base address of array: 0x00000800 (word offset 512)
    ARRAY_BASE = 0x800
    ARRAY_LEN  = 64
    ITERATIONS = 4

    instrs = []
    # x1: Loop outer counter (iterations)
    instrs.extend(asm.li(1, ITERATIONS))
    # x10: Accumulator sum
    instrs.extend(asm.li(10, 0))

    # Outer loop head
    outer_loop_start = len(instrs) * 4
    # x2: Array pointer
    instrs.extend(asm.li(2, ARRAY_BASE))
    # x3: Inner count
    instrs.extend(asm.li(3, ARRAY_LEN))

    # Inner loop head
    inner_loop_start = len(instrs) * 4
    # lw x4, 0(x2)
    instrs.append(asm.lw(4, 2, 0))
    # add x10, x10, x4
    instrs.append(asm.add(10, 10, 4))
    # addi x2, x2, 4
    instrs.append(asm.addi(2, 2, 4))
    # addi x3, x3, -1
    instrs.append(asm.addi(3, 3, -1))
    # bne x3, x0, inner_loop
    inner_offset = inner_loop_start - (len(instrs) * 4)
    instrs.append(asm.b(1, 3, 0, inner_offset))  # bne

    # addi x1, x1, -1
    instrs.append(asm.addi(1, 1, -1))
    # bne x1, x0, outer_loop
    outer_offset = outer_loop_start - (len(instrs) * 4)
    instrs.append(asm.b(1, 1, 0, outer_offset))

    # Store final result in mailbox (0x1FC)
    instrs.extend(asm.li(5, 0x1FC))
    instrs.append(asm.sw(10, 5, 0))
    # Magic completion flag at 0x1F8 (write 0x1)
    instrs.extend(asm.li(6, 0x1F8))
    instrs.extend(asm.li(7, 1))
    instrs.append(asm.sw(7, 6, 0))

    # Halt loop: j self
    instrs.append(asm.j(0, 0))

    # Initialize data array with values 1..ARRAY_LEN
    dmem = [0] * NUM_WORDS
    expected_sum = 0
    for i in range(ARRAY_LEN):
        val = (i + 1) * 3
        dmem[(ARRAY_BASE // 4) + i] = val
        expected_sum += val
    expected_sum *= ITERATIONS

    write_hex_files("array_sum", instrs, dmem)
    return expected_sum


def build_vector_dot():
    """
    Workload 2: Vector Dot Product
    Computes dot product = sum(A[i] * B[i]) for 32 elements.
    Combines RV32M MUL instruction with dual streaming array loads.
    A is at 0x0400, B is at 0x0600.
    """
    ADDR_A = 0x0400
    ADDR_B = 0x0600
    LEN    = 32

    instrs = []
    instrs.extend(asm.li(1, ADDR_A))  # x1: ptr A
    instrs.extend(asm.li(2, ADDR_B))  # x2: ptr B
    instrs.extend(asm.li(3, LEN))     # x3: count
    instrs.extend(asm.li(10, 0))      # x10: dot product accumulator

    loop_start = len(instrs) * 4
    # lw x4, 0(x1)
    instrs.append(asm.lw(4, 1, 0))
    # lw x5, 0(x2)
    instrs.append(asm.lw(5, 2, 0))
    # mul x6, x4, x5
    instrs.append(asm.m("mul", 6, 4, 5))
    # add x10, x10, x6
    instrs.append(asm.add(10, 10, 6))
    # addi x1, x1, 4
    instrs.append(asm.addi(1, 1, 4))
    # addi x2, x2, 4
    instrs.append(asm.addi(2, 2, 4))
    # addi x3, x3, -1
    instrs.append(asm.addi(3, 3, -1))
    # bne x3, x0, loop
    offset = loop_start - (len(instrs) * 4)
    instrs.append(asm.b(1, 3, 0, offset))

    # Store result to 0x1FC
    instrs.extend(asm.li(7, 0x1FC))
    instrs.append(asm.sw(10, 7, 0))
    # Done flag at 0x1F8
    instrs.extend(asm.li(8, 0x1F8))
    instrs.extend(asm.li(9, 1))
    instrs.append(asm.sw(9, 8, 0))

    # Halt loop
    instrs.append(asm.j(0, 0))

    # Initialize A and B
    dmem = [0] * NUM_WORDS
    expected_dot = 0
    for i in range(LEN):
        va = i + 2
        vb = (i % 5) + 1
        dmem[(ADDR_A // 4) + i] = va
        dmem[(ADDR_B // 4) + i] = vb
        expected_dot += va * vb

    write_hex_files("vector_dot", instrs, dmem)
    return expected_dot


def build_conflict_thrash():
    """
    Workload 3: Cache Conflict Thrashing
    Two arrays separated by exactly 2048 bytes (2 KB, matching L1 capacity).
    Addr A = 0x0800 (Index = 0), Addr B = 0x1000 (Index = 0).
    Alternating accesses between A[i] and B[i] cause 100% conflict misses in direct-mapped L1!
    """
    ADDR_A = 0x0800  # Index = 0, Tag = 1
    ADDR_B = 0x1000  # Index = 0, Tag = 2
    NUM_ITERS = 16

    instrs = []
    instrs.extend(asm.li(1, ADDR_A))
    instrs.extend(asm.li(2, ADDR_B))
    instrs.extend(asm.li(3, NUM_ITERS))
    instrs.extend(asm.li(10, 0))

    loop_start = len(instrs) * 4
    # lw x4, 0(x1)  -> maps to Index 0
    instrs.append(asm.lw(4, 1, 0))
    # add x10, x10, x4
    instrs.append(asm.add(10, 10, 4))
    # lw x5, 0(x2)  -> maps to Index 0 (COLLISION / CONFLICT MISS!)
    instrs.append(asm.lw(5, 2, 0))
    # add x10, x10, x5
    instrs.append(asm.add(10, 10, 5))
    # addi x3, x3, -1
    instrs.append(asm.addi(3, 3, -1))
    # bne x3, x0, loop
    offset = loop_start - (len(instrs) * 4)
    instrs.append(asm.b(1, 3, 0, offset))

    # Store result at 0x1FC
    instrs.extend(asm.li(6, 0x1FC))
    instrs.append(asm.sw(10, 6, 0))
    # Done flag at 0x1F8
    instrs.extend(asm.li(7, 0x1F8))
    instrs.extend(asm.li(8, 1))
    instrs.append(asm.sw(8, 7, 0))
    instrs.append(asm.j(0, 0))

    dmem = [0] * NUM_WORDS
    dmem[ADDR_A // 4] = 0x00000042
    dmem[ADDR_B // 4] = 0x00000018
    expected = (0x42 + 0x18) * NUM_ITERS

    write_hex_files("conflict_thrash", instrs, dmem)
    return expected


def build_rw_persistence():
    """
    Workload 4: Read-Modify-Write Persistence
    Reads 16 elements, multiplies each by 3, writes back with SW,
    then forces eviction with a colliding address, and verifies reloaded data.
    """
    ADDR_X = 0x0400  # Index = 0
    ADDR_Y = 0x0C00  # Index = 0 (collides)
    LEN    = 8

    instrs = []
    instrs.extend(asm.li(1, ADDR_X))
    instrs.extend(asm.li(2, LEN))
    instrs.extend(asm.li(3, 3))       # multiplier = 3

    # Step 1: Read, multiply by 3, store back
    loop1_start = len(instrs) * 4
    instrs.append(asm.lw(4, 1, 0))
    instrs.append(asm.m("mul", 5, 4, 3))
    instrs.append(asm.sw(5, 1, 0))     # Write dirty line
    instrs.append(asm.addi(1, 1, 4))
    instrs.append(asm.addi(2, 2, -1))
    offset1 = loop1_start - (len(instrs) * 4)
    instrs.append(asm.b(1, 2, 0, offset1))

    # Step 2: Force dirty eviction by reading colliding address Y
    instrs.extend(asm.li(6, ADDR_Y))
    instrs.append(asm.lw(7, 6, 0))

    # Step 3: Reload X[0] from memory and accumulate sum
    instrs.extend(asm.li(1, ADDR_X))
    instrs.extend(asm.li(2, LEN))
    instrs.extend(asm.li(10, 0))       # Accumulator

    loop2_start = len(instrs) * 4
    instrs.append(asm.lw(8, 1, 0))
    instrs.append(asm.add(10, 10, 8))
    instrs.append(asm.addi(1, 1, 4))
    instrs.append(asm.addi(2, 2, -1))
    offset2 = loop2_start - (len(instrs) * 4)
    instrs.append(asm.b(1, 2, 0, offset2))

    # Store result at 0x1FC
    instrs.extend(asm.li(9, 0x1FC))
    instrs.append(asm.sw(10, 9, 0))
    instrs.extend(asm.li(9, 0x1F8))
    instrs.extend(asm.li(8, 1))
    instrs.append(asm.sw(8, 9, 0))
    instrs.append(asm.j(0, 0))

    dmem = [0] * NUM_WORDS
    expected_sum = 0
    for i in range(LEN):
        init_val = (i + 1) * 7
        dmem[(ADDR_X // 4) + i] = init_val
        expected_sum += init_val * 3
    dmem[ADDR_Y // 4] = 0x55555555

    write_hex_files("rw_persistence", instrs, dmem)
    return expected_sum


if __name__ == "__main__":
    print("Building RISC-V workloads...")
    s1 = build_array_sum()
    s2 = build_vector_dot()
    s3 = build_conflict_thrash()
    s4 = build_rw_persistence()
    print("All workloads built successfully!")
    print(f"Golden results: array_sum={s1}, vector_dot={s2}, conflict={s3}, rw={s4}")
