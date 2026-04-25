# F4 — CLAUDE.md pad-count consistency PR suggestion (USER DECIDE)

**Status**: NOT applied. User-side decision required because the
target file is the **global** `CLAUDE.md`, not the in-repo one.

## Background

Original F4 finding (against main @ d75be55c):

> `CLAUDE.md` 写 "55 总 = 52 usable signal + 6 power/ground + 3
> ESD-reserved"（合计 61，自相矛盾）。`doc/15` 才是正确口径："55 总
> = 52 usable + 3 ESD-reserved；52 usable = 46 signal + 6 power"。

The user's red-line on this fix:

> F4 是修 ~/.claude 全局 CLAUDE.md，不在仓库内（需要 user 同意）
> → 把 F4 改成"在仓库内 doc/15 里加一行 cross-reference"，把 CLAUDE.md
> 改动写成 PR 建议交给 user 决定

## On the arm branch the in-repo cross-reference half is also a no-op

Verification:

```bash
git -C v2-arm-fpga-demo-passed grep -nE "总 pad|52 usable|46 signal|44 signal|72 pad" CLAUDE.md
# 0 命中
```

Arm tag's `CLAUDE.md` has no pad-related statement, so adding a
cross-reference in `doc/15_asic_pad_map.md` pointing back to
`CLAUDE.md` would point at nothing. Doing it anyway would:

1. Encode an arm-specific assumption that `CLAUDE.md` is supposed
   to talk about pads (it currently does not on this branch).
2. Drift further from the actual behavior of the global `CLAUDE.md`,
   which is what the original F4 was complaining about.

So: on arm, the in-repo half of F4 is **N/A**. See
`audit_2026_main_findings_applicability.md` §F4 for that part.

## What we suggest the user do (out-of-tree)

Below is the recommended fix to the **global**
`~/.claude/CLAUDE.md` (or whichever per-user CLAUDE.md the user
keeps). User can paste the diff as a PR description if they version
that file; otherwise just edit by hand.

### Current (incorrect)

```markdown
- **总 pad 数：55**（之前 48，2026-04-24 扩 +7 给外部编程接口）
  - 52 usable signal + 6 power/ground + 3 ESD-reserved
```

### Suggested (math now closes)

```markdown
- **总 pad 数：55**（之前 48，2026-04-24 扩 +7 给外部编程接口）
  - 46 signal + 6 power/ground + 3 ESD-reserved = 55 total
  - 等价拆分：52 usable (= 46 signal + 6 power) + 3 ESD-reserved
  - Source of truth: `doc/15_asic_pad_map.md` §"Counting rule"
```

### Verification

```bash
$ python3 -c "print(46 + 6 + 3)"
55
$ python3 -c "print(52 + 3, 'and', 46 + 6 + 3)"   # both 55
55 and 55
```

Diff against `doc/15_asic_pad_map.md` §"Counting rule" (should
match):

```bash
git grep -nE "55 pads total|52 usable pads|46 functional signal|3 .ESD-reserved" \
    doc/15_asic_pad_map.md
```

## Why this PR-suggestion lives in the arm branch

The user is fanning the same audit pass across `main`,
`v2-fpga-e203-passed`, and `v2-arm-fpga-demo-passed`. The CLAUDE.md
correction is a one-time edit shared by all three. Recording the
suggestion here gives the user one place to ack it once and apply
manually; it is **not** a branch-local fix and should not be
cherry-picked between fix branches.

## Frozen artifact impact

None. `CLAUDE.md` is a documentation/preferences file outside the
ASIC build path; bitstream / ELF SHA256 are insensitive to it.
Marking this PR-suggestion as **NO RE-BURN** by definition.
