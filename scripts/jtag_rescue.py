#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import List, Protocol, Sequence


IR_WIDTH = 4
IR_IDCODE = 0x1
IR_MEMACC = 0x2
IR_CPUCTL = 0x3
IR_BYPASS = 0xF

IDCODE_VALUE = 0xE2030001

MEMACC_FLUSH_ADDR = 0x40000000
ADDR_INSTR_BASE = 0x00000000
ADDR_DATA_BASE = 0x00010000
ADDR_WEIGHT_BASE = 0x00030000


class Transport(Protocol):
    def step(self, tms: int, tdi: int) -> int:
        ...

    def close(self) -> None:
        ...


class PyFtdiBitbangTransport:
    def __init__(
        self,
        url: str,
        frequency: int,
        tck_bit: int,
        tms_bit: int,
        tdi_bit: int,
        tdo_bit: int,
        sample_delay_us: float,
    ) -> None:
        try:
            from pyftdi.gpio import GpioAsyncController
        except ImportError as exc:
            raise SystemExit(
                "pyftdi is required for --backend pyftdi. Install it with: pip install pyftdi"
            ) from exc

        self._gpio = GpioAsyncController()
        self._tck_bit = tck_bit
        self._tms_bit = tms_bit
        self._tdi_bit = tdi_bit
        self._tdo_mask = 1 << tdo_bit
        self._sample_delay_s = max(sample_delay_us, 0.0) / 1_000_000.0
        direction = (1 << tck_bit) | (1 << tms_bit) | (1 << tdi_bit)
        try:
            self._gpio.configure(url, direction=direction, frequency=frequency, initial=0x00)
        except Exception as exc:  # pragma: no cover - depends on host USB stack
            raise RuntimeError(
                f"pyftdi failed to open '{url}': {exc}. "
                "Ensure a libusb backend is available and an FTDI adapter is connected."
            ) from exc
        self._write_outputs(0, 0, 0)

    def _encode(self, tck: int, tms: int, tdi: int) -> int:
        return (
            ((1 if tck else 0) << self._tck_bit)
            | ((1 if tms else 0) << self._tms_bit)
            | ((1 if tdi else 0) << self._tdi_bit)
        )

    def _write_outputs(self, tck: int, tms: int, tdi: int) -> None:
        self._gpio.write(self._encode(tck, tms, tdi))

    def step(self, tms: int, tdi: int) -> int:
        self._write_outputs(0, tms, tdi)
        self._write_outputs(1, tms, tdi)
        if self._sample_delay_s:
            time.sleep(self._sample_delay_s)
        sample = self._gpio.read(peek=True)
        self._write_outputs(0, tms, tdi)
        return 1 if (sample & self._tdo_mask) else 0

    def close(self) -> None:
        try:
            self._write_outputs(0, 0, 0)
        finally:
            self._gpio.close()


@dataclass
class MemAccResponse:
    rdata: int
    err: int
    done: int


