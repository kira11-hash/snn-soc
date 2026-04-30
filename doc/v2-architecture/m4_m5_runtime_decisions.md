# M4/M5 Runtime Decisions

Date: 2026-04-30

These decisions were confirmed by the user before starting the autonomous
M4/M5 LeNet-5, Tiny VGG, and Plain-CNN-4 bit-exact cosim work.

1. Checkpoint source: train from scratch locally.
   - LeNet-5, Tiny VGG, and Plain-CNN-4 checkpoints are generated in this
     worktree.
   - CPU training is acceptable.

2. Accuracy target: best reasonable effort, not a hard milestone gate.
   - The user wants accuracy high enough to be credible for a paper.
   - Bit-exact Python integer reference versus RTL remains the hard gate.

3. Cosim mode: run smoke first, then full if possible.
   - Smoke means one sample per network.
   - Full means ten samples per network.
   - Full runs are preferred when runtime permits.

4. Test sample selection: first test-split sample from each class.
   - Ten samples per network, one per class.

5. Training hyperparameters: autonomous.
   - Epochs, batch size, learning rate, optimizer, scheduler, and calibration
     details may be chosen by the implementation.

6. Commit batch: one commit per network.
   - M4 LeNet-5 commit.
   - M5 Tiny VGG commit.
   - M5 Plain-CNN-4 commit.

Frozen-tag policy remains unchanged: existing frozen tags must not be moved.
