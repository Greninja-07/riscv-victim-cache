import sys, subprocess, re
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from asm import addi, add, b, j, sw, m, auipc, write_hex, MNEM
from md_test_golden import golden

M = 0xffffffff

def simulate_directed_auipc(words):
    """Python architectural golden model for directed AUIPC test."""
    regs = [0] * 32
    mem = {}
    pc = 0
    words_map = {i * 4: w for i, w in enumerate(words)}
    
    max_steps = 1000
    steps = 0
    while pc in words_map and steps < max_steps:
        steps += 1
        w = words_map[pc]
        op = w & 0x7f
        rd = (w >> 7) & 0x1f
        f3 = (w >> 12) & 0x7
        rs1 = (w >> 15) & 0x1f
        rs2 = (w >> 20) & 0x1f
        next_pc = pc + 4

        if op == 0x17:  # AUIPC
            imm20 = (w >> 12) & 0xfffff
            imm = (imm20 << 12) & M
            if rd != 0:
                regs[rd] = (pc + imm) & M
        elif op == 0x37:  # LUI
            imm20 = (w >> 12) & 0xfffff
            if rd != 0:
                regs[rd] = (imm20 << 12) & M
        elif op == 0x13:  # ADDI
            imm = (w >> 20) & 0xfff
            if imm & 0x800:
                imm -= 0x1000
            if rd != 0:
                regs[rd] = (regs[rs1] + imm) & M
        elif op == 0x33:  # R-type (ADD / MUL / DIV)
            f7 = (w >> 25) & 0x7f
            if f7 == 1:
                # M-extension
                inv_mnem = {v: k for k, v in MNEM.items()}
                res = golden(f3, regs[rs1], regs[rs2])
                if rd != 0:
                    regs[rd] = res
            elif f3 == 0 and f7 == 0:
                # ADD
                if rd != 0:
                    regs[rd] = (regs[rs1] + regs[rs2]) & M
        elif op == 0x23:  # STORE (SW)
            imm = ((w >> 25) << 5) | ((w >> 7) & 0x1f)
            if imm & 0x800:
                imm -= 0x1000
            addr = (regs[rs1] + imm) & M
            mem[addr] = regs[rs2] & M
        elif op == 0x63:  # BRANCH (BEQ)
            imm12 = ((w >> 31) << 12) | (((w >> 7) & 1) << 11) | (((w >> 25) & 0x3f) << 5) | (((w >> 8) & 0xf) << 1)
            if imm12 & 0x1000:
                imm12 -= 0x2000
            if f3 == 0:  # BEQ
                if regs[rs1] == regs[rs2]:
                    next_pc = (pc + imm12) & M
        elif op == 0x6f:  # JAL
            imm20 = ((w >> 31) << 20) | (((w >> 12) & 0xff) << 12) | (((w >> 20) & 1) << 11) | (((w >> 21) & 0x3ff) << 1)
            if imm20 & 0x100000:
                imm20 -= 0x200000
            if rd != 0:
                regs[rd] = (pc + 4) & M
            next_pc = (pc + imm20) & M
            if next_pc == pc:  # Infinite halt loop
                break

        regs[0] = 0
        pc = next_pc

    return mem

