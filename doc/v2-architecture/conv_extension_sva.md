# V2.B CONV Extension SVA Checklist

M0 interface-level assertion inventory. These assertions are the contract for
M3 RTL work; exact line numbers for new files are placeholders until the files
exist.

## Insertion Strategy

Existing files:

- `rtl/snn/stage_engine_v2.sv`: insert dynamic-WL assertions near current
  `S_READ_WL/S_MAC_WAIT/S_MAC_LATCH` logic, currently around lines 328-368.
- `rtl/top/snn_soc_v2b_top.sv`: current v2 branch local simple-bus register
  bank; insert mux/register assertions here if M3 continues from this top.
- `rtl/top/v2b_axi_wrapper.sv`: planned AXI-facing register wrapper named by
  REV 4. This file is not present in the audited v2 worktree, so M3 must either
  add it or map the same SVA names to `snn_soc_v2b_top.sv`.
- `rtl/top/snn_soc_pkg.sv`: enum width/type assertions live in consumers, not
  the package.

New files:

- `rtl/snn/patch_unroller_v2.sv`: insert after FSM and address-generation
  logic.
- `rtl/snn/fmap_flatten_reader_v2.sv`: insert after row-major address logic.
- `rtl/snn/conv_ctrl_v2.sv`: insert after configuration validator and FSM.
- `rtl/snn/fmap_sram_v2.sv`: insert after read/write bank address decode.

## Checklist

