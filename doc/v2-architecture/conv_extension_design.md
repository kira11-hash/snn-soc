# V2.B CONV Extension Design Freeze

M0 deliverable for `feature/v2-conv-extension`.

Scope: architecture and interface freeze only. This document intentionally does
not prescribe any functional RTL edits beyond future insertion points, SVA
contracts, and configuration semantics.

Source of truth: `C:\Users\24201\.claude\plans\d1-d3-idempotent-umbrella.md`,
REV 4, read on 2026-04-30. All D1-D18 decisions remain frozen.

Frozen tags are not moved:

- `v2-fpga-e203-passed @ e696dc39`
- `v2-arm-fpga-demo-v2-passed @ 03a39a61`
- `v2-permanent-gate-2026-04-25`

Permanent gate: `tb/v2b_partial_write_invariant_tb.sv` remains mandatory.

## 1. Overview

The V2.B CONV extension adds runtime-configurable CONV and CONV-to-FC
flatten stages to the existing V2.B streamed-rate SNN accelerator. The extension
follows route B from the plan: hardware patch unroller plus fmap SRAM, not
software im2col.

The existing FC path is the baseline and remains byte-level stable when
`CONV_MODE=0`. In that mode:

- `stage_engine_v2` uses the existing input sources only:
  `INPUT_SRAM`, `STREAM_A`, or `STREAM_B`.
- dynamic WL request signals are held inactive.
- fmap SRAM, patch unroller, fmap flatten reader, and `conv_ctrl_v2` are
  bypassed.
- the existing nine V2 simulation gates remain the regression guard.
- `tb/v2b_partial_write_invariant_tb.sv` continues to guard byte-mask behavior.

Runtime configurability means firmware can select, per stage:

- FC mode: the current V2.B streamed-rate path.
- CONV mode: patch unroller provides one 256-bit WL mask per timestep.
- FLATTEN mode: fmap flatten reader provides row-major 256-bit WL masks for
  CONV-to-FC transitions.

The CONV extension is additive:

- New modules in M3: `fmap_sram_v2`, `patch_unroller_v2`,
  `fmap_flatten_reader_v2`, and `conv_ctrl_v2`.
- Existing `stage_engine_v2` is reused as the MAC/LIF engine.
- Existing `tile_partial_buf` is reused for cross-tile partial sums.
- Existing `MAC_W_LOAD_*` path is reused for weights; no new weight-load
  register is added.

Execution model:

1. Firmware configures one layer and loads the input fmap if this is the first
   CONV layer.
2. `conv_ctrl_v2` validates the configuration before any MAC work.
3. For each spatial point and tile, `conv_ctrl_v2` requests the matching weight
   tile from firmware.
4. Firmware loads the tile through the existing MAC weight-load registers and
   pulses `CONV_CTRL.WEIGHT_READY`.
5. `conv_ctrl_v2` starts one `stage_engine_v2` run for that `(h,w,tile_idx)`.
6. During the timestep loop, `stage_engine_v2` requests a dynamic WL mask from
   the selected reader.
7. The final tile performs LIF and emits `spike_out_*`.
8. The CONV packer writes spikes back to fmap SRAM using the 32-bit padded
   layout in section 3.

Non-goals for V2.B REV 4:

- no ASIC/tapeout signoff;
- no residual/add/pooling operators;
- no FC-to-CONV chain;
- no weight-stationary optimization;
- no new weight-load register path;
- no widening of `V2B_PARTIAL_WIDTH`.

M0 audit note: current repo `rtl/top/snn_soc_v2b_top.sv` defines
`MAC_W_LOAD_ADDR/DATA/CTRL` at `0x050/0x054/0x058`, while REV 4 plan text names
`0x048/0x04C/0x050`. The frozen architectural decision is semantic reuse of the
existing `MAC_W_LOAD_*` path, not addition of a second path. Claude review must
pick the canonical offset set before M3 RTL/FW edits.

## 2. Dynamic WL Ready-Valid Protocol

### 2.1 Signal Definitions

The dynamic WL interface is used only when `cfg_conv_mode=1` and
`cfg_input_src` selects `PATCH_UNROLLER` or `FMAP_FLATTEN`.

