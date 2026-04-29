"""Generate M1 synthetic CONV golden bundles.

The files emitted here are consumed by M3 RTL/TB work.  They intentionally do
not use PyTorch float CONV as golden; all outputs come from ``snn_engine_conv``.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

from exporter_conv import make_weight_tiles_from_kernel, write_weight_tiles_split_hex
from pack_fmap_words import pack_spike_fmap, sha256_file, write_hex_words
from snn_engine_conv import (
    ERR_CODES,
    ConvConfigError,
    PartialSumOverflowError,
    encode_image_to_spike_fmap,
    run_conv_layer,
    validate_conv_cfg,
)
from synthetic_conv_cases import SYNTHETIC_CASES, SyntheticConvCase, get_case


def _write_json(path: Path, data: dict) -> str:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="ascii")
    return sha256_file(path)


def _write_output_counts(path: Path, counts: np.ndarray | None, *, err_name: str) -> str:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="ascii", newline="\n") as f:
        if counts is None:
            f.write(f"# illegal config: {err_name}; no output fmap generated\n")
        else:
            h_out, w_out, c_out = counts.shape
            for h in range(h_out):
                for w in range(w_out):
                    for c in range(c_out):
                        f.write(f"{h} {w} {c} {int(counts[h, w, c])}\n")
    return sha256_file(path)


def _make_input_spikes(case: SyntheticConvCase) -> np.ndarray:
    rng = np.random.default_rng(case.seed)
    pixels = rng.integers(0, 256, size=(case.H, case.W, case.C_in), dtype=np.int64)
    return encode_image_to_spike_fmap(pixels, case.T)


def _make_kernel(case: SyntheticConvCase) -> np.ndarray:
    rng = np.random.default_rng(case.seed + 0x500)
    kernel = rng.integers(
        -7, 8,
        size=(case.K, case.K, case.C_in, case.C_out),
        dtype=np.int64,
    )
    # Keep lane/tile ordering visible in traces and harder to accidentally pass
    # with a transposed exporter.
    for ky in range(case.K):
        for kx in range(case.K):
            for c in range(case.C_in):
                conv_idx = (ky * case.K + kx) * case.C_in + c
                tile_idx = conv_idx // 256
                kernel[ky, kx, c, :] = np.clip(
                    kernel[ky, kx, c, :] + ((tile_idx % 3) - 1),
                    -7,
                    7,
                )
    return kernel.astype(np.int64)


def _case_cfg_expected(case: SyntheticConvCase) -> dict:
    cfg = case.cfg_dict(include_tile_cfg=True)
    ok, err_name = validate_conv_cfg(cfg)
    err_code = ERR_CODES[err_name]
    if err_code != case.expected_err_code:
        raise AssertionError(
            f"{case.name}: validator returned {err_name}/{err_code}, "
            f"expected {case.expected_err_name}/{case.expected_err_code}"
        )
    expected = case.manifest_dict()
    expected.update(cfg)
    expected.update({
        "validator_ok": ok,
        "validator_err_name": err_name,
        "validator_err_code": err_code,
        "expected_err_code": case.expected_err_code,
        "expected_err_name": case.expected_err_name,
    })
    return expected


def generate_case(case: SyntheticConvCase, out_dir: Path) -> dict:
    """Generate one synthetic case and return its manifest entry."""
    prefix = f"synthetic_{case.name}"
    cfg_expected = _case_cfg_expected(case)

    input_spikes = _make_input_spikes(case)
    input_words = pack_spike_fmap(input_spikes)
    input_path = out_dir / f"{prefix}_input_fmap_words.hex"
    input_sha = write_hex_words(input_words, input_path)

    kernel = _make_kernel(case)
    weight_tiles = make_weight_tiles_from_kernel(kernel)
    weight_records = write_weight_tiles_split_hex(
        weight_tiles,
        out_dir,
        case_id=case.name,
        layer_id="L0",
    )
    weight_tiles_manifest = []
    for record in weight_records:
        pos_path = Path(record["pos"])
        neg_path = Path(record["neg"])
        weight_tiles_manifest.append({
            "tile_idx": int(record["tile_idx"]),
            "pos": pos_path.name,
            "neg": neg_path.name,
            "sha256_pos": sha256_file(pos_path),
            "sha256_neg": sha256_file(neg_path),
        })

    cfg_path = out_dir / f"{prefix}_cfg_expected.json"
    cfg_sha = _write_json(cfg_path, cfg_expected)

    counts_path = out_dir / f"{prefix}_output_counts.txt"
    trace_path = out_dir / f"{prefix}_trace.json"

    ok, err_name = validate_conv_cfg(cfg_expected)
    output_sha = ""
    trace_sha = ""
    trace: dict = {}
    if ok:
        try:
            result = run_conv_layer(
                input_words,
                cfg_expected,
                weight_tiles,
                collect_trace=(case.name == "C1"),
            )
        except PartialSumOverflowError:
            raise
        except ConvConfigError as exc:  # pragma: no cover - defensive.
            raise AssertionError(f"{case.name}: unexpected ConvConfigError {exc}") from exc
        output_sha = _write_output_counts(counts_path, result.output_counts, err_name=err_name)
        if case.name == "C1":
            trace = result.trace
            trace.update({
                "case": case.name,
                "notes": "patch0_words_hex lists eight 32-bit words covering dyn_wl_resp_data[255:0]",
            })
            trace_sha = _write_json(trace_path, trace)
    else:
        output_sha = _write_output_counts(counts_path, None, err_name=err_name)
        if trace_path.exists():
            trace_path.unlink()

    return {
        "case": case.name,
        "K": case.K,
        "stride": case.stride,
        "pad": case.pad,
        "C_in": case.C_in,
        "C_out": case.C_out,
        "H": case.H,
        "W": case.W,
        "T": case.T,
        "out_H": cfg_expected["out_H"],
        "out_W": cfg_expected["out_W"],
        "tile_count": cfg_expected["tile_count"] if ok else None,
        "generated_tile_count": case.tile_count(),
        "last_tile_valid_count": cfg_expected["last_tile_valid_count"] if ok else None,
        "generated_last_tile_valid_count": case.last_tile_valid_count(),
        "expected_err_code": case.expected_err_code,
        "expected_err_name": case.expected_err_name,
        "validator_err_code": ERR_CODES[err_name],
        "validator_err_name": err_name,
        "files": {
            "input_fmap_words": input_path.name,
            "cfg_expected": cfg_path.name,
            "output_counts": counts_path.name,
            "trace": trace_path.name if trace_sha else None,
            "weight_tiles": weight_tiles_manifest,
        },
        "sha256": {
            "input_fmap_words": input_sha,
            "cfg_expected": cfg_sha,
            "output_counts": output_sha,
            "trace": trace_sha or None,
        },
        "trace_preview": trace if case.name == "C1" else None,
    }


def build_manifest(case_entries: list[dict]) -> dict:
    return {
        "schema_version": "v2b-conv-synthetic-golden-m1",
        "generator": "python_multilayer/gen_synthetic_conv_golden.py",
        "layout": "32-bit padded stream: word_addr=base+((h*W+w)*C+c)*ceil(T/32)+(t>>5)",
        "weight_layout": "weight_tile[tile_idx][lane][out_c], split unsigned pos/neg hex, each value in [0, 7]",
        "err_codes": ERR_CODES,
        "cases": case_entries,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--all", action="store_true", help="generate all synthetic cases")
    parser.add_argument("--case", action="append", default=[], help="case name, e.g. C1")
    parser.add_argument("--out-dir", default=".", help="output directory")
    args = parser.parse_args(argv)

    if args.all:
        selected = list(SYNTHETIC_CASES)
    elif args.case:
        selected = [get_case(name) for name in args.case]
    else:
        selected = [get_case("C1")]

    out_dir = Path(args.out_dir)
    entries = [generate_case(case, out_dir) for case in selected]
    manifest = build_manifest(entries)
    manifest_path = out_dir / "synthetic_golden_manifest.json"
    _write_json(manifest_path, manifest)
    print(f"SYNTHETIC_CONV_GOLDEN_PASS cases={len(entries)} manifest={manifest_path}")
    print(f"manifest_sha256={sha256_file(manifest_path)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
