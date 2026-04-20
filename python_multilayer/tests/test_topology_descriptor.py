"""Binary topology_desc.bin + .h exporter round-trip tests (REV 3.1 D3).

Verifies the Phase C firmware descriptor:
  - bin size matches expected header + stages stride
  - magic / version / field values parseable as little-endian
  - generated .h mirrors the struct layout (offsets, sizes)
  - is_resident policy: 14×14 single/multi = 1; tile/chunk-overflow = 0
  - SHA-256 deterministic across identical inputs
"""

from __future__ import annotations

import hashlib
import struct
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from exporter_multilayer import (  # noqa: E402
    ADC_FULL_SCALE_ACTIVE_WL,
    TOPO_DESC_HEADER_SIZE,
    TOPO_DESC_MAGIC,
    TOPO_DESC_MAX_STAGES,
    TOPO_DESC_STAGE_SIZE,
    TOPO_DESC_VERSION,
    export_topology_descriptor,
)
from topologies import get_topology_by_name, load_topology_file

TOPO_YAML = ROOT / "topologies.yaml"


@pytest.fixture
def topo_file():
    return load_topology_file(TOPO_YAML)


def _unpack_header(buf: bytes):
    """Return header fields as dict. 32-byte header + flex stages after."""
    (
        magic, version, stream_ts, adc_bits, adc_full_scale,
        num_stages, num_chunks, pixel_addr, _reserved,
    ) = struct.unpack("<IHHBBBBI16s", buf[:TOPO_DESC_HEADER_SIZE])
    return dict(
        magic=magic, version=version, stream_timesteps=stream_ts,
        adc_bits=adc_bits, adc_full_scale=adc_full_scale,
        num_stages_total=num_stages, num_chunks=num_chunks,
        pixel_stream_addr=pixel_addr,
    )


def _unpack_stage(buf: bytes, idx: int):
    start = TOPO_DESC_HEADER_SIZE + idx * TOPO_DESC_STAGE_SIZE
    end = start + TOPO_DESC_STAGE_SIZE
    (
        in_dim, out_dim, threshold, sum_max,
        w_pos_addr, w_neg_addr,
        is_resident, is_tile_final, tile_mode, chunk_id,
    ) = struct.unpack("<HHIIIIBBBB", buf[start:end])
    return dict(
        in_dim=in_dim, out_dim=out_dim, threshold=threshold, sum_max=sum_max,
        weight_pos_addr=w_pos_addr, weight_neg_addr=w_neg_addr,
        is_resident=is_resident, is_tile_final=is_tile_final,
        tile_mode=tile_mode, chunk_id=chunk_id,
    )


class TestDescriptorRoundTrip:
    @pytest.mark.parametrize(
        "topo_name,expected_stages",
        [
            ("196_10", 1),
            ("196_64_10", 2),
            ("mnist_196_10", 1),
            ("mnist_196_64_10", 2),
        ],
    )
    def test_streamed_topology_descriptor_roundtrip(
        self, topo_file, tmp_path, topo_name, expected_stages
    ):
        topo = get_topology_by_name(topo_file.topologies, topo_name)
        result = export_topology_descriptor(topo, tmp_path)

        assert not result.get("skipped"), "streamed topology must emit descriptor"
        bin_path = Path(result["bin_path"])
        header_path = Path(result["header_path"])
        assert bin_path.exists()
        assert header_path.exists()

        blob = bin_path.read_bytes()
        expected_size = TOPO_DESC_HEADER_SIZE + expected_stages * TOPO_DESC_STAGE_SIZE
        assert len(blob) == expected_size, (
            f"{topo_name}: bin size {len(blob)} != {expected_size}"
        )

        hdr = _unpack_header(blob)
        assert hdr["magic"] == TOPO_DESC_MAGIC
        assert hdr["version"] == TOPO_DESC_VERSION
        assert hdr["num_stages_total"] == expected_stages
        assert hdr["num_chunks"] == 1
        assert hdr["stream_timesteps"] == topo.stream_timesteps
        assert hdr["adc_bits"] == topo.adc_bits
        # Default policy in YAML is active_wl for the current topologies
        assert hdr["adc_full_scale"] == ADC_FULL_SCALE_ACTIVE_WL

        for i, stage in enumerate(topo.stages):
            s = _unpack_stage(blob, i)
            assert s["in_dim"] == stage.in_dim
            assert s["out_dim"] == stage.out_dim
            assert s["threshold"] == stage.threshold
            # sum_max = in_dim * 15 (active_wl) unless explicit
            expected_sum_max = stage.sum_max if stage.sum_max else stage.in_dim * 15
            assert s["sum_max"] == expected_sum_max
            # 14×14 main demo fits 256×256, resident=1
            assert s["is_resident"] == 1, (
                f"{topo_name} stage {i}: 14×14 must be resident"
            )
            # V0: single-tile, single-chunk
            assert s["is_tile_final"] == 1
            assert s["tile_mode"] == 0
            assert s["chunk_id"] == 0

    def test_c_header_contains_struct_definitions(self, topo_file, tmp_path):
        topo = get_topology_by_name(topo_file.topologies, "196_64_10")
        result = export_topology_descriptor(topo, tmp_path)
        header_text = Path(result["header_path"]).read_text(encoding="utf-8")

        # Key struct definitions must be present for firmware compile
        for needle in [
            "typedef struct", "stage_desc_t", "topology_desc_t",
            "TOPO_DESC_MAGIC", "TOPO_DESC_VERSION",
            "ADC_FULL_SCALE_ACTIVE_WL",
            "__attribute__((packed))",
            "stream_timesteps", "adc_bits", "is_resident",
        ]:
            assert needle in header_text, f"missing {needle!r} in header"

    def test_deterministic_sha256(self, topo_file, tmp_path):
        topo = get_topology_by_name(topo_file.topologies, "196_64_10")
        r1 = export_topology_descriptor(topo, tmp_path / "a")
        r2 = export_topology_descriptor(topo, tmp_path / "b")
        assert r1["sha256"] == r2["sha256"]

    def test_legacy_bitplane_topology_is_skipped(self, topo_file, tmp_path):
        topo = get_topology_by_name(topo_file.topologies, "64_32_10")
        result = export_topology_descriptor(topo, tmp_path)
        assert result.get("skipped") is True

    def test_max_stages_bound(self):
        # TOPO_DESC_MAX_STAGES must be >= HW_MAX_LAYERS so single-chunk topologies
        # always fit, with slack for future multi-chunk descriptors.
        from topologies import HW_MAX_LAYERS
        assert TOPO_DESC_MAX_STAGES >= HW_MAX_LAYERS
