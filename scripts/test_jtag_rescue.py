#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import inspect
import sys
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
from unittest import mock

import pyftdi
from pyftdi.gpio import GpioAsyncController


SCRIPT_PATH = Path(__file__).with_name("jtag_rescue.py")
SPEC = importlib.util.spec_from_file_location("jtag_rescue", SCRIPT_PATH)
assert SPEC and SPEC.loader
JTAG_RESCUE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = JTAG_RESCUE
SPEC.loader.exec_module(JTAG_RESCUE)


class FakeGpioAsyncController:
    instances = []

    def __init__(self) -> None:
        self.calls = []
        self.read_value = 0
        FakeGpioAsyncController.instances.append(self)

    def configure(self, url: str, direction: int = 0, **kwargs) -> int:
        self.calls.append(("configure", url, direction, kwargs))
        return int(kwargs.get("frequency", 0))

    def write(self, out) -> None:
        self.calls.append(("write", int(out)))

    def read(self, readlen: int = 1, peek: bool | None = None, noflush: bool = False):
        self.calls.append(("read", readlen, peek, noflush))
        return self.read_value

    def close(self, freeze: bool = False) -> None:
        self.calls.append(("close", freeze))


class FakeTapTransport:
    TAP_TLR = 0
    TAP_RTI = 1
    TAP_SEL_DR = 2
    TAP_CAP_DR = 3
    TAP_SHIFT_DR = 4
    TAP_EXIT1_DR = 5
    TAP_PAUSE_DR = 6
    TAP_EXIT2_DR = 7
    TAP_UPD_DR = 8
    TAP_SEL_IR = 9
    TAP_CAP_IR = 10
    TAP_SHIFT_IR = 11
    TAP_EXIT1_IR = 12
    TAP_PAUSE_IR = 13
    TAP_EXIT2_IR = 14
    TAP_UPD_IR = 15

    def __init__(self, latency: int = 2) -> None:
        self.state = self.TAP_TLR
        self.ir = JTAG_RESCUE.IR_IDCODE
        self.ir_shift = JTAG_RESCUE.IR_IDCODE
        self.dr_shift = 0
        self.cpu_hold = 0
        self.mem_rsp = JTAG_RESCUE.MemAccResponse(0, 0, 1)
        self.pending = None
        self.latency = latency
        self.memory: dict[int, int] = {}

    def close(self) -> None:
        return None

    def step(self, tms: int, tdi: int) -> int:
        tdo = self._tdo()
        cur = self.state

        if cur == self.TAP_CAP_IR:
            self.ir_shift = 0x1
        elif cur == self.TAP_SHIFT_IR:
            self.ir_shift = ((tdi & 0x1) << (JTAG_RESCUE.IR_WIDTH - 1)) | (self.ir_shift >> 1)
        elif cur == self.TAP_UPD_IR:
            self.ir = self.ir_shift & ((1 << JTAG_RESCUE.IR_WIDTH) - 1)
        elif cur == self.TAP_CAP_DR:
            self._capture_dr()
        elif cur == self.TAP_SHIFT_DR:
            width = self._dr_width()
            self.dr_shift = ((tdi & 0x1) << (width - 1)) | (self.dr_shift >> 1)
        elif cur == self.TAP_UPD_DR:
            self._update_dr()

        self.state = self._tap_next(cur, tms)
        if self.state == self.TAP_RTI and self.pending is not None:
            self._tick_pending()
        return tdo

    def _tdo(self) -> int:
        if self.state == self.TAP_SHIFT_IR:
            return self.ir_shift & 0x1
        if self.state == self.TAP_SHIFT_DR:
            return self.dr_shift & 0x1
        return 0

    def _dr_width(self) -> int:
        if self.ir == JTAG_RESCUE.IR_IDCODE:
            return 32
        if self.ir == JTAG_RESCUE.IR_CPUCTL:
            return 2
        return 69

    def _capture_dr(self) -> None:
        if self.ir == JTAG_RESCUE.IR_IDCODE:
            self.dr_shift = JTAG_RESCUE.IDCODE_VALUE
        elif self.ir == JTAG_RESCUE.IR_CPUCTL:
            self.dr_shift = self.cpu_hold & 0x1
        elif self.ir == JTAG_RESCUE.IR_MEMACC:
            self.dr_shift = (
                (self.mem_rsp.rdata & 0xFFFF_FFFF)
                | ((self.mem_rsp.err & 0x1) << 32)
                | ((self.mem_rsp.done & 0x1) << 33)
            )
        else:
            self.dr_shift = 0

    def _tick_pending(self) -> None:
        assert self.pending is not None
        self.pending["latency"] -= 1
        if self.pending["latency"] > 0:
            return

        write = self.pending["write"]
        addr = self.pending["addr"]
        wstrb = self.pending["wstrb"]
        wdata = self.pending["wdata"]

        if write:
            current = self.memory.get(addr & ~0x3, 0)
            merged = current
            for byte in range(4):
                if (wstrb >> byte) & 0x1:
                    mask = 0xFF << (byte * 8)
                    merged = (merged & ~mask) | (wdata & mask)
            self.memory[addr & ~0x3] = merged & 0xFFFF_FFFF
            self.mem_rsp = JTAG_RESCUE.MemAccResponse(0, 0, 1)
        else:
            self.mem_rsp = JTAG_RESCUE.MemAccResponse(self.memory.get(addr & ~0x3, 0), 0, 1)

        self.pending = None

    def _update_dr(self) -> None:
        if self.ir == JTAG_RESCUE.IR_CPUCTL:
            self.cpu_hold = self.dr_shift & 0x1
            return

        if self.ir != JTAG_RESCUE.IR_MEMACC:
            return

        if self.pending is not None:
            self.mem_rsp = JTAG_RESCUE.MemAccResponse(0, 1, 1)
            return

        write = self.dr_shift & 0x1
        addr = (self.dr_shift >> 1) & 0xFFFF_FFFF
        wstrb = (self.dr_shift >> 33) & 0xF
        wdata = (self.dr_shift >> 37) & 0xFFFF_FFFF

        if not self._is_sram_addr(addr):
            self.mem_rsp = JTAG_RESCUE.MemAccResponse(0, 1, 1)
            return

        self.mem_rsp = JTAG_RESCUE.MemAccResponse(0, 0, 0)
        self.pending = {
            "write": write,
            "addr": addr,
            "wstrb": wstrb,
            "wdata": wdata,
            "latency": self.latency,
        }

    @staticmethod
    def _is_sram_addr(addr: int) -> bool:
        return (
            0x00000000 <= addr <= 0x00003FFF
            or 0x00010000 <= addr <= 0x00013FFF
            or 0x00030000 <= addr <= 0x00033FFF
        )

    @classmethod
    def _tap_next(cls, cur: int, tms: int) -> int:
        if cur == cls.TAP_TLR:
            return cls.TAP_TLR if tms else cls.TAP_RTI
        if cur == cls.TAP_RTI:
            return cls.TAP_SEL_DR if tms else cls.TAP_RTI
        if cur == cls.TAP_SEL_DR:
            return cls.TAP_SEL_IR if tms else cls.TAP_CAP_DR
        if cur == cls.TAP_CAP_DR:
            return cls.TAP_EXIT1_DR if tms else cls.TAP_SHIFT_DR
        if cur == cls.TAP_SHIFT_DR:
            return cls.TAP_EXIT1_DR if tms else cls.TAP_SHIFT_DR
        if cur == cls.TAP_EXIT1_DR:
            return cls.TAP_UPD_DR if tms else cls.TAP_PAUSE_DR
        if cur == cls.TAP_PAUSE_DR:
            return cls.TAP_EXIT2_DR if tms else cls.TAP_PAUSE_DR
        if cur == cls.TAP_EXIT2_DR:
            return cls.TAP_UPD_DR if tms else cls.TAP_SHIFT_DR
        if cur == cls.TAP_UPD_DR:
            return cls.TAP_SEL_DR if tms else cls.TAP_RTI
        if cur == cls.TAP_SEL_IR:
            return cls.TAP_TLR if tms else cls.TAP_CAP_IR
        if cur == cls.TAP_CAP_IR:
            return cls.TAP_EXIT1_IR if tms else cls.TAP_SHIFT_IR
        if cur == cls.TAP_SHIFT_IR:
            return cls.TAP_EXIT1_IR if tms else cls.TAP_SHIFT_IR
        if cur == cls.TAP_EXIT1_IR:
            return cls.TAP_UPD_IR if tms else cls.TAP_PAUSE_IR
        if cur == cls.TAP_PAUSE_IR:
            return cls.TAP_EXIT2_IR if tms else cls.TAP_PAUSE_IR
        if cur == cls.TAP_EXIT2_IR:
            return cls.TAP_UPD_IR if tms else cls.TAP_SHIFT_IR
        if cur == cls.TAP_UPD_IR:
            return cls.TAP_SEL_DR if tms else cls.TAP_RTI
        return cls.TAP_TLR


