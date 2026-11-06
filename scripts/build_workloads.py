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


def build_complex_ops():
    """
    Workload 5: Multi-Operation Complex Kernel
    - Operation 0: Matrix Inversion & Multiplication (A^-1 * B), det = 14, sum = 14
    - Operation 1: Vector Dot-Product (V1 . V2) using RV32M MUL, sum = 70
    - Operation 2: 1D Array Accumulation (Spatial Locality), sum = 136
    - Operation 3: Strided Transpose of 4x4 matrix (Stride = 16 bytes = 1 cache line), sum = 680
    - Grand Total: 14 + 70 + 136 + 680 = 900
    """
    ADDR_A   = 0x0300
    ADDR_B   = 0x0340
    ADDR_C   = 0x0380
    ADDR_V1  = 0x03A0
    ADDR_V2  = 0x03B0
    ADDR_ARR = 0x0600
    ADDR_S   = 0x0400
    ADDR_D   = 0x0500

    instrs = []

    # --- Part 1: Matrix Inversion & Multiplication (A^-1 * B) ---
    # Load A: a00, a01, a10, a11 into x1, x2, x3, x4
    instrs.extend(asm.li(20, ADDR_A))
    instrs.append(asm.lw(1, 20, 0))   # a00 = 4
    instrs.append(asm.lw(2, 20, 4))   # a01 = 2
    instrs.append(asm.lw(3, 20, 8))   # a10 = 3
    instrs.append(asm.lw(4, 20, 12))  # a11 = 5

    # Det = a00*a11 - a01*a10 -> x5
    instrs.append(asm.m('mul', 5, 1, 4))
    instrs.append(asm.m('mul', 6, 2, 3))
    instrs.append(asm.sub(5, 5, 6))   # det = 14

    # Adj(A): adj00 = a11 (x4), adj01 = -a01 (sub x7, x0, x2), adj10 = -a10 (sub x8, x0, x3), adj11 = a00 (x1)
    instrs.append(asm.sub(7, 0, 2))   # -a01 = -2
    instrs.append(asm.sub(8, 0, 3))   # -a10 = -3

    # Load B: b00, b01, b10, b11 into x9, x10, x11, x12
    instrs.extend(asm.li(21, ADDR_B))
    instrs.append(asm.lw(9, 21, 0))   # b00 = 14
    instrs.append(asm.lw(10, 21, 4))  # b01 = 28
    instrs.append(asm.lw(11, 21, 8))  # b10 = 14
    instrs.append(asm.lw(12, 21, 12)) # b11 = 42

    # c00 = adj00*b00 + adj01*b10 = x4*x9 + x7*x11 -> x13
    instrs.append(asm.m('mul', 13, 4, 9))
    instrs.append(asm.m('mul', 14, 7, 11))
    instrs.append(asm.add(13, 13, 14))
    instrs.append(asm.m('div', 13, 13, 5)) # c00 = 3

    # c01 = adj00*b01 + adj01*b11 = x4*x10 + x7*x12 -> x14
    instrs.append(asm.m('mul', 14, 4, 10))
    instrs.append(asm.m('mul', 15, 7, 12))
    instrs.append(asm.add(14, 14, 15))
    instrs.append(asm.m('div', 14, 14, 5)) # c01 = 4

    # c10 = adj10*b00 + adj11*b10 = x8*x9 + x1*x11 -> x15
    instrs.append(asm.m('mul', 15, 8, 9))
    instrs.append(asm.m('mul', 16, 1, 11))
    instrs.append(asm.add(15, 15, 16))
    instrs.append(asm.m('div', 15, 15, 5)) # c10 = 1

    # c11 = adj10*b01 + adj11*b11 = x8*x10 + x1*x12 -> x16
    instrs.append(asm.m('mul', 16, 8, 10))
    instrs.append(asm.m('mul', 17, 1, 12))
    instrs.append(asm.add(16, 16, 17))
    instrs.append(asm.m('div', 16, 16, 5)) # c11 = 6

    # Store C matrix to ADDR_C
    instrs.extend(asm.li(22, ADDR_C))
    instrs.append(asm.sw(13, 22, 0))
    instrs.append(asm.sw(14, 22, 4))
    instrs.append(asm.sw(15, 22, 8))
    instrs.append(asm.sw(16, 22, 12))

    # x18 = Sum of Matrix Inversion*B = 3 + 4 + 1 + 6 = 14
    instrs.append(asm.add(18, 13, 14))
    instrs.append(asm.add(18, 18, 15))
    instrs.append(asm.add(18, 18, 16)) # x18 = 14

    # --- Part 2: Vector Dot-Product (x25 = 70) ---
    instrs.extend(asm.li(28, ADDR_V1))
    instrs.extend(asm.li(29, ADDR_V2))
    instrs.extend(asm.li(25, 0)) # dot_sum = 0
    for i in range(4):
        instrs.append(asm.lw(30, 28, i * 4))
        instrs.append(asm.lw(31, 29, i * 4))
        instrs.append(asm.m('mul', 30, 30, 31))
        instrs.append(asm.add(25, 25, 30))

    # --- Part 3: 1D Array Accumulation (x26 = 136) ---
    instrs.extend(asm.li(28, ADDR_ARR))
    instrs.extend(asm.li(29, 16)) # len = 16
    instrs.extend(asm.li(26, 0))  # sum = 0
    loop_arr = len(instrs) * 4
    instrs.append(asm.lw(30, 28, 0))
    instrs.append(asm.add(26, 26, 30))
    instrs.append(asm.addi(28, 28, 4))
    instrs.append(asm.addi(29, 29, -1))
    offset_arr = loop_arr - (len(instrs) * 4)
    instrs.append(asm.b(1, 29, 0, offset_arr))

    # --- Part 4: Strided 4x4 Matrix Traversal (Stride = 16 bytes = 1 line) ---
    # Traverses columns with stride of 16 bytes, loading into x19
    instrs.extend(asm.li(23, ADDR_S))
    instrs.extend(asm.li(24, ADDR_D))
    instrs.extend(asm.li(10, 0))  # Strided accumulator (x10 = 680)

    dst_idx = 0
    # Column 0: 0, 16, 32, 48
    for offset in [0, 16, 32, 48]:
        instrs.append(asm.lw(19, 23, offset))
        instrs.append(asm.add(10, 10, 19))
        instrs.append(asm.sw(19, 24, dst_idx * 4))
        dst_idx += 1

    # Column 1: 4, 20, 36, 52
    for offset in [4, 20, 36, 52]:
        instrs.append(asm.lw(19, 23, offset))
        instrs.append(asm.add(10, 10, 19))
        instrs.append(asm.sw(19, 24, dst_idx * 4))
        dst_idx += 1

    # Column 2: 8, 24, 40, 56
    for offset in [8, 24, 40, 56]:
        instrs.append(asm.lw(19, 23, offset))
        instrs.append(asm.add(10, 10, 19))
        instrs.append(asm.sw(19, 24, dst_idx * 4))
        dst_idx += 1

    # Column 3: 12, 28, 44, 60
    for offset in [12, 28, 44, 60]:
        instrs.append(asm.lw(19, 23, offset))
        instrs.append(asm.add(10, 10, 19))
        instrs.append(asm.sw(19, 24, dst_idx * 4))
        dst_idx += 1

    # --- Store Individual Operation Results into Mailboxes ---
    # Store Op 0 result (14) at 0x1F0
    instrs.extend(asm.li(9, 0x1F0))
    instrs.append(asm.sw(18, 9, 0))

    # Store Op 1 result (70) at 0x1F4
    instrs.extend(asm.li(9, 0x1F4))
    instrs.append(asm.sw(25, 9, 0))

    # Store Op 2 result (136) at 0x1E8
    instrs.extend(asm.li(9, 0x1E8))
    instrs.append(asm.sw(26, 9, 0))

    # Store Op 3 result (680) at 0x1EC
    instrs.extend(asm.li(9, 0x1EC))
    instrs.append(asm.sw(10, 9, 0))

    # Compute Grand Total Checksum (14 + 70 + 136 + 680 = 900) into x27
    instrs.append(asm.add(27, 18, 25))
    instrs.append(asm.add(27, 27, 26))
    instrs.append(asm.add(27, 27, 10))

    # Store Grand Total at 0x1FC
    instrs.extend(asm.li(9, 0x1FC))
    instrs.append(asm.sw(27, 9, 0))

    # Write completion flag at 0x1F8
    instrs.extend(asm.li(9, 0x1F8))
    instrs.extend(asm.li(8, 1))
    instrs.append(asm.sw(8, 9, 0))
    instrs.append(asm.j(0, 0))

    # Populate Data Memory
    dmem = [0] * NUM_WORDS
    # Matrix A: [4, 2], [3, 5]
    dmem[(ADDR_A // 4) + 0] = 4
    dmem[(ADDR_A // 4) + 1] = 2
    dmem[(ADDR_A // 4) + 2] = 3
    dmem[(ADDR_A // 4) + 3] = 5

    # Matrix B: [14, 28], [14, 42]
    dmem[(ADDR_B // 4) + 0] = 14
    dmem[(ADDR_B // 4) + 1] = 28
    dmem[(ADDR_B // 4) + 2] = 14
    dmem[(ADDR_B // 4) + 3] = 42

    # Vector 1: [1, 2, 3, 4]
    for i in range(4):
        dmem[(ADDR_V1 // 4) + i] = i + 1

    # Vector 2: [5, 6, 7, 8]
    for i in range(4):
        dmem[(ADDR_V2 // 4) + i] = i + 5

    # Array: [1, 2, ..., 16]
    for i in range(16):
        dmem[(ADDR_ARR // 4) + i] = i + 1

    # Strided Source Matrix 4x4
    stride_sum = 0
    for i in range(16):
        val = (i + 1) * 5
        dmem[(ADDR_S // 4) + i] = val
        stride_sum += val

    expected_total = 14 + 70 + 136 + stride_sum  # 14 + 70 + 136 + 680 = 900

    write_hex_files("complex_ops", instrs, dmem)
    return expected_total


def build_stride_sum():
    ARRAY_BASE = 0x0800  
    NUM_ELEMS  = 160     

    instrs = []
    instrs.extend(asm.li(2, ARRAY_BASE)) 
    instrs.extend(asm.li(3, NUM_ELEMS))  
    instrs.extend(asm.li(10, 0))         

    loop_start = len(instrs) * 4
    instrs.append(asm.lw(4, 2, 0))       
    instrs.append(asm.add(10, 10, 4))    

    # --- INJECTED COMPUTE DELAY ---
    # CPU spins here for ~90 cycles. The Baseline will sit idle, but the 
    # Prefetcher will use this exact time to fetch the next block in the background!
    instrs.extend(asm.li(11, 30))        # Load loop counter = 30
    delay_start = len(instrs) * 4
    instrs.append(asm.addi(11, 11, -1))  
    offset_delay = delay_start - (len(instrs) * 4)
    instrs.append(asm.b(1, 11, 0, offset_delay)) 
    # ------------------------------

    instrs.append(asm.addi(2, 2, 16))    
    instrs.append(asm.addi(3, 3, -1))    
    offset = loop_start - (len(instrs) * 4)
    instrs.append(asm.b(1, 3, 0, offset))

    instrs.extend(asm.li(5, 0x1FC))
    instrs.append(asm.sw(10, 5, 0))
    instrs.extend(asm.li(6, 0x1F8))
    instrs.extend(asm.li(7, 1))
    instrs.append(asm.sw(7, 6, 0))
    instrs.append(asm.j(0, 0))

    dmem = [0] * 4096
    expected_sum = 0
    for i in range(NUM_ELEMS):
        val = (i + 1) * 7
        dmem[(ARRAY_BASE // 4) + (i * 4)] = val
        expected_sum = (expected_sum + val) & 0xffffffff

    write_hex_files("stride_sum", instrs, dmem)
    return expected_sum


def build_stride_mixed():
    """
    Workload 7: Stride Mixed (Dual Strided Stream + RV32M MUL)
    Interleaved loads from two arrays with different strides:
    - Array A: Stride +16 B (4 words)
    - Array B: Stride +32 B (8 words)
    - Multiplies A[i] * B[i] and accumulates into x10 for 64 iterations.
    Tests multi-stream RPT tracking and RV32M pipeline throughput.
    """
    ADDR_A = 0x0400  # 1024 bytes (spans 64 * 16 = 1024 B, ends at 0x0800)
    ADDR_B = 0x0C00  # 3072 bytes (spans 64 * 32 = 2048 B, ends at 0x1400)
    LEN    = 64

    instrs = []
    instrs.extend(asm.li(1, ADDR_A))     # x1: ptr A
    instrs.extend(asm.li(2, ADDR_B))     # x2: ptr B
    instrs.extend(asm.li(3, LEN))        # x3: count
    instrs.extend(asm.li(10, 0))         # x10: accumulator

    loop_start = len(instrs) * 4
    instrs.append(asm.lw(4, 1, 0))       # lw x4, 0(x1) (PC1: trains RPT for Stream A)
    instrs.append(asm.lw(5, 2, 0))       # lw x5, 0(x2) (PC2: trains RPT for Stream B)
    instrs.append(asm.m('mul', 6, 4, 5)) # mul x6, x4, x5
    instrs.append(asm.add(10, 10, 6))    # add x10, x10, x6

    # --- INJECTED COMPUTE DELAY ---
    # CPU spins here for ~90 cycles. The Baseline will sit idle, but the 
    # Prefetcher will use this exact time to fetch the next block in the background!
    instrs.extend(asm.li(11, 30))        # Load loop counter = 30
    delay_start = len(instrs) * 4
    instrs.append(asm.addi(11, 11, -1))  
    offset_delay = delay_start - (len(instrs) * 4)
    instrs.append(asm.b(1, 11, 0, offset_delay)) 
    # ------------------------------

    instrs.append(asm.addi(1, 1, 16))    # addi x1, x1, 16 (stride +16 B)
    instrs.append(asm.addi(2, 2, 32))    # addi x2, x2, 32 (stride +32 B)
    instrs.append(asm.addi(3, 3, -1))    # addi x3, x3, -1
    offset = loop_start - (len(instrs) * 4)
    instrs.append(asm.b(1, 3, 0, offset))# bne x3, x0, loop_start

    # Mailbox completion
    instrs.extend(asm.li(5, 0x1FC))
    instrs.append(asm.sw(10, 5, 0))
    instrs.extend(asm.li(6, 0x1F8))
    instrs.extend(asm.li(7, 1))
    instrs.append(asm.sw(7, 6, 0))
    instrs.append(asm.j(0, 0))

    dmem = [0] * NUM_WORDS
    expected_sum = 0
    for i in range(LEN):
        val_a = (i + 1) * 3
        val_b = (i + 2) * 5
        dmem[(ADDR_A // 4) + (i * 4)] = val_a
        dmem[(ADDR_B // 4) + (i * 8)] = val_b
        expected_sum = (expected_sum + (val_a * val_b)) & 0xffffffff

    write_hex_files("stride_mixed", instrs, dmem)
    return expected_sum


if __name__ == "__main__":
    print("Building RISC-V workloads...")
    s1 = build_array_sum()
    s2 = build_vector_dot()
    s3 = build_conflict_thrash()
    s4 = build_rw_persistence()
    s5 = build_complex_ops()
    s6 = build_stride_sum()
    s7 = build_stride_mixed()
    print("All workloads built successfully!")
    print(f"Golden results: array_sum={s1}, vector_dot={s2}, conflict={s3}, rw={s4}, complex_ops={s5}, stride_sum={s6}, stride_mixed={s7}")