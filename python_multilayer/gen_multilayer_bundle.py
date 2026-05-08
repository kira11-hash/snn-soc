"""Generate per-config FC golden bundles for paper manifests.

This helper generalizes the original Fashion-14x14 bundle flow to other
paper-facing FC configurations whose sample bundles are used by M4 manifests.
It emits:

- ``sample_XX_wl_stream.hex``   stage-0 encoded WL stream
- ``sample_XX_counts.txt``      final per-class spike counts
- ``sample_XX_predicted.txt``   argmax class
- ``sample_XX_label.txt``       ground-truth label
- ``meta.txt``                  topology / dataset / selection provenance
"""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import torch

ROOT = Path(__file__).resolve().parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import _vendored_from_v1.data_utils as v1_data  # noqa: E402
import config_multilayer as cfg  # noqa: E402
from exporter_multilayer import _get_device_levels_for_export, _quantize_stage_weights  # noqa: E402
from snn_engine_multilayer import _run_stage_streamed_rate, encode_pixel_to_spike_stream  # noqa: E402
from topologies import get_topology_by_name, load_topology_file  # noqa: E402


@dataclass
class FakeStage:
    in_dim: int
    out_dim: int
    threshold: int


def dump_wl_stream_hex(path: Path, wl_stream: np.ndarray, pad_width: int) -> None:
    """Write a [T, in_dim] binary WL stream as one packed hex word per line."""
    timesteps, in_dim = wl_stream.shape
    assert pad_width >= in_dim
    hex_chars = (pad_width + 3) // 4
    with path.open("w", encoding="utf-8") as f:
        for t in range(timesteps):
            value = 0
            for i in range(in_dim):
                if wl_stream[t, i]:
                    value |= (1 << i)
            f.write(f"{value:0{hex_chars}x}\n")


def dump_weight_hex(path: Path, weights: np.ndarray) -> None:
    """Write an [in_dim, out_dim] 4-bit matrix as one nibble per line."""
    in_dim, out_dim = weights.shape
    with path.open("w", encoding="utf-8") as f:
        for i in range(in_dim):
            for j in range(out_dim):
                f.write(f"{int(weights[i, j]):01x}\n")


def _load_dataset(dataset: str, target_size: int) -> tuple[np.ndarray, np.ndarray]:
    data_dir = str(cfg.ROOT_DIR / "data")
    if dataset == "mnist":
        images, labels = v1_data.load_mnist_test(data_dir, target_size=target_size, method="avgpool")
    elif dataset == "fashion_mnist":
        images, labels = v1_data.load_fashion_mnist_test(data_dir, target_size=target_size, method="avgpool")
    else:
        raise ValueError(f"unsupported dataset={dataset!r}")

    images_np = images.numpy().astype(np.int64) if hasattr(images, "numpy") else np.asarray(images).astype(np.int64)
    if images_np.ndim == 3:
        images_np = images_np.reshape(-1, target_size * target_size)
    labels_np = labels.numpy() if hasattr(labels, "numpy") else np.asarray(labels)
    return images_np, labels_np


def _select_class_first_indices(labels: np.ndarray, num_samples: int) -> list[int]:
    chosen: list[int] = []
    for cls in range(10):
        hits = np.where(labels == cls)[0]
        if len(hits) == 0:
            raise RuntimeError(f"no sample found for class {cls}")
        chosen.append(int(hits[0]))
    return chosen[:num_samples]


def _load_state_dict(model_path: Path) -> dict[str, torch.Tensor]:
    state = torch.load(model_path, map_location="cpu", weights_only=False)
    if isinstance(state, dict) and "state_dict" in state:
        return state["state_dict"]
    return state


def _quantized_stage_weights(topo_name: str, model_path: Path) -> tuple[list[FakeStage], list[tuple[np.ndarray, np.ndarray]], int]:
    topo_file = load_topology_file(ROOT / "topologies.yaml")
    topo = get_topology_by_name(topo_file.topologies, topo_name)
    if topo.input_encoding != "streamed_rate":
        raise ValueError(f"{topo_name} is not a streamed_rate topology")

    state_dict = _load_state_dict(model_path)
    levels = _get_device_levels_for_export(2 ** cfg.QAT_WEIGHT_BITS)
    fake_stages: list[FakeStage] = []
    stage_weights: list[tuple[np.ndarray, np.ndarray]] = []
    for i, stage in enumerate(topo.stages):
        key = f"layers.{i}.weight"
        if key not in state_dict:
            raise KeyError(f"missing key {key!r} in {model_path}")
        w_pos, w_neg = _quantize_stage_weights(state_dict[key], cfg.QAT_WEIGHT_BITS, levels)
        fake_stages.append(FakeStage(int(stage.in_dim), int(stage.out_dim), int(stage.threshold)))
        stage_weights.append((w_pos, w_neg))
    return fake_stages, stage_weights, int(topo.adc_bits)