| Signal | Direction from `stage_engine_v2` | Width | Meaning |
|---|---:|---:|---|
| `dyn_wl_req_valid` | output | 1 | Stage engine requests the WL mask for the current timestep. |
| `dyn_wl_req_ready` | input | 1 | Selected reader can accept the request. |
| `dyn_wl_req_timestep` | output | `$clog2(V2B_MAX_TIMESTEPS)` | Timestep index requested by the stage engine. |
| `dyn_wl_resp_valid` | input | 1 | Selected reader returns a valid WL response. |
| `dyn_wl_resp_ready` | output | 1 | Stage engine can accept the response. |
| `dyn_wl_resp_data` | input | 256 | WL bits for lanes 0..255. |
| `dyn_wl_resp_valid_count` | input | 9 | Number of active lanes, range 1..256. |

`dyn_wl_resp_valid_count` is a count, not a mask. The value 256 is represented
as 9-bit `9'd256`; `0` is illegal.

M3 interface-width note: current `stage_engine_v2.sv` has a 2-bit
`cfg_input_src` port, and current `snn_soc_pkg.sv` consumes the four 2-bit
encodings. M3 must widen the input-source selector to at least 3 bits or add an
equivalent conv-only source selector. `cfg_output_dst` can stay 2-bit.

### 2.2 Source Selection

Source behavior:

| Mode | `cfg_conv_mode` | `cfg_flatten_mode` | Dynamic source | Reader selected |
|---|---:|---:|---|---|
| FC | 0 | ignored | disabled | none |
| CONV | 1 | 0 | enabled | `patch_unroller_v2` |
| FLATTEN-FC | 1 | 1 | enabled | `fmap_flatten_reader_v2` |

In FC mode, dynamic readers observe `req_valid=0`. Their responses are ignored.

In CONV mode, only patch-unroller receives `req_valid`.

In FLATTEN-FC mode, only fmap-flatten-reader receives `req_valid`.

Top-level mux contract:

```systemverilog
patch_req_valid = dyn_wl_req_valid && cfg_input_src == BUF_SEL_PATCH_UNROLLER;
flat_req_valid  = dyn_wl_req_valid && cfg_input_src == BUF_SEL_FMAP_FLATTEN;

stage_resp_valid =
    patch_selected ? patch_resp_valid :
    flat_selected  ? flat_resp_valid  :
                     1'b0;
```

The unselected reader must see `req_valid=0`, and unselected response signals
must not affect `stage_engine_v2`.

### 2.3 Timing

ASCII timing for a selected dynamic reader:

```text
clk                 0     1     2     3     4     5     6
stage state         READ  WAIT  WAIT  LATCH KICK  RUN   ...
t_idx               t     t     t     t     t     t     ...
req_valid           1     1     0     0     0     0
req_ready           0     1     0     0     0     0
req_timestep        t     t     x     x     x     x
reader work         -     accept gather gather done -
resp_valid          0     0     0     1     0     0
resp_ready          1     1     1     1     0     0
resp_data           x     x     x     WL[t] x     x
wl_latched          old   old   old   WL[t] WL[t] WL[t]
mac_start           0     0     0     0     1     0
```

The reader must return the response at least one cycle after the accepted
request. Same-cycle request-to-response is forbidden to prevent a combinational
loop through top-level muxing.

### 2.4 Stall Semantics

When a dynamic source is selected and the request or response is not complete:

- `t_idx` / `debug_t_idx` does not advance.
- `mac_start` remains low.
- `wl_latched` remains stable.
- `tpb_acc_en` remains low.
- stream-buffer write enables remain low.
- LIF membrane registers do not update.
- `spike_out_valid` remains low.

The existing FC synchronous SRAM path remains unchanged:

- `S_READ_WL` pulses the existing read enable.
- `S_MAC_WAIT` accounts for one-cycle SRAM read latency.
- `S_MAC_LATCH` captures the existing `isr_rd_data`, `sbA_rd_data`, or
  `sbB_rd_data`.

Dynamic reader insertion point:

- current state enum in `stage_engine_v2.sv` has `S_READ_WL=5'd3`,
  `S_MAC_WAIT=5'd4`, and `S_MAC_LATCH=5'd5`;
- dynamic request acceptance happens in or immediately after `S_READ_WL`;
- dynamic response capture replaces the existing SRAM latch only for dynamic
  sources;
