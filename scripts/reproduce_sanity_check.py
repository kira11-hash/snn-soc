#!/usr/bin/env python3
"""Sanity-check the committed REPRODUCE.md command/file chain."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


PATH_PATTERN = re.compile(r"audit-v2/[^\s`\\]+")
REQUIRED_PATHS = (
    "audit-v2/python_multilayer/requirements-repro-frozen.txt",
    "audit-v2/python_multilayer/h1_schedule_ablation.py",
    "audit-v2/scripts/manifest_verify_ci.sh",
    "audit-v2/python_multilayer/h1_lenet5_equivalence_check.py",
)
REQUIRED_CONFIG_IDS = (
    "v1_fc_8x8_mnist",
    "v2b_fc_fashion14_2L",
    "v2b_fc_mnist14_2L",
    "v2b_lenet5_mnist_28x28",
    "v2b_fc_fashion28_2L",
    "v2b_lenet5_fashion_28x28",
)
REQUIRED_TEXT_SNIPPETS = (
    "## CPU-only quick start for Config #5",
    "--config-id v2b_fc_fashion28_2L",
    "--schedule baseline",
    "accuracy_pct=84.0500",
    "audit-v2/python_multilayer/data/",
)


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


def _load_text(reproduce_md: Path) -> str:
    return reproduce_md.read_text(encoding="utf-8")


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

    text = _load_text(reproduce)
    referenced = _referenced_paths(reproduce)
    missing: list[str] = []
    for rel in referenced:
        if not rel.startswith("audit-v2/"):
            continue
        path = audit_v2 / Path(rel.removeprefix("audit-v2/"))
        if not path.exists():
            missing.append(rel)

    missing_required_paths = [
        rel
        for rel in REQUIRED_PATHS
        if rel not in referenced or not (audit_v2 / Path(rel.removeprefix("audit-v2/"))).exists()
    ]
    missing_config_ids = [config_id for config_id in REQUIRED_CONFIG_IDS if config_id not in text]
    missing_snippets = [snippet for snippet in REQUIRED_TEXT_SNIPPETS if snippet not in text]

    if missing or missing_required_paths or missing_config_ids or missing_snippets:
        for rel in missing:
            print(f"[FAIL] REPRODUCE.md references missing path: {rel}")
        for rel in missing_required_paths:
            print(f"[FAIL] REPRODUCE.md missing required repro path: {rel}")
        for config_id in missing_config_ids:
            print(f"[FAIL] REPRODUCE.md missing required config id mention: {config_id}")
        for snippet in missing_snippets:
            print(f"[FAIL] REPRODUCE.md missing required snippet: {snippet}")
        print("REPRODUCE_SANITY_FAIL")
        return 1

    print(
        f"[ok]   REPRODUCE.md sanity checked: "
        f"{len(referenced)} audit-v2 paths, "
        f"{len(REQUIRED_CONFIG_IDS)} config ids, "
        f"{len(REQUIRED_TEXT_SNIPPETS)} key snippets"
    )
    print("REPRODUCE_SANITY_PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
