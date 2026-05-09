#!/usr/bin/env python3
"""Sanity-check the committed REPRODUCE.md command/file chain."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


PATH_PATTERN = re.compile(r"audit-v2/[^\s`\\]+")


def _resolve_roots(args: argparse.Namespace) -> tuple[Path, Path, Path]:
    audit_v2 = Path(args.audit_v2).resolve()
    soc_design = Path(args.soc_design).resolve()
    reproduce = soc_design / "essay" / "REPRODUCE.md"
    return audit_v2, soc_design, reproduce


def _referenced_paths(reproduce_md: Path) -> list[str]:
    text = reproduce_md.read_text(encoding="utf-8")
    found = []
    for match in PATH_PATTERN.finditer(text):
        rel = match.group(0)
        if rel not in found:
            found.append(rel)
    return found


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--audit-v2", required=True)
    parser.add_argument("--soc-design", required=True)
    args = parser.parse_args(argv)

    audit_v2, soc_design, reproduce = _resolve_roots(args)
    if not reproduce.exists():
        print(f"[FAIL] missing REPRODUCE.md: {reproduce}")
        print("REPRODUCE_SANITY_FAIL")
        return 1

    referenced = _referenced_paths(reproduce)
    missing: list[str] = []
    for rel in referenced:
        if not rel.startswith("audit-v2/"):
            continue
        path = audit_v2 / Path(rel.removeprefix("audit-v2/"))
        if not path.exists():
            missing.append(rel)

    if missing:
        for rel in missing:
            print(f"[FAIL] REPRODUCE.md references missing path: {rel}")
        print("REPRODUCE_SANITY_FAIL")
        return 1

    print(f"[ok]   REPRODUCE.md path sanity checked: {len(referenced)} audit-v2 paths")
    print("REPRODUCE_SANITY_PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