class JtagRescueClient:
    def __init__(self, transport: Transport, idle_cycles: int) -> None:
        self._transport = transport
        self._idle_cycles = idle_cycles
        self._cpu_hold_state = 0

    def close(self) -> None:
        self._transport.close()

    def _step(self, tms: int, tdi: int) -> int:
        return self._transport.step(1 if tms else 0, 1 if tdi else 0)

    def run_idle(self, cycles: int) -> None:
        for _ in range(cycles):
            self._step(0, 0)

    def tap_reset(self) -> None:
        for _ in range(6):
            self._step(1, 0)
        self._step(0, 0)

    def _shift_ir(self, ir_value: int, width: int = IR_WIDTH) -> int:
        rx = 0
        self._step(1, 0)
        self._step(1, 0)
        self._step(0, 0)
        self._step(0, 0)
        for bit in range(width):
            tdo = self._step(1 if bit == (width - 1) else 0, (ir_value >> bit) & 0x1)
            rx |= (tdo & 0x1) << bit
        self._step(1, 0)
        self._step(0, 0)
        return rx

    def _shift_dr(self, value: int, width: int) -> int:
        rx = 0
        self._step(1, 0)
        self._step(0, 0)
        self._step(0, 0)
        for bit in range(width):
            tdo = self._step(1 if bit == (width - 1) else 0, (value >> bit) & 0x1)
            rx |= (tdo & 0x1) << bit
        self._step(1, 0)
        self._step(0, 0)
        return rx

    def read_idcode(self) -> int:
        self._shift_ir(IR_IDCODE)
        return self._shift_dr(0, 32) & 0xFFFF_FFFF

    def cpuctl_scan(self, hold_writeback: int) -> int:
        self._shift_ir(IR_CPUCTL)
        payload = hold_writeback & 0x1
        rsp = self._shift_dr(payload, 2)
        self._cpu_hold_state = hold_writeback & 0x1
        return rsp & 0x1

    def hold_cpu(self) -> int:
        self._shift_ir(IR_CPUCTL)
        self._shift_dr(0x1, 2)
        self._cpu_hold_state = 1
        return self.cpuctl_scan(1)

    def release_cpu(self) -> int:
        self._shift_ir(IR_CPUCTL)
        self._shift_dr(0x0, 2)
        self._cpu_hold_state = 0
        return self.cpuctl_scan(0)

    def read_cpu_hold(self) -> int:
        return self.cpuctl_scan(self._cpu_hold_state)

    @staticmethod
    def _pack_memacc(write: int, addr: int, wstrb: int, wdata: int) -> int:
        payload = 0
        payload |= (write & 0x1) << 0
        payload |= (addr & 0xFFFF_FFFF) << 1
        payload |= (wstrb & 0xF) << 33
        payload |= (wdata & 0xFFFF_FFFF) << 37
        return payload

    def _memacc_scan(self, write: int, addr: int, wstrb: int, wdata: int) -> MemAccResponse:
        self._shift_ir(IR_MEMACC)
        rsp = self._shift_dr(self._pack_memacc(write, addr, wstrb, wdata), 69)
        return MemAccResponse(
            rdata=rsp & 0xFFFF_FFFF,
            err=(rsp >> 32) & 0x1,
            done=(rsp >> 33) & 0x1,
        )

    def _memacc_issue(self, write: int, addr: int, wstrb: int, wdata: int) -> None:
        self._memacc_scan(write, addr, wstrb, wdata)

    def _memacc_finish(self) -> MemAccResponse:
        self.run_idle(self._idle_cycles)
        rsp = self._memacc_scan(0, MEMACC_FLUSH_ADDR, 0, 0)
        if not rsp.done:
            raise RuntimeError("MEMACC response timeout; increase --idle-cycles or check target state")
        self.run_idle(self._idle_cycles)
        return rsp

    def memacc(self, write: int, addr: int, wstrb: int, wdata: int) -> MemAccResponse:
        self._memacc_issue(write, addr, wstrb, wdata)
        return self._memacc_finish()

    def read_word(self, addr: int) -> int:
        rsp = self.memacc(0, addr, 0, 0)
        if rsp.err:
            raise RuntimeError(f"read failed at 0x{addr:08X}")
        return rsp.rdata

    def write_word(self, addr: int, value: int, wstrb: int = 0xF) -> None:
        rsp = self.memacc(1, addr, wstrb, value)
        if rsp.err:
            raise RuntimeError(f"write failed at 0x{addr:08X}")


def parse_int(value: str) -> int:
    return int(value, 0)


def parse_readmemh(path: Path) -> List[int]:
    words: List[int] = []
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.split("//", 1)[0].strip()
        if not line:
            continue
        if line.startswith("@"):
            raise ValueError(f"address directives are not supported in {path}: {line}")
        words.append(int(line, 16) & 0xFFFF_FFFF)
    return words


def write_words(client: JtagRescueClient, base_addr: int, words: Sequence[int]) -> None:
    for index, word in enumerate(words):
        client.write_word(base_addr + index * 4, word)


def verify_words(client: JtagRescueClient, base_addr: int, words: Sequence[int]) -> None:
    for index, expected in enumerate(words):
        addr = base_addr + index * 4
        got = client.read_word(addr)
        if got != expected:
            raise RuntimeError(
                f"verify mismatch at 0x{addr:08X}: got 0x{got:08X}, expected 0x{expected:08X}"
            )


def build_transport(args: argparse.Namespace) -> Transport:
    if args.backend == "pyftdi":
        return PyFtdiBitbangTransport(
            url=args.url,
            frequency=args.frequency,
            tck_bit=args.tck_bit,
            tms_bit=args.tms_bit,
            tdi_bit=args.tdi_bit,
            tdo_bit=args.tdo_bit,
            sample_delay_us=args.sample_delay_us,
        )
    raise SystemExit(f"unsupported backend: {args.backend}")


def add_transport_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--backend", default="pyftdi", choices=["pyftdi"])
    parser.add_argument("--url", default="ftdi:///1")
    parser.add_argument("--frequency", type=int, default=1_000_000)
    parser.add_argument("--idle-cycles", type=int, default=2048)
    parser.add_argument("--tck-bit", type=int, default=0)
    parser.add_argument("--tms-bit", type=int, default=1)
    parser.add_argument("--tdi-bit", type=int, default=2)
    parser.add_argument("--tdo-bit", type=int, default=3)
    parser.add_argument("--sample-delay-us", type=float, default=0.0)


def cmd_idcode(client: JtagRescueClient, _args: argparse.Namespace) -> int:
    idcode = client.read_idcode()
    print(f"IDCODE 0x{idcode:08X}")
    return 0 if idcode == IDCODE_VALUE else 1