| Name | Target module | Trigger | Expected behavior | Planned location |
|---|---|---|---|---|
| `SVA_DYN_WL_FC_NO_REQ` | `stage_engine_v2` | `cfg_conv_mode==0` | `dyn_wl_req_valid==0` | `rtl/snn/stage_engine_v2.sv`, after input-source decode near current line 328 |
| `SVA_DYN_WL_REQ_STABLE_UNTIL_READY` | `stage_engine_v2` | `dyn_wl_req_valid && !dyn_wl_req_ready` | request valid/timestep remain stable | `rtl/snn/stage_engine_v2.sv`, dynamic request block |
| `SVA_DYN_WL_STALL_FREEZE_TIMESTEP` | `stage_engine_v2` | request or response wait | `t_idx/debug_t_idx` unchanged next cycle | `rtl/snn/stage_engine_v2.sv`, near current `debug_t_idx` assignment line 147 |
| `SVA_DYN_WL_STALL_NO_MAC_START` | `stage_engine_v2` | dynamic wait state | `mac_start==0` | `rtl/snn/stage_engine_v2.sv`, near current `S_MAC_KICK` logic |
| `SVA_DYN_WL_STALL_NO_ACCUM_OR_LIF` | `stage_engine_v2` | dynamic wait state | no `tpb_acc_en`, no stream write, no spike output | `rtl/snn/stage_engine_v2.sv`, sequential datapath default pulse block |
| `SVA_DYN_WL_RESP_COUNT_RANGE` | `stage_engine_v2` and readers | `dyn_wl_resp_valid` | `valid_count inside {[1:256]}` | `rtl/snn/stage_engine_v2.sv`, dynamic response latch block |
| `SVA_DYN_WL_RESP_NOT_SAME_CYCLE` | `patch_unroller_v2`, `fmap_flatten_reader_v2` | request accepted | response is not valid in same cycle | reader FSM, `RESPOND` transition |
| `SVA_DYN_WL_RESP_STABLE_UNTIL_READY` | readers | `resp_valid && !resp_ready` | response data/count stable | reader response holding register |
| `SVA_DYN_WL_SELECTED_READER_ONLY` | top mux in `snn_soc_v2b_top` / `v2b_axi_wrapper` integration | dynamic request active | only selected reader sees `req_valid=1` | `rtl/top/snn_soc_v2b_top.sv` or future `rtl/top/v2b_axi_wrapper.sv`, dynamic-WL mux |
| `SVA_DYN_WL_UNSELECTED_RESP_MASKED` | top mux in `snn_soc_v2b_top` / `v2b_axi_wrapper` integration | unselected reader response toggles | stage response ignores it | `rtl/top/snn_soc_v2b_top.sv` or future `rtl/top/v2b_axi_wrapper.sv`, dynamic-WL mux |
| `SVA_STAGE_WL_LATCH_FROM_DYNAMIC_ONLY_WHEN_SELECTED` | `stage_engine_v2` | dynamic source selected | `wl_latched` equals dynamic response data | `rtl/snn/stage_engine_v2.sv`, after current `S_MAC_LATCH` case |
| `SVA_STAGE_FC_WL_LATCH_UNCHANGED` | `stage_engine_v2` | FC source selected | `wl_latched` comes only from ISR/SBA/SBB | `rtl/snn/stage_engine_v2.sv`, after current `S_MAC_LATCH` case |
| `SVA_STAGE_INPUT_SRC_WIDTH_VALID` | `stage_engine_v2` | start accepted | source selector is one legal enum | `rtl/snn/stage_engine_v2.sv`, config validation near current line 199 |
| `SVA_STAGE_SPIKE_FINAL_TILE_ONLY` | `stage_engine_v2` | `spike_out_valid` | `cfg_tile_mode && cfg_is_tile_final` | `rtl/snn/stage_engine_v2.sv`, future spike output block |
| `SVA_STAGE_SPIKE_EACH_T_EXACTLY_ONCE` | `stage_engine_v2` | final tile run | exactly one spike output per timestep | `rtl/snn/stage_engine_v2.sv`, future final-tile LIF/write block |
| `SVA_STAGE_NO_SPIKE_ON_NONFINAL_TILE` | `stage_engine_v2` | tile mode and nonfinal tile | `spike_out_valid==0` | `rtl/snn/stage_engine_v2.sv`, future spike output block |
| `SVA_PATCH_CTX_STABLE_WHILE_BUSY` | `patch_unroller_v2` | unroller busy | context fields stable | `rtl/snn/patch_unroller_v2.sv`, after context latch |
| `SVA_PATCH_WORD_ADDR_IN_RANGE` | `patch_unroller_v2` | fmap read issued | read address `< 65536` | `rtl/snn/patch_unroller_v2.sv`, address-generation block |
| `SVA_PATCH_ZERO_PAD_OOB` | `patch_unroller_v2` | source coordinate outside image | lane bit is zero and no illegal read | `rtl/snn/patch_unroller_v2.sv`, lane gather block |
| `SVA_PATCH_LAST_TILE_ZERO_PAD` | `patch_unroller_v2` | `lane >= valid_count` | lane bit is zero | `rtl/snn/patch_unroller_v2.sv`, response pack block |
| `SVA_PATCH_VALID_COUNT_MATCHES_CONTEXT` | `patch_unroller_v2` | response valid | count equals min remaining tile lanes | `rtl/snn/patch_unroller_v2.sv`, response count logic |
| `SVA_FLAT_CTX_STABLE_WHILE_BUSY` | `fmap_flatten_reader_v2` | flatten reader busy | flat context stable | `rtl/snn/fmap_flatten_reader_v2.sv`, after context latch |
| `SVA_FLAT_ROW_MAJOR_ADDR` | `fmap_flatten_reader_v2` | lane valid | address follows row-major formula | `rtl/snn/fmap_flatten_reader_v2.sv`, address-generation block |
| `SVA_FLAT_LAST_TILE_ZERO_PAD` | `fmap_flatten_reader_v2` | `lane >= valid_count` | lane bit is zero | `rtl/snn/fmap_flatten_reader_v2.sv`, response pack block |
| `SVA_FLAT_NO_SPATIAL_WRITEBACK` | `conv_ctrl_v2` | `FLATTEN_MODE=1` | no fmap packer writeback | `rtl/snn/conv_ctrl_v2.sv`, flatten branch |
| `SVA_FMAP_ADDR_IN_BANK` | `fmap_sram_v2` | read or write enable | word address `< bank_words` | `rtl/snn/fmap_sram_v2.sv`, bank decode |
| `SVA_FMAP_NO_CROSS_BANK_WRITE` | `fmap_sram_v2` | write enable | exactly one bank write enable active | `rtl/snn/fmap_sram_v2.sv`, write mux |
| `SVA_FMAP_PADDING_BITS_ZERO` | `conv_ctrl_v2` | packer writes final word | bits `t>=T_count` are zero | `rtl/snn/conv_ctrl_v2.sv`, packer flush block |
| `SVA_CONV_CFG_VALIDATE_BEFORE_WEIGHT_REQ` | `conv_ctrl_v2` | `CONV_CTRL.START` | invalid config reaches DONE/ERR without weight request | `rtl/snn/conv_ctrl_v2.sv`, validator output |
| `SVA_CONV_BAD_CFG_NO_STAGE_START` | `conv_ctrl_v2` | any nonzero config error | `stage_start_pulse==0` | `rtl/snn/conv_ctrl_v2.sv`, validator/FSM boundary |
| `SVA_WEIGHT_REQ_BLOCKS_STAGE_START` | `conv_ctrl_v2` | `WEIGHT_REQ && !WEIGHT_READY` | no stage start | `rtl/snn/conv_ctrl_v2.sv`, `WAIT_WEIGHT` state |
| `SVA_WEIGHT_READY_CLEARS_WEIGHT_REQ` | `conv_ctrl_v2` | `WEIGHT_READY` accepted | sticky request clears next cycle | `rtl/snn/conv_ctrl_v2.sv`, `WAIT_WEIGHT` state |
| `SVA_WEIGHT_TIMEOUT_ERR` | `conv_ctrl_v2` | timeout enabled and expires | error code `ERR_WEIGHT_TIMEOUT` | `rtl/snn/conv_ctrl_v2.sv`, timeout counter |
| `SVA_CONV_STATUS_DONE_W1C_BYTE0_ONLY` | `v2b_axi_wrapper` / current `snn_soc_v2b_top` register bank | write to `CONV_STATUS` | DONE clears only through byte0 bit1 | future `rtl/top/v2b_axi_wrapper.sv` or current `rtl/top/snn_soc_v2b_top.sv`, CONV_STATUS write path |
| `SVA_CONV_CTRL_W1P_BYTE0_ONLY` | `v2b_axi_wrapper` / current `snn_soc_v2b_top` register bank | write to `CONV_CTRL` | START/ABORT/WEIGHT_READY only fire via byte0 | future `rtl/top/v2b_axi_wrapper.sv` or current `rtl/top/snn_soc_v2b_top.sv`, CONV_CTRL write path |
| `SVA_CONV_FMAP_WR_COMMIT_BYTE0_ONLY` | `v2b_axi_wrapper` / current `snn_soc_v2b_top` register bank | write to `CONV_FMAP_WR_CTRL` | commit only fires via byte0 bit0 | future `rtl/top/v2b_axi_wrapper.sv` or current `rtl/top/snn_soc_v2b_top.sv`, fmap write-control path |
| `SVA_CONV_RW_APPLY_WSTRB` | `v2b_axi_wrapper` / current `snn_soc_v2b_top` register bank | write to any RW CONV config | only strobed bytes update | future `rtl/top/v2b_axi_wrapper.sv` or current `rtl/top/snn_soc_v2b_top.sv`, CONV config write cases |
| `SVA_FMAP_FW_WRITE_BLOCKED_WHILE_BUSY` | `conv_ctrl_v2` / top regs | FW commit while busy | error `ERR_FMAP_WRITE_WHILE_BUSY`, no write | `rtl/snn/conv_ctrl_v2.sv`, FW write path |
| `SVA_FMAP_WR_OOB_NO_WRITE` | `conv_ctrl_v2` / `fmap_sram_v2` | FW commit with address OOB | error `ERR_FMAP_WR_OOB`, no BRAM write | `rtl/snn/conv_ctrl_v2.sv`, FW write path |
| `SVA_PARTIAL_SUM_BOUND_14BIT` | `stage_engine_v2` / MAC path | CONV accumulation active | signed partial remains in 14-bit range | `rtl/snn/stage_engine_v2.sv`, MAC diff/TPB write block |