- FC sources keep the current state sequence.

### 2.5 Interface-Level SVA List

These properties are duplicated and expanded in
`doc/v2-architecture/conv_extension_sva.md`.

```systemverilog
// SVA_DYN_WL_FC_NO_REQ
assert property (@(posedge clk) disable iff (!rst_n)
  (cfg_conv_mode == 1'b0) |-> (dyn_wl_req_valid == 1'b0));
```

```systemverilog
// SVA_DYN_WL_STALL_FREEZE_TIMESTEP
assert property (@(posedge clk) disable iff (!rst_n)
  (dyn_wl_req_valid && !dyn_wl_req_ready)
  |=> (t_idx == $past(t_idx)));
```

```systemverilog
// SVA_DYN_WL_STALL_NO_MAC
assert property (@(posedge clk) disable iff (!rst_n)
  (dynamic_source_active && dyn_waiting)
  |-> (!mac_start && !tpb_acc_en && !sbA_wr_en && !sbB_wr_en));
```

```systemverilog
// SVA_DYN_WL_RESP_COUNT_RANGE
assert property (@(posedge clk) disable iff (!rst_n)
  dyn_wl_resp_valid |-> (dyn_wl_resp_valid_count inside {[9'd1:9'd256]}));
```

```systemverilog
// SVA_DYN_WL_UNSELECTED_PATCH_REQ_ZERO
assert property (@(posedge clk) disable iff (!rst_n)
  (cfg_input_src != BUF_SEL_PATCH_UNROLLER) |-> !patch_req_valid);
```

```systemverilog
// SVA_DYN_WL_UNSELECTED_FLAT_REQ_ZERO
assert property (@(posedge clk) disable iff (!rst_n)
  (cfg_input_src != BUF_SEL_FMAP_FLATTEN) |-> !flat_req_valid);
```

```systemverilog
// SVA_DYN_WL_NO_SAME_CYCLE_RESP
assert property (@(posedge clk) disable iff (!rst_n)
  (dyn_wl_req_valid && dyn_wl_req_ready)
  |-> !dyn_wl_resp_valid);
```

```systemverilog
// SVA_DYN_WL_RESP_STABLE_UNTIL_READY
assert property (@(posedge clk) disable iff (!rst_n)
  (dyn_wl_resp_valid && !dyn_wl_resp_ready)
  |=> $stable({dyn_wl_resp_data, dyn_wl_resp_valid_count}));
```

## 3. 32-bit Padded Fmap Layout

### 3.1 Formula

Logical fmap bit:

```text
spike[h][w][c][t] in {0,1}
```

Physical storage:

```text
stream_words  = ceil(T_count / 32)
              = (T_count + 31) >> 5
T_stride_bits = stream_words * 32
linear_stream = (h * W + w) * C + c
word_addr     = base_word + linear_stream * stream_words + (t >> 5)
bit_idx       = t & 31
```

Equivalent single-line formula:

```text
word_addr = base_word + ((h*W+w)*C+c)*stream_words + (t>>5)
bit_idx   = t & 31
```

Capacity check:

```text
fmap_size_words = H * W * C * stream_words
fmap_size_words <= bank_words
bank_words = 65536  // 256 KiB / 4 bytes
```

Examples:

| Network class | `T_count` | `stream_words` | Physical stream bits |
|---|---:|---:|---:|
| LeNet | 10 | 1 | 32 |
| CIFAR | 64 | 2 | 64 |
| max V2.B | 256 | 8 | 256 |

Padding bits where `t >= T_count` are not valid spikes. Writers must write them
as zero. Readers must ignore them.

### 3.2 Shared Writers and Readers

All participants use the exact same address formula:

- firmware input-fmap initializer;
- `conv_ctrl_v2` fmap writeback packer;
- Python integer reference;
- `patch_unroller_v2`;
- `fmap_flatten_reader_v2`.

No component may use a bit-packed arbitrary-T layout.

### 3.3 Pack Operation

Pseudocode:

```text
word = fmap_sram[word_addr]
if spike:
  word[bit_idx] = 1
else:
  word[bit_idx] = 0
fmap_sram[word_addr] = word
```

For hardware packer writes, a small pixel-local buffer is allowed:

```text
pixel_word_buf[c][stream_word_idx][31:0]
```