def cmd_hold_cpu(client: JtagRescueClient, _args: argparse.Namespace) -> int:
    hold = client.hold_cpu()
    print(f"cpu_reset_hold={hold}")
    return 0 if hold == 1 else 1


def cmd_release_cpu(client: JtagRescueClient, _args: argparse.Namespace) -> int:
    hold = client.release_cpu()
    print(f"cpu_reset_hold={hold}")
    return 0 if hold == 0 else 1


def cmd_cpu_state(client: JtagRescueClient, _args: argparse.Namespace) -> int:
    hold = client.read_cpu_hold()
    print(f"cpu_reset_hold={hold}")
    return 0


def cmd_read(client: JtagRescueClient, args: argparse.Namespace) -> int:
    base = parse_int(args.addr)
    words = int(args.words, 0)
    for index in range(words):
        addr = base + index * 4
        value = client.read_word(addr)
        print(f"0x{addr:08X}: 0x{value:08X}")
    return 0


def cmd_write(client: JtagRescueClient, args: argparse.Namespace) -> int:
    base = parse_int(args.addr)
    values = [parse_int(word) & 0xFFFF_FFFF for word in args.word]
    for index, value in enumerate(values):
        addr = base + index * 4
        client.write_word(addr, value)
        print(f"0x{addr:08X}: wrote 0x{value:08X}")
    return 0


def cmd_load_imem(client: JtagRescueClient, args: argparse.Namespace) -> int:
    imem_path = Path(args.readmemh)
    words = parse_readmemh(imem_path)
    write_words(client, ADDR_INSTR_BASE, words)
    verify_words(client, ADDR_INSTR_BASE, words)
    print(f"loaded {len(words)} IMEM words from {imem_path}")
    return 0


def cmd_rescue_load(client: JtagRescueClient, args: argparse.Namespace) -> int:
    imem_path = Path(args.imem_hex)
    imem_words = parse_readmemh(imem_path)
    data_words: List[int] = []
    data_path = Path(args.data_hex) if args.data_hex else None
    if data_path:
        data_words = parse_readmemh(data_path)

    load_addr = args.load_addr
    hold = client.hold_cpu()
    if hold != 1:
        raise RuntimeError("failed to hold CPU before rescue load")

    write_words(client, load_addr, imem_words)
    verify_words(client, load_addr, imem_words)

    if data_words:
        write_words(client, ADDR_DATA_BASE, data_words)
        verify_words(client, ADDR_DATA_BASE, data_words)

    hold = client.release_cpu()
    if hold != 0:
        raise RuntimeError("failed to release CPU after rescue load")

    print(
        f"rescue-load complete: load_addr=0x{load_addr:08X} "
        f"imem_words={len(imem_words)} data_words={len(data_words)}"
    )
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Minimal rescue JTAG loader for the SNN SoC main branch."
    )
    add_transport_args(parser)
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("idcode")
    subparsers.add_parser("hold-cpu")
    subparsers.add_parser("release-cpu")
    subparsers.add_parser("cpu-state")

    read_parser = subparsers.add_parser("read")
    read_parser.add_argument("addr")
    read_parser.add_argument("words")

    write_parser = subparsers.add_parser("write")
    write_parser.add_argument("addr")
    write_parser.add_argument("word", nargs="+")

    load_imem_parser = subparsers.add_parser("load-imem")
    load_imem_parser.add_argument("readmemh")

    rescue_parser = subparsers.add_parser("rescue-load")
    rescue_parser.add_argument("imem_hex")
    rescue_parser.add_argument("data_hex", nargs="?")
    # When tape-out chip_top has ENABLE_BOOT_ROM=1, the bus decoder routes
    # 0x0..0xFFF to the mask ROM (writes ignored).  In that layout the real
    # INSTR_SRAM sits at 0x1000..0x4FFF, so firmware must be loaded to 0x1000.
    # Accept an override here; default keeps legacy V1 behaviour (0x0).
    rescue_parser.add_argument(
        "--load-addr",
        type=parse_int,
        default=ADDR_INSTR_BASE,
        help="Destination base address for imem_hex "
             "(default 0x0 V1 layout; use 0x1000 when ENABLE_BOOT_ROM=1).",
    )

    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    handlers = {
        "idcode": cmd_idcode,
        "hold-cpu": cmd_hold_cpu,
        "release-cpu": cmd_release_cpu,
        "cpu-state": cmd_cpu_state,
        "read": cmd_read,
        "write": cmd_write,
        "load-imem": cmd_load_imem,
        "rescue-load": cmd_rescue_load,
    }

    client: JtagRescueClient | None = None
    try:
        transport = build_transport(args)
        client = JtagRescueClient(transport, idle_cycles=args.idle_cycles)
        client.tap_reset()
        return handlers[args.command](client, args)
    except KeyboardInterrupt:
        return 130
    except RuntimeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    finally:
        if client is not None:
            client.close()


if __name__ == "__main__":
    sys.exit(main())
