#!/usr/bin/env python3
"""Legacy FPGA boot-image helper for the old boot_main/app_link.ld flow.

Tape-out / silicon Day-2 boot should use scripts/make_boot_image.py instead.
"""
import pathlib
import struct
import sys

BOOT_IMAGE_MAGIC = 0x544F4F42
APP_LOAD_ADDR = 0x00010000
FLASH_BYTES = 65536


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: build_flash_image.py <app.bin> <flash.bin> <flash.hex>")
        return 1

    app_bin = pathlib.Path(sys.argv[1]).read_bytes()
    flash_bin_path = pathlib.Path(sys.argv[2])
    flash_hex_path = pathlib.Path(sys.argv[3])

    header = struct.pack(
        "<IIII",
        BOOT_IMAGE_MAGIC,
        len(app_bin),
        APP_LOAD_ADDR,
        APP_LOAD_ADDR,
    )
    flash_image = header + app_bin
    if len(flash_image) > FLASH_BYTES:
        raise SystemExit(f"flash image too large: {len(flash_image)} > {FLASH_BYTES}")
    flash_image = flash_image + (b"\xFF" * (FLASH_BYTES - len(flash_image)))

    flash_bin_path.parent.mkdir(parents=True, exist_ok=True)
    flash_bin_path.write_bytes(flash_image)

    with flash_hex_path.open("w", encoding="ascii", newline="\n") as fh:
        for byte in flash_image:
            fh.write(f"{byte:02x}\n")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
