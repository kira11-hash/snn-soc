# M4 + M5 Autonomous Run Summary

Generated: 2026-04-30

## Scope

This summary reflects the current branch state after the M4 LeNet-5 work was
completed and the M5 CIFAR-scale work was investigated far enough to determine
that the blocker is architectural rather than a simple TB or scripting defect.

Frozen-tag policy remains unchanged:
- `v2-fpga-e203-passed`
- `v2-arm-fpga-demo-v2-passed`
- `v2-permanent-gate-2026-04-25`

## Runtime decisions used

Source: [m4_m5_runtime_decisions.md](./m4_m5_runtime_decisions.md)

1. Checkpoints are trained locally.
2. Accuracy is treated as a real quality goal, not just a bit-exact side note.
3. Smoke is run first, then full when the path proves stable.
4. Samples are class-first selections from the test split.
5. Hyperparameters are implementation-chosen.
6. Commit strategy is one commit per network, but this branch is currently
   being held at a LeNet-only review/commit point.

## M4 status: LeNet-5 complete

LeNet-5 topology:
- `Conv1 28x28x1 -> 28x28x6`, `K=5`, `S=1`, `P=2`, `T=10`
- `Conv2 28x28x6 -> 12x12x16`, `K=5`, `S=2`, `P=0`, `T=10`
- `FC1(flatten) 2304 -> 120`, `tile_count=9`
- `FC2 120 -> 84`
- `FC3 84 -> 10`

Current generated bundle:
- manifest:
  `python_multilayer/results_conv/lenet5/lenet5_golden_manifest.json`
- checkpoint:
  `python_multilayer/checkpoints/lenet5_snn.pth`

Key results:
- Quantized SNN test accuracy: `93.03%`
- Selected class-first samples: `10/10` correct
- Layer thresholds exported into the current bundle:
  - `conv1 = 8`
  - `conv2 = 16`
  - `fc1 = 7`
  - `fc2 = 7`
  - `fc3 = 3`

Cosim evidence:
- `bash sim/run_lenet5_cosim.sh --smoke` PASS
- `bash sim/run_lenet5_cosim.sh --full` PASS
- Full mode is `10/10` byte-exact against the Python integer golden
- Final concatenated counts SHA:
  `549fc0dd5ac50b55d7e7ac687caf97d2f998fd0c5e91962f2931ad3c5a1e4383`

Interpretation:
- The branch now has a credible end-to-end demonstration of:
  - true CONV execution,
  - CONV-to-CONV chaining,
  - CONV-to-FC flatten chaining,
  - FC tail execution,
  - Python/RTL bit-exact closure on a real network.

## M5 status: blocked

Tiny VGG and Plain-CNN-4 are not being presented as successful deliverables in
 the current branch state.

See:
- [m4_m5_BLOCKER_6.md](./m4_m5_BLOCKER_6.md)

Short version:
- Tiny VGG float/proxy checkpoint is viable at about `71.12%` test accuracy.
- Once mapped into the frozen SNN/integer/flatten-FC envelope, accuracy
  collapses to near-random behavior.
- Plain-CNN-4 is structurally harder because its final flatten dimension is
  larger.

Current judgment:
- M5 should not gate the present paper branch.
- CIFAR-scale evidence should be reframed as future work unless the frozen
  architecture is reopened.

## Recommended review / commit scope

What is ready to review:
- `python_multilayer/gen_convnet_golden.py`
- `tb/lenet5_cosim_tb.sv`
- `sim/sim_lenet5_cosim.f`
- `sim/run_lenet5_cosim.sh`
- `doc/v2-architecture/m4_m5_runtime_decisions.md`
- `doc/v2-architecture/m4_m5_summary.md`
- `doc/v2-architecture/m4_m5_BLOCKER_6.md`
- `doc/v2-architecture/paper_claim_lenet_only.md`
- LeNet bundle and checkpoint artifacts under:
  - `python_multilayer/checkpoints/lenet5*.pth`
  - `python_multilayer/results_conv/lenet5/`

What should not be treated as paper-ready deliverables:
- `python_multilayer/results_conv/tiny_vgg/`
- `python_multilayer/checkpoints/tiny_vgg_snn.pth`

## Ready-for-next-step recommendation

If the paper claim is intentionally narrowed to LeNet-5 plus synthetic tiled
evidence, this branch is in a good state to move toward a limited M6-style FPGA
evidence step.

That means:
- LeNet-5 end-to-end evidence can move forward.
- Synthetic tiled CONV gates remain useful architectural support.
- Tiny VGG / Plain-CNN-4 should not be used as required acceptance gates for
  the current paper branch.
