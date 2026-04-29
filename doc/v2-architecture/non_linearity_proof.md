# V2.B Multi-layer SNN — Non-Linearity Implementation Proof

**Status**: Architecture supplementary, paper §method back-reference
**Date**: 2026-04-25 (cycle close evidence; underlying RTL frozen since v2-fpga-e203-passed @ e696dc39)
**Purpose**: Refute the natural ANN-equivalence question — *"do you need an activation function between stages?"* — with concrete RTL evidence.

---

## 1. Background

In **ANN**, stacking linear layers without an activation function collapses to a single linear layer:

```
y = W₂(W₁·x + b₁) + b₂ = (W₂W₁)·x + (W₂b₁ + b₂)
                      = W'·x + b'        ← still linear
```

So ANN must insert ReLU / sigmoid / tanh between layers to preserve representational power. This costs LUTs, multipliers, or look-up tables on dedicated activation function units.

**SNN** does not need a separate activation unit because the **LIF neuron itself is the non-linearity**. The threshold-compare-and-spike mechanism inside each neuron is a hard non-linearity (Heaviside step) that produces a binary output, breaking linear stacking automatically.

This document proves, against the V2.B RTL, that:

1. The LIF non-linearity (`(v_mem ≥ θ) ? 1 : 0`) is **actually invoked** between every stage transition.
2. Inter-stage data path is **1-bit binary spike**, not multi-bit membrane potential.
3. There is **no linear shortcut** that would let stage k+1 see stage k's pre-LIF value.

---

## 2. Pipeline data flow (V2.B 2-stage Fashion-14×14)

```
                     pixel[196] (8-bit grayscale)
                              │
                              ▼  Bresenham even-rate encoder (linear)
                     stream_bits[T=64][196 bits]
                              │
                  ┌───────────┘   stage_in_src = INPUT_SRAM
                  ▼
        ┌─────────── Stage 0 (in=196, out=64, θ=16) ───────────┐
        │  WL_in (binary)                                       │
        │    ↓ CIM MAC: W_pos·s − W_neg·s          ── linear    │
        │  partial_sum[14-bit signed]                           │
        │    ↓ membrane accumulate (T cycles)      ── linear    │
        │  v_mem[t][j] (16-bit signed)                          │
        │    ↓ (v_mem ≥ θ_S0=16) ?  ★ LIF NON-LINEARITY ★      │
        │  spike_this_t[j] ∈ {0,1}      ← 1-bit; v_mem hidden   │
        │                                                        │
        └────────────────────┬───────────────────────────────────┘
                             │ stream_buffer_A[t][j] (1-bit/neuron)
                             │ stage_in_src = STREAM_A
                             ▼
        ┌─────────── Stage 1 (in=64, out=10, θ=8) ─────────────┐
        │  WL_in = stream_A[t][j]      ← post-LIF spike, 1-bit │
        │    ↓ CIM MAC                              ── linear   │
        │  partial_sum                                          │
        │    ↓ membrane accumulate                  ── linear   │
        │  v_mem[t][k]                                          │
        │    ↓ (v_mem ≥ θ_S1=8) ?   ★ LIF NON-LINEARITY ★      │
        │  spike_this_t[k] ∈ {0,1} → stream_buffer_B            │
        └────────────────────┬───────────────────────────────────┘
                             │
                             ▼
                   count over T=64 → argmax → predicted class
```

Two activations in series (one per stage). Functionally equivalent to a 2-layer MLP with hard-step activation, but realized for free by the spiking neuron model.

---

## 3. RTL evidence chain

All citations are against `v2` branch HEAD `3e8905c0` (sister commits on `feature/v2-fpga-e203` `ae377d3c` and `feature/v2-arm-fpga-demo` `bd860dcc` are byte-identical for these files).

### 3.1 Stage 1 reads stage 0's spike, not membrane

**File**: `rtl/snn/stage_engine_v2.sv` lines 355–366

```sv
case (cfg_input_src)
  V2B_BUF_SEL_INPUT_SRAM:  wl_latched <= isr_rd_data;                       // stage 0 path
  V2B_BUF_SEL_STREAM_A:    wl_latched <= { {(P_N_IN-P_N_OUT){1'b0}}, sbA_rd_data };  // stage 1 ← stage 0 SPIKE
  V2B_BUF_SEL_STREAM_B:    wl_latched <= { {(P_N_IN-P_N_OUT){1'b0}}, sbB_rd_data };
  default:                 wl_latched <= '0;
endcase
```

`sbA_rd_data` is the read port of `stream_buffer_v2` instance A. Its data width is `P_N_OUT-1:0` (1 bit per output neuron per timestep). Zero-padded to fill the wider `P_N_IN` WL bus.

### 3.2 LIF threshold compare is the activation