def run_test(sim_cpu='sim_cpu'):
    # Build test program covering:
    # 1. AUIPC at several PCs (0x000, 0x004, 0x010, 0x028, 0x038, 0x040, 0x044)
    # 2. AUIPC with rd=x0 (x0 must remain 0)
    # 3. AUIPC followed by immediate dependent use (WB/EX forwarding)
    # 4. AUIPC right after taken branch (target is AUIPC at 0x028)
    # 5. AUIPC right after 33-cycle DIV stall (0x038)
    # 6. AUIPC right after MUL stall (0x040)
    # 7. AUIPC with high/negative immediate (0x044)

    words = [
        # 0x000 (word 0): AUIPC at PC 0x000
        auipc(1, 0x10000),
        # 0x004 (word 1): AUIPC at PC 0x004
        auipc(2, 0x00001),
        # 0x008 (word 2): AUIPC with rd=x0
        auipc(0, 0x12345),
        # 0x00c (word 3): Verify x0 remains 0
        add(3, 0, 0),
        # 0x010 (word 4): AUIPC followed by dependent forwarding
        auipc(4, 0x20000),
        # 0x014 (word 5): Immediate dependent use of x4
        addi(5, 4, 0x20),
        # 0x018 (word 6): BEQ branch to 0x028 (+16 bytes)
        b(0, 0, 0, 16),
        # 0x01c (word 7): Wrong-path bubble instructions
        addi(0, 0, 0),
        # 0x020 (word 8): Wrong-path bubble instructions
        addi(0, 0, 0),
        # 0x024 (word 9): Wrong-path bubble instructions
        addi(0, 0, 0),
        # 0x028 (word 10): AUIPC right after taken branch
        auipc(6, 0x30000),
        # 0x02c (word 11): Operand 1 for DIV/MUL
        addi(7, 0, 100),
        # 0x030 (word 12): Operand 2 for DIV/MUL
        addi(8, 0, 3),
        # 0x034 (word 13): DIV (multi-cycle stall)
        m('div', 9, 7, 8),
        # 0x038 (word 14): AUIPC during/after DIV stall
        auipc(10, 0x40000),
        # 0x03c (word 15): MUL (stall or single cycle)
        m('mul', 11, 7, 8),
        # 0x040 (word 16): AUIPC during/after MUL stall
        auipc(12, 0x50000),
        # 0x044 (word 17): AUIPC with negative/high immediate
        auipc(13, 0xfffff),
        # 0x048 (word 18): Dependent use of x13
        addi(14, 13, 0x10),

        # Store results to memory starting at 0x200
        sw(1, 0, 0x200),   # x1  (AUIPC at PC 0x000 -> 0x10000000)
        sw(2, 0, 0x204),   # x2  (AUIPC at PC 0x004 -> 0x00001004)
        sw(3, 0, 0x208),   # x3  (x0 after AUIPC rd=x0 -> 0x00000000)
        sw(4, 0, 0x20c),   # x4  (AUIPC at PC 0x010 -> 0x20000010)
        sw(5, 0, 0x210),   # x5  (Forwarded AUIPC: 0x20000010 + 0x20 = 0x20000030)
        sw(6, 0, 0x214),   # x6  (AUIPC after taken branch -> 0x30000028)
        sw(9, 0, 0x218),   # x9  (DIV result: 100 / 3 = 33 = 0x00000021)
        sw(10, 0, 0x21c),  # x10 (AUIPC after DIV stall -> 0x40000038)
        sw(11, 0, 0x220),  # x11 (MUL result: 100 * 3 = 300 = 0x0000012c)
        sw(12, 0, 0x224),  # x12 (AUIPC after MUL stall -> 0x50000040)
        sw(13, 0, 0x228),  # x13 (AUIPC at PC 0x044 -> 0xfffff044)
        sw(14, 0, 0x22c),  # x14 (Forwarded AUIPC: 0xfffff044 + 0x10 = 0xfffff054)

        # Halt loop
        j(0, 0)
    ]

    write_hex('imem.hex', words)
    write_hex('dmem.hex', [0] * 1024)

    # Compute expected results via Python reference model
    expected = simulate_directed_auipc(words)

    res = subprocess.run(['vvp', sim_cpu, '+MAXC=1000'], capture_output=True, text=True)
    if res.returncode != 0:
        print(f"ERROR: vvp returned non-zero code {res.returncode}")
        return False

    got = {}
    for line in res.stdout.splitlines():
        match = re.match(r'W (\d+) ([0-9a-f]{8}) ([0-9a-f]{8})', line)
        if match:
            addr = int(match.group(1))
            data = int(match.group(2), 16)
            mask = int(match.group(3), 16)
            cur = got.get(addr, 0)
            for bi in range(4):
                if (mask >> bi) & 1:
                    cur = (cur & ~(0xff << (8 * bi))) | (data & (0xff << (8 * bi)))
            got[addr] = cur

    ok = True
    for addr, exp_val in sorted(expected.items()):
        got_val = got.get(addr, None)
        if got_val != exp_val:
            got_str = f"0x{got_val:08x}" if got_val is not None else "NOT WRITTEN"
            print(f"MISMATCH at addr 0x{addr:x}: expected 0x{exp_val:08x}, got {got_str}")
            ok = False

    if ok:
        print(f"Directed AUIPC test PASSED on {sim_cpu}!")
    else:
        print(f"Directed AUIPC test FAILED on {sim_cpu}!")

    return ok

if __name__ == '__main__':
    sim = sys.argv[1] if len(sys.argv) > 1 else 'sim_cpu'
    if not run_test(sim):
        sys.exit(1)
