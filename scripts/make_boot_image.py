#!/usr/bin/env python3
"""Create a SPI-flash boot image with the 16-byte V1 boot header."""

from __future__ import annotations

import argparse
import pathlib
import struct
import sys

BOOT_IMAGE_MAGIC = 0x544F4F42  # 'BOOT', little-endian bytes: 42 4f 4f 54


def parse_u32(text: str) -> int:
    try:
        value = int(text, 0)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"invalid integer: {text}") from exc
    if not 0 <= value <= 0xFFFF_FFFF:
        raise argparse.ArgumentTypeError(f"value out of uint32 range: {text}")
    return value


def write_hex_bytes(path: pathlib.Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="ascii", newline="\n") as fh:
        for byte in data:
            fh.write(f"{byte:02x}\n")


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--firmware", required=True, type=pathlib.Path,
                    help="raw application .bin payload")
    ap.add_argument("--load-addr", required=True, type=parse_u32,
                    help="destination address, e.g. 0x1000")
    ap.add_argument("--entry-addr", required=True, type=parse_u32,
                    help="entry address, e.g. 0x1000")
    ap.add_argument("--out", required=True, type=pathlib.Path,
                    help="output boot image .bin")
    ap.add_argument("--hex", type=pathlib.Path,
                    help="optional byte-wide .hex for tb/spi_flash_model.sv")
    ap.add_argument("--pad-to", type=parse_u32, default=0,
                    help="optional output size padding with 0xFF bytes")
    args = ap.parse_args(argv)

    payload = args.firmware.read_bytes()
    if not payload:
        raise SystemExit("firmware payload is empty")
    if args.load_addr & 0x3:
        raise SystemExit(f"load address must be 4-byte aligned: 0x{args.load_addr:08x}")
    if args.entry_addr & 0x3:
        raise SystemExit(f"entry address must be 4-byte aligned: 0x{args.entry_addr:08x}")
    if not (args.load_addr <= args.entry_addr < args.load_addr + len(payload)):
        raise SystemExit("entry address must point inside the loaded payload")

    header = struct.pack(
        "<IIII",
        BOOT_IMAGE_MAGIC,
        len(payload),
        args.load_addr,
        args.entry_addr,
    )
    image = header + payload
    if args.pad_to:
        if len(image) > args.pad_to:
            raise SystemExit(f"boot image too large: {len(image)} > {args.pad_to}")
        image += b"\xFF" * (args.pad_to - len(image))

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_bytes(image)
    if args.hex is not None:
        write_hex_bytes(args.hex, image)

    print(f"[DONE] wrote {args.out} ({len(image)} bytes)")
    if args.hex is not None:
        print(f"[DONE] wrote {args.hex} ({len(image)} byte lines)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
