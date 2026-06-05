"""Tests for v2c.data loaders (run in venv with torchvision; downloads MNIST test set once)."""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import numpy as np  # noqa: E402
import pytest  # noqa: E402

import data  # noqa: E402


def test_unknown_dataset_raises():
    with pytest.raises(ValueError):
        data.load_dataset("cifar10")


@pytest.mark.parametrize("name,n_test", [("mnist", 10000), ("fashion_mnist", 10000), ("kmnist", 10000)])
def test_load_real_dataset_shapes(name, n_test):
    images, labels = data.load_dataset(name, train=False)  # test split (smaller, downloads once)
    assert images.shape == (n_test, 784)
    assert images.dtype == np.uint8
    assert 0 <= int(images.min()) and int(images.max()) <= 255
    assert labels.shape == (n_test,)
    assert labels.dtype == np.int64
    assert 0 <= int(labels.min()) and int(labels.max()) <= 9
    assert images.max() > 0  # not all-zero (sanity)


def test_load_train_split_and_flatten_convention():
    images, labels = data.load_dataset("mnist", train=True)
    assert images.shape == (60000, 784) and labels.shape == (60000,)
    # lock row-major (C-order) flatten: images[0] must equal raw 28x28 reshaped row-major
    import torchvision
    ds = torchvision.datasets.MNIST(root=data._DEFAULT_ROOT, train=True, download=False)
    assert np.array_equal(images[0], ds.data[0].numpy().reshape(-1))
