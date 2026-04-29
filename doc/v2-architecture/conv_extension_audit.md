# V2.B CONV Extension M0 RTL Audit

M0 audit scope: inspect existing RTL structure for reuse feasibility before any
functional RTL is written.

Branch/worktree audited: `feature/v2-conv-extension` linked worktree at
`C:\tmp\v2-conv-extension`, based on `v2 @ c479c1d0`.

Files inspected:

- `rtl/snn/tile_partial_buf.sv`
- `rtl/snn/stage_engine_v2.sv`
- `rtl/top/snn_soc_pkg.sv`
- `rtl/top/snn_soc_v2b_top.sv`
- `rtl/snn/cim_mac_behavioral_v2.sv`
- `tb/v2b_partial_write_invariant_tb.sv`
- `doc/19_phase_d_synthesis_readiness.md`

Repo note: `rtl/top/v2b_axi_wrapper.sv` is referenced by REV 4 but is not
present in this audited v2 worktree. The current V2.B local register bank lives
inside `rtl/top/snn_soc_v2b_top.sv`.

## Audit-1: `rtl/snn/tile_partial_buf.sv`

### Question

Can the current buffer save partial sums across CONV tiles as:

```text
partial_sum[t][out_neuron]
```

for all V2.B timesteps and output neurons?

### Current Structure

The module parameters are already tied to V2.B limits:

```text
P_DEPTH = V2B_MAX_TIMESTEPS       = 256
P_WIDTH = V2B_MAX_OUT_NEURONS     = 128
P_CELL  = V2B_PARTIAL_WIDTH       = 14
```

Relevant source references:

- `tile_partial_buf.sv:32-33`: capacity comment explicitly states
  `256 * 128 * 14 = 458752 bit`, about 56 KiB.
- `tile_partial_buf.sv:38-40`: parameters bind depth/width/cell to V2.B maxes.
- `tile_partial_buf.sv:60-70`: storage is a flat one-dimensional memory with
  `P_TOTAL = P_DEPTH * P_WIDTH`.
- `tile_partial_buf.sv:73-76`: `flat_addr(t,j) = t * P_WIDTH + j`.
- `tile_partial_buf.sv:113-114`: accumulation writes
  `mem[flat_addr(wr_t,wr_j)] += wr_diff`.
- `tile_partial_buf.sv:137-138`: synchronous read returns
  `mem[flat_addr(rd_t,rd_j)]`.

The logical shape is therefore already `[t][out_neuron]`.

### Capacity Check

Required by plan:

```text
V2B_MAX_TIMESTEPS * V2B_MAX_OUT_NEURONS * V2B_PARTIAL_WIDTH
= 256 * 128 * 14
= 458752 bits
= 57344 bytes
= 56 KiB
```

Current implementation provides exactly that capacity.

No expansion is required for the planned V2.B CONV max:

```text
KKC <= 1152
C_out <= 128
T_count <= 256
weight in [-7,+7]
```

### Interface Fit

Current write/accumulate port:

```systemverilog
acc_en
wr_t
wr_j
wr_diff
```

Current read port:

```systemverilog
rd_en
rd_t
rd_j
rd_data
```

`stage_engine_v2` already drives these ports in tile mode:

- nonfinal tiles: `S_NEURON_LOOP` accumulates MAC diff into TPB;
- final tile: after all timesteps, `S_FINAL_LIF` / `S_FINAL_READ` /
  `S_FINAL_NEURON` sweeps TPB and performs LIF.

For CONV, `conv_ctrl_v2` does not need a new direct TPB interface if it starts
`stage_engine_v2` once per tile with:

```text
cfg_tile_mode = 1
cfg_is_tile_final = (tile_idx == tile_count-1)
cfg_in_dim = valid_count
cfg_out_dim = C_out
```

### Clear Behavior

The only caveat is clear latency:

- simulation path clears the whole memory in one cycle;
- synthesis path uses a counter walker and requires `P_TOTAL` cycles.

Source references:

- `tile_partial_buf.sv:80-84`: synthesis contract says firmware must wait
  `P_TOTAL` cycles after `clear_all`;
- `tile_partial_buf.sv:94-101`: clear walker starts and stops;
- `tile_partial_buf.sv:111-114`: clear has priority over accumulation.

CONV control must therefore treat TPB clear as a real operation before the first
tile of each output pixel. M3 can implement this either by:

- exposing TPB clear-busy to `conv_ctrl_v2`; or
- conservatively waiting `P_TOTAL` cycles after clear in synthesis; or
- using an implementation-specific faster clear if the buffer is later
  refactored.

