# Setup Guide: Other Gadi Projects (non-rg42)

This guide is for deploying the pipeline under **your own NCI/Gadi project**
(not the shared `rg42` install). You have PBS, and Gadi modules for `nextflow`,
`singularity`, and `R`, but none of the databases, tools, or config are set up
for your project yet.

Once setup is done, running the pipeline is identical for everyone — see the
main [README](../README.md) for the universal command, metadata sheet, FOFN,
and outputs.

## 1. Prerequisites

Gadi already provides the scheduler and the module environment. Confirm the
modules the backend expects (`nextflow`, `singularity`, `R`) and that you have
writable scratch under `/scratch/<your_project>/<user>/...`. Details:
[docs/runtime-dependencies.md](runtime-dependencies.md) → "Backend Assumptions".

## 2. Install Bactopia + Datasets + Kleborate

These are shared across all environments, so follow the canonical guide rather
than repeating it here: [docs/bactopia-setup.md](bactopia-setup.md). In short:

- clone the **Bactopia v3.2.0** source checkout (the directory `BACTOPIA_PIPELINE`
  points at)
- obtain the custom datasets cache (`scripts/download_bactopia_datasets.sh`, or
  build your own) — see also [datasets notes below](#4-download-the-custom-datasets)
- Kleborate needs no separate install; it runs inside Bactopia's container

## 3. Clone The Pipeline And Create Your Site Config

```bash
cd /g/data/<your_project>
git clone https://github.com/sethiyap/bactopia-workbench.git bactopia-workbench
cd bactopia-workbench

cp config/sites/gadi.env.example config/sites/gadi.local.env
```

Edit `config/sites/gadi.local.env` and change the keys that are rg42-specific in
the example. The scheduler is selected by the `submit gadi` subcommand, not by a
config key.

| Key | rg42 example value | Change to |
| --- | --- | --- |
| `PROJECT` | `rg42` | your NCI project code |
| `PIPELINE_ROOT` | `/g/data/${PROJECT}/bactopia-workbench` | your clone path |
| `BACTOPIA_PIPELINE` | `/g/data/${PROJECT}/bactopia/bactopia` | your Bactopia v3.2.0 checkout |
| `DATASETS_CACHE` | `/g/data/${PROJECT}/bactopia_datasets/bactopia_datasets_custom` | your datasets cache |
| `KRAKEN2_DB` | `/g/data/${PROJECT}/bactopia/kraken_indices/k2_pluspf_16_GB_...` | your Kraken2/Bracken DB |
| `NEXTFLOW_CONFIG` | `$PIPELINE_ROOT/bactopia_config/nextflow.gadi.alltools.config` | keep (Gadi/PBS config) |
| `KLEBORATE_COMPAT_SCRIPT` | `$PIPELINE_ROOT/scripts/kleborate_232_compat.sh` | usually keep |
| `FIMTYPER_PIPELINE` / `FIMTYPER_CONFIG` / `MERGE_FIMTYPER_SCRIPT` | rg42 paths | your FimTyper paths (if used) |
| `MINIFORGE_ROOT` | `/g/data/${PROJECT}/bactopia_datasets/miniforge3` | your Miniforge |
| `MLST_ENV` | `/g/data/${PROJECT}/bactopia_datasets/envs/mlst_env` | your mlst/seqkit env |
| `RESULTS_ROOT_DEFAULT` | `/scratch/${PROJECT}/${USER_NAME}/custom_bactopia_runs` | your scratch results root |
| `SING_CACHE` | `/scratch/${PROJECT}/${USER_NAME}/singularity_cache` | your writable scratch |
| `BACTOPIA_VERSION` | `3.2.0` | keep unless you retest a new version |
| `CHECK_INODE_QUOTA` + `INODE_*` | `1` + thresholds | keep (Gadi inode preflight) |

For the full deployment checklist (shared permissions, what must live outside the
repo, verification), see
[docs/gadi-shared-install-checklist.md](gadi-shared-install-checklist.md).

## 4. Download The Custom Datasets

`DATASETS_CACHE` must point at a real cache before a run. Fetch it on demand:

```bash
DATASETS_CACHE=/g/data/<your_project>/bactopia_datasets_custom \
  ./scripts/download_bactopia_datasets.sh
```

(Reuses an existing cache if present; see
[docs/bactopia-setup.md](bactopia-setup.md) for build-your-own and the direct
download link.)

## 5. MLST Review Environment

The MLST review stage needs `mlst` + `seqkit` in a conda env pointed to by
`MINIFORGE_ROOT` / `MLST_ENV`. If your project doesn't have one, the packaged
helper builds it (see [docs/setup-non-gadi.md](setup-non-gadi.md#2-install-optional-local-tools)
or `scripts/install_optional_local_tools.sh`), or create it manually per
[docs/runtime-dependencies.md](runtime-dependencies.md).

## 6. Optional: FimTyper

FimTyper is off by default. The image is published to GHCR, but **Gadi compute
nodes have no internet**, so it must be **pre-staged** into `SING_CACHE` — Nextflow
cannot pull it at run time on a compute node. Do one of these on a **login node**
(which does have internet), then set `FIMTYPER_CONTAINER` to the result:

```bash
# Pre-pull the published image into your project cache:
SING_CACHE=/g/data/<your_project>/bactopia/caches/singularity \
  /g/data/<your_project>/bactopia-workbench/scripts/pull_local_containers.sh --with-fimtyper

# ...or copy the rg42 image if you have read access:
cp /g/data/rg42/bactopia/caches/singularity/fimtyper.sif \
   /g/data/<your_project>/bactopia/caches/singularity/fimtyper.sif
```

Keep `FIMTYPER_CONFIG` on `fimtyper.gadi.config` and set `FIMTYPER_CONTAINER` to
the staged `.sif`, then enable with `RUN_FIMTYPER=1`. Details and build-your-own:
[docs/setup-non-gadi.md → Getting the FimTyper container](setup-non-gadi.md#getting-the-fimtyper-container).

## 7. Validate, Then Run

Validate config, inputs, and dependencies without submitting jobs:

```bash
./bin/bactopia-workbench submit gadi --dry-run \
  --site-config config/sites/gadi.local.env \
  INPUT_SOURCE METADATA_DIR RESULTS_ROOT 50
```

Fix anything it flags (a common one is `DATASETS_CACHE` not found — download it,
step 4). Then run the real submission using the universal command on the main
[README](../README.md#running-the-pipeline).
