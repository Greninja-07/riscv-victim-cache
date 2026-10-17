import sys, subprocess, re
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from asm import addi, add, b, j, i, sw, write_hex

def jalr(rd, rs1, imm):
    return i(0x67, 0, rd, rs1, imm)

def run_test(sim_cpu='sim_cpu'):
    # Directed test program:
    # 0x000: addi x1, x0, 5        (word 0)
    # 0x004: addi x2, x0, 0        (word 1)
    # 0x008: addi x4, x0, 0        (word 2)
    # 0x00c: add  x2, x2, x1       (word 3) <- loop
    # 0x010: addi x1, x1, -1       (word 4)
    # 0x014: bne  x1, x0, -8       (word 5) -> backward branch to 0x00c
    # 0x018: jal  x3, 16           (word 6) -> jump to 0x028, x3 = 0x01c
    # 0x01c: sw   x1, 0(0x204)     (word 7) <- return point
    # 0x020: sw   x2, 0(0x208)     (word 8)
    # 0x024: j    16               (word 9) -> jump to 0x034
    # 0x028: addi x4, x4, 10       (word 10) <- function
    # 0x02c: jalr x0, x3, 0        (word 11) -> return to 0x01c
    # 0x030: addi x0, x0, 0        (word 12)
    # 0x034: sw   x3, 0(0x20c)     (word 13) <- finish
    # 0x038: sw   x4, 0(0x210)     (word 14)
    # 0x03c: j    0                (word 15) -> halt

    words = [
        addi(1, 0, 5),
        addi(2, 0, 0),
        addi(4, 0, 0),
        add(2, 2, 1),
        addi(1, 1, -1),
        b(1, 1, 0, -8),
        j(3, 16),
        sw(1, 0, 0x204),
        sw(2, 0, 0x208),
        j(0, 16),
        addi(4, 4, 10),
        jalr(0, 3, 0),
        addi(0, 0, 0),
        sw(3, 0, 0x20c),
        sw(4, 0, 0x210),
        j(0, 0)
    ]

    write_hex('imem.hex', words)
    write_hex('dmem.hex', [0] * 4096)

    expected = {
        0x204: 0x00000000,  # x1: 0 after loop countdown
        0x208: 0x0000000f,  # x2: 15 (5+4+3+2+1)
        0x20c: 0x0000001c,  # x3: return address from JAL (0x018 + 4)
        0x210: 0x0000000a   # x4: 10 set inside function called via JAL and returned via JALR
    }

    res = subprocess.run(['vvp', sim_cpu, '+MAXC=1000'], capture_output=True, text=True)
    if res.returncode != 0:
        print(f"ERROR: vvp returned non-zero code {res.returncode}")
        return False

    got = {}
    for line in res.stdout.splitlines():
        m = re.match(r'W (\d+) ([0-9a-f]{8}) ([0-9a-f]{8})', line)
        if m:
            a = int(m.group(1))
            d = int(m.group(2), 16)
            be = int(m.group(3), 16)
            cur = got.get(a, 0)
            for bi in range(4):
                if (be >> bi) & 1:
                    cur = (cur & ~(0xff << (8 * bi))) | (d & (0xff << (8 * bi)))
            got[a] = cur

    ok = True
    for addr, exp_val in expected.items():
        got_val = got.get(addr, None)
        if got_val != exp_val:
            got_str = f"0x{got_val:08x}" if got_val is not None else "NOT WRITTEN"
            print(f"MISMATCH at addr 0x{addr:x}: expected 0x{exp_val:08x}, got {got_str}")
            ok = False

    if ok:
        print(f"Directed control-flow test (countdown loop, backward branch, JAL, JALR) PASSED on {sim_cpu}!")
    else:
        print(f"Directed control-flow test FAILED on {sim_cpu}!")

    return ok

if __name__ == '__main__':
    sim = sys.argv[1] if len(sys.argv) > 1 else 'sim_cpu'
    if not run_test(sim):
        sys.exit(1)
