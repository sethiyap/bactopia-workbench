# Runtime Dependencies

This project ships the orchestration scripts, PBS wrappers, small config files,
and helper logic needed to run the Bactopia Workbench workflow.

## Bundled In This Repo

- `bin/bactopia-workbench`
- `wrappers/submit.gadi.sh`
- `wrappers/submit.slurm.sh`
- `config/defaults.env`
- `config/sites/gadi.env.example`
- `config/sites/slurm.env.example`
- `scripts/submit_workbench_pipeline.sh`
- `scripts/submit_bactopia_batch_pipeline.sh`
- PBS wrappers under `scripts/*.pbs`
- Slurm wrappers under `scripts/*.slurm`
- helper shell scripts under `scripts/*.sh`
- shipped workflow configs:
  - `scripts/nextflow.gadi.all_tools.config`
  - `scripts/nextflow.slurm.all_tools.config`
  - `scripts/kleborate_232_compat.config`
  - `scripts/kleborate_232_compat.sh`
- `scripts/download_bactopia_datasets.sh`: on-demand custom-datasets downloader

See [bactopia-setup.md](bactopia-setup.md) for installing Bactopia on a new
system, downloading the custom datasets, and how Kleborate is supplied.

## External Runtime Dependencies

These are not bundled in the repo and must exist on the execution site.

- Bactopia pipeline install:
  - required; Bactopia is not bundled or installed by this repository
  - set `BACTOPIA_PIPELINE` to the Bactopia directory containing `main.nf` and
    `nextflow.config`
  - the shared Gadi default is `/g/data/rg42/bactopia/bactopia` (Bactopia
    v3.2.0)
  - other projects and non-Gadi sites must provide their own path in the site
    config or through the `BACTOPIA_PIPELINE` environment variable
- shared Bactopia datasets cache / custom datasets:
  - `DATASETS_CACHE`
  - download on demand with `scripts/download_bactopia_datasets.sh`; see
    [bactopia-setup.md](bactopia-setup.md)
- Kraken2 / Bracken database (only when kraken2/bracken tools run):
  - `KRAKEN2_DB` — large prebuilt index; find an existing one or download with
    `scripts/download_kraken2_db.sh`. See
    [bactopia-setup.md](bactopia-setup.md#4-kraken2--bracken-database-kraken2_db).
- FimTyper (opt-in; `RUN_FIMTYPER=1`):
  - `FIMTYPER_PIPELINE`, `FIMTYPER_CONFIG`, optional `MERGE_FIMTYPER_SCRIPT`
  - container is **published to GHCR and auto-pulled** on Slurm/local (no external
    install); on Gadi it is pre-staged (see
    [setup-non-gadi.md](setup-non-gadi.md#getting-the-fimtyper-container)). Built from
    `containers/fimtyper/Dockerfile` via `.github/workflows/build-fimtyper.yml`.
- Singularity cache and, if pre-pulled, container images:
  - `SING_CACHE`
  - optional `MLST_CONTAINER`
  - optional `KLEBORATE_CONTAINER`
- Conda / Miniforge install used by the standalone MLST review helper:
  - `MINIFORGE_ROOT`
  - `MLST_ENV`
  - `mlst`
  - `seqkit`
- ST131Typer helper script used by the optional ST131Typer steps:
  - `ST131Typer.sh`
- Python environment for final workbook export:
  - `python3`
  - `openpyxl`

For non-Gadi or non-`rg42` installs, these helpers are not installed by cloning
this repo. Install them only if they are not already available on the target
site, then point the wrappers at the correct paths via environment variables
such as `BACTOPIA_PIPELINE`, `MINIFORGE_ROOT`, `MLST_ENV`, `ST131_TYPER_DIR`,
and `ST131_TYPER_SCRIPT`.

## MLST Review Workflow

The packaged workflow includes a phenotype-guided MLST review stage.

- `map_samplesheet_results.R` writes the main AGRF-mapped results table and
  a review-only subset called
  `<prefix>_samplesheet_with_results_review_required.tsv`
- a sample is flagged for review when the canonicalized AGRF phenotype in
  `Comments` disagrees with the canonicalized genus implied by the MLST scheme,
  or when MLST carries an ambiguity that requires follow-up
- `run_review_mlst_from_tsv.sh` reruns standalone `mlst` only for those flagged
  isolates

Here, `<prefix>` is taken from the metadata filename before `_samplesheet.txt`.

Resolution behavior:

- the raw automatic MLST call is preserved as `auto_scheme`, `auto_st`, and
  `auto_profile`
- if `mlst` reports an ambiguous or tied result and one tied scheme matches the
  AGRF phenotype, the helper reruns `mlst --scheme <matching>` and records the
  resolved call
- if no phenotype-matching tied scheme exists, the resolved call remains the
  automatic call

Reviewed outputs include:

- `mlst_review.tsv`
- `<prefix>_samplesheet_with_results_mlst_reviewed.tsv`
- optional `<prefix>_samplesheet_with_results_post_review.tsv`

## Backend Assumptions

The `gadi` backend assumes:

- PBS Pro scheduler
- module environment with:
  - `nextflow`
  - `singularity`
  - `R`
- writable scratch space under `/scratch/<project>/<user>/...`

The `slurm` backend assumes:

- a Linux host with Slurm
- `nextflow`
- `singularity` or `apptainer`
- `R`
- writable scratch or project work space appropriate for your site

The `local` backend (scheduler-free; `submit local`) assumes:

- a Linux host with **no** required scheduler — stages run in-process, in order
- `nextflow`, `singularity`/`apptainer`, `R`/`Rscript`, and `python3` + `openpyxl`
  on `PATH` (typically via an activated conda env); `USE_MODULES=0`
- Bactopia runs with Nextflow's local executor via
  `scripts/nextflow.local.all_tools.config`
- see [setup-non-gadi.md](setup-non-gadi.md) "No Scheduler? Use The Local Backend"

## Site Config Entry Point

Gadi installs should set shared paths through:

- `config/sites/gadi.local.env`

Create it from:

```bash
cp config/sites/gadi.env.example config/sites/gadi.local.env
```

That file is the intended place to define the shared database paths and site
defaults before distribution.

Generic Slurm installs should set site paths through:

- `config/sites/slurm.local.env`

Create it from:

```bash
cp config/sites/slurm.env.example config/sites/slurm.local.env
```

That file is the intended place to define your non-Gadi Slurm paths, scratch
defaults, and optional Slurm partition or account settings.