**File**: `rtl/snn/stage_engine_v2.sv` line 394 (tile_mode=0 path, used by Fashion-14×14)

```sv
if ((membrane[j_idx] + mac_diff_used) >= cfg_threshold) begin
    spike_this_t[j_idx] <= 1'b1;                               // ── fire spike ──
    membrane[j_idx]    <= membrane[j_idx] + mac_diff_used      // ── soft reset ──
                          - cfg_threshold;
end else begin
    spike_this_t[j_idx] <= 1'b0;                               // ── no spike ──
    membrane[j_idx]    <= membrane[j_idx] + mac_diff_used;     // ── accumulate only ──
end
```

The `(membrane ≥ threshold) ? 1 : 0` step function is exactly the Heaviside non-linearity. `spike_this_t` is a `P_N_OUT`-wide bit-vector where each bit represents one neuron's binary output.

### 3.3 Stream buffer stores only 1-bit binary spike

**File**: `rtl/snn/stream_buffer_v2.sv` lines 32–46

```sv
parameter int P_DEPTH = V2B_MAX_TIMESTEPS,     // 256 timesteps
parameter int P_WIDTH = V2B_MAX_OUT_NEURONS    // 128 neurons (1 bit each)
...
input  logic [P_WIDTH-1:0] wr_data,
output logic [P_WIDTH-1:0] rd_data,
```

The buffer's element type is `[P_WIDTH-1:0]` = 128-bit row, where bit *j* is neuron *j*'s spike at the row's timestep. **There is no width to store membrane potential** — even if a designer wanted to leak `v_mem`, the buffer port is too narrow to carry the 16-bit-signed membrane value.

### 3.4 Stage engine writes spike (post-LIF) to stream buffer

**File**: `rtl/snn/stage_engine_v2.sv` lines 411–415, 463–467

```sv
// S_WRITE_SPIKE state (after LIF compare in the same timestep)
if (cfg_output_dst == V2B_BUF_SEL_STREAM_A) begin
    sbA_wr_en   <= 1'b1;
    sbA_wr_addr <= t_idx;
    sbA_wr_data <= spike_this_t;       // ← writes BINARY SPIKE, not membrane
end
```

The write payload is `spike_this_t`, which is set to 0/1 by the LIF compare immediately above (line 394). Membrane is **not** routed to any external port.

### 3.5 Membrane is module-local, never exported

**File**: `rtl/snn/stage_engine_v2.sv` line 141

```sv
logic signed [P_MEM_W-1:0]  membrane [0:P_N_OUT-1];   // local variable, no output port
```

The module's external port list (lines ~50–105) declares only:
- Configuration inputs (`cfg_*`)
- Input-stream-SRAM read interface
- Stream-buffer A/B read & write interfaces
- Tile-partial-buf read & write interfaces
- Status outputs: `busy`, `done_pulse`, `err_code[7:0]`, `debug_t_idx`

`membrane` does not appear among them. `grep -n "output.*membrane\|assign.*membrane\b" rtl/snn/stage_engine_v2.sv` returns **zero hits** — every `membrane[]` reference is either a reset (`<= '0`) or an LIF-compare-or-accumulate update (lines 394/396/399, 441/443/446).

### 3.6 Tile-mode-1 partial path also routes through LIF

In tile_mode=1, partial sums are spread across multiple MAC tiles. The natural worry: does this leak partial_sum past the activation?

**File**: `rtl/snn/stage_engine_v2.sv` line 441 (`S_FINAL_LIF` state)

```sv
// In S_FINAL_LIF (only entered when cfg_tile_mode && cfg_is_tile_final):
if ((membrane[j_idx] + tpb_rd_data) >= cfg_threshold) begin
    spike_this_t[j_idx] <= 1'b1;
    membrane[j_idx]    <= membrane[j_idx] + tpb_rd_data - cfg_threshold;
end else begin
    spike_this_t[j_idx] <= 1'b0;
    membrane[j_idx]    <= membrane[j_idx] + tpb_rd_data;
end
```

Even when partial sums are read back from `tile_partial_buf` (`tpb_rd_data`, 14-bit signed), they go through **the same threshold compare** before any write to `stream_buffer_A/B`. The tile mode is a way to spread one neuron's MAC across multiple DRAM-style tiles, not a way to skip activation.

### 3.7 Software orchestration agrees

**File**: `fw/src/v2b_scheduler.c` `v2b_infer_resident_14x14()`

