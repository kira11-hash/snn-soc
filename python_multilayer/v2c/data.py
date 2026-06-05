"""
V2C dataset loaders: MNIST / Fashion-MNIST / KMNIST -> flat uint8 ``[N, 784]`` + int64 labels.

All three are 28x28 grayscale, 10 classes -> the *same* 784-input V2C MLP and array mapping
(plan: 数据集 = MNIST + Fashion-MNIST + KMNIST，复用同一网络与映射；MNIST 作 sanity/对比锚点).
torchvision downloads on first use and caches under ``root`` (default: ``v2c/_data``).

Images are returned as raw uint8 in [0, 255] (row-major 28x28 flatten); the TTFS encoder
(``ttfs.encode_pixel_to_ttfs``) maps intensity -> first-spike time downstream.
"""
import os

import numpy as np

DATASETS = {"mnist": "MNIST", "fashion_mnist": "FashionMNIST", "kmnist": "KMNIST"}
_DEFAULT_ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "_data")


def load_dataset(name, train=True, root=None):
    """Load a dataset split.

    name  : one of ``DATASETS`` ("mnist" / "fashion_mnist" / "kmnist").
    train : training split if True, else test split.
    root  : cache dir (default ``v2c/_data``); downloaded once.
    returns ``(images uint8 [N, 784] in 0..255, labels int64 [N] in 0..9)``.
    """
    if name not in DATASETS:
        raise ValueError(f"unknown dataset {name!r}; use one of {sorted(DATASETS)}")
    import torchvision  # lazy: heavy import, only when actually loading

    ds_cls = getattr(torchvision.datasets, DATASETS[name])
    ds = ds_cls(root=root or _DEFAULT_ROOT, train=train, download=True)
    images = ds.data.numpy().reshape(len(ds), -1).astype(np.uint8)  # [N, 28*28]
    labels = np.asarray(ds.targets, dtype=np.int64)
    assert images.shape == (len(ds), 784), images.shape
    return images, labels