This is not a capacity blocker.

### Conclusion

Audit-1 conclusion: `tile_partial_buf` can be directly reused.

Conditions:

- `P_ENABLE_TILE_BUF` must be enabled for CONV builds.
- `conv_ctrl_v2` must clear the buffer before tile 0 of each output pixel.
- M3 must honor synthesis clear latency or expose a clear-done handshake.

No buffer expansion and no t-major execution rewrite is required for V2.B REV 4.

## Audit-2: `rtl/snn/stage_engine_v2.sv`

### Question

Can dynamic WL ready-valid stall be inserted without degrading FC timing?

### Current Timestep Loop

The current FSM has the relevant states:

```text
S_READ_WL   = 5'd3
S_MAC_WAIT  = 5'd4
S_MAC_LATCH = 5'd5
S_MAC_KICK  = 5'd6
S_MAC_RUN   = 5'd7
S_NEURON_LOOP
S_NEXT_T
```

Source references:

- `stage_engine_v2.sv:118-132`: state enum.
- `stage_engine_v2.sv:223-225`: `S_READ_WL -> S_MAC_WAIT -> S_MAC_LATCH`.
- `stage_engine_v2.sv:328-345`: `S_READ_WL` pulses existing source read enables.
- `stage_engine_v2.sv:347-350`: `S_MAC_WAIT` accounts for synchronous read latency.
- `stage_engine_v2.sv:353-367`: `S_MAC_LATCH` captures `wl_latched`.
- `stage_engine_v2.sv:405-424`: `S_NEXT_T` writes spike output and advances `t_idx`.

The current stall insertion point is therefore exactly after `S_READ_WL` and
before `S_MAC_KICK`, with `S_MAC_WAIT/S_MAC_LATCH` as the latency boundary.

### Proposed Dynamic Insertion Strategy

For FC sources:

```text
S_READ_WL -> S_MAC_WAIT -> S_MAC_LATCH -> S_MAC_KICK
```

remains unchanged.

For dynamic sources:

```text
S_READ_WL
  assert dyn_wl_req_valid(t_idx)
  wait until dyn_wl_req_ready
  wait until dyn_wl_resp_valid
  latch dyn_wl_resp_data into wl_latched
  then S_MAC_KICK
```

During dynamic wait:

- `t_idx` is stable;
- `j_idx` is stable or reset to zero before MAC;
- `mac_start=0`;
- `tpb_acc_en=0`;
- `sbA_wr_en=0`;
- `sbB_wr_en=0`;
- `spike_out_valid=0`;
- membrane does not update.

This preserves the current FC path because all new wait behavior is gated by:

```text
cfg_conv_mode == 1
cfg_input_src in {PATCH_UNROLLER, FMAP_FLATTEN}
```

### Current Interface Gaps

Two implementation details must be resolved in M3.

First, current `cfg_input_src` is only 2-bit:

- `stage_engine_v2.sv:61`: `input logic [1:0] cfg_input_src`
- `snn_soc_v2b_top.sv:152`: `logic [1:0] reg_cfg_input_src`
- `snn_soc_pkg.sv` currently defines four 2-bit source/destination values.

REV 4 needs at least five conceptual input sources:

```text
INPUT_SRAM
STREAM_A
STREAM_B
PATCH_UNROLLER
FMAP_FLATTEN
```

M3 must widen the input selector to at least 3 bits or add an equivalent
conv-only dynamic-source selector. `cfg_output_dst` can remain 2-bit.

Second, current config-conflict check compares `cfg_input_src` and
`cfg_output_dst` directly:

- `stage_engine_v2.sv:199-205`: `config_ok`;
- `stage_engine_v2.sv:294-306`: sequential reject path.

After widening or separating dynamic source selection, the conflict check must
remain meaningful for FC sources and must not reject dynamic input sources just
because their enum overlaps output-destination values.

### FC Non-Degradation Argument

The current FC source behavior is self-contained:

- `INPUT_SRAM` drives `isr_rd_en/isr_rd_addr`;
- `STREAM_A` drives `sbA_rd_en/sbA_rd_addr`;
- `STREAM_B` drives `sbB_rd_en/sbB_rd_addr`;
- `S_MAC_LATCH` captures the same data into `wl_latched`.

If M3 keeps that code path byte-identical under `cfg_conv_mode=0`, the existing
V2 gates should not degrade.

Required M3 guardrails:

- assertion that `cfg_conv_mode==0` never asserts dynamic WL request;
- assertion that FC `wl_latched` is only sourced from existing FC buffers;
- regression of all existing V2 gates;
- byte-byte comparison against `v2` for FC-mode traces where practical.

