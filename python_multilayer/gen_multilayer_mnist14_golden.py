"""Generate the Config #3 MNIST 14x14 FC golden bundle for M4 manifests."""

from __future__ import annotations

import sys
from pathlib import Path

from gen_multilayer_bundle import generate_bundle


ROOT = Path(__file__).resolve().parent


def main() -> int:
    return generate_bundle(
        topo_name="mnist_196_64_10",
        model_path=ROOT / "results_multilayer" / "196_64_10__mnist14" / "model.pt",
        out_dir=ROOT / "results_multilayer" / "mnist14_multilayer_golden",
        dataset="mnist",
        target_size=14,
        timesteps=64,
        num_samples=10,
    )


if __name__ == "__main__":
    sys.exit(main())
