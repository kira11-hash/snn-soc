"""Pack and unpack V2.B CONV feature maps.

The physical layout is frozen by ``doc/v2-architecture/conv_extension_design.md``
section 3.  Every ``(h, w, c)`` stream owns ``ceil(T / 32)`` 32-bit words, even
when ``T`` is not a multiple of 32.
"""

from __future__ import annotations

import hashlib
from pathlib import Path

import numpy as np


def stream_words_for_t(t_count: int) -> int:
    """Return ``ceil(t_count / 32)``."""
    if t_count <= 0:
        raise ValueError(f"t_count must be positive, got {t_count}")
    return (int(t_count) + 31) >> 5


def fmap_word_addr(
    h: int,
    w: int,
    c: int,
    t: int,
    *,
    width: int,
    channels: int,
    t_count: int,
    base_word: int = 0,
) -> int:
    """Compute the frozen 32-bit padded fmap word address."""
    stream_words = stream_words_for_t(t_count)
    linear_stream = ((int(h) * int(width)) + int(w)) * int(channels) + int(c)
    return int(base_word) + linear_stream * stream_words + (int(t) >> 5)


def fmap_bit_idx(t: int) -> int:
    """Return the bit index inside a 32-bit stream word."""
    return int(t) & 31


def fmap_size_words(height: int, width: int, channels: int, t_count: int) -> int:
    """Return ``H * W * C * stream_words``."""
    return int(height) * int(width) * int(channels) * stream_words_for_t(t_count)


def pack_spike_fmap(spikes: np.ndarray, base_word: int = 0) -> np.ndarray:
    """Pack ``[H, W, C, T]`` binary spikes into 32-bit words.

    The returned array is long enough to include ``base_word`` leading words,
    which mirrors the hardware address space where ``base_word`` is an offset
    into the selected fmap bank.
    """
    arr = np.asarray(spikes, dtype=np.int64)
    if arr.ndim != 4:
        raise ValueError(f"spikes must be [H, W, C, T], got shape {arr.shape}")
    if np.any((arr != 0) & (arr != 1)):
        raise ValueError("spikes must contain only 0/1 values")

    height, width, channels, t_count = (int(x) for x in arr.shape)
    words = np.zeros(int(base_word) + fmap_size_words(height, width, channels, t_count),
                     dtype=np.uint32)
    for h in range(height):
        for w in range(width):
            for c in range(channels):
                for t in range(t_count):
                    if int(arr[h, w, c, t]):
                        addr = fmap_word_addr(
                            h, w, c, t,
                            width=width,
                            channels=channels,
                            t_count=t_count,
                            base_word=base_word,
                        )
                        words[addr] = np.uint32(int(words[addr]) | (1 << fmap_bit_idx(t)))
    return words


def unpack_spike_fmap(
    words: np.ndarray,
    *,
    height: int,
    width: int,
    channels: int,
    t_count: int,
    base_word: int = 0,
) -> np.ndarray:
    """Unpack words into a ``[H, W, C, T]`` binary spike tensor."""
    word_arr = np.asarray(words, dtype=np.uint32).reshape(-1)
    required = int(base_word) + fmap_size_words(height, width, channels, t_count)
    if word_arr.shape[0] < required:
        raise ValueError(f"words has {word_arr.shape[0]} entries, need {required}")

    spikes = np.zeros((height, width, channels, t_count), dtype=np.int64)
    for h in range(height):
        for w in range(width):
            for c in range(channels):
                for t in range(t_count):
                    addr = fmap_word_addr(
                        h, w, c, t,
                        width=width,
                        channels=channels,
                        t_count=t_count,
                        base_word=base_word,
                    )
                    spikes[h, w, c, t] = (int(word_arr[addr]) >> fmap_bit_idx(t)) & 1
    return spikes


def get_fmap_bit(
    words: np.ndarray,
    *,
    h: int,
    w: int,
    c: int,
    t: int,
    width: int,
    channels: int,
    t_count: int,
    base_word: int = 0,
) -> int:
    """Read one logical spike bit from packed fmap words."""
    addr = fmap_word_addr(
        h, w, c, t,
        width=width,
        channels=channels,
        t_count=t_count,
        base_word=base_word,
    )
    return (int(np.asarray(words, dtype=np.uint32).reshape(-1)[addr]) >> fmap_bit_idx(t)) & 1


def set_fmap_bit(
    words: np.ndarray,
    *,
    h: int,
    w: int,
    c: int,
    t: int,
    value: int,
    width: int,
    channels: int,
    t_count: int,
    base_word: int = 0,
) -> None:
    """Write one logical spike bit into packed fmap words."""
    addr = fmap_word_addr(
        h, w, c, t,
        width=width,
        channels=channels,
        t_count=t_count,
        base_word=base_word,
    )
    bit = 1 << fmap_bit_idx(t)
    if int(value):
        words[addr] = np.uint32(int(words[addr]) | bit)
    else:
        words[addr] = np.uint32(int(words[addr]) & ~bit)


def write_hex_words(words: np.ndarray, path: str | Path) -> str:
    """Write one 32-bit lowercase hex word per line and return SHA-256."""
    out_path = Path(path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", encoding="ascii", newline="\n") as f:
        for word in np.asarray(words, dtype=np.uint32).reshape(-1):
            f.write(f"{int(word) & 0xffffffff:08x}\n")
    return sha256_file(out_path)


def read_hex_words(path: str | Path) -> np.ndarray:
    """Read one 32-bit hex word per line."""
    values: list[int] = []
    with Path(path).open("r", encoding="ascii") as f:
        for line in f:
            text = line.strip()
            if not text or text.startswith("#"):
                continue
            values.append(int(text, 16) & 0xffffffff)
    return np.asarray(values, dtype=np.uint32)


def sha256_file(path: str | Path) -> str:
    """Return the SHA-256 digest for a file."""
    digest = hashlib.sha256()
    with Path(path).open("rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def test_roundtrip() -> None:
    """Self-check used by the M1 gate."""
    rng = np.random.default_rng(0x2B)
    shapes = [
        (1, 1, 1, 1),
        (3, 5, 2, 10),
        (2, 4, 3, 31),
        (2, 4, 3, 32),
        (4, 3, 5, 33),
        (3, 3, 4, 64),
    ]
    for shape in shapes:
        spikes = rng.integers(0, 2, size=shape, dtype=np.int64)
        words = pack_spike_fmap(spikes)
        unpacked = unpack_spike_fmap(
            words,
            height=shape[0],
            width=shape[1],
            channels=shape[2],
            t_count=shape[3],
        )
        if not np.array_equal(spikes, unpacked):
            raise AssertionError(f"pack/unpack mismatch for shape {shape}")
    print("PACK_FMAP_WORDS_ROUNDTRIP_PASS")


if __name__ == "__main__":
    test_roundtrip()