## Minimal Gate Set

At least these properties must exist before M3 can be called interface-complete:

1. `SVA_DYN_WL_FC_NO_REQ`
2. `SVA_DYN_WL_STALL_FREEZE_TIMESTEP`
3. `SVA_DYN_WL_RESP_COUNT_RANGE`
4. `SVA_DYN_WL_SELECTED_READER_ONLY`
5. `SVA_DYN_WL_RESP_NOT_SAME_CYCLE`
6. `SVA_PATCH_WORD_ADDR_IN_RANGE`
7. `SVA_PATCH_LAST_TILE_ZERO_PAD`
8. `SVA_FLAT_ROW_MAJOR_ADDR`
9. `SVA_FLAT_LAST_TILE_ZERO_PAD`
10. `SVA_CONV_CFG_VALIDATE_BEFORE_WEIGHT_REQ`
11. `SVA_WEIGHT_REQ_BLOCKS_STAGE_START`
12. `SVA_STAGE_SPIKE_FINAL_TILE_ONLY`
13. `SVA_FMAP_FW_WRITE_BLOCKED_WHILE_BUSY`
14. `SVA_CONV_CTRL_W1P_BYTE0_ONLY`
15. `SVA_CONV_RW_APPLY_WSTRB`
16. `SVA_PARTIAL_SUM_BOUND_14BIT`

## Open Review Items

Two SVA insertion details require Claude signoff before M3 coding:

- `cfg_input_src` is currently 2-bit in `stage_engine_v2.sv` and
  `snn_soc_v2b_top.sv`; adding two dynamic sources requires widening or an
  equivalent conv-only selector.
- `MAC_W_LOAD_*` offsets differ between REV 4 prose and current repo constants;
  the SVA/TB names should follow the final canonical map.