The packer fills all `c < C_out`, zeros all `c >= C_out`, and writes words in
row-major order after the current output pixel finishes its timestep loop.

### 3.4 Gather Operation

For a requested timestep `t`, both readers compute:

```text
word = fmap_sram[word_addr]
lane_bit = word[bit_idx]
```

The returned lane is zero when:

- the spatial coordinate is outside the source image after padding;
- `lane >= dyn_wl_resp_valid_count`;
- the logical index is outside the full input dimension;
- `t >= T_count` by illegal or malformed caller behavior.

### 3.5 Network Capacity

LeNet-5:

```text
Conv1 out = 28*28*6*1 words = 4704 words = 18.375 KiB
Conv2 out = 12*12*16*1 words = 2304 words = 9 KiB
```

Tiny VGG:

```text
Conv1 out = 32*32*16*2 words = 32768 words = 128 KiB
Conv4 out = 8*8*64*2 words = 8192 words = 32 KiB
```

Plain-CNN-4:

```text
Conv1 out = 32*32*32*2 words = 65536 words = 256 KiB
Conv4 out = 8*8*96*2 words = 12288 words = 48 KiB
```

The maximum planned fmap exactly fills one 256 KiB bank and must pass
`base_word + fmap_size_words <= 65536`.

### 3.6 Layout SVA

```systemverilog
// SVA_FMAP_ADDR_IN_BANK
assert property (@(posedge clk) disable iff (!rst_n)
  fmap_rd_en |-> (fmap_rd_word_addr < 16'd65536));
```

```systemverilog
// SVA_FMAP_PADDING_ZERO_WRITE
assert property (@(posedge clk) disable iff (!rst_n)
  packer_wr_en && (packer_t >= cfg_T_count) |-> (packer_wr_bit == 1'b0));
```

```systemverilog
// SVA_FMAP_STREAM_WORDS_RANGE
assert property (@(posedge clk) disable iff (!rst_n)
  cfg_valid |-> (stream_words inside {[4'd1:4'd8]}));
```

## 4. Weight Tile Layout and Loading

### 4.1 Logical Layout

The exporter emits:

```text
weight_tile[tile_idx][lane][out_c]
```

Each logical weight is signed 4-bit and must be clamped to:

```text
[-7, +7]
```

CONV logical index:

```text
conv_idx = (ky*K + kx)*C_in + c
tile_idx = conv_idx / 256
lane     = conv_idx % 256
```

FLATTEN logical index:

```text
flat_idx = (h*W + w)*C + c
tile_idx = flat_idx / 256
lane     = flat_idx % 256
```

For `lane >= valid_count`, exporter writes zero, reader returns zero, and MAC
must not consume the lane because `cfg_in_dim == valid_count`.

### 4.2 Existing Weight-Load Register Reuse

No new weight-load register is added.

Firmware loads each tile through the existing MAC weight-load path:

| Semantic register | Plan REV4 text | Current repo v2 local offset |
|---|---:|---:|
| `MAC_W_LOAD_ADDR` | `0x048` | `0x050` |
| `MAC_W_LOAD_DATA` | `0x04C` | `0x054` |
| `MAC_W_LOAD_CTRL` | `0x050` | `0x058` |

M0 freezes the semantic reuse contract:

- `MAC_W_LOAD_ADDR` selects lane `i` and output neuron `j`.
- `MAC_W_LOAD_DATA` carries existing pos/neg 4-bit fields.
- `MAC_W_LOAD_CTRL.WRITE_STROBE` is W1P and byte0-only.

Current MAC implementation accepts pos/neg nibbles. The CONV exporter may keep
the architectural signed weight in intermediate files, but the firmware load
path lowers it to existing differential format:

```text
if signed_w >= 0:
  pos = signed_w
  neg = 0
else:
  pos = 0
  neg = -signed_w
```

Claude review item: reconcile the plan offset typo or stale map before M3 so
RTL, firmware headers, TBs, and docs name one canonical offset set.

### 4.3 WAIT_WEIGHT Handshake

`conv_ctrl_v2` must not implicitly invoke firmware. Weight loading is
firmware-managed:

