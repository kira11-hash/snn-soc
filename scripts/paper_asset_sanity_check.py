#!/usr/bin/env python3
"""Sanity-check paper-facing close-out assets that can drift independently."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


PLACEHOLDER_PATTERN = re.compile(r"placeholder|tbd|<missing>", re.IGNORECASE)
ENTRY_PATTERN = re.compile(r"^@\w+\{", re.MULTILINE)
DOI_PATTERN = re.compile(r"\bdoi\s*=", re.IGNORECASE)
MIN_EXPECTED_ENTRIES = 21
MIN_EXPECTED_DOIS = 21


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--soc-design", required=True)
    args = parser.parse_args(argv)

    soc_design = Path(args.soc_design).resolve()
    paper_bib = soc_design / "essay" / "paper.bib"
    if not paper_bib.exists():
        print(f"[FAIL] missing bibliography file: {paper_bib}")
        print("PAPER_ASSET_SANITY_FAIL")
        return 1

    text = paper_bib.read_text(encoding="utf-8")
    entry_count = len(ENTRY_PATTERN.findall(text))
    doi_count = len(DOI_PATTERN.findall(text))
    if entry_count < MIN_EXPECTED_ENTRIES:
        print(
            f"[FAIL] bibliography entry count regressed: "
            f"{entry_count} < {MIN_EXPECTED_ENTRIES}"
        )
        print("PAPER_ASSET_SANITY_FAIL")
        return 1
    if doi_count < MIN_EXPECTED_DOIS:
        print(
            f"[FAIL] DOI-tagged bibliography entry count regressed: "
            f"{doi_count} < {MIN_EXPECTED_DOIS}"
        )
        print("PAPER_ASSET_SANITY_FAIL")
        return 1
    if PLACEHOLDER_PATTERN.search(text):
        print("[FAIL] bibliography still contains placeholder-style tokens")
        print("PAPER_ASSET_SANITY_FAIL")
        return 1

    print(
        f"[ok]   paper.bib sanity checked: entries={entry_count} "
        f"doi_entries={doi_count}"
    )
    print("PAPER_ASSET_SANITY_PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
