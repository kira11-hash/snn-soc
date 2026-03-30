#!/usr/bin/env python3
"""Check local Markdown links across tracked .md files."""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
LINK_RE = re.compile(r"\[[^\]]+\]\(([^)]+)\)")


def tracked_markdown_files() -> list[Path]:
    proc = subprocess.run(
        ["git", "-c", "core.quotePath=false", "ls-files", "*.md"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        encoding="utf-8",
        check=True,
    )
    return [REPO_ROOT / rel for rel in proc.stdout.splitlines() if rel]


def iter_local_targets(md_path: Path):
    text = md_path.read_text(encoding="utf-8", errors="ignore")
    for match in LINK_RE.finditer(text):
        target = match.group(1).strip()
        if not target or target.startswith(("http://", "https://", "mailto:", "#")):
            continue
        path_text = target.split("#", 1)[0].strip()
        if not path_text:
            continue
        yield target, (md_path.parent / path_text).resolve()


def main() -> int:
    md_files = tracked_markdown_files()
    broken: list[tuple[Path, str]] = []

    for md_path in md_files:
        for target, resolved in iter_local_targets(md_path):
            if not resolved.exists():
                broken.append((md_path.relative_to(REPO_ROOT), target))

    if broken:
        print("[FAIL] Broken Markdown links detected:")
        for md_rel, target in broken:
            print(f"  {md_rel} -> {target}")
        return 1

    print(f"MARKDOWN_LINK_CHECK_PASS ({len(md_files)} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