```text
conv_ctrl enters WAIT_WEIGHT
conv_ctrl sets CONV_STATUS.WEIGHT_REQ = 1
conv_ctrl exposes current tile/h/w status
firmware observes WEIGHT_REQ
firmware loads weight_tile[tile_idx] via MAC_W_LOAD_*
firmware writes CONV_CTRL.WEIGHT_READY = 1
conv_ctrl clears WEIGHT_REQ
conv_ctrl starts stage_engine_v2
```

Timeout is optional and controlled by `WEIGHT_TIMEOUT_EN`.

### 4.4 Weight SVA

```systemverilog
// SVA_WEIGHT_REQ_BLOCKS_STAGE_START
assert property (@(posedge clk) disable iff (!rst_n)
  weight_req_sticky && !weight_ready_pulse |-> !stage_start_pulse);
```

```systemverilog
// SVA_WEIGHT_READY_CLEARS_REQ
assert property (@(posedge clk) disable iff (!rst_n)
  weight_req_sticky && weight_ready_pulse |=> !weight_req_sticky);
```

```systemverilog
// SVA_LAST_TILE_LANE_ZERO_PAD
assert property (@(posedge clk) disable iff (!rst_n)
  dyn_wl_resp_valid && (lane_idx >= dyn_wl_resp_valid_count)
  |-> dyn_wl_resp_data[lane_idx] == 1'b0);
```

## 5. First-Layer Input Encoding

RTL CONV path does not encode raw pixels.

First-layer input is already a binary spike fmap:

```text
pixel[h][w][c] -> rate/Bresenham encoder -> spike[h][w][c][t]
```

The existing Python reference function is
`python_multilayer/snn_engine_multilayer.py:100`, especially the
Bresenham-style loop around lines 131-141:

```text
acc += pixel
fired = acc >= 256
out[t, fired] = 1
acc[fired] -= 256
```

The M1 packer writes:

```text
input_fmap_words.hex
```

using the section 3 formula:

```text
word_addr = base_word + ((h*W+w)*C+c)*stream_words + (t>>5)
bit_idx   = t & 31
```

Firmware initializes fmap SRAM bank A:

```text
for word_addr, word_data in input_fmap_words.hex:
  write CONV_FMAP_WR_DATA = word_data
  write CONV_FMAP_WR_ADDR = word_addr
  write CONV_FMAP_WR_CTRL.WR_COMMIT = 1
```

`CONV_FMAP_WR_CTRL.TARGET_BANK=0` means bank A. `AUTO_INC=1` may be used for
sequential initialization.

The SHA256 of packed input words is part of the golden contract.

### 5.1 Encoding SVA

```systemverilog
// SVA_FMAP_FW_WRITE_BLOCKED_WHILE_BUSY
assert property (@(posedge clk) disable iff (!rst_n)
  conv_busy && fmap_wr_commit_pulse |=> conv_err_code == ERR_FMAP_WRITE_WHILE_BUSY);
```

```systemverilog
// SVA_FMAP_WR_OOB_NO_BRAM_WRITE
assert property (@(posedge clk) disable iff (!rst_n)
  fmap_wr_commit_pulse && (fmap_wr_addr >= BANK_WORDS)
  |-> !fmap_sram_wr_en);
```

## 6. Patch Unroller Context and FSM Spec

### 6.1 Context

`patch_unroller_v2` receives context from `conv_ctrl_v2` before the stage run:

| Field | Meaning |
|---|---|
| `ctx_h` | output pixel row |
| `ctx_w` | output pixel column |
| `ctx_tile_idx` | tile index in `K*K*C_in` |
| `cfg_K` | kernel size, valid set `{3,5}` |
| `cfg_stride` | stride, valid set `{1,2}` |
| `cfg_pad` | padding, `0..2` |
| `cfg_C_in` | input channels |
| `cfg_H` | input height |
| `cfg_W` | input width |
| `fmap_base_word` | input fmap base word |
| `stream_words` | `(T_count + 31) >> 5` |

The context excludes timestep. Timestep arrives only through
`dyn_wl_req_timestep`.

### 6.2 FSM

Patch unroller FSM:

```text
IDLE
  -> CTX_LATCH
  -> READ_KKC
  -> RESPOND
  -> IDLE
```

`IDLE`:

- waits for `ctx_valid`;
- deasserts `dyn_wl_req_ready` if context is absent.

`CTX_LATCH`:

