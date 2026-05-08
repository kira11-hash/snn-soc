"""Generate the Config #5 Fashion 28x28 FC golden bundle for M4 manifests."""

from __future__ import annotations

import sys
from pathlib import Path

from gen_multilayer_bundle import generate_bundle


ROOT = Path(__file__).resolve().parent


def main() -> int:
    return generate_bundle(
        topo_name="784_64_10",
        model_path=ROOT / "results_multilayer" / "784_64_10" / "model.pt",
        out_dir=ROOT / "results_multilayer" / "fashion28_multilayer_golden",
        dataset="fashion_mnist",
        target_size=28,
        timesteps=64,
        num_samples=10,
    )


if __name__ == "__main__":
    sys.exit(main())