def _sum_max_for(stage_idx: int, topo_name: str, stages: list[FakeStage]) -> int:
    if topo_name in ("196_64_10", "mnist_196_64_10", "784_64_10") and stage_idx == 1:
        return 960
    return int(stages[stage_idx].in_dim) * 15


def _run_pipeline(
    pixel: np.ndarray,
    *,
    topo_name: str,
    stages: list[FakeStage],
    stage_weights: list[tuple[np.ndarray, np.ndarray]],
    timesteps: int,
    adc_bits: int,
) -> tuple[np.ndarray, np.ndarray, int]:
    wl_stream = encode_pixel_to_spike_stream(pixel, timesteps, method="even_rate")
    stage_input = wl_stream
    final_counts: np.ndarray | None = None
    for idx, (stage, (w_pos, w_neg)) in enumerate(zip(stages, stage_weights)):
        counts, _, spike_stream = _run_stage_streamed_rate(
            stage,
            stage_input,
            w_pos,
            w_neg,
            sum_max=_sum_max_for(idx, topo_name, stages),
            adc_bits=adc_bits,
        )
        final_counts = counts
        stage_input = spike_stream
    assert final_counts is not None
    predicted = int(final_counts.argmax())
    return wl_stream, final_counts, predicted


def generate_bundle(
    *,
    topo_name: str,
    model_path: Path,
    out_dir: Path,
    dataset: str,
    target_size: int,
    timesteps: int,
    num_samples: int = 10,
) -> int:
    out_dir.mkdir(parents=True, exist_ok=True)
    images, labels = _load_dataset(dataset, target_size)
    chosen_idx = _select_class_first_indices(labels, num_samples)
    stages, stage_weights, adc_bits = _quantized_stage_weights(topo_name, model_path)
    pad_width = ((int(stages[0].in_dim) + 255) // 256) * 256

    for idx, (w_pos, w_neg) in enumerate(stage_weights):
        dump_weight_hex(out_dir / f"stage{idx}_w_pos.hex", w_pos)
        dump_weight_hex(out_dir / f"stage{idx}_w_neg.hex", w_neg)

    for sample_no, idx in enumerate(chosen_idx):
        wl_stream, counts, predicted = _run_pipeline(
            images[idx],
            topo_name=topo_name,
            stages=stages,
            stage_weights=stage_weights,
            timesteps=timesteps,
            adc_bits=adc_bits,
        )
        tag = f"sample_{sample_no:02d}"
        dump_wl_stream_hex(out_dir / f"{tag}_wl_stream.hex", wl_stream, pad_width=pad_width)
        with (out_dir / f"{tag}_counts.txt").open("w", encoding="utf-8") as f:
            for value in counts:
                f.write(f"{int(value)}\n")
        (out_dir / f"{tag}_predicted.txt").write_text(f"{predicted}\n", encoding="utf-8")
        (out_dir / f"{tag}_label.txt").write_text(f"{int(labels[idx])}\n", encoding="utf-8")
        print(f"[sample {sample_no}] idx={idx} label={int(labels[idx])} pred={predicted} counts={counts.tolist()}")

    (out_dir / "meta.txt").write_text(
        "\n".join(
            [
                f"topology {topo_name}",
                f"dataset {dataset}",
                f"target_size {target_size}",
                f"timesteps {timesteps}",
                f"adc_bits {adc_bits}",
                f"pad_width {pad_width}",
                f"num_samples {num_samples}",
                "selection_rule class-first one-per-class",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    print(f"[done] wrote {out_dir}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--topology", required=True)
    parser.add_argument("--model-path", required=True)
    parser.add_argument("--out-dir", required=True)
    parser.add_argument("--dataset", required=True, choices=("mnist", "fashion_mnist"))
    parser.add_argument("--target-size", required=True, type=int)
    parser.add_argument("--timesteps", default=64, type=int)
    parser.add_argument("--num-samples", default=10, type=int)
    args = parser.parse_args(argv)
    return generate_bundle(
        topo_name=args.topology,
        model_path=Path(args.model_path),
        out_dir=Path(args.out_dir),
        dataset=args.dataset,
        target_size=args.target_size,
        timesteps=args.timesteps,
        num_samples=args.num_samples,
    )


if __name__ == "__main__":
    raise SystemExit(main())