def assert_equal(got, exp, label: str) -> None:
    if got != exp:
        raise AssertionError(f"{label}: got={got!r} exp={exp!r}")


def run_pyftdi_api_check() -> None:
    assert_equal(pyftdi.__version__, "0.57.1", "pyftdi_version")
    configure_sig = inspect.signature(GpioAsyncController.configure)
    write_sig = inspect.signature(GpioAsyncController.write)
    read_sig = inspect.signature(GpioAsyncController.read)
    close_sig = inspect.signature(GpioAsyncController.close)
    assert "direction" in configure_sig.parameters
    assert "out" in write_sig.parameters
    assert "peek" in read_sig.parameters
    assert "freeze" in close_sig.parameters


def run_pyftdi_transport_mock_check() -> None:
    FakeGpioAsyncController.instances = []
    with mock.patch("pyftdi.gpio.GpioAsyncController", FakeGpioAsyncController):
        transport = JTAG_RESCUE.PyFtdiBitbangTransport(
            url="ftdi:///1",
            frequency=1_000_000,
            tck_bit=0,
            tms_bit=1,
            tdi_bit=2,
            tdo_bit=3,
            sample_delay_us=0.0,
        )
        fake = FakeGpioAsyncController.instances[-1]
        fake.read_value = 1 << 3
        bit = transport.step(1, 0)
        assert_equal(bit, 1, "pyftdi_step_sample")
        transport.close()

    writes = [entry[1] for entry in fake.calls if entry[0] == "write"]
    assert_equal(writes[:4], [0, 2, 3, 2], "pyftdi_write_sequence")
    reads = [entry for entry in fake.calls if entry[0] == "read"]
    assert_equal(reads[0][2], True, "pyftdi_read_peek")