- captures context once;
- computes `full_dim = K*K*C_in`;
- computes `tile_base = ctx_tile_idx * 256`;
- computes `valid_count = min(256, full_dim - tile_base)`;
- rejects invalid `valid_count==0` through `conv_ctrl_v2` validator, not here.

`READ_KKC`:

- accepts one `dyn_wl_req_timestep`;
- for each lane `0..255`, computes `logical_idx = tile_base + lane`;
- maps `logical_idx` to `(ky,kx,c)`;
- computes source coordinate:

```text
src_h = ctx_h * cfg_stride + ky - cfg_pad
src_w = ctx_w * cfg_stride + kx - cfg_pad
```

- returns zero if `src_h/src_w` is outside `[0,H)` / `[0,W)`;
- otherwise reads fmap SRAM using section 3 formula.

`RESPOND`:

- asserts `dyn_wl_resp_valid`;
- holds response stable until `dyn_wl_resp_ready`;
- returns `dyn_wl_resp_valid_count`.

Latency can be one or more cycles. Random backpressure TBs must cover both.

### 6.3 Last Tile Zero Padding

If `lane >= valid_count`:

- no fmap SRAM read is required;
- response bit is zero;
- weight exporter also writes zero for that lane;
- `stage_engine_v2.cfg_in_dim` must equal `valid_count`.

### 6.4 Patch SVA

```systemverilog
// SVA_PATCH_CTX_STABLE_WHILE_BUSY
assert property (@(posedge clk) disable iff (!rst_n)
  patch_busy |-> $stable({ctx_h, ctx_w, ctx_tile_idx, cfg_K, cfg_stride,
                          cfg_pad, cfg_C_in, cfg_H, cfg_W, fmap_base_word,
                          stream_words}));
```

```systemverilog
// SVA_PATCH_ZERO_PAD_OOB
assert property (@(posedge clk) disable iff (!rst_n)
  patch_lane_oob |-> patch_lane_bit == 1'b0);
```

```systemverilog
// SVA_PATCH_RESP_AFTER_REQ
assert property (@(posedge clk) disable iff (!rst_n)
  patch_req_accept |-> ##[1:$] patch_resp_valid);
```

## 7. Fmap Flatten Reader Context and FSM Spec

### 7.1 Context

`fmap_flatten_reader_v2` receives context from `conv_ctrl_v2`:

| Field | Meaning |
|---|---|
| `flat_tile_idx` | tile index in row-major `H*W*C` |
| `cfg_H` | fmap height |
| `cfg_W` | fmap width |
| `cfg_C_in` | fmap channels |
| `fmap_base_word` | input fmap base word |
| `stream_words` | `(T_count + 31) >> 5` |

The full flatten dimension is:

```text
flat_dim = H * W * C_in
```

The logical index is:

```text
flat_idx = flat_tile_idx * 256 + lane
h        = flat_idx / (W*C_in)
rem      = flat_idx % (W*C_in)
w        = rem / C_in
c        = rem % C_in
```

### 7.2 FSM

Flatten reader FSM:

```text
IDLE
  -> CTX_LATCH
  -> READ_FLAT
  -> RESPOND
  -> IDLE
```

It is intentionally simpler than the patch unroller:

- no `K`, stride, or padding;
- no spatial CONV loop;
- no output fmap writeback;
- row-major only;
- same dynamic WL request/response protocol.

### 7.3 Flatten-FC Execution

`CONV_MODE=1, FLATTEN_MODE=1` means flatten-FC stage:

```text
stage_engine membrane reset
for tile_idx in 0..tile_count-1:
  WAIT_WEIGHT
  latch flat context
  start stage_engine
  stage_engine requests one flat WL per timestep
  final tile writes regular stream_buffer output
```

`out_H`, `out_W`, and `out_base_word` are ignored in FLATTEN mode. Input fmap
bounds are still validated.

### 7.4 Flatten SVA

```systemverilog
// SVA_FLAT_ROW_MAJOR_ADDR
assert property (@(posedge clk) disable iff (!rst_n)
  flat_lane_valid |-> (flat_word_addr == fmap_base_word
    + (((flat_h * cfg_W + flat_w) * cfg_C_in + flat_c) * stream_words)
    + (dyn_wl_req_timestep >> 5)));
```

