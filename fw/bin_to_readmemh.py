#!/usr/bin/env python3
import pathlib
import struct
import sys


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: bin_to_readmemh.py <input.bin> <output.hex> <words>")
        return 1

    input_path = pathlib.Path(sys.argv[1])
    output_path = pathlib.Path(sys.argv[2])
    total_words = int(sys.argv[3], 0)

    data = input_path.read_bytes()
    total_bytes = total_words * 4
    if len(data) > total_bytes:
      raise SystemExit(f"binary too large: {len(data)} bytes > {total_bytes} bytes")

    padded = data + b"\x13\x00\x00\x00" * total_words
    padded = padded[:total_bytes]

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="ascii", newline="\n") as fh:
        for idx in range(total_words):
            word = struct.unpack_from("<I", padded, idx * 4)[0]
            fh.write(f"{word:08x}\n")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
