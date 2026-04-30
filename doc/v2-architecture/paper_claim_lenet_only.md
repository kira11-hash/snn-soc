# Paper Claim Shrink Recommendation

Date: 2026-04-30

## One-sentence position

If the immediate goal is a credible SCI 4-tier paper without reopening the
frozen RTL architecture, the strongest and safest narrative is:

`runtime-configurable FC/CONV SNN accelerator with bit-exact LeNet-5 evidence,
plus synthetic tiled-CONV and CONV-to-FC architectural validation`

## What can be claimed confidently

1. The hardware is no longer FC-only.
   - It supports true convolutional execution through:
     - patch-based dynamic WL delivery,
     - feature-map SRAM ping-pong,
     - CONV controller orchestration,
     - explicit CONV-to-FC flatten reader.

2. The CONV extension is not just unit-tested.
   - It has:
     - synthetic tiled-CONV bit-exact validation,
     - CONV-to-FC chain validation,
     - real-network LeNet-5 end-to-end bit-exact cosim.

3. The LeNet-5 evidence is substantial enough for a paper section.
   - quantized SNN accuracy: `93.03%`
   - full RTL/Python byte-exact closure on `10/10` selected samples
   - no architecture changes were required after the M3 freeze

## What should be said carefully

1. Do not describe the current branch as a solved CIFAR-scale SNN CNN
   accelerator.
   - Tiny VGG and Plain-CNN-4 are not mature evidence points under the frozen
     flatten-FC arithmetic envelope.

2. Do not blur bit-exact cosim coverage and dataset-wide test accuracy.
   - accuracy comes from the Python quantized SNN reference
   - bit-exactness comes from RTL/Python sample-by-sample cosim

3. Do not oversell generality.
   - the present evidence strongly supports convolutional capability
   - it does not yet prove paper-grade accuracy on larger CIFAR-scale
     topologies under the same frozen arithmetic contract

## A safe abstract-level claim

Suggested wording:

`We extend a previously FC-only SNN accelerator with a runtime-configurable
convolutional dataflow including dynamic patch gathering, feature-map ping-pong
storage, and an explicit CONV-to-FC flatten path. The design is validated by
bit-exact RTL/Python co-simulation on LeNet-5 and by synthetic tiled-CONV
stress tests covering multi-tile patches, padding, stride, and CONV-to-FC
chaining.`

## A safe limitations statement

Suggested wording:

`CIFAR-scale convolutional topologies with very large flatten-to-FC stages are
left as future work because they expose a capacity tradeoff under the current
frozen FC partial-sum envelope.`

## Recommendation

For the current paper:
- make LeNet-5 the headline real-network result
- keep synthetic tiled-CONV and CONV-to-FC chain tests as architectural
  support evidence
- move Tiny VGG / Plain-CNN-4 from required evidence to limitations / future
  work

This is enough to support the claim that the accelerator has genuine
convolutional capability, while keeping the paper honest about the present
CIFAR-scale limitation.
