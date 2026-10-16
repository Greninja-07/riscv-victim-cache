import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from asm import addi, sw, j, write_hex

if __name__ == '__main__':
    # Generate default test program: x1 = 42; sw x1, 0x200; j 0
    words = [
        addi(1, 0, 42),
        sw(1, 0, 0x200),
        j(0, 0)
    ]
    write_hex('imem.hex', words)
    write_hex('dmem.hex', [0] * 4096)
