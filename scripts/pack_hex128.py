#!/usr/bin/env python3
"""
pack_hex128.py - Pack 32-bit word hex files into 128-bit block hex format for main_memory.

Format:
  Each line in the output file represents one 128-bit (16-byte) block:
    {word3, word2, word1, word0}
  where:
    - word0 is at the lowest byte address (offset +0, bits [31:0])
    - word1 is at offset +4 (bits [63:32])
    - word2 is at offset +8 (bits [95:64])
    - word3 is at the highest byte address (offset +12, bits [127:96])
  Each line is 32 hexadecimal characters (no leading '0x').
"""

import sys
import os
import argparse
import unittest
import tempfile

M32 = 0xffffffff


def pack_words_to_128(words, num_blocks=None):
    """
    Pack an iterable of 32-bit integers into a list of 128-bit hex strings.
    Groups 4 words as {w3, w2, w1, w0} with w0 at lowest address.
    Pads incomplete blocks with 0x00000000.
    """
    words = [int(w) & M32 for w in words]
    # Pad to multiple of 4
    rem = len(words) % 4
    if rem != 0:
        words.extend([0] * (4 - rem))

    blocks = []
    for i in range(0, len(words), 4):
        w0 = words[i]
        w1 = words[i + 1]
        w2 = words[i + 2]
        w3 = words[i + 3]
        line = f"{w3:08x}{w2:08x}{w1:08x}{w0:08x}"
        blocks.append(line)

    if num_blocks is not None and len(blocks) < num_blocks:
        zero_block = "0" * 32
        blocks.extend([zero_block] * (num_blocks - len(blocks)))

    return blocks


def parse_hex_words(lines):
    """Parse lines containing 32-bit hex words (ignoring comments/whitespace)."""
    words = []
    for line in lines:
        line = line.strip()
        if not line or line.startswith('#') or line.startswith('//'):
            continue
        # Strip comments if present
        for c in ('#', '//'):
            if c in line:
                line = line[:line.index(c)].strip()
        if not line:
            continue
        words.append(int(line, 16) & M32)
    return words


def pack_hex128_file(in_path, out_path, num_blocks=None):
    """Read a 32-bit word hex file and write a packed 128-bit block hex file."""
    with open(in_path, 'r') as f:
        words = parse_hex_words(f)
    blocks = pack_words_to_128(words, num_blocks=num_blocks)
    with open(out_path, 'w') as f:
        for b in blocks:
            f.write(b + '\n')
    return len(blocks)


def unpack_128_to_words(blocks):
    """Unpack 128-bit hex blocks back to a list of 32-bit integer words."""
    words = []
    for b in blocks:
        b = b.strip()
        if not b:
            continue
        assert len(b) == 32, f"Expected 32 hex chars, got {len(b)}: {b}"
        w3 = int(b[0:8], 16)
        w2 = int(b[8:16], 16)
        w1 = int(b[16:24], 16)
        w0 = int(b[24:32], 16)
        words.extend([w0, w1, w2, w3])
    return words


class TestPackHex128(unittest.TestCase):
    def test_single_block_packing(self):
        words = [0xCAFE0000, 0xCAFE0001, 0xCAFE0002, 0xCAFE0003]
        packed = pack_words_to_128(words)
        self.assertEqual(len(packed), 1)
        # {word3, word2, word1, word0}
        self.assertEqual(packed[0], "cafe0003cafe0002cafe0001cafe0000")

    def test_incomplete_block_padding(self):
        words = [0x11111111, 0x22222222]
        packed = pack_words_to_128(words)
        self.assertEqual(len(packed), 1)
        # w2 and w3 padded with 0
        self.assertEqual(packed[0], "00000000000000002222222211111111")

    def test_num_blocks_padding(self):
        words = [0x12345678]
        packed = pack_words_to_128(words, num_blocks=3)
        self.assertEqual(len(packed), 3)
        self.assertEqual(packed[0], "00000000000000000000000012345678")
        self.assertEqual(packed[1], "0" * 32)
        self.assertEqual(packed[2], "0" * 32)

    def test_unpack_roundtrip(self):
        original = [0x00000001, 0x00000002, 0x00000003, 0x00000004,
                    0xAABBCCDD, 0xEEFF0011, 0x22334455, 0x66778899]
        packed = pack_words_to_128(original)
        unpacked = unpack_128_to_words(packed)
        self.assertEqual(unpacked, original)

    def test_file_pack(self):
        with tempfile.NamedTemporaryFile('w', delete=False) as f_in:
            f_in.write("CAFE0000\nCAFE0001\nCAFE0002\nCAFE0003\nBEEF0000\n")
            in_path = f_in.name
        out_path = in_path + ".out"
        try:
            count = pack_hex128_file(in_path, out_path, num_blocks=2)
            self.assertEqual(count, 2)
            with open(out_path, 'r') as f:
                lines = [line.strip() for line in f if line.strip()]
            self.assertEqual(lines[0], "cafe0003cafe0002cafe0001cafe0000")
            self.assertEqual(lines[1], "000000000000000000000000beef0000")
        finally:
            if os.path.exists(in_path):
                os.remove(in_path)
            if os.path.exists(out_path):
                os.remove(out_path)


def main():
    if len(sys.argv) == 1 or '--test' in sys.argv:
        # Run unit tests
        suite = unittest.TestLoader().loadTestsFromTestCase(TestPackHex128)
        runner = unittest.TextTestRunner(verbosity=2)
        result = runner.run(suite)
        sys.exit(0 if result.wasSuccessful() else 1)

    parser = argparse.ArgumentParser(description="Pack 32-bit word hex file into 128-bit block hex file.")
    parser.add_argument("input", help="Path to input 32-bit hex file")
    parser.add_argument("output", help="Path to output 128-bit hex file")
    parser.add_argument("--blocks", type=int, default=None, help="Total 128-bit blocks to write (zero-padded)")
    parser.add_argument("--bytes", type=int, default=None, help="Total bytes of memory (blocks = bytes / 16)")
    args = parser.parse_args()

    num_blocks = args.blocks
    if num_blocks is None and args.bytes is not None:
        num_blocks = args.bytes // 16

    n = pack_hex128_file(args.input, args.output, num_blocks=num_blocks)
    print(f"Packed {n} 128-bit blocks into {args.output}")


if __name__ == '__main__':
    main()
