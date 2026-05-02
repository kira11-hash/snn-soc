#!/usr/bin/env python3
"""scripts/gen_bram_init.py
Convert a RISC-V ELF (or flat binary) to a $readmemh-compatible word-wide hex
file for Vivado BRAM pre-initialization.

Usage:
    python3 gen_bram_init.py <input.elf|input.bin> <output.hex> [words]

    words : total SRAM words (default 4096 = 16 KB / 4 bytes).
            If the firmware is smaller it is NOP-padded (RISC-V NOP = 0x13).
            If it is larger the script exits with an error.

Output format: one 8-digit hex word per line, little-endian 32-bit words.
Compatible with Vivado BRAM INIT_xx attributes (via $readmemh in initial block).
"""

import pathlib
import struct
import subprocess
import sys
import tempfile


def elf_to_bin(elf_path: pathlib.Path) -> bytes:
    """Use objcopy to strip ELF to flat binary."""
    with tempfile.NamedTemporaryFile(suffix=".bin", delete=False) as tmp:
        tmp_path = tmp.name

    # Try common RISC-V toolchain prefixes
    for prefix in ("riscv64-unknown-elf", "riscv32-unknown-elf", "riscv-none-elf"):
        objcopy = f"{prefix}-objcopy"
        try:
            subprocess.run(
                [objcopy, "-O", "binary", str(elf_path), tmp_path],
                check=True,
                capture_output=True,
            )
            data = pathlib.Path(tmp_path).read_bytes()
            pathlib.Path(tmp_path).unlink(missing_ok=True)
            return data
        except (FileNotFoundError, subprocess.CalledProcessError):
            continue

    raise SystemExit(
        "ERROR: No RISC-V objcopy found. "
        "Install riscv64-unknown-elf-objcopy or riscv32-unknown-elf-objcopy."
    )


def bin_to_hex(data: bytes, total_words: int, out_path: pathlib.Path) -> None:
    """Write word-wide $readmemh hex, NOP-padded to total_words."""
    total_bytes = total_words * 4
    nop = b"\x13\x00\x00\x00"  # RISC-V NOP (addi x0,x0,0)

    if len(data) > total_bytes:
        raise SystemExit(
            f"ERROR: binary too large: {len(data)} bytes > {total_bytes} bytes "
            f"({total_words} words × 4 bytes)"
        )

    padded = data + nop * total_words
    padded = padded[:total_bytes]

    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", encoding="ascii", newline="\n") as fh:
        for idx in range(total_words):
            word = struct.unpack_from("<I", padded, idx * 4)[0]
            fh.write(f"{word:08x}\n")


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 1

    in_path = pathlib.Path(sys.argv[1])
    out_path = pathlib.Path(sys.argv[2])
    total_words = int(sys.argv[3], 0) if len(sys.argv) >= 4 else 4096

    if not in_path.exists():
        raise SystemExit(f"ERROR: input file not found: {in_path}")

    # Detect ELF by magic bytes
    magic = in_path.read_bytes()[:4]
    if magic == b"\x7fELF":
        print(f"[INFO] Detected ELF, running objcopy → binary")
        data = elf_to_bin(in_path)
    else:
        print(f"[INFO] Treating input as flat binary")
        data = in_path.read_bytes()

    bin_to_hex(data, total_words, out_path)
    print(f"[DONE] {out_path}  ({total_words} words, {total_words * 4} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
