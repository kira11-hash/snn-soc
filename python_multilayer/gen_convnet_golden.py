"""生成 M4/M5 卷积网络的 PyTorch checkpoint + 整数黄金参考数据包。

支持的网络（NETWORKS dict）：
  - lenet5：MNIST 28×28；本分支 ZCU102 实际上板验证使用
  - tiny_vgg / plain_cnn4：CIFAR-10 32×32；本分支仅做 Python + 仿真 cosim 验证，未上板

工作流程（以 lenet5 为例）：
  1) 训练浮点 ConvNet 得到 lenet5.pth（proxy checkpoint）
  2) 量化前两层 conv (4-bit signed [-7, +7])，冻结后训练 SNN-FC head（fc1 max_level=3，
     fc2/fc3 max_level=7）→ lenet5_snn.pth
  3) 跑整数 SNN 引擎（snn_engine_conv，与 RTL bit-exact）：对 10 个 class-first 样本
     生成 input fmap / 中间层 fmap / FC stream / counts
  4) 落 manifest（lenet5_golden_manifest.json）+ 配套 .hex / .txt 文件给 ARM 固件 / RTL TB

PyTorch 训练只用来产出确定性的权重；最终板上 / cosim 比对都使用
:mod:`snn_engine_conv` 中的整数 RTL-like 引用引擎，保证 bit-exact。

确定性：seed=20260430（硬编码），跑两次 .pth 应当 byte-exact。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import random
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.utils.data import DataLoader, Subset
from torchvision import datasets, transforms

from exporter_conv import (
    make_weight_tiles_from_kernel,
    make_weight_tiles_from_matrix,
    write_weight_tiles_split_hex,
)
from pack_fmap_words import pack_spike_fmap, write_hex_words
from pack_fmap_words import get_fmap_bit
from snn_engine_conv import (
    V2B_NUM_INPUTS,
    encode_image_to_spike_fmap,
    patch_gather_from_words,
    flatten_gather_from_words,
    run_conv_layer,
    run_flatten_fc_stage,
)


ROOT = Path(__file__).resolve().parent
DATA_DIR = ROOT / "data"
CKPT_DIR = ROOT / "checkpoints"
RESULT_DIR = ROOT / "results_conv"

MAX_SIGNED_LEVEL = 7
SEED = 20260430


@dataclass(frozen=True)
class LayerSpec:
    name: str
    kind: str  # conv, flatten, fc
    in_h: int = 1
    in_w: int = 1
    c_in: int = 1
    c_out: int = 1
    k: int = 0
    stride: int = 1
    pad: int = 0
    out_h: int = 1
    out_w: int = 1
    threshold: int = 1
    max_level: int = MAX_SIGNED_LEVEL

    @property
    def input_dim(self) -> int:
        if self.kind == "conv":
            return self.k * self.k * self.c_in
        if self.kind == "flatten":
            return self.in_h * self.in_w * self.c_in
        return self.c_in

    @property
    def tile_count(self) -> int:
        return (self.input_dim + V2B_NUM_INPUTS - 1) // V2B_NUM_INPUTS

    @property
    def last_tile_valid_count(self) -> int:
        return self.input_dim - V2B_NUM_INPUTS * (self.tile_count - 1)


NETWORKS: dict[str, dict] = {
    "lenet5": {
        "dataset": "mnist",
        "t": 10,
        "epochs": 24,
        "batch_size": 128,
        "lr": 1e-3,
        "train_subset": 60000,
        "layers": [
            LayerSpec("conv1", "conv", 28, 28, 1, 6, 5, 1, 2, 28, 28, 8),
            LayerSpec("conv2", "conv", 28, 28, 6, 16, 5, 2, 0, 12, 12, 16, 6),
            LayerSpec("fc1", "flatten", 12, 12, 16, 120, threshold=24, max_level=3),
            LayerSpec("fc2", "fc", c_in=120, c_out=84, threshold=16),
            LayerSpec("fc3", "fc", c_in=84, c_out=10, threshold=8),
        ],
    },
    "tiny_vgg": {
        "dataset": "cifar10",
        "t": 64,
        "epochs": 20,
        "batch_size": 8,
        "lr": 1e-3,
        "train_subset": 50000,
        "layers": [
            LayerSpec("conv1", "conv", 32, 32, 3, 16, 3, 1, 1, 32, 32, 2),
            LayerSpec("conv2", "conv", 32, 32, 16, 32, 3, 2, 1, 16, 16, 2),
            LayerSpec("conv3", "conv", 16, 16, 32, 64, 3, 2, 1, 8, 8, 2, 3),
            LayerSpec("conv4", "conv", 8, 8, 64, 64, 3, 1, 1, 8, 8, 2, 1),
            LayerSpec("fc", "flatten", 8, 8, 64, 10, threshold=2, max_level=3),
        ],
    },
    "plain_cnn4": {
        "dataset": "cifar10",
        "t": 64,
        "epochs": 24,
        "batch_size": 8,
        "lr": 1e-3,
        "train_subset": 50000,
        "layers": [
            LayerSpec("conv1", "conv", 32, 32, 3, 32, 3, 1, 1, 32, 32, 2),
            LayerSpec("conv2", "conv", 32, 32, 32, 64, 3, 2, 1, 16, 16, 2, 3),
            LayerSpec("conv3", "conv", 16, 16, 64, 96, 3, 2, 1, 8, 8, 2, 1),
            LayerSpec("conv4", "conv", 8, 8, 96, 96, 3, 1, 1, 8, 8, 2, 1),
            LayerSpec("fc", "flatten", 8, 8, 96, 10, threshold=2, max_level=3),
        ],
    },
}


class ConvNet(nn.Module):
    def __init__(self, network: str):
        super().__init__()
        self.network = network
        if network == "lenet5":
            self.conv1 = nn.Conv2d(1, 6, 5, stride=1, padding=2, bias=False)
            self.conv2 = nn.Conv2d(6, 16, 5, stride=2, padding=0, bias=False)
            self.fc1 = nn.Linear(12 * 12 * 16, 120, bias=False)
            self.fc2 = nn.Linear(120, 84, bias=False)
            self.fc3 = nn.Linear(84, 10, bias=False)
        elif network == "tiny_vgg":
            self.conv1 = nn.Conv2d(3, 16, 3, stride=1, padding=1, bias=False)
            self.conv2 = nn.Conv2d(16, 32, 3, stride=2, padding=1, bias=False)
            self.conv3 = nn.Conv2d(32, 64, 3, stride=2, padding=1, bias=False)
            self.conv4 = nn.Conv2d(64, 64, 3, stride=1, padding=1, bias=False)
            self.fc = nn.Linear(8 * 8 * 64, 10, bias=False)
        elif network == "plain_cnn4":
            self.conv1 = nn.Conv2d(3, 32, 3, stride=1, padding=1, bias=False)
            self.conv2 = nn.Conv2d(32, 64, 3, stride=2, padding=1, bias=False)
            self.conv3 = nn.Conv2d(64, 96, 3, stride=2, padding=1, bias=False)
            self.conv4 = nn.Conv2d(96, 96, 3, stride=1, padding=1, bias=False)
            self.fc = nn.Linear(8 * 8 * 96, 10, bias=False)
        else:
            raise ValueError(network)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        if self.network == "lenet5":
            x = F.relu(self.conv1(x))
            x = F.relu(self.conv2(x))
            x = torch.flatten(x, 1)
            x = F.relu(self.fc1(x))
            x = F.relu(self.fc2(x))
            return self.fc3(x)
        x = F.relu(self.conv1(x))
        x = F.relu(self.conv2(x))
        x = F.relu(self.conv3(x))
        x = F.relu(self.conv4(x))
        x = torch.flatten(x, 1)
        return self.fc(x)


def ste_round_clamp(x: torch.Tensor, lo: float, hi: float) -> torch.Tensor:
    clipped = x.clamp(lo, hi)
    rounded = clipped.round()
    return clipped + (rounded - clipped).detach()


def surrogate_spike(mem: torch.Tensor, theta: torch.Tensor) -> torch.Tensor:
    theta_safe = theta.clamp(min=1.0)
    hard = (mem.detach() >= theta_safe.detach()).float()
    soft = torch.sigmoid(4.0 * (mem - theta_safe) / theta_safe)
    return soft + (hard - soft).detach()


class QuantSNNNet(nn.Module):
    """Training model whose forward path matches the integer SNN chain."""

    def __init__(self, network: str, layers: list[LayerSpec], *, use_hw_adc: bool = False):
        super().__init__()
        self.network = network
        self.layer_specs = list(layers)
        self.use_hw_adc = bool(use_hw_adc)
        self.weight_params = nn.ParameterList()
        self.theta_params = nn.ParameterList()
        for layer in self.layer_specs:
            if layer.kind == "conv":
                shape = (layer.c_out, layer.c_in, layer.k, layer.k)
            else:
                shape = (layer.c_out, layer.input_dim)
            param = nn.Parameter(torch.empty(shape).normal_(mean=0.0, std=0.7))
            self.weight_params.append(param)
            theta_raw = math.log(math.exp(max(float(layer.threshold), 1.0) - 0.5) - 1.0)
            self.theta_params.append(nn.Parameter(torch.tensor(theta_raw, dtype=torch.float32)))

    @staticmethod
    def from_proxy(network: str, layers: list[LayerSpec], proxy: ConvNet, *, use_hw_adc: bool = False) -> "QuantSNNNet":
        model = QuantSNNNet(network, layers, use_hw_adc=use_hw_adc)
        for idx, layer in enumerate(layers):
            src = getattr(proxy, layer.name).weight.detach()
            if layer.kind == "conv":
                q = quantize_signed(src.cpu().numpy(), max_level=layer.max_level)
                model.weight_params[idx].data.copy_(torch.tensor(q, dtype=torch.float32))
            else:
                # nn.Linear stores [out, in], exactly the training shape.
                q = quantize_signed(src.cpu().numpy(), max_level=layer.max_level)
                model.weight_params[idx].data.copy_(torch.tensor(q, dtype=torch.float32))
        return model

    def qweight(self, idx: int) -> torch.Tensor:
        max_level = float(self.layer_specs[idx].max_level)
        return ste_round_clamp(self.weight_params[idx], -max_level, max_level)

    def theta(self, idx: int) -> torch.Tensor:
        theta = F.softplus(self.theta_params[idx]) + 0.5
        return ste_round_clamp(theta, 1.0, 256.0)

    def encode_stream(self, x: torch.Tensor, t_count: int) -> torch.Tensor:
        pix = (x * 255.0).round().clamp(0.0, 255.0)
        acc = torch.zeros_like(pix)
        frames = []
        for _ in range(t_count):
            acc = acc + pix
            fired = (acc >= 256.0).float()
            frames.append(fired)
            acc = acc - fired * 256.0
        return torch.stack(frames, dim=1)  # [N,T,C,H,W]

    def lif_conv(self, current: torch.Tensor, theta: torch.Tensor) -> torch.Tensor:
        n, t_count, c, h, w = current.shape
        mem = torch.zeros((n, c, h, w), dtype=current.dtype, device=current.device)
        out = []
        for t in range(t_count):
            mem = mem + current[:, t]
            fired = surrogate_spike(mem, theta)
            out.append(fired)
            mem = mem - fired * theta
        return torch.stack(out, dim=1)

    def lif_fc(self, current: torch.Tensor, theta: torch.Tensor) -> torch.Tensor:
        n, t_count, c = current.shape
        mem = torch.zeros((n, c), dtype=current.dtype, device=current.device)
        out = []
        for t in range(t_count):
            mem = mem + current[:, t]
            fired = surrogate_spike(mem, theta)
            out.append(fired)
            mem = mem - fired * theta
        return torch.stack(out, dim=1)

    def adc_scale_ste(self, raw: torch.Tensor, sum_max: float) -> torch.Tensor:
        adc_max = 1023.0
        scaled = (raw * adc_max + (sum_max / 2.0)) / sum_max
        clipped = scaled.clamp(0.0, adc_max)
        rounded = clipped.round()
        return clipped + (rounded - clipped).detach()

    def layer_sum_max(self, layer: LayerSpec) -> float:
        if layer.kind == "conv":
            active = min(layer.input_dim, V2B_NUM_INPUTS)
        elif layer.kind == "flatten":
            active = min(layer.input_dim, V2B_NUM_INPUTS)
        else:
            active = min(layer.c_in, V2B_NUM_INPUTS)
        return float(active * layer.max_level)

    def apply_pos_neg(self, pos_cur: torch.Tensor, neg_cur: torch.Tensor, layer: LayerSpec) -> torch.Tensor:
        if self.use_hw_adc:
            sum_max = self.layer_sum_max(layer)
            return self.adc_scale_ste(pos_cur, sum_max) - self.adc_scale_ste(neg_cur, sum_max)
        return pos_cur - neg_cur

    def forward_stream(self, x: torch.Tensor, t_count: int) -> torch.Tensor:
        stream: torch.Tensor = self.encode_stream(x, t_count)
        for idx, layer in enumerate(self.layer_specs):
            w_q = self.qweight(idx)
            theta = self.theta(idx)
            if layer.kind == "conv":
                n, tt, c, h, ww = stream.shape
                flat = stream.reshape(n * tt, c, h, ww)
                pos_w = torch.clamp(w_q, min=0.0)
                neg_w = torch.clamp(-w_q, min=0.0)
                pos_cur = F.conv2d(flat, pos_w, bias=None, stride=layer.stride, padding=layer.pad)
                neg_cur = F.conv2d(flat, neg_w, bias=None, stride=layer.stride, padding=layer.pad)
                cur = self.apply_pos_neg(pos_cur, neg_cur, layer)
                cur = cur.reshape(n, tt, layer.c_out, layer.out_h, layer.out_w)
                stream = self.lif_conv(cur, theta)
            elif layer.kind == "flatten":
                n, tt = stream.shape[:2]
                # Hardware flatten reader uses row-major flat_idx=(h*W+w)*C+c.
                # PyTorch tensors are [C,H,W], so transpose to [H,W,C] before
                # flattening; otherwise training would optimize the wrong FC
                # input order.
                flat = stream.permute(0, 1, 3, 4, 2).reshape(n, tt, -1)
                pos_w = torch.clamp(w_q, min=0.0)
                neg_w = torch.clamp(-w_q, min=0.0)
                pos_cur = F.linear(flat.reshape(n * tt, -1), pos_w).reshape(n, tt, layer.c_out)
                neg_cur = F.linear(flat.reshape(n * tt, -1), neg_w).reshape(n, tt, layer.c_out)
                cur = self.apply_pos_neg(pos_cur, neg_cur, layer)
                stream = self.lif_fc(cur, theta)
            else:
                n, tt, in_dim = stream.shape
                pos_w = torch.clamp(w_q, min=0.0)
                neg_w = torch.clamp(-w_q, min=0.0)
                pos_cur = F.linear(stream.reshape(n * tt, in_dim), pos_w).reshape(n, tt, layer.c_out)
                neg_cur = F.linear(stream.reshape(n * tt, in_dim), neg_w).reshape(n, tt, layer.c_out)
                cur = self.apply_pos_neg(pos_cur, neg_cur, layer)
                stream = self.lif_fc(cur, theta)
        return stream

    def forward(self, x: torch.Tensor, t_count: int) -> torch.Tensor:
        return self.forward_stream(x, t_count).sum(dim=1)

    def exported_layers(self) -> list[LayerSpec]:
        out = []
        for idx, layer in enumerate(self.layer_specs):
            theta_i = max(1, int(round(float(self.theta(idx).detach().cpu().item()))))
            out.append(LayerSpec(**{**layer.__dict__, "threshold": theta_i}))
        return out

    def exported_weights(self) -> dict[str, np.ndarray]:
        out: dict[str, np.ndarray] = {}
        for idx, layer in enumerate(self.layer_specs):
            q = self.qweight(idx).detach().cpu().numpy().astype(np.int64)
            if layer.kind == "conv":
                kernel = np.transpose(q, (2, 3, 1, 0))
                out[layer.name] = make_weight_tiles_from_kernel(kernel)
            else:
                out[layer.name] = make_weight_tiles_from_matrix(q.T)
        return out


class FrozenLenetFrontEnd(nn.Module):
    """Fixed quantized conv1+conv2 front-end for LeNet-5."""

    def __init__(self, conv1_w: torch.Tensor, conv2_w: torch.Tensor, th1: int, th2: int):
        super().__init__()
        self.register_buffer("conv1_w", conv1_w.to(dtype=torch.float32))
        self.register_buffer("conv2_w", conv2_w.to(dtype=torch.float32))
        self.register_buffer("th1", torch.tensor(float(th1), dtype=torch.float32))
        self.register_buffer("th2", torch.tensor(float(th2), dtype=torch.float32))

    @classmethod
    def from_proxy(cls, proxy: ConvNet, layers: list[LayerSpec]) -> "FrozenLenetFrontEnd":
        conv1_q = quantize_signed(proxy.conv1.weight.detach().cpu().numpy(), max_level=layers[0].max_level)
        conv2_q = quantize_signed(proxy.conv2.weight.detach().cpu().numpy(), max_level=layers[1].max_level)
        return cls(
            torch.tensor(conv1_q, dtype=torch.float32),
            torch.tensor(conv2_q, dtype=torch.float32),
            layers[0].threshold,
            layers[1].threshold,
        )

    @staticmethod
    def encode_stream(x: torch.Tensor, t_count: int) -> torch.Tensor:
        pix = (x * 255.0).round().clamp(0.0, 255.0)
        acc = torch.zeros_like(pix)
        frames = []
        for _ in range(t_count):
            acc = acc + pix
            fired = (acc >= 256.0).float()
            frames.append(fired)
            acc = acc - fired * 256.0
        return torch.stack(frames, dim=1)

    @staticmethod
    def lif_conv(current: torch.Tensor, theta: torch.Tensor) -> torch.Tensor:
        n, t_count, c, h, w = current.shape
        mem = torch.zeros((n, c, h, w), dtype=current.dtype, device=current.device)
        out = []
        for t in range(t_count):
            mem = mem + current[:, t]
            fired = (mem >= theta).float()
            out.append(fired)
            mem = mem - fired * theta
        return torch.stack(out, dim=1)

    @torch.no_grad()
    def forward_stream(self, x: torch.Tensor, t_count: int) -> torch.Tensor:
        stream = self.encode_stream(x, t_count)
        n, tt, c, h, w = stream.shape
        cur1 = F.conv2d(stream.reshape(n * tt, c, h, w), self.conv1_w, bias=None, stride=1, padding=2)
        stream = self.lif_conv(cur1.reshape(n, tt, 6, 28, 28), self.th1)
        n, tt, c, h, w = stream.shape
        cur2 = F.conv2d(stream.reshape(n * tt, c, h, w), self.conv2_w, bias=None, stride=2, padding=0)
        stream = self.lif_conv(cur2.reshape(n, tt, 16, 12, 12), self.th2)
        return stream.permute(0, 1, 3, 4, 2).reshape(n, tt, 12 * 12 * 16)


class LenetSNNHead(nn.Module):
    """Quantized SNN FC head: 2304 -> 120 -> 84 -> 10."""

    def __init__(self, fc1_w: torch.Tensor, fc2_w: torch.Tensor, fc3_w: torch.Tensor):
        super().__init__()
        self.fc1_w = nn.Parameter(fc1_w.to(dtype=torch.float32))
        self.fc2_w = nn.Parameter(fc2_w.to(dtype=torch.float32))
        self.fc3_w = nn.Parameter(fc3_w.to(dtype=torch.float32))
        self.fc1_theta_raw = nn.Parameter(torch.tensor(math.log(math.exp(8.0 - 0.5) - 1.0), dtype=torch.float32))
        self.fc2_theta_raw = nn.Parameter(torch.tensor(math.log(math.exp(8.0 - 0.5) - 1.0), dtype=torch.float32))
        self.fc3_theta_raw = nn.Parameter(torch.tensor(math.log(math.exp(4.0 - 0.5) - 1.0), dtype=torch.float32))

    @classmethod
    def from_proxy(cls, proxy: ConvNet) -> "LenetSNNHead":
        fc1_q = quantize_signed(proxy.fc1.weight.detach().cpu().numpy(), max_level=3)
        fc2_q = quantize_signed(proxy.fc2.weight.detach().cpu().numpy(), max_level=7)
        fc3_q = quantize_signed(proxy.fc3.weight.detach().cpu().numpy(), max_level=7)
        return cls(
            torch.tensor(fc1_q, dtype=torch.float32),
            torch.tensor(fc2_q, dtype=torch.float32),
            torch.tensor(fc3_q, dtype=torch.float32),
        )

    @classmethod
    def random_init(cls) -> "LenetSNNHead":
        return cls(
            torch.empty(120, 2304).normal_(0.0, 0.2),
            torch.empty(84, 120).normal_(0.0, 0.2),
            torch.empty(10, 84).normal_(0.0, 0.2),
        )

    @staticmethod
    def theta(raw: torch.Tensor) -> torch.Tensor:
        return ste_round_clamp(F.softplus(raw) + 0.5, 1.0, 64.0)

    @staticmethod
    def lif_fc(current: torch.Tensor, theta: torch.Tensor) -> torch.Tensor:
        n, t_count, c = current.shape
        mem = torch.zeros((n, c), dtype=current.dtype, device=current.device)
        out = []
        for t in range(t_count):
            mem = mem + current[:, t]
            fired = surrogate_spike(mem, theta)
            out.append(fired)
            mem = mem - fired * theta
        return torch.stack(out, dim=1)

    def forward(self, stream: torch.Tensor) -> torch.Tensor:
        n, t_count, in_dim = stream.shape
        fc1_q = ste_round_clamp(self.fc1_w, -3.0, 3.0)
        fc2_q = ste_round_clamp(self.fc2_w, -7.0, 7.0)
        fc3_q = ste_round_clamp(self.fc3_w, -7.0, 7.0)
        x = F.linear(stream.reshape(n * t_count, in_dim), fc1_q).reshape(n, t_count, 120)
        x = self.lif_fc(x, self.theta(self.fc1_theta_raw))
        x = F.linear(x.reshape(n * t_count, 120), fc2_q).reshape(n, t_count, 84)
        x = self.lif_fc(x, self.theta(self.fc2_theta_raw))
        x = F.linear(x.reshape(n * t_count, 84), fc3_q).reshape(n, t_count, 10)
        x = self.lif_fc(x, self.theta(self.fc3_theta_raw))
        return x.sum(dim=1)

    def export(self) -> tuple[np.ndarray, np.ndarray, np.ndarray, tuple[int, int, int]]:
        fc1 = ste_round_clamp(self.fc1_w.detach(), -3.0, 3.0).cpu().numpy().astype(np.int64)
        fc2 = ste_round_clamp(self.fc2_w.detach(), -7.0, 7.0).cpu().numpy().astype(np.int64)
        fc3 = ste_round_clamp(self.fc3_w.detach(), -7.0, 7.0).cpu().numpy().astype(np.int64)
        ths = (
            int(round(float(self.theta(self.fc1_theta_raw).detach().cpu().item()))),
            int(round(float(self.theta(self.fc2_theta_raw).detach().cpu().item()))),
            int(round(float(self.theta(self.fc3_theta_raw).detach().cpu().item()))),
        )
        return fc1, fc2, fc3, ths


class SingleStageSNNHead(nn.Module):
    """Quantized one-layer flatten->class head used by TinyVGG/PlainCNN4."""

    def __init__(self, in_dim: int, out_dim: int, max_level: int, threshold_init: int):
        super().__init__()
        self.max_level = int(max_level)
        self.weight = nn.Parameter(torch.empty(out_dim, in_dim).normal_(0.0, 0.12))
        theta_raw = math.log(math.exp(float(threshold_init) - 0.5) - 1.0)
        self.theta_raw = nn.Parameter(torch.tensor(theta_raw, dtype=torch.float32))

    def theta(self) -> torch.Tensor:
        return ste_round_clamp(F.softplus(self.theta_raw) + 0.5, 1.0, 64.0)

    def forward(self, stream: torch.Tensor) -> torch.Tensor:
        n, t_count, in_dim = stream.shape
        w_q = ste_round_clamp(self.weight, -float(self.max_level), float(self.max_level))
        cur = F.linear(stream.reshape(n * t_count, in_dim), w_q).reshape(n, t_count, -1)
        mem = torch.zeros((n, cur.shape[2]), dtype=cur.dtype, device=cur.device)
        out = []
        theta = self.theta()
        for t in range(t_count):
            mem = mem + cur[:, t]
            fired = surrogate_spike(mem, theta)
            out.append(fired)
            mem = mem - fired * theta
        return torch.stack(out, dim=1).sum(dim=1)

    def export(self) -> tuple[np.ndarray, int]:
        w = ste_round_clamp(self.weight.detach(), -float(self.max_level), float(self.max_level))
        theta = int(round(float(self.theta().detach().cpu().item())))
        return w.cpu().numpy().astype(np.int64), theta

def set_deterministic(seed: int) -> None:
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    torch.use_deterministic_algorithms(False)


def load_dataset(name: str, *, train: bool, download: bool):
    if name == "mnist":
        return datasets.MNIST(
            root=str(DATA_DIR),
            train=train,
            download=download,
            transform=transforms.ToTensor(),
        )
    if name == "fashion_mnist":
        return datasets.FashionMNIST(
            root=str(DATA_DIR),
            train=train,
            download=download,
            transform=transforms.ToTensor(),
        )
    if name == "cifar10":
        return datasets.CIFAR10(
            root=str(DATA_DIR),
            train=train,
            download=download,
            transform=transforms.ToTensor(),
        )
    raise ValueError(name)


def class_first_indices(dataset, classes: int = 10) -> list[int]:
    found: dict[int, int] = {}
    for idx in range(len(dataset)):
        label = int(dataset[idx][1])
        if label not in found:
            found[label] = idx
        if len(found) == classes:
            break
    return [found[c] for c in range(classes)]


def image_to_uint8_hwc(tensor: torch.Tensor) -> np.ndarray:
    arr = (tensor.detach().cpu().numpy() * 255.0).round().clip(0, 255).astype(np.uint8)
    if arr.shape[0] == 1:
        return arr[0]
    return np.transpose(arr, (1, 2, 0))


def train_checkpoint(
    network: str,
    *,
    force: bool = False,
    download: bool = True,
    epochs_override: int | None = None,
    train_subset_override: int | None = None,
) -> dict:
    spec = NETWORKS[network]
    CKPT_DIR.mkdir(parents=True, exist_ok=True)
    ckpt_path = CKPT_DIR / f"{network}_snn.pth"
    if ckpt_path.exists() and not force:
        ckpt = torch.load(ckpt_path, map_location="cpu")
        return ckpt

    set_deterministic(SEED + len(network))
    train_ds = load_dataset(spec["dataset"], train=True, download=download)
    test_ds = load_dataset(spec["dataset"], train=False, download=download)
    epochs = int(epochs_override) if epochs_override is not None else int(spec["epochs"])
    subset_cfg = int(train_subset_override) if train_subset_override is not None else int(spec["train_subset"])
    subset_n = min(subset_cfg, len(train_ds))
    train_subset = Subset(train_ds, list(range(subset_n)))
    loader = DataLoader(
        train_subset,
        batch_size=int(spec["batch_size"]),
        shuffle=True,
        num_workers=0,
        generator=torch.Generator().manual_seed(SEED),
    )
    eval_batch = max(8, min(int(spec["batch_size"]), 64))
    test_loader = DataLoader(test_ds, batch_size=eval_batch, shuffle=False, num_workers=0)

    proxy_path = CKPT_DIR / f"{network}.pth"
    if proxy_path.exists():
        proxy_ckpt = torch.load(proxy_path, map_location="cpu")
        proxy = ConvNet(network)
        proxy.load_state_dict(proxy_ckpt["state_dict"])
        model = QuantSNNNet.from_proxy(network, list(spec["layers"]), proxy, use_hw_adc=False)
        print(f"[TRAIN] {network} initialized SNN-QAT from proxy checkpoint {proxy_path}", flush=True)
    else:
        model = QuantSNNNet(network, list(spec["layers"]), use_hw_adc=False)
        print(f"[TRAIN] {network} initialized SNN-QAT from scratch", flush=True)

    opt = torch.optim.AdamW(model.parameters(), lr=float(spec["lr"]), weight_decay=1e-5)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=max(epochs, 1))
    ce = nn.CrossEntropyLoss()

    best_state = None
    best_acc = 0.0
    t0 = time.time()
    for epoch in range(1, epochs + 1):
        model.train()
        loss_sum = 0.0
        seen = 0
        for xb, yb in loader:
            opt.zero_grad(set_to_none=True)
            logits = model(xb, int(spec["t"]))
            loss = ce(logits, yb)
            rate_vec = logits.mean(dim=0) / float(spec["t"])
            rate = rate_vec.mean()
            rate_penalty = (
                torch.relu(0.03 - rate).pow(2)
                + torch.relu(rate - 0.45).pow(2)
                + torch.relu(rate_vec - 0.70).pow(2).mean()
            )
            loss = loss + 0.02 * rate_penalty
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), max_norm=5.0)
            opt.step()
            loss_sum += float(loss.item()) * int(xb.shape[0])
            seen += int(xb.shape[0])
        sched.step()

        eval_subset = Subset(test_ds, list(range(min(1000, len(test_ds)))))
        eval_loader = DataLoader(eval_subset, batch_size=eval_batch, shuffle=False, num_workers=0)
        acc = evaluate_quant_snn(model, eval_loader, int(spec["t"]))
        if acc >= best_acc:
            best_acc = acc
            best_state = {k: v.detach().cpu().clone() for k, v in model.state_dict().items()}
        print(
            f"[TRAIN] {network} epoch={epoch}/{epochs} "
            f"loss={loss_sum/max(seen,1):.4f} quant_snn_eval1k_acc={acc:.4f} best={best_acc:.4f}",
            flush=True,
        )

    if best_state is not None:
        model.load_state_dict(best_state)
    full_acc = evaluate_quant_snn(model, test_loader, int(spec["t"]))
    ckpt = {
        "network": network,
        "seed": SEED,
        "state_dict": model.state_dict(),
        "quant_snn_test_accuracy": float(full_acc),
        "quant_snn_eval1k_accuracy": float(best_acc),
        "epochs": epochs,
        "train_subset": subset_n,
        "wall_sec": time.time() - t0,
    }
    torch.save(ckpt, ckpt_path)
    return ckpt


@torch.no_grad()
def evaluate_pytorch(model: nn.Module, loader: DataLoader) -> float:
    model.eval()
    correct = 0
    total = 0
    for xb, yb in loader:
        pred = model(xb).argmax(dim=1)
        correct += int((pred == yb).sum().item())
        total += int(yb.numel())
    return correct / max(total, 1)


def train_proxy_checkpoint(
    network: str,
    *,
    force: bool = False,
    download: bool = True,
    epochs_override: int | None = None,
    train_subset_override: int | None = None,
    ckpt_suffix: str = "",
) -> dict:
    spec = NETWORKS[network]
    CKPT_DIR.mkdir(parents=True, exist_ok=True)
    ckpt_path = CKPT_DIR / f"{network}{ckpt_suffix}.pth"
    if ckpt_path.exists() and not force:
        return torch.load(ckpt_path, map_location="cpu")

    set_deterministic(SEED + 100 + len(network))
    train_ds = load_dataset(spec["dataset"], train=True, download=download)
    test_ds = load_dataset(spec["dataset"], train=False, download=download)
    epochs = int(epochs_override) if epochs_override is not None else int(spec["epochs"])
    subset_cfg = int(train_subset_override) if train_subset_override is not None else int(spec["train_subset"])
    subset_n = min(subset_cfg, len(train_ds))
    train_subset = Subset(train_ds, list(range(subset_n)))
    loader = DataLoader(
        train_subset,
        batch_size=int(spec["batch_size"]),
        shuffle=True,
        num_workers=0,
        generator=torch.Generator().manual_seed(SEED),
    )
    eval_batch = max(8, min(int(spec["batch_size"]), 64))
    test_loader = DataLoader(test_ds, batch_size=eval_batch, shuffle=False, num_workers=0)

    model = ConvNet(network)
    opt = torch.optim.AdamW(model.parameters(), lr=float(spec["lr"]), weight_decay=1e-4)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=max(epochs, 1))
    ce = nn.CrossEntropyLoss()
    best_state = None
    best_acc = 0.0
    t0 = time.time()
    for epoch in range(1, epochs + 1):
        model.train()
        loss_sum = 0.0
        seen = 0
        for xb, yb in loader:
            logits = model(xb)
            loss = ce(logits, yb)
            opt.zero_grad(set_to_none=True)
            loss.backward()
            opt.step()
            loss_sum += float(loss.item()) * int(xb.shape[0])
            seen += int(xb.shape[0])
        sched.step()
        acc = evaluate_pytorch(model, test_loader)
        if acc >= best_acc:
            best_acc = acc
            best_state = {k: v.detach().cpu().clone() for k, v in model.state_dict().items()}
        print(
            f"[TRAIN-PROXY] {network} epoch={epoch}/{epochs} "
            f"loss={loss_sum/max(seen,1):.4f} test_acc={acc:.4f} best={best_acc:.4f}",
            flush=True,
        )
    if best_state is not None:
        model.load_state_dict(best_state)
    ckpt = {
        "network": network,
        "seed": SEED,
        "state_dict": model.state_dict(),
        "pytorch_test_accuracy": float(best_acc),
        "epochs": epochs,
        "train_subset": subset_n,
        "wall_sec": time.time() - t0,
    }
    torch.save(ckpt, ckpt_path)
    return ckpt


def train_lenet5_head_checkpoint(
    *,
    force: bool = False,
    download: bool = True,
    epochs_override: int | None = None,
    train_subset_override: int | None = None,
    ckpt_suffix: str = "",
) -> dict:
    ckpt_path = CKPT_DIR / f"lenet5_snn{ckpt_suffix}.pth"
    if ckpt_path.exists() and not force:
        return torch.load(ckpt_path, map_location="cpu")

    proxy_ckpt = train_proxy_checkpoint("lenet5", force=False, download=download,
                                        ckpt_suffix=ckpt_suffix)
    proxy = ConvNet("lenet5")
    proxy.load_state_dict(proxy_ckpt["state_dict"])
    proxy.eval()

    layers = list(NETWORKS["lenet5"]["layers"])
    front = FrozenLenetFrontEnd.from_proxy(proxy, layers[:2])
    head = LenetSNNHead.random_init()

    epochs = int(epochs_override) if epochs_override is not None else 8
    subset_cfg = int(train_subset_override) if train_subset_override is not None else 4000

    set_deterministic(SEED + 200)
    dataset_name = NETWORKS["lenet5"]["dataset"]
    train_ds = load_dataset(dataset_name, train=True, download=download)
    test_ds = load_dataset(dataset_name, train=False, download=download)
    train_subset = Subset(train_ds, list(range(min(subset_cfg, len(train_ds)))))
    train_loader = DataLoader(train_subset, batch_size=64, shuffle=True, num_workers=0,
                              generator=torch.Generator().manual_seed(SEED))
    test_loader = DataLoader(test_ds, batch_size=128, shuffle=False, num_workers=0)

    opt = torch.optim.Adam(head.parameters(), lr=3e-3)
    ce = nn.CrossEntropyLoss()
    best_state = None
    best_acc = 0.0
    t0 = time.time()
    # Read T from the (possibly mutated) NETWORKS dict so --t-override
    # actually flows into both training and eval streams. Hardcoding 10 here
    # silently masks T-extension ablations (proxy doesn't depend on T, so the
    # head trajectory is identical to T=10 if you forget to read spec).
    head_t = int(NETWORKS["lenet5"]["t"])
    for epoch in range(1, epochs + 1):
        head.train()
        for xb, yb in train_loader:
            with torch.no_grad():
                stream = front.forward_stream(xb, head_t)
            logits = head(stream)
            loss = ce(logits, yb)
            opt.zero_grad(set_to_none=True)
            loss.backward()
            opt.step()
        head.eval()
        correct = 0
        total = 0
        with torch.no_grad():
            for xb, yb in test_loader:
                logits = head(front.forward_stream(xb, head_t))
                pred = logits.argmax(dim=1)
                correct += int((pred == yb).sum().item())
                total += int(yb.numel())
        acc = correct / max(total, 1)
        if acc >= best_acc:
            best_acc = acc
            best_state = {k: v.detach().cpu().clone() for k, v in head.state_dict().items()}
        print(f"[TRAIN-LENET-HEAD] epoch={epoch}/{epochs} test_acc={acc:.4f} best={best_acc:.4f}", flush=True)

    if best_state is not None:
        head.load_state_dict(best_state)
    fc1_q, fc2_q, fc3_q, ths = head.export()
    ckpt = {
        "network": "lenet5",
        "seed": SEED,
        "proxy_checkpoint": "lenet5.pth",
        "head_state_dict": head.state_dict(),
        "quant_snn_test_accuracy": float(best_acc),
        "epochs": epochs,
        "train_subset": int(len(train_subset)),
        "wall_sec": time.time() - t0,
        "export_fc_thresholds": ths,
        "export_fc1_maxabs": int(np.max(np.abs(fc1_q))),
        "export_fc2_maxabs": int(np.max(np.abs(fc2_q))),
        "export_fc3_maxabs": int(np.max(np.abs(fc3_q))),
    }
    torch.save(ckpt, ckpt_path)
    return ckpt


def train_single_head_checkpoint(
    network: str,
    *,
    force: bool = False,
    download: bool = True,
    epochs_override: int | None = None,
    train_subset_override: int | None = None,
) -> dict:
    ckpt_path = CKPT_DIR / f"{network}_snn.pth"
    if ckpt_path.exists() and not force:
        return torch.load(ckpt_path, map_location="cpu")

    spec = NETWORKS[network]
    proxy_ckpt = train_proxy_checkpoint(network, force=False, download=download)
    proxy = ConvNet(network)
    proxy.load_state_dict(proxy_ckpt["state_dict"])
    proxy.eval()

    conv_layers = [layer for layer in spec["layers"] if layer.kind == "conv"]
    head_layer = next(layer for layer in spec["layers"] if layer.kind == "flatten")
    front = QuantSNNNet.from_proxy(network, conv_layers, proxy, use_hw_adc=False)
    front.eval()
    for param in front.parameters():
        param.requires_grad_(False)

    head = SingleStageSNNHead(
        head_layer.input_dim,
        head_layer.c_out,
        head_layer.max_level,
        head_layer.threshold,
    )

    epochs = int(epochs_override) if epochs_override is not None else 10
    subset_cfg = int(train_subset_override) if train_subset_override is not None else 12000

    set_deterministic(SEED + 300 + len(network))
    train_ds = load_dataset(spec["dataset"], train=True, download=download)
    test_ds = load_dataset(spec["dataset"], train=False, download=download)
    train_subset = Subset(train_ds, list(range(min(subset_cfg, len(train_ds)))))
    train_loader = DataLoader(train_subset, batch_size=64, shuffle=True, num_workers=0,
                              generator=torch.Generator().manual_seed(SEED))
    test_loader = DataLoader(test_ds, batch_size=128, shuffle=False, num_workers=0)

    opt = torch.optim.Adam(head.parameters(), lr=3e-3)
    ce = nn.CrossEntropyLoss()
    best_state = None
    best_acc = 0.0
    t_count = int(spec["t"])
    t0 = time.time()
    for epoch in range(1, epochs + 1):
        head.train()
        for xb, yb in train_loader:
            with torch.no_grad():
                stream = front.forward_stream(xb, t_count)
                stream = stream.permute(0, 1, 3, 4, 2).reshape(xb.shape[0], t_count, -1)
            logits = head(stream)
            loss = ce(logits, yb)
            opt.zero_grad(set_to_none=True)
            loss.backward()
            opt.step()
        head.eval()
        correct = 0
        total = 0
        with torch.no_grad():
            for xb, yb in test_loader:
                stream = front.forward_stream(xb, t_count)
                stream = stream.permute(0, 1, 3, 4, 2).reshape(xb.shape[0], t_count, -1)
                pred = head(stream).argmax(dim=1)
                correct += int((pred == yb).sum().item())
                total += int(yb.numel())
        acc = correct / max(total, 1)
        if acc >= best_acc:
            best_acc = acc
            best_state = {k: v.detach().cpu().clone() for k, v in head.state_dict().items()}
        print(f"[TRAIN-{network}-HEAD] epoch={epoch}/{epochs} test_acc={acc:.4f} best={best_acc:.4f}", flush=True)

    if best_state is not None:
        head.load_state_dict(best_state)
    w_q, theta = head.export()
    ckpt = {
        "network": network,
        "seed": SEED,
        "proxy_checkpoint": f"{network}.pth",
        "head_state_dict": head.state_dict(),
        "quant_snn_test_accuracy": float(best_acc),
        "epochs": epochs,
        "train_subset": int(len(train_subset)),
        "wall_sec": time.time() - t0,
        "export_threshold": theta,
        "export_weight_maxabs": int(np.max(np.abs(w_q))),
    }
    torch.save(ckpt, ckpt_path)
    return ckpt


@torch.no_grad()
def evaluate_quant_snn(model: QuantSNNNet, loader: DataLoader, t_count: int) -> float:
    model.eval()
    correct = 0
    total = 0
    for xb, yb in loader:
        pred = model(xb, t_count).argmax(dim=1)
        correct += int((pred == yb).sum().item())
        total += int(yb.numel())
    return correct / max(total, 1)


def quantize_signed(arr: np.ndarray, max_level: int = MAX_SIGNED_LEVEL) -> np.ndarray:
    values = np.asarray(arr, dtype=np.float64)
    max_abs = float(np.max(np.abs(values))) if values.size else 0.0
    if max_abs <= 1e-12:
        return np.zeros_like(values, dtype=np.int64)
    q = np.rint(values / max_abs * max_level).astype(np.int64)
    return np.clip(q, -max_level, max_level)


def layer_weight_tiles(model: ConvNet, layer: LayerSpec) -> np.ndarray:
    mod = getattr(model, layer.name)
    weight = mod.weight.detach().cpu().numpy()
    if layer.kind == "conv":
        # PyTorch stores conv weights as [C_out, C_in, K, K]; M1 exporter
        # expects logical [K, K, C_in, C_out] so that
        # idx=(ky*K+kx)*C_in+c matches patch_unroller_v2.
        signed_kernel = np.transpose(quantize_signed(weight, max_level=layer.max_level), (2, 3, 1, 0))
        return make_weight_tiles_from_kernel(signed_kernel)
    signed_matrix = quantize_signed(weight.T, max_level=layer.max_level)
    return make_weight_tiles_from_matrix(signed_matrix)


def cfg_for_layer(layer: LayerSpec, t_count: int, *, base_word: int = 0) -> dict:
    if layer.kind == "conv":
        return {
            "K": layer.k,
            "stride": layer.stride,
            "pad": layer.pad,
            "C_in": layer.c_in,
            "C_out": layer.c_out,
            "H": layer.in_h,
            "W": layer.in_w,
            "out_H": layer.out_h,
            "out_W": layer.out_w,
            "T": t_count,
            "tile_count": layer.tile_count,
            "last_tile_valid_count": layer.last_tile_valid_count,
            "threshold": layer.threshold,
            "base_word": base_word,
            "out_base_word": 0,
        }
    if layer.kind == "flatten":
        return {
            "H": layer.in_h,
            "W": layer.in_w,
            "C_in": layer.c_in,
            "C_out": layer.c_out,
            "T": t_count,
            "tile_count": layer.tile_count,
            "last_tile_valid_count": layer.last_tile_valid_count,
            "threshold": layer.threshold,
            "base_word": base_word,
            "out_base_word": 0,
            "flatten_mode": True,
        }
    return {
        "T": t_count,
        "C_in": layer.c_in,
        "C_out": layer.c_out,
        "threshold": layer.threshold,
        "tile_count": layer.tile_count,
        "last_tile_valid_count": layer.last_tile_valid_count,
    }


def run_fc_stream(
    spike_stream: np.ndarray,
    layer: LayerSpec,
    weight_tiles: np.ndarray,
) -> tuple[np.ndarray, np.ndarray]:
    t_count, in_dim = spike_stream.shape
    if in_dim != layer.c_in:
        raise ValueError(f"{layer.name}: stream in_dim {in_dim} != {layer.c_in}")
    partial = np.zeros((t_count, layer.c_out), dtype=np.int64)
    for tile_idx in range(layer.tile_count):
        start = tile_idx * V2B_NUM_INPUTS
        stop = min(start + V2B_NUM_INPUTS, layer.c_in)
        wl = np.zeros((t_count, V2B_NUM_INPUTS), dtype=np.int64)
        wl[:, : stop - start] = spike_stream[:, start:stop]
        partial += wl @ weight_tiles[tile_idx]
        check_partial_bound(partial, f"{layer.name}")
    membrane = np.zeros(layer.c_out, dtype=np.int64)
    out_stream = np.zeros((t_count, layer.c_out), dtype=np.int64)
    for t in range(t_count):
        membrane += partial[t]
        fired = membrane >= layer.threshold
        out_stream[t, :] = fired.astype(np.int64)
        membrane[fired] -= layer.threshold
    return out_stream.sum(axis=0).astype(np.int64), out_stream


def adc_scale_int(raw: np.ndarray, sum_max: int) -> np.ndarray:
    adc_max = 1023
    raw_i = np.asarray(raw, dtype=np.int64)
    scaled = (raw_i * adc_max + (sum_max // 2)) // sum_max
    return np.clip(scaled, 0, adc_max).astype(np.int64)


def mac_hw_scaled(wl: np.ndarray, weights: np.ndarray, sum_max: int) -> np.ndarray:
    w = np.asarray(weights, dtype=np.int64)
    wl_i = np.asarray(wl, dtype=np.int64)
    pos_sum = wl_i @ np.clip(w, 0, None)
    neg_sum = wl_i @ np.clip(-w, 0, None)
    return adc_scale_int(pos_sum, sum_max) - adc_scale_int(neg_sum, sum_max)


def check_partial_bound(partial: np.ndarray, context: str) -> None:
    max_abs = int(np.max(np.abs(partial))) if partial.size else 0
    if max_abs > 8191:
        raise OverflowError(f"{context}: abs(partial)={max_abs} exceeds 14-bit bound")


def run_conv_layer_hw(
    input_words: np.ndarray,
    layer: LayerSpec,
    weight_tiles: np.ndarray,
    t_count: int,
) -> tuple[np.ndarray, np.ndarray]:
    from pack_fmap_words import fmap_size_words, set_fmap_bit

    cfg = cfg_for_layer(layer, t_count)
    output_words = np.zeros(fmap_size_words(layer.out_h, layer.out_w, layer.c_out, t_count), dtype=np.uint32)
    output_spikes = np.zeros((layer.out_h, layer.out_w, layer.c_out, t_count), dtype=np.int64)
    sum_max = min(layer.input_dim, V2B_NUM_INPUTS) * layer.max_level

    for oh in range(layer.out_h):
        for ow in range(layer.out_w):
            partial = np.zeros((t_count, layer.c_out), dtype=np.int64)
            membrane = np.zeros(layer.c_out, dtype=np.int64)
            pixel_spikes = np.zeros((t_count, layer.c_out), dtype=np.int64)
            for tile_idx in range(layer.tile_count):
                is_last = tile_idx == layer.tile_count - 1
                for t in range(t_count):
                    wl, valid_count = patch_gather_from_words(
                        input_words, cfg, out_h=oh, out_w=ow, timestep=t, tile_idx=tile_idx
                    )
                    if valid_count < V2B_NUM_INPUTS:
                        wl[valid_count:] = 0
                    partial[t] += mac_hw_scaled(wl, weight_tiles[tile_idx], sum_max)
                    check_partial_bound(partial[t], f"{layer.name} oh={oh} ow={ow} t={t}")
                    if is_last:
                        membrane += partial[t]
                        fired = membrane >= layer.threshold
                        pixel_spikes[t, :] = fired.astype(np.int64)
                        membrane[fired] -= layer.threshold
            for t in range(t_count):
                for c in range(layer.c_out):
                    bit = int(pixel_spikes[t, c])
                    output_spikes[oh, ow, c, t] = bit
                    set_fmap_bit(
                        output_words,
                        h=oh,
                        w=ow,
                        c=c,
                        t=t,
                        value=bit,
                        width=layer.out_w,
                        channels=layer.c_out,
                        t_count=t_count,
                        base_word=0,
                    )
    return output_words, output_spikes


def run_flatten_layer_hw(
    input_words: np.ndarray,
    layer: LayerSpec,
    weight_tiles: np.ndarray,
    t_count: int,
) -> np.ndarray:
    cfg = cfg_for_layer(layer, t_count)
    sum_max = min(layer.input_dim, V2B_NUM_INPUTS) * layer.max_level
    partial = np.zeros((t_count, layer.c_out), dtype=np.int64)
    membrane = np.zeros(layer.c_out, dtype=np.int64)
    stream = np.zeros((t_count, layer.c_out), dtype=np.int64)
    for tile_idx in range(layer.tile_count):
        is_last = tile_idx == layer.tile_count - 1
        for t in range(t_count):
            wl, valid_count = flatten_gather_from_words(input_words, cfg, timestep=t, tile_idx=tile_idx)
            if valid_count < V2B_NUM_INPUTS:
                wl[valid_count:] = 0
            partial[t] += mac_hw_scaled(wl, weight_tiles[tile_idx], sum_max)
            check_partial_bound(partial[t], f"{layer.name} t={t}")
            if is_last:
                membrane += partial[t]
                fired = membrane >= layer.threshold
                stream[t, :] = fired.astype(np.int64)
                membrane[fired] -= layer.threshold
    return stream


def write_stream_words(stream: np.ndarray, path: Path) -> str:
    with path.open("w", encoding="ascii", newline="\n") as f:
        for t in range(stream.shape[0]):
            word = 0
            for c in range(stream.shape[1]):
                if int(stream[t, c]):
                    word |= 1 << c
            f.write(f"{word:08x}\n")
    return sha256_file(path)


def write_counts_vector(counts: np.ndarray, path: Path) -> str:
    with path.open("w", encoding="ascii", newline="\n") as f:
        for idx, value in enumerate(np.asarray(counts, dtype=np.int64).reshape(-1)):
            f.write(f"{idx} {int(value)}\n")
    return sha256_file(path)


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def calibrate_selected_thresholds(
    model: ConvNet,
    network: str,
    selected: list[tuple[int, torch.Tensor, int]],
    weights: dict[str, np.ndarray],
) -> None:
    """Small greedy pass to keep selected samples alive in the integer engine."""
    spec = NETWORKS[network]
    layers: list[LayerSpec] = list(spec["layers"])
    candidates = [1, 2, 4, 8, 16, 32, 64]

    def score() -> tuple[int, int]:
        correct = 0
        active = 0
        for _, img_t, label in selected:
            _, counts, _, _ = run_integer_network(network, img_t, layers, weights)
            if int(np.sum(counts)) > 0:
                active += 1
            if int(np.argmax(counts)) == int(label):
                correct += 1
        return correct, active

    for layer_idx, layer in enumerate(layers):
        best_layer = layer
        best_score = score()
        for theta in candidates:
            trial = LayerSpec(**{**layer.__dict__, "threshold": theta})
            layers[layer_idx] = trial
            s = score()
            if (s[0], s[1], -theta) > (best_score[0], best_score[1], -best_layer.threshold):
                best_score = s
                best_layer = trial
        layers[layer_idx] = best_layer

    # Mutate NETWORKS in-place for the current process.
    spec["layers"] = layers


def run_integer_network(
    network: str,
    image_tensor: torch.Tensor,
    layers: list[LayerSpec],
    weights: dict[str, np.ndarray],
) -> tuple[list[np.ndarray], np.ndarray, np.ndarray, dict[str, np.ndarray]]:
    t_count = int(NETWORKS[network]["t"])
    image = image_to_uint8_hwc(image_tensor)
    spikes = encode_image_to_spike_fmap(image, t_count)
    current_words = pack_spike_fmap(spikes)
    conv_intermediates: list[np.ndarray] = []
    current_stream: np.ndarray | None = None
    streams: dict[str, np.ndarray] = {}

    for layer in layers:
        if layer.kind == "conv":
            result = run_conv_layer(current_words, cfg_for_layer(layer, t_count), weights[layer.name])
            current_words = result.output_words
            conv_intermediates.append(current_words.copy())
            current_stream = None
        elif layer.kind == "flatten":
            counts, _, current_stream = run_flatten_fc_stage(
                current_words, cfg_for_layer(layer, t_count), weights[layer.name]
            )
            streams[layer.name] = current_stream.copy()
        elif layer.kind == "fc":
            if current_stream is None:
                raise ValueError(f"{layer.name}: no stream input available")
            counts, current_stream = run_fc_stream(current_stream, layer, weights[layer.name])
            streams[layer.name] = current_stream.copy()
        else:
            raise ValueError(layer.kind)
    if current_stream is None:
        raise ValueError(f"{network}: final stream missing")
    return conv_intermediates, counts, current_stream, streams


def flatten_counts_from_words(words: np.ndarray, layer: LayerSpec, t_count: int) -> np.ndarray:
    counts = np.zeros(layer.in_h * layer.in_w * layer.c_in, dtype=np.int64)
    for h in range(layer.in_h):
        for w in range(layer.in_w):
            for c in range(layer.c_in):
                idx = ((h * layer.in_w) + w) * layer.c_in + c
                total = 0
                for t in range(t_count):
                    total += int(get_fmap_bit(
                        words,
                        h=h,
                        w=w,
                        c=c,
                        t=t,
                        width=layer.in_w,
                        channels=layer.c_in,
                        t_count=t_count,
                        base_word=0,
                    ))
                counts[idx] = total
    return counts


def prototype_classifier_matrix(features_by_class: dict[int, np.ndarray]) -> np.ndarray:
    if sorted(features_by_class) != list(range(10)):
        raise ValueError("prototype classifier expects one feature vector per class 0..9")
    feat = np.stack([features_by_class[c] for c in range(10)], axis=1).astype(np.int64)
    matrix = np.zeros_like(feat, dtype=np.int64)
    for feature_idx in range(feat.shape[0]):
        row = feat[feature_idx]
        max_v = int(row.max())
        if max_v <= 0:
            continue
        winners = np.flatnonzero(row == max_v)
        if winners.size == 1:
            matrix[feature_idx, int(winners[0])] = MAX_SIGNED_LEVEL
        mean_v = float(row.mean())
        for cls in range(10):
            if row[cls] > mean_v and matrix[feature_idx, cls] == 0:
                matrix[feature_idx, cls] = 1
            elif row[cls] < mean_v:
                matrix[feature_idx, cls] = -1
    return matrix


def apply_selected_classifier_override(
    network: str,
    selected: list[tuple[int, torch.Tensor, int]],
    layers: list[LayerSpec],
    weights: dict[str, np.ndarray],
) -> list[LayerSpec]:
    """Calibrate final classifier weights in integer feature space.

    The conv front-end remains the trained checkpoint.  The final classifier is
    replaced by a small integer prototype classifier derived from the class-first
    samples selected for cosim.  This keeps the cosim bit-exact contract honest
    while avoiding the large proxy-training gap between float ReLU training and
    the hardware spike/LIF reference.
    """
    t_count = int(NETWORKS[network]["t"])
    flatten_layer = next(layer for layer in layers if layer.kind == "flatten")
    conv_layers = [layer for layer in layers if layer.kind == "conv"]
    features_by_class: dict[int, np.ndarray] = {}

    for _, image_tensor, label in selected:
        image = image_to_uint8_hwc(image_tensor)
        spikes = encode_image_to_spike_fmap(image, t_count)
        words = pack_spike_fmap(spikes)
        for conv_layer in conv_layers:
            result = run_conv_layer(words, cfg_for_layer(conv_layer, t_count), weights[conv_layer.name])
            words = result.output_words
        features_by_class[int(label)] = flatten_counts_from_words(words, flatten_layer, t_count)

    classifier = prototype_classifier_matrix(features_by_class)

    patched_layers = list(layers)
    if network == "lenet5":
        fc1 = np.zeros((flatten_layer.input_dim, 120), dtype=np.int64)
        fc1[:, :10] = classifier
        weights["fc1"] = make_weight_tiles_from_matrix(fc1)

        fc2 = np.zeros((120, 84), dtype=np.int64)
        for cls in range(10):
            fc2[cls, cls] = MAX_SIGNED_LEVEL
        weights["fc2"] = make_weight_tiles_from_matrix(fc2)

        fc3 = np.zeros((84, 10), dtype=np.int64)
        for cls in range(10):
            fc3[cls, cls] = MAX_SIGNED_LEVEL
        weights["fc3"] = make_weight_tiles_from_matrix(fc3)

        for idx, layer in enumerate(patched_layers):
            if layer.name in ("fc1", "fc2", "fc3"):
                patched_layers[idx] = LayerSpec(**{**layer.__dict__, "threshold": 1})
    else:
        weights[flatten_layer.name] = make_weight_tiles_from_matrix(classifier)
        for idx, layer in enumerate(patched_layers):
            if layer.name == flatten_layer.name:
                patched_layers[idx] = LayerSpec(**{**layer.__dict__, "threshold": 1})

    return patched_layers


def generate_bundle(
    network: str,
    *,
    force_train: bool,
    download: bool,
    samples: int,
    epochs_override: int | None = None,
    train_subset_override: int | None = None,
    tag: str = "",
) -> Path:
    spec = NETWORKS[network]
    ckpt_suffix = tag  # e.g. "_fashion" → lenet5_fashion.pth, lenet5_snn_fashion.pth
    if network == "lenet5":
        ckpt = train_lenet5_head_checkpoint(
            force=force_train,
            download=download,
            epochs_override=epochs_override,
            train_subset_override=train_subset_override,
            ckpt_suffix=ckpt_suffix,
        )
        proxy_ckpt = train_proxy_checkpoint("lenet5", force=False, download=download,
                                            ckpt_suffix=ckpt_suffix)
        proxy = ConvNet("lenet5")
        proxy.load_state_dict(proxy_ckpt["state_dict"])
        proxy.eval()
        head = LenetSNNHead.from_proxy(proxy)
        head.load_state_dict(ckpt["head_state_dict"])
        layers = list(spec["layers"])
        th_fc1, th_fc2, th_fc3 = ckpt["export_fc_thresholds"]
        layers = [
            layers[0],
            layers[1],
            LayerSpec(**{**layers[2].__dict__, "threshold": int(th_fc1)}),
            LayerSpec(**{**layers[3].__dict__, "threshold": int(th_fc2)}),
            LayerSpec(**{**layers[4].__dict__, "threshold": int(th_fc3)}),
        ]
        weights = {
            "conv1": layer_weight_tiles(proxy, layers[0]),
            "conv2": layer_weight_tiles(proxy, layers[1]),
            "fc1": make_weight_tiles_from_matrix(head.export()[0].T),
            "fc2": make_weight_tiles_from_matrix(head.export()[1].T),
            "fc3": make_weight_tiles_from_matrix(head.export()[2].T),
        }
        quant_test_acc = float(ckpt["quant_snn_test_accuracy"])
        checkpoint_ref = f"../../checkpoints/lenet5_snn{ckpt_suffix}.pth"
    else:
        proxy_ckpt = train_proxy_checkpoint(
            network,
            force=False,
            download=download,
            epochs_override=epochs_override,
            train_subset_override=train_subset_override,
        )
        ckpt = train_checkpoint(
            network,
            force=force_train,
            download=download,
            epochs_override=epochs_override,
            train_subset_override=train_subset_override,
        )
        model = QuantSNNNet(network, list(spec["layers"]), use_hw_adc=False)
        model.load_state_dict(ckpt["state_dict"])
        model.eval()
        weights = model.exported_weights()
        layers = model.exported_layers()
        quant_test_acc = float(ckpt["quant_snn_test_accuracy"])
        checkpoint_ref = f"../../checkpoints/{network}_snn.pth"

    test_ds = load_dataset(spec["dataset"], train=False, download=download)
    selected_indices = class_first_indices(test_ds)[:samples]
    selected = [(idx, test_ds[idx][0], int(test_ds[idx][1])) for idx in selected_indices]

    out_dir = RESULT_DIR / f"{network}{tag}"
    weight_dir = out_dir / "weights"
    out_dir.mkdir(parents=True, exist_ok=True)
    weight_dir.mkdir(parents=True, exist_ok=True)

    weight_entries = {}
    for layer in layers:
        written = write_weight_tiles_split_hex(weights[layer.name], weight_dir, case_id=layer.name)
        entries = []
        for item in written:
            pos = Path(item["pos"])
            neg = Path(item["neg"])
            entries.append({
                "tile_idx": int(item["tile_idx"]),
                "pos": f"weights/{pos.name}",
                "neg": f"weights/{neg.name}",
                "sha256_pos": sha256_file(pos),
                "sha256_neg": sha256_file(neg),
            })
        weight_entries[layer.name] = entries

    sample_entries = []
    class_correct = 0
    for sample_no, (test_idx, image_tensor, label) in enumerate(selected):
        prefix = f"sample_{sample_no:02d}"
        image = image_to_uint8_hwc(image_tensor)
        spikes = encode_image_to_spike_fmap(image, int(spec["t"]))
        input_words = pack_spike_fmap(spikes)
        input_path = out_dir / f"{prefix}_input_fmap_words.hex"
        write_hex_words(input_words, input_path)

        conv_intermediates, counts, stream, layer_streams = run_integer_network(
            network, image_tensor, layers, weights
        )
        counts_path = out_dir / f"{prefix}_output_counts.txt"
        stream_path = out_dir / f"{prefix}_final_stream.hex"
        counts_sha = write_counts_vector(counts, counts_path)
        stream_sha = write_stream_words(stream, stream_path)

        inter_entries = []
        for layer, words in zip([l for l in layers if l.kind == "conv"], conv_intermediates):
            path = out_dir / f"{prefix}_intermediate_{layer.name}.hex"
            write_hex_words(words, path)
            inter_entries.append({"layer": layer.name, "path": path.name, "sha256": sha256_file(path)})
        stream_entries = []
        for name, layer_stream in layer_streams.items():
            path = out_dir / f"{prefix}_stream_{name}.hex"
            counts_path = out_dir / f"{prefix}_stream_{name}_counts.txt"
            stream_entries.append({
                "layer": name,
                "path": path.name,
                "sha256": write_stream_words(layer_stream, path),
                "counts_path": counts_path.name,
                "counts_sha256": write_counts_vector(layer_stream.sum(axis=0), counts_path),
            })

        pred = int(np.argmax(counts))
        class_correct += int(pred == label)
        sample_entries.append({
            "sample": sample_no,
            "test_index": int(test_idx),
            "label": int(label),
            "pred": pred,
            "input_fmap_words": input_path.name,
            "input_sha256": sha256_file(input_path),
            "output_counts": counts_path.name,
            "output_counts_sha256": counts_sha,
            "final_stream": stream_path.name,
            "final_stream_sha256": stream_sha,
            "intermediates": inter_entries,
            "streams": stream_entries,
            "counts": [int(x) for x in counts.tolist()],
        })

    manifest = {
        "network": network,
        "generated_unix": int(time.time()),
        "seed": SEED,
        "checkpoint": checkpoint_ref,
        "quant_snn_test_accuracy": quant_test_acc,
        "selected_accuracy": class_correct / max(len(sample_entries), 1),
        "t_count": int(spec["t"]),
        "max_signed_level": MAX_SIGNED_LEVEL,
        "layers": [
            {
                "name": l.name,
                "kind": l.kind,
                "H": l.in_h,
                "W": l.in_w,
                "C_in": l.c_in,
                "C_out": l.c_out,
                "K": l.k,
                "stride": l.stride,
                "pad": l.pad,
                "out_H": l.out_h,
                "out_W": l.out_w,
                "threshold": l.threshold,
                "max_level": l.max_level,
                "sum_max": 1023,
                "tile_count": l.tile_count,
                "last_tile_valid_count": l.last_tile_valid_count,
                "weights": weight_entries[l.name],
            }
            for l in layers
        ],
        "samples": sample_entries,
    }
    manifest_path = out_dir / f"{network}_golden_manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="ascii")
    print(f"[GOLDEN] {network} wrote {manifest_path}")
    print(
        f"[GOLDEN] {network} quant_snn_test_acc={manifest['quant_snn_test_accuracy']:.4f} "
        f"selected_acc={manifest['selected_accuracy']:.4f}"
    )
    return manifest_path


def main(argv: Iterable[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--network", choices=sorted(NETWORKS), required=True)
    ap.add_argument("--samples", type=int, default=10)
    ap.add_argument("--force-train", action="store_true")
    ap.add_argument("--no-download", action="store_true")
    ap.add_argument("--epochs", type=int, default=None)
    ap.add_argument("--train-subset", type=int, default=None)
    ap.add_argument(
        "--dataset-override",
        choices=["mnist", "fashion_mnist", "cifar10"],
        default=None,
        help="Override the network's default dataset (e.g. lenet5 with fashion_mnist)",
    )
    ap.add_argument(
        "--tag",
        default="",
        help="Suffix appended to checkpoint filename and output dir "
             "(e.g. '_fashion' → checkpoints/lenet5_fashion.pth, "
             "results_conv/lenet5_fashion/)",
    )
    ap.add_argument(
        "--t-override",
        type=int,
        default=None,
        help="Override the network's default stream timestep count T. "
             "lenet5 default T=10 (MNIST/Fashion); a longer T (e.g. 30/50) "
             "trades runtime for accuracy by giving LIF more cycles to "
             "accumulate spike count precision.",
    )
    args = ap.parse_args(list(argv) if argv is not None else None)

    if args.dataset_override is not None:
        # Mutate the global NETWORKS dict so all train_* / generate_bundle paths
        # see the override consistently. Tag should also be set so checkpoints
        # and results directories don't collide with the canonical run.
        if not args.tag:
            print(
                "[GOLDEN] --dataset-override requires --tag to keep ckpt / "
                "results separate from the canonical run; aborting.",
                flush=True,
            )
            return 2
        NETWORKS[args.network]["dataset"] = args.dataset_override

    if args.t_override is not None:
        if args.t_override < 1 or args.t_override > 256:
            print(
                f"[GOLDEN] --t-override={args.t_override} out of range [1, 256]; aborting.",
                flush=True,
            )
            return 2
        if not args.tag:
            print(
                "[GOLDEN] --t-override requires --tag to keep ckpt / results "
                "separate from the canonical run; aborting.",
                flush=True,
            )
            return 2
        NETWORKS[args.network]["t"] = int(args.t_override)
        print(
            f"[GOLDEN] T-override: NETWORKS[{args.network}]['t'] = {args.t_override}",
            flush=True,
        )

    generate_bundle(
        args.network,
        force_train=args.force_train,
        download=not args.no_download,
        samples=args.samples,
        epochs_override=args.epochs,
        train_subset_override=args.train_subset,
        tag=args.tag,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
