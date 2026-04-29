"""Synthetic V2.B CONV golden case definitions."""

from __future__ import annotations

from dataclasses import asdict, dataclass


@dataclass(frozen=True)
class SyntheticConvCase:
    name: str
    K: int
    stride: int
    pad: int
    C_in: int
    C_out: int
    H: int
    W: int
    T: int
    expected_err_code: int = 0
    expected_err_name: str = "OK"
    threshold: int | None = None
    seed: int = 1

    def out_hw(self) -> tuple[int, int]:
        out_h = ((self.H + 2 * self.pad - self.K) // self.stride) + 1
        out_w = ((self.W + 2 * self.pad - self.K) // self.stride) + 1
        return out_h, out_w

    def kkc(self) -> int:
        return self.K * self.K * self.C_in

    def tile_count(self) -> int:
        return (self.kkc() + 255) // 256

    def last_tile_valid_count(self) -> int:
        return self.kkc() - 256 * (self.tile_count() - 1)

    def stream_words(self) -> int:
        return (self.T + 31) >> 5

    def default_threshold(self) -> int:
        if self.threshold is not None:
            return int(self.threshold)
        # Synthetic-only thresholds are intentionally modest so traces contain
        # useful spike activity without hiding partial-sum behavior.
        return max(4, min(96, self.kkc() // 6))

    def cfg_dict(self, *, include_tile_cfg: bool = True) -> dict:
        out_h, out_w = self.out_hw()
        cfg = {
            "name": self.name,
            "K": self.K,
            "stride": self.stride,
            "pad": self.pad,
            "C_in": self.C_in,
            "C_out": self.C_out,
            "H": self.H,
            "W": self.W,
            "out_H": out_h,
            "out_W": out_w,
            "T": self.T,
            "threshold": self.default_threshold(),
            "base_word": 0,
            "out_base_word": 0,
            "expected_err_code": self.expected_err_code,
            "expected_err_name": self.expected_err_name,
        }
        if include_tile_cfg:
            cfg["tile_count"] = self.tile_count()
            cfg["last_tile_valid_count"] = self.last_tile_valid_count()
        return cfg

    def manifest_dict(self) -> dict:
        data = asdict(self)
        out_h, out_w = self.out_hw()
        data.update({
            "out_H": out_h,
            "out_W": out_w,
            "KKC": self.kkc(),
            "tile_count": self.tile_count() if self.expected_err_code == 0 else None,
            "generated_tile_count": self.tile_count(),
            "last_tile_valid_count": (
                self.last_tile_valid_count() if self.expected_err_code == 0 else None
            ),
            "generated_last_tile_valid_count": self.last_tile_valid_count(),
            "stream_words": self.stream_words(),
            "threshold": self.default_threshold(),
        })
        return data


SYNTHETIC_CASES: tuple[SyntheticConvCase, ...] = (
    SyntheticConvCase("C1", K=3, stride=1, pad=1, C_in=4, C_out=8, H=8, W=8,
                      T=10, seed=101, threshold=4),
    SyntheticConvCase("C2", K=3, stride=2, pad=1, C_in=16, C_out=16, H=16, W=16,
                      T=32, seed=102, threshold=12),
    SyntheticConvCase("C3", K=5, stride=1, pad=2, C_in=6, C_out=16, H=14, W=14,
                      T=10, seed=103, threshold=18),
    SyntheticConvCase("C4", K=3, stride=1, pad=1, C_in=32, C_out=32, H=8, W=8,
                      T=64, seed=104, threshold=48),
    SyntheticConvCase("C5", K=3, stride=1, pad=1, C_in=64, C_out=64, H=8, W=8,
                      T=64, seed=105, threshold=80),
    SyntheticConvCase("C6", K=3, stride=1, pad=1, C_in=128, C_out=32, H=4, W=4,
                      T=64, seed=106, threshold=96),
    SyntheticConvCase("C7", K=3, stride=1, pad=0, C_in=8, C_out=16, H=5, W=5,
                      T=16, seed=107, threshold=10),
    SyntheticConvCase("C8", K=3, stride=1, pad=1, C_in=8, C_out=16, H=33, W=33,
                      T=33, seed=108, threshold=10),
    SyntheticConvCase("C9", K=5, stride=1, pad=0, C_in=128, C_out=16, H=8, W=8,
                      T=10, seed=109, expected_err_code=1,
                      expected_err_name="ERR_ILLEGAL_KKC"),
    SyntheticConvCase("C10", K=3, stride=1, pad=0, C_in=16, C_out=16, H=65, W=65,
                      T=10, seed=110, expected_err_code=3,
                      expected_err_name="ERR_BAD_GEOMETRY"),
)


def get_case(name: str) -> SyntheticConvCase:
    for case in SYNTHETIC_CASES:
        if case.name.lower() == name.lower():
            return case
    raise KeyError(f"unknown synthetic CONV case {name!r}")
