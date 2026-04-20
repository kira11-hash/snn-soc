"""Vendored from V1 ``data_utils.py`` at 2026-04-19.

ONLY the functions V2 needs:
    * ``downsample_batch`` — MNIST 28×28 → 8×8 (avgpool), bit-identical
    * ``load_mnist_test`` — torchvision MNIST test split loader (new helper
      specific to V2; V1's ``prepare_all_datasets`` depends on V1 config and
      cannot be reused verbatim)

DO NOT EDIT. Must stay bit-identical to V1 for A1.2 parity.
Source: d:/SoC Design/SoC Design/项目相关文件/器件对齐/Python建模/data_utils.py
"""

from __future__ import annotations

import torch
import torch.nn.functional as F
from torchvision import datasets


def downsample_batch(
    images_28x28: torch.Tensor, target_size: int, method: str
) -> torch.Tensor:
    """Downsample a batch of 28×28 MNIST images.

    Args:
        images_28x28: Tensor of shape ``[N, 28, 28]``, values in ``[0, 255]``.
        target_size:  Target height/width (e.g., 8 for 64-dim input).
        method:       One of ``bilinear / nearest / avgpool / maxpool /
                      pad32_zero / pad32_replicate / pad32_reflect``.

    Returns:
        Tensor of shape ``[N, target_size * target_size]``, uint8,
        values in ``[0, 255]``.

    Implementation is an exact copy of V1 ``downsample_batch``; the quantize-
    clamp-round-byte pipeline is preserved verbatim for bit-parity with V1.
    """
    N = images_28x28.shape[0]
    # [N, 28, 28] -> [N, 1, 28, 28] (add channel dim, cast to float)
    x = images_28x28.float().unsqueeze(1)

    if method == "bilinear":
        out = F.interpolate(
            x, size=(target_size, target_size), mode="bilinear", align_corners=False
        )
    elif method == "nearest":
        out = F.interpolate(x, size=(target_size, target_size), mode="nearest")
    elif method == "avgpool":
        out = F.adaptive_avg_pool2d(x, (target_size, target_size))
    elif method == "maxpool":
        out = F.adaptive_max_pool2d(x, (target_size, target_size))
    elif method == "pad32_zero":
        padded = F.pad(x, (2, 2, 2, 2), mode="constant", value=0)
        out = F.avg_pool2d(padded, kernel_size=4, stride=4)
    elif method == "pad32_replicate":
        padded = F.pad(x, (2, 2, 2, 2), mode="replicate")
        out = F.avg_pool2d(padded, kernel_size=4, stride=4)
    elif method == "pad32_reflect":
        padded = F.pad(x, (2, 2, 2, 2), mode="reflect")
        out = F.avg_pool2d(padded, kernel_size=4, stride=4)
    else:
        raise ValueError(f"Unknown downsample method: {method}")

    out = out.squeeze(1)                            # [N, size, size]
    out = torch.clamp(out, 0, 255).round().byte()   # uint8
    return out.reshape(N, -1)                       # [N, size*size]


def load_mnist_test(
    data_dir: str, target_size: int = 8, method: str = "avgpool"
) -> tuple[torch.Tensor, torch.Tensor]:
    """Load MNIST test split and downsample.

    Args:
        data_dir:    MNIST download directory (created if missing).
        target_size: Output spatial size (default 8 -> 64-dim).
        method:      Downsample method passed to ``downsample_batch``.

    Returns:
        ``(images_uint8, labels)`` — images shape ``[10000, 64]`` uint8,
        labels shape ``[10000]`` int64.
    """
    test_mnist = datasets.MNIST(data_dir, train=False, download=True)
    images_28 = test_mnist.data            # [10000, 28, 28] uint8
    labels = test_mnist.targets            # [10000]
    images_flat = downsample_batch(images_28, target_size, method)
    return images_flat, labels


def load_mnist_train(
    data_dir: str, target_size: int = 8, method: str = "avgpool"
) -> tuple[torch.Tensor, torch.Tensor]:
    """Load MNIST training split and downsample."""
    train_mnist = datasets.MNIST(data_dir, train=True, download=True)
    images_28 = train_mnist.data
    labels = train_mnist.targets
    images_flat = downsample_batch(images_28, target_size, method)
    return images_flat, labels


def load_fashion_mnist_test(
    data_dir: str, target_size: int = 8, method: str = "avgpool"
) -> tuple[torch.Tensor, torch.Tensor]:
    """Fashion-MNIST test split, avgpool-downsampled to 8x8 for V2 pipeline."""
    ds = datasets.FashionMNIST(data_dir, train=False, download=True)
    images_flat = downsample_batch(ds.data, target_size, method)
    return images_flat, ds.targets


def load_fashion_mnist_train(
    data_dir: str, target_size: int = 8, method: str = "avgpool"
) -> tuple[torch.Tensor, torch.Tensor]:
    """Fashion-MNIST training split, avgpool-downsampled for V2 pipeline."""
    ds = datasets.FashionMNIST(data_dir, train=True, download=True)
    images_flat = downsample_batch(ds.data, target_size, method)
    return images_flat, ds.targets