```systemverilog
// SVA_FLAT_NO_SPATIAL_WRITEBACK
assert property (@(posedge clk) disable iff (!rst_n)
  cfg_conv_mode && cfg_flatten_mode |-> !fmap_packer_wr_en);
```

## 8. Register Map and Configuration Validator

### 8.1 New CONV Register Map

The 15 new registers occupy the REV 4 planned range `0x084..0x0BC`.

| Offset | Register | Access | Fields |
|---:|---|---|---|
| `0x084` | `CONV_MODE` | RW | `[0]=CONV_MODE`, `[1]=FLATTEN_MODE`, `[2]=FMAP_PP_SEL`, `[3]=WEIGHT_TIMEOUT_EN` |
| `0x088` | `CONV_CFG_HW` | RW | `[15:0]=H`, `[31:16]=W` |
| `0x08C` | `CONV_CFG_C` | RW | `[15:0]=C_in`, `[31:16]=C_out` |
| `0x090` | `CONV_CFG_K_S_P` | RW | `[3:0]=K`, `[7:4]=stride`, `[11:8]=pad` |
| `0x094` | `CONV_CFG_OUT_HW` | RW | `[15:0]=out_H`, `[31:16]=out_W` |
| `0x098` | `CONV_CFG_T` | RW | `[15:0]=T_count` |
| `0x09C` | `CONV_CFG_TILE` | RW | `[15:0]=tile_count`, `[31:16]=last_tile_valid_count` |
| `0x0A0` | `CONV_CFG_FMAP_BASE` | RW | `[31:0]=base_word` |
| `0x0A4` | `CONV_CFG_OUT_BASE` | RW | `[31:0]=out_base_word` |
| `0x0A8` | `CONV_CTRL` | W1P | `[0]=START`, `[1]=ABORT`, `[2]=WEIGHT_READY` |
| `0x0AC` | `CONV_STATUS` | mixed | `[0]=BUSY(RO)`, `[1]=DONE(W1C)`, `[2]=WEIGHT_REQ(RO)`, `[7:4]=ERR(RO)`, `[15:8]=current_pixel_h`, `[23:16]=current_pixel_w`, `[31:24]=current_tile_idx` |
| `0x0B0` | `CONV_FMAP_WR_DATA` | RW | 32-bit firmware fmap write data |
| `0x0B4` | `CONV_FMAP_WR_ADDR` | RW | 32-bit word offset |
| `0x0B8` | `CONV_PERF_CYCLES` | RO | last run cycle count |
| `0x0BC` | `CONV_FMAP_WR_CTRL` | mixed | `[0]=WR_COMMIT(W1P)`, `[1]=AUTO_INC(RW)`, `[2]=TARGET_BANK(RW)` |

All writable fields use the existing `apply_wstrb()` merge function style from
`rtl/top/snn_soc_v2b_top.sv`.

Wrapper note: REV 4 names `v2b_axi_wrapper` as the AXI register owner, but the
audited v2 worktree currently exposes the V2.B register bank inside
`rtl/top/snn_soc_v2b_top.sv` and has no `rtl/top/v2b_axi_wrapper.sv` file. M3
must either add the wrapper or keep the local simple-bus top as the insertion
site while preserving the same byte-mask contract.

### 8.2 Configuration Validator

Validation occurs after `CONV_CTRL.START` and before `WEIGHT_REQ`.

Derived values:

```text
stream_words = (T_count + 31) >> 5
input_dim    = FLATTEN_MODE ? H*W*C_in : K*K*C_in
tile_expected = ceil(input_dim / 256)
last_expected = input_dim - 256*(tile_expected-1)
bank_words = 65536
```

If any validation fails:

- `BUSY=0`;
- `DONE=1`;
- `ERR!=0`;
- no `WEIGHT_REQ`;
- no `stage_start_pulse`;
- no fmap SRAM write.

### 8.3 Error Codes