def run_client_protocol_check() -> None:
    client = JTAG_RESCUE.JtagRescueClient(FakeTapTransport(latency=2), idle_cycles=4)
    client.tap_reset()
    assert_equal(client.read_idcode(), JTAG_RESCUE.IDCODE_VALUE, "idcode")
    assert_equal(client.hold_cpu(), 1, "hold_cpu")
    client.write_word(JTAG_RESCUE.ADDR_INSTR_BASE, 0x12345678)
    assert_equal(client.read_word(JTAG_RESCUE.ADDR_INSTR_BASE), 0x12345678, "imem_readback")
    client.write_word(JTAG_RESCUE.ADDR_DATA_BASE, 0x4A544147)
    assert_equal(client.read_word(JTAG_RESCUE.ADDR_DATA_BASE), 0x4A544147, "dmem_readback")
    try:
        client.read_word(0x40000000)
    except RuntimeError:
        pass
    else:
        raise AssertionError("mmio read should fail")
    assert_equal(client.release_cpu(), 0, "release_cpu")
    client.close()


def run_rescue_load_command_check() -> None:
    client = JTAG_RESCUE.JtagRescueClient(FakeTapTransport(latency=2), idle_cycles=4)
    client.tap_reset()
    with TemporaryDirectory() as tempdir:
        temp = Path(tempdir)
        imem = temp / "imem.hex"
        dmem = temp / "dmem.hex"
        imem.write_text("12345678\n9abcdef0\n", encoding="utf-8")
        dmem.write_text("4a544147\n", encoding="utf-8")
        args = SimpleNamespace(imem_hex=str(imem), data_hex=str(dmem))
        rc = JTAG_RESCUE.cmd_rescue_load(client, args)
        assert_equal(rc, 0, "rescue_load_rc")
        assert_equal(client.read_word(JTAG_RESCUE.ADDR_INSTR_BASE), 0x12345678, "rescue_imem_word0")
        assert_equal(client.read_word(JTAG_RESCUE.ADDR_INSTR_BASE + 4), 0x9ABCDEF0, "rescue_imem_word1")
        assert_equal(client.read_word(JTAG_RESCUE.ADDR_DATA_BASE), 0x4A544147, "rescue_dmem_word0")
        assert_equal(client.read_cpu_hold(), 0, "rescue_cpu_released")
    client.close()


def main() -> int:
    run_pyftdi_api_check()
    run_pyftdi_transport_mock_check()
    run_client_protocol_check()
    run_rescue_load_command_check()
    print("JTAG_PYHOST_SELFTEST_PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
