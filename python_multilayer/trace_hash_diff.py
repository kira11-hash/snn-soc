#!/usr/bin/env python3
"""
python_multilayer/trace_hash_diff.py

Compare two M1 trace-hash UART logs (one from the ARM PS-side host,
one from the E203 PL soft-core host) and report whether the hash
sequences are byte-byte identical. If they diverge, report the first
divergence as (layer_id, t_idx, buf_sel) plus the conflicting hash
words.

Used by the dual-host validation methodology in paper section 4.2.

Log format produced by fw/src/v2b_trace_hash.c::v2b_trace_hash_dump_uart:

    TRACE_HASH_BEGIN config=<config> host=<host> sample=<sample>
    [TRACE_HASH_WARN OVERFLOW]
    [TRACE_HASH_WARN LAYER_ID_FAULT]
    HASH layer=<L> t=<T> buf=<A|B> 0x<HHHHHHHH>
    ...
    TRACE_HASH_END count=<N>

Usage:
    python trace_hash_diff.py --arm arm.log --e203 e203.log
    python trace_hash_diff.py --arm arm.log --e203 e203.log --sample 7

Exit codes:
    0  exact match (all entries byte-byte identical)
    1  divergence detected (first-divergence report printed)
    2  parser / IO error
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field


HASH_LINE_RE = re.compile(
    r"^HASH\s+layer=(\d+)\s+t=(\d+)\s+buf=([AB])\s+0x([0-9A-Fa-f]{8})\s*$"
)
BEGIN_LINE_RE = re.compile(
    r"^TRACE_HASH_BEGIN\s+config=(\S+)\s+host=(\S+)\s+sample=(\d+)\s*$"
)
END_LINE_RE = re.compile(r"^TRACE_HASH_END\s+count=(\d+)\s*$")
WARN_LINE_RE = re.compile(r"^TRACE_HASH_WARN\s+(\S+)\s*$")


@dataclass(frozen=True)
class HashEntry:
    layer_id: int
    t_idx: int
    buf_sel: int   # 0=A, 1=B
    hash_word: int


@dataclass
class HostLog:
    config: str = ""
    host: str = ""
    sample: int = -1
    warnings: list[str] = field(default_factory=list)
    entries: list[HashEntry] = field(default_factory=list)
    count_reported: int = -1   # value parsed from the END line; -1 if missing


@dataclass
class DiffReport:
    config_name: str
    sample_id: int
    arm_count: int
    e203_count: int
    hash_mismatch_count: int
    length_mismatch_count: int
    diverge_count: int
    first_divergence: tuple[int, int, int] | None  # (layer, t, buf_sel)
    arm_hash_at_first: int | None
    e203_hash_at_first: int | None
    missing_host: str | None
    arm_warnings: list[str]
    e203_warnings: list[str]


def parse_log(path: str, sample_filter: int | None = None) -> HostLog:
    """Parse one host log; default keeps the first block, --sample picks one."""
    log = HostLog()
    in_block = False
    keep_block = False
    matched_block = False
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for raw in f:
            line = raw.rstrip("\r\n")
            m = BEGIN_LINE_RE.match(line)
            if m:
                in_block = True
                config, host, sample_str = m.group(1), m.group(2), m.group(3)
                sample_int = int(sample_str)
                keep_block = False
                if sample_filter is None:
                    if not matched_block:
                        keep_block = True
                elif sample_int == sample_filter:
                    keep_block = True
                if keep_block:
                    matched_block = True
                    log.config = config
                    log.host = host
                    log.sample = sample_int
                    log.warnings = []
                    log.entries = []
                    log.count_reported = -1
                continue
            if not in_block:
                continue
            m = WARN_LINE_RE.match(line)
            if m and keep_block:
                log.warnings.append(m.group(1))
                continue
            m = HASH_LINE_RE.match(line)
            if m and keep_block:
                log.entries.append(HashEntry(
                    layer_id  = int(m.group(1)),
                    t_idx     = int(m.group(2)),
                    buf_sel   = 0 if m.group(3) == "A" else 1,
                    hash_word = int(m.group(4), 16),
                ))
                continue
            if keep_block and line.startswith("HASH "):
                raise ValueError(f"{path}: malformed HASH line: {line}")
            m = END_LINE_RE.match(line)
            if m and keep_block:
                log.count_reported = int(m.group(1))
                if log.count_reported != len(log.entries):
                    raise ValueError(
                        f"{path}: TRACE_HASH_END count={log.count_reported} "
                        f"but parsed {len(log.entries)} HASH lines"
                    )
                break
            if m:
                in_block = False
                continue
            if keep_block and line.startswith("TRACE_HASH_WARN"):
                raise ValueError(f"{path}: malformed WARN line: {line}")
            if keep_block and line.startswith("TRACE_HASH_END"):
                raise ValueError(f"{path}: malformed END line: {line}")

    if sample_filter is not None and not matched_block:
        raise ValueError(f"{path}: sample {sample_filter} not found")
    if matched_block and log.count_reported < 0:
        raise ValueError(f"{path}: missing TRACE_HASH_END for selected block")
    return log


def diff_hash_logs(arm: HostLog, e203: HostLog) -> DiffReport:
    """Walk both lists in parallel; first divergence wins."""
    n = min(len(arm.entries), len(e203.entries))
    hash_mismatch = 0
    first_div: tuple[int, int, int] | None = None
    arm_h_first: int | None = None
    e203_h_first: int | None = None
    missing_host: str | None = None

    for i in range(n):
        a = arm.entries[i]
        b = e203.entries[i]
        if (a.layer_id, a.t_idx, a.buf_sel, a.hash_word) != \
           (b.layer_id, b.t_idx, b.buf_sel, b.hash_word):
            hash_mismatch += 1
            if first_div is None:
                # Use the ARM key as the canonical first-divergence
                # location so both reports look the same regardless of
                # the order arguments were passed.
                first_div = (a.layer_id, a.t_idx, a.buf_sel)
                arm_h_first = a.hash_word
                e203_h_first = b.hash_word

    extra = abs(len(arm.entries) - len(e203.entries))
    if extra and first_div is None:
        # Length mismatch but the common prefix matched. Flag the first
        # missing entry as the divergence point.
        if len(arm.entries) < len(e203.entries):
            tail = e203.entries[len(arm.entries)]
            missing_host = "arm"
        else:
            tail = arm.entries[len(e203.entries)]
            missing_host = "e203"
        first_div = (tail.layer_id, tail.t_idx, tail.buf_sel)

    return DiffReport(
        config_name        = arm.config or e203.config,
        sample_id          = arm.sample if arm.sample >= 0 else e203.sample,
        arm_count          = len(arm.entries),
        e203_count         = len(e203.entries),
        hash_mismatch_count = hash_mismatch,
        length_mismatch_count = extra,
        diverge_count      = hash_mismatch + extra,
        first_divergence   = first_div,
        arm_hash_at_first  = arm_h_first,
        e203_hash_at_first = e203_h_first,
        missing_host       = missing_host,
        arm_warnings       = arm.warnings,
        e203_warnings      = e203.warnings,
    )


def emit_report(rep: DiffReport) -> int:
    if rep.diverge_count == 0 and rep.arm_count == rep.e203_count:
        print(f"TRACE_HASH_DIFF MATCH config={rep.config_name} "
              f"sample={rep.sample_id} entries={rep.arm_count}")
        if rep.arm_warnings:
            print(f"  ARM warnings: {','.join(rep.arm_warnings)}")
        if rep.e203_warnings:
            print(f"  E203 warnings: {','.join(rep.e203_warnings)}")
        return 0

    print("TRACE_HASH_DIFF DIVERGENCE")
    print(f"  config: {rep.config_name}")
    print(f"  sample: {rep.sample_id}")
    print(f"  total entries (arm/e203): {rep.arm_count}/{rep.e203_count}")
    print(f"  hash mismatch count: {rep.hash_mismatch_count}")
    print(f"  length mismatch count: {rep.length_mismatch_count}")
    print(f"  diverge count: {rep.diverge_count}")
    if rep.first_divergence is not None:
        layer, t, buf_sel = rep.first_divergence
        buf_label = "A" if buf_sel == 0 else "B"
        print(f"  first divergence at: layer={layer} t={t} buf={buf_label}")
        if rep.arm_hash_at_first is not None and rep.e203_hash_at_first is not None:
            print(f"    arm  hash: 0x{rep.arm_hash_at_first:08X}")
            print(f"    e203 hash: 0x{rep.e203_hash_at_first:08X}")
        else:
            print(f"    (length mismatch; missing on {rep.missing_host})")
    if rep.arm_warnings:
        print(f"  ARM warnings: {','.join(rep.arm_warnings)}")
    if rep.e203_warnings:
        print(f"  E203 warnings: {','.join(rep.e203_warnings)}")
    return 1


def main() -> int:
    ap = argparse.ArgumentParser(description="Diff two M1 trace-hash UART logs.")
    ap.add_argument("--arm", required=True, help="ARM-side UART log path")
    ap.add_argument("--e203", required=True, help="E203-side UART log path")
    ap.add_argument("--sample", type=int, default=None,
                    help="Optional sample id filter; default = first block in each log")
    args = ap.parse_args()

    try:
        arm = parse_log(args.arm, args.sample)
        e203 = parse_log(args.e203, args.sample)
    except (FileNotFoundError, IOError, OSError, ValueError) as exc:
        print(f"trace_hash_diff: parse or I/O error: {exc}", file=sys.stderr)
        return 2

    if not arm.entries and not e203.entries:
        print("trace_hash_diff: both logs are empty (no HASH lines parsed)", file=sys.stderr)
        return 2
    if not arm.entries:
        print("trace_hash_diff: ARM log is missing HASH entries", file=sys.stderr)
        return 2
    if not e203.entries:
        print("trace_hash_diff: E203 log is missing HASH entries", file=sys.stderr)
        return 2

    rep = diff_hash_logs(arm, e203)
    return emit_report(rep)


if __name__ == "__main__":
    sys.exit(main())