| Code | Name | Condition |
|---:|---|---|
| 0 | `OK` | no error |
| 1 | `ERR_ILLEGAL_KKC` | `K*K*C_in == 0` or `K*K*C_in > V2B_CONV_MAX_KKC` |
| 2 | `ERR_TILE_CFG_MISMATCH` | `tile_count` or `last_tile_valid_count` mismatches derived values |
| 3 | `ERR_BAD_GEOMETRY` | illegal `K`, stride, pad, H/W, out shape, or status-width geometry |
| 4 | `ERR_FMAP_OOB` | input or output fmap exceeds bank |
| 5 | `ERR_BAD_T` | `T_count == 0` or `T_count > V2B_MAX_TIMESTEPS` |
| 6 | `ERR_BAD_COUT` | `C_out == 0` or `C_out > V2B_MAX_OUT_NEURONS` |
| 7 | `ERR_FMAP_WRITE_WHILE_BUSY` | firmware commits fmap write while `BUSY=1` |
| 8 | `ERR_WEIGHT_TIMEOUT` | optional timeout expires in `WAIT_WEIGHT` |
| 9 | `ERR_FMAP_WR_OOB` | firmware fmap write address exceeds bank |

### 8.4 Byte-Mask Expectation Matrix

The byte-mask invariant covers three field classes.

#### W1P command bits

Applies to:

- `CONV_CTRL.START`;
- `CONV_CTRL.ABORT`;
- `CONV_CTRL.WEIGHT_READY`;
- `CONV_FMAP_WR_CTRL.WR_COMMIT`.

| `wstrb` | Expected behavior |
|---:|---|
| `4'b0001` | command bit in byte0 may fire when written as 1 |
| `4'b0010` | no byte0 command side effect |
| `4'b0100` | no byte0 command side effect |
| `4'b1000` | no byte0 command side effect |

#### W1C status bits

Applies to:

- `CONV_STATUS.DONE`.

| `wstrb` | Expected behavior |
|---:|---|
| `4'b0001` | `DONE` clears only when byte0 bit1 is written as 1 |
| `4'b0010` | `DONE` remains unchanged |
| `4'b0100` | `DONE` remains unchanged |
| `4'b1000` | `DONE` remains unchanged |

RO fields never change because of writes:

- `BUSY`;
- `WEIGHT_REQ`;
- `ERR`;
- current pixel/tile status.

#### Ordinary RW fields

Applies to:

- mode/config registers;
- fmap write data;
- fmap write address;
- `AUTO_INC`;
- `TARGET_BANK`.

| `wstrb` | Expected behavior |
|---:|---|
| `4'b0001` | only bits `[7:0]` update |
| `4'b0010` | only bits `[15:8]` update |
| `4'b0100` | only bits `[23:16]` update |
| `4'b1000` | only bits `[31:24]` update |

The permanent invariant TB must extend from the current six checks to all 15
CONV offsets times four single-byte strobes.

### 8.5 Register SVA

```systemverilog
// SVA_CONV_CFG_VALIDATE_BEFORE_WEIGHT_REQ
assert property (@(posedge clk) disable iff (!rst_n)
  conv_start_pulse && !cfg_valid |=> (!weight_req_sticky && !stage_start_pulse));
```

```systemverilog
// SVA_REG_W1P_BYTE0_ONLY
assert property (@(posedge clk) disable iff (!rst_n)
  conv_ctrl_write && !cmd_wstrb[0] |-> !start_pulse && !abort_pulse && !weight_ready_pulse);
```

```systemverilog
// SVA_REG_W1C_DONE_BYTE0_ONLY
assert property (@(posedge clk) disable iff (!rst_n)
  conv_status_write && !cmd_wstrb[0] |=> $stable(done_sticky));
```

```systemverilog
// SVA_REG_RW_APPLY_WSTRB
assert property (@(posedge clk) disable iff (!rst_n)
  cfg_reg_write |=> cfg_reg_q == apply_wstrb($past(cfg_reg_q), $past(cmd_wdata), $past(cmd_wstrb)));
```

### 8.6 Partial-Sum Bound

`V2B_PARTIAL_WIDTH` remains 14.

Bound:

```text
max_KKC       = 3*3*128 = 1152
max_abs_w     = 7
worst_abs_sum = 1152*7 = 8064
signed 14-bit = [-8192, 8191]
```

For K=5, the validator still enforces:

```text
K*K*C_in <= 1152
```

This is why `K=5,C_in=128` is illegal.

```systemverilog
// SVA_PARTIAL_SUM_BOUND_14BIT
assert property (@(posedge clk) disable iff (!rst_n)
  conv_accum_active |-> (partial_sum <= 14'sd8191 && partial_sum >= -14'sd8192));
```
