# M4/M5 Blocker 6

Date: 2026-04-30

Status:
- M4 LeNet-5 is solved and reproducible.
- M5 Tiny VGG / Plain-CNN-4 is blocked by a design-level contradiction between
  the frozen V2.B FC tile datapath and the required CIFAR flatten dimensions.

## What passed

LeNet-5:
- `python_multilayer/results_conv/lenet5/lenet5_golden_manifest.json`
  generated from a fixed quantized conv front-end plus a trained quantized SNN
  FC head.
- Quantized SNN test accuracy: 93.03%.
- Selected 10 class-first samples: 10/10 correct.
- `bash sim/run_lenet5_cosim.sh --full` passes with 10/10 byte-exact samples.
- Final counts SHA:
  `c9c0bc8602c52ac468e852b08b0ff93253933d28932d1272d5cdebf224ad2954`

## What failed

Tiny VGG:
- Float/proxy checkpoint can be trained to about 71.12% CIFAR-10 test
  accuracy (`tiny_vgg.pth`), so the topology itself is viable in float form.
- After quantization and frozen-architecture conversion, several attempts fail:

1. Full-network SNN/QAT from proxy init:
   - `train_checkpoint("tiny_vgg", epochs=4, train_subset=1000)`
   - stays at about 10.5% eval accuracy, 11.07% full-test accuracy.

2. Fixed quantized conv front-end + trained one-layer SNN head:
   - `train_single_head_checkpoint("tiny_vgg", epochs=4, train_subset=8000)`
   - only reaches about 13.7% test accuracy.

3. Fixed quantized conv front-end + offline linear upper-bound probe:
   - 2000-train / 2000-test feature probe
   - final-layer quantized weights constrained to `[-1, +1]`
   - accuracy only about 12.75%.

Plain-CNN-4:
- Not promoted to full long training after the Tiny VGG failure, because the
  final FC constraint is strictly worse:
  - Tiny VGG flatten dim = 4096
  - Plain-CNN-4 flatten dim = 6144

## Why this is a red-line blocker

The frozen architecture keeps `V2B_PARTIAL_WIDTH = 14` for the existing FC tile
path. The FC flatten layer accumulates across all input features over all
tiles.

For the final CIFAR FC layer, the worst-case per-timestep partial bound is:

- Tiny VGG: `4096 * w_max`
- Plain-CNN-4: `6144 * w_max`

To stay inside signed 14-bit range `[-8192, 8191]`, the final FC weights must
satisfy:

- Tiny VGG: `w_max <= floor(8191 / 4096) = 1`
- Plain-CNN-4: `w_max <= floor(8191 / 6144) = 1`

That means the frozen architecture effectively forces the final CIFAR FC layer
to binary-like `{-1, 0, +1}` weights if we want a clean no-overflow contract.

In practice, the experiments above show that:
- a good float/proxy network exists,
- but once the final flatten-FC is reduced to the frozen V2.B FC arithmetic
  envelope, the classifier capacity collapses.

This is not a small script bug. It is a design-level tension between:
- frozen FC partial width / tile semantics,
- very large CIFAR flatten dimensions,
- and the user requirement that quantized accuracy must still be paper-grade.

## Why I am stopping here

Any real fix appears to require at least one frozen-architecture change:

1. Increase FC partial width beyond 14 bits, or
2. add another reduction stage before the final FC, or
3. change the CIFAR topologies to reduce flatten dimensionality, or
4. add a different FC arithmetic/scaling contract for large flatten stages.

Those are architecture decisions, not just M4/M5 implementation details.

## Recommendation

Treat this as a plan-level checkpoint:

1. Keep the successful M4 LeNet-5 work.
2. Re-open the M5 CIFAR architecture envelope before claiming Tiny VGG /
   Plain-CNN-4 evidence.
3. Decide whether to:
   - widen FC partial width, or
   - reduce the final flatten dimension, or
   - accept that M5 cannot meet the new "quantized accuracy must be strong"
     requirement under the current frozen RTL contract.
