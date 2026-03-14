# Smoke Test Checklist

Last update: 2026-03-14

## 0. Scope

This document defines practical smoke-test entry points and pass/fail criteria.

- Blackbox light flow (Icarus): `sim/run_icarus_light.sh`
- Weighted source-level flow (Icarus): `sim/run_icarus_weighted.sh`
- Weighted full flow (Linux + VCS + Verdi): `sim/run_vcs_weighted.sh`, `sim/run_verdi_weighted.sh`

Note:
- `run_vcs_weighted.sh` and `run_verdi_weighted.sh` are the current weighted full-flow entry points.
- If your environment differs, use the Icarus flows first.

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
- If no weights are found (main blackbox path, current `T=10` default):
  - default `EXPECTED_OUT_COUNT=100`

Optional overrides:

```bash
SMOKE_EXPECTED_OUT_COUNT=18 bash run_icarus_light.sh
SMOKE_CHECK_OUT_COUNT=0 bash run_icarus_light.sh
```

## 2. Weighted Icarus Smoke

### 2.1 Command

```bash
cd sim
bash run_icarus_weighted.sh
```

Prerequisite:

- stage `weight_pos.hex` and `weight_neg.hex` first
- supported lookup order: any `results/exports/` directory, `fpga/cim_model/`, then `sim/`
- a clean checkout of `main` does not include these generated weight hex files by default

Expected artifacts:

- `sim/icarus_weighted.log`
- `sim/waves/icarus_weighted.vcd`

Pass banner:

- `WEIGHTED_SIM_PASS`

## 3. Weighted VCS Smoke (Lab environment)

### 3.1 Command

```bash
cd sim
bash run_vcs_weighted.sh
```

Expected artifacts:

- `sim/vcs_weighted_compile.log`
- `sim/vcs_weighted.log`
- `sim/waves/snn_soc_weighted.fsdb`

### 3.2 Open waveform

```bash
cd sim
bash run_verdi_weighted.sh
```

## 4. Quick checks after run

### 4.1 Light flow

```bash
grep -E "LIGHT_SMOKETEST_(PASS|FAIL)" sim/icarus_light.log
```

### 4.2 Weighted Icarus flow

```bash
grep -E "WEIGHTED_SIM_(PASS|FAIL)" sim/icarus_weighted.log
```

### 4.3 Weighted VCS flow

```bash
grep -i "error\|fatal" sim/vcs_weighted_compile.log sim/vcs_weighted.log
ls -lh sim/waves/snn_soc_weighted.fsdb
```

## 5. Common issues

### 5.1 CRLF line ending issues on Linux

```bash
cd sim
sed -i 's/\r$//' run_vcs_weighted.sh run_verdi_weighted.sh run_icarus_light.sh run_icarus_weighted.sh
```

### 5.2 No spike output / count mismatch

Check in order:

1. threshold/timesteps register writes
2. DMA start and done bits
3. input FIFO feeding path
4. whether weight files are staged for the branch you run
5. whether you are using the latest canonical `weight_pos.hex` / `weight_neg.hex`

## 6. Minimal acceptance criteria

A smoke run is accepted when all are true:

1. Script exit code is 0
2. PASS banner exists in log
3. No fatal simulation error
4. Expected artifacts are generated (VCD or FSDB)
