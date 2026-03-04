# Smoke Test Checklist

Last update: 2026-03-04

## 0. Scope

This document defines practical smoke-test entry points and pass/fail criteria.

- Full flow (Linux + VCS + Verdi): `sim/run_vcs.sh`, `sim/run_verdi.sh`
- Local light flow (Icarus): `sim/run_icarus_light.sh`

Note:
- `run_vcs.sh` and `run_verdi.sh` intentionally use fixed lab paths.
- If your environment differs, use the light flow first.

## 1. Icarus Light Smoke (Recommended baseline)

### 1.1 Command

```bash
cd sim
bash run_icarus_light.sh
```

### 1.2 Exit-code rule (strict)

`run_icarus_light.sh` now returns non-zero unless log contains:

- `LIGHT_SMOKETEST_PASS`

So CI/shell can trust the exit code directly.

### 1.3 OUT_FIFO_COUNT policy

The testbench supports plusargs:

- `+EXPECTED_OUT_COUNT=<N>`
- `+CHECK_OUT_COUNT=<0|1>`

Script default behavior:

- If staged weights exist (`../fpga/cim_model/*.hex` or `sim/*.hex`):
  - default `EXPECTED_OUT_COUNT=14`
- If no weights are found (main blackbox path):
  - default `EXPECTED_OUT_COUNT=20`

Optional overrides:

```bash
SMOKE_EXPECTED_OUT_COUNT=18 bash run_icarus_light.sh
SMOKE_CHECK_OUT_COUNT=0 bash run_icarus_light.sh
```

## 2. Full VCS Smoke (Lab environment)

### 2.1 Command

```bash
cd sim
bash run_vcs.sh
```

Expected artifacts:

- `sim/vcs.log`
- `sim/sim.log`
- `sim/waves/snn_soc.fsdb`

### 2.2 Open waveform

```bash
cd sim
bash run_verdi.sh
```

## 3. Quick checks after run

### 3.1 Light flow

```bash
grep -E "LIGHT_SMOKETEST_(PASS|FAIL)" sim/icarus_light.log
```

### 3.2 VCS flow

```bash
grep -i "error\|fatal" sim/sim.log
ls -lh sim/waves/snn_soc.fsdb
```

## 4. Common issues

### 4.1 CRLF line ending issues on Linux

```bash
cd sim
sed -i 's/\r$//' run_vcs.sh run_verdi.sh run_icarus_light.sh
```

### 4.2 No spike output / count mismatch

Check in order:

1. threshold/timesteps register writes
2. DMA start and done bits
3. input FIFO feeding path
4. whether weight files are staged for the branch you run

## 5. Minimal acceptance criteria

A smoke run is accepted when all are true:

1. Script exit code is 0
2. PASS banner exists in log
3. No fatal simulation error
4. Expected artifacts are generated (VCD or FSDB)