### Stage Conclusion

Audit-2 conclusion: FC-nondegrading stall insertion is feasible.

The insertion strategy is:

- add dynamic WL wait only on dynamic input sources;
- hold timestep/MAC/LIF state while waiting;
- keep current FC `S_READ_WL/S_MAC_WAIT/S_MAC_LATCH` sequence unchanged;
- widen or separate input-source selection in M3;
- update conflict validation accordingly.

No pre-M3 RTL edit is required in M0.

## Audit-3: FPGA-Only Resource Scope

### Scope Decision

The user has explicitly frozen scope as:

```text
simulation + ZCU102 FPGA evidence extension
```

Not in scope:

- ASIC SRAM macro selection;
- ASIC area/power/timing signoff;
- tapeout baseline claim.

Docs and paper language must say FPGA prototype/evidence extension.

### ZCU102 BRAM Budget

Plan REV 4 states:

```text
ZCU102 BRAM ~= 32.1 Mb ~= 4 MiB
fmap_sram = 512 KiB total = 4 Mb
fmap_sram utilization ~= 12.5%
```

The current local synthesis-readiness doc also records a ZCU102/xczu9eg budget:

- `doc/19_phase_d_synthesis_readiness.md:33`: post-synth resource context for
  ZCU102 / xczu9eg;
- `doc/19_phase_d_synthesis_readiness.md:43`: current weight memories map to
  `168 RAMB18 + 84 RAMB36 = 252 BRAM`;
- `doc/19_phase_d_synthesis_readiness.md:51`: `252` BRAM tiles out of `912`,
  about `27.6%`;
- `doc/19_phase_d_synthesis_readiness.md:50`: current input/stream/tile buffers
  use distributed LUTRAM and are under 1% LUT impact;
- `doc/19_phase_d_synthesis_readiness.md:85`: ZCU102 target is
  `xczu9eg-ffvb1156-2-e @ 50 MHz`.

The CONV fmap SRAM adds:

```text
A bank = 256 KiB = 2 Mb
B bank = 256 KiB = 2 Mb
Total  = 512 KiB = 4 Mb
```

Approximate BRAM36 count:

```text
4 Mb / 36 Kb ~= 114 BRAM36
```

Against 912 BRAM36-equivalent blocks, this is about 12.5%.

Existing post-synth BRAM estimate plus fmap:

```text
existing weight BRAM ~= 252 / 912 = 27.6%
new fmap BRAM       ~= 114 / 912 = 12.5%
combined rough      ~= 366 / 912 = 40.1%
```

This leaves meaningful ZCU102 headroom for control logic, E203/ARM integration,
and future evidence builds.

### Existing Buffer Resource Context

Current `tile_partial_buf`, `input_stream_sram`, and stream buffers are not the
dominant BRAM consumers in the latest local synthesis note:

- `tile_partial_buf` maps to `RAM64M8 x 2048` distributed LUTRAM;
- input stream and stream buffers also map to distributed LUTRAM;
- the current note says this impact is under 1% LUT.

The new fmap SRAM should be implemented as true block RAM because it is large,
word-addressed, and does not need one-cycle RMW over `[t][j]`.

### Audit-3 Conclusion

Audit-3 conclusion: FPGA-only resource scope is acceptable and frozen.

The M3 resource target is:

- A/B fmap SRAM: 512 KiB total;
- about 12.5% of ZCU102 block RAM;
- combined rough BRAM use about 40% with current weight-memory mapping;
- no ASIC claim.

## Overall M0 Audit Conclusion

No stop condition was hit.

Summary:

| Audit | Conclusion |
|---|---|
| `tile_partial_buf` | Can directly reuse for `[t][out_neuron]` partial sums. |
| `stage_engine_v2` | Dynamic WL stall insertion is feasible at `S_READ_WL`/`S_MAC_WAIT` boundary without FC degradation if gated by dynamic source. |
| FPGA scope | A/B 256 KiB fmap SRAM is acceptable for ZCU102 FPGA evidence; ASIC signoff is out of scope. |

High-risk items for Claude review:

1. Resolve register ownership/map consistency: `MAC_W_LOAD_*` offset discrepancy
   plus whether M3 adds `rtl/top/v2b_axi_wrapper.sv` or extends the current
   `snn_soc_v2b_top.sv` simple-bus register bank.
2. Approve the `cfg_input_src` widening or equivalent conv-only source selector.
3. Decide how `conv_ctrl_v2` observes or waits for `tile_partial_buf` synthesis
   clear completion.