```c
// Step 3: stage 0 — input from INPUT_SRAM, output to STREAM_A
v2b_run_stage(196, 64, S0_THRESHOLD=16, ...,
              V2B_SOC_BUF_SEL_INPUT_SRAM,        // src = pixel-encoded spike train
              V2B_SOC_BUF_SEL_STREAM_A);          // dst = stage 0's SPIKE output

// Step 4: stage 1 — input from STREAM_A (= stage 0 spike), output to STREAM_B
v2b_run_stage(64, 10, S1_THRESHOLD=8, ...,
              V2B_SOC_BUF_SEL_STREAM_A,           // src = stage 0's SPIKE
              V2B_SOC_BUF_SEL_STREAM_B);
```

The scheduler's Step 3 → Step 4 hand-off uses STREAM_A as the connector, which is the same buffer that §3.3–3.4 proved holds only 1-bit binary spikes. Software does not have an alternate "leak membrane" register-map path because the V2.B SoC top exposes only `INPUT_SRAM`, `STREAM_A`, `STREAM_B` as buffer choices (`v2b_soc_regs.h` `V2B_SOC_BUF_SEL_*`).

---

## 4. What if we *did* add a separate activation function?

It would be wasted silicon:

| What you could add | Why it's redundant |
|---|---|
| ReLU between stages | LIF is strictly stronger than ReLU (ReLU = `max(0, x)`, LIF = `(x ≥ θ) ? 1 : 0`). Adding ReLU on top of LIF saturates at the same `(0, 1)` output. |
| Sigmoid / tanh | Hard threshold already breaks linearity. Smooth activations are useful for *gradient flow during training*, but training happens in PyTorch with surrogate gradients (e.g., fast-sigmoid). Hardware uses hard threshold. |
| BatchNorm-style scaling | LIF's `θ` parameter is per-stage configurable (`S0_THRESHOLD=16`, `S1_THRESHOLD=8`), serving as a scale knob. Membrane decay `β` (set to 1 for soft-reset, no decay) is another knob. |
| Sub-LSB quantization | Spike output is already 1-bit, the strongest possible quantization; further compression is a no-op. |

The only thing a separate activation buys you is *gradient differentiability for end-to-end training*, which is solved at the Python/training-time layer (`torch.surrogate.fast_sigmoid` or similar) and does not require runtime hardware support.

---

## 5. Paper §method snippet (drop-in)

> **Activation function.** The V2.B accelerator does not instantiate a dedicated activation function unit between stages. Each LIF neuron's threshold-compare-and-spike mechanism — `(v_mem[t,j] ≥ θ) ? 1 : 0`, implemented in `stage_engine_v2.sv:394` — provides the inter-stage non-linearity directly. Stage *k*'s binary spike output `spike_this_t ∈ {0, 1}^N_out` is the only connection to stage *k+1*'s WL input via the `stream_buffer_v2` module (1-bit per neuron per timestep, `stream_buffer_v2.sv:33`). Membrane potential is local to each stage's `stage_engine_v2` module and is not exported through any port. This eliminates the dedicated multipliers, lookup tables, or comparator trees that ANN activation functions require, while preserving full multi-layer non-linear representational power. The architecture is verified bit-exact in simulation against a Python reference (`tb/fw_cosim_resident_14x14_tb.sv`) and on ZCU102 hardware (10×10 = 100 spike counts byte-exact, evidence tags `v2-fpga-e203-passed` and `v2-arm-fpga-demo-v2-passed`).

---

## 6. Cross-references

- RTL: `rtl/snn/stage_engine_v2.sv:362, 394, 411, 441, 463`
- RTL: `rtl/snn/stream_buffer_v2.sv:33, 41, 46`
- RTL: `rtl/snn/tile_partial_buf.sv:38–57`
- Firmware: `fw/src/v2b_scheduler.c` (`v2b_infer_resident_14x14`)
- Headers: `fw/include/v2b_soc_regs.h` (`V2B_SOC_BUF_SEL_*`)
- TB regression: `tb/fw_cosim_resident_14x14_tb.sv` (10/10 sample bit-exact)
- TB regression (permanent gate, 2026-04-25): `tb/v2b_partial_write_invariant_tb.sv` (byte-mask invariant)
- Sister commits: `v2 @ 3e8905c0`, `feature/v2-fpga-e203 @ ae377d3c`, `feature/v2-arm-fpga-demo @ bd860dcc`
- Anchor tag: `v2-permanent-gate-2026-04-25`

---

## 7. Open extensions (not in V1 silicon scope)

- **Configurable membrane decay β**: currently hard `β=1` (soft-reset, no decay). Adding a programmable β would give "leaky" behavior used in some neuromorphic literature. Cost: one multiplier per stage_engine.
- **Per-channel θ**: currently scalar `cfg_threshold` shared across all neurons in a stage. Heterogeneous thresholds would require a small SRAM and a read port. Useful for class-balance correction.
- **Surrogate gradient on-chip**: not in V1 scope. Inference-only hardware never needs it.

These are listed for completeness; they are not blockers for the current paper claim about non-linearity sufficiency.
