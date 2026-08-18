# Bactopia Setup: Install, Custom Datasets, And Kleborate

This page is for setting up a **new** system to run `bactopia-workbench`. It
covers three things users most often ask about:

1. how to install Bactopia and what its prerequisites are
2. how to obtain the custom Bactopia datasets (and where they go)
3. how Kleborate is provided (spoiler: you do not install it separately)

If you are on the shared `rg42` Gadi install, all of this is already set up —
see the [README](../README.md) and just submit. This page matters when you are
deploying to a new project or a non-Gadi machine.

## What You Provide vs What Is Automatic

| Piece | Who provides it |
| --- | --- |
| Nextflow, a container engine, conda/mamba | **You** (system prerequisites) |
| Bactopia pipeline source (`BACTOPIA_PIPELINE`) | **You** (clone once, pin v3.2.0) |
| Per-tool containers, including **Kleborate** | **Automatic** — Nextflow pulls them into `SING_CACHE` on first run |
| Custom datasets (`DATASETS_CACHE`) | **Download link** — not bundled; fetch on demand (helper below) or build your own. Must point at a real cache before a run. |
| `mlst` + `seqkit` for MLST review | Helper: [`install_optional_local_tools.sh`](../scripts/install_optional_local_tools.sh) |

## 1. Prerequisites On A New System

Bactopia is a Nextflow pipeline that runs each tool inside a container, so a new
host needs:

- **Nextflow** — the workflow engine (`nextflow` on `PATH`, or a module).
- **A container engine** — Singularity/Apptainer on HPC (this repo runs Bactopia
  with `-profile singularity`, see
  [run_bactopia_batch.pbs:127](../scripts/run_bactopia_batch.pbs#L127)); Docker
  works on a laptop with Bactopia's `-profile docker`.
- **conda / mamba** (Miniforge) — needed for the optional `bactopia` CLI (used to
  build datasets) and for the pipeline's `mlst`/`seqkit` review environment.
- Plus a scheduler (PBS or Slurm) and `R` for the `gadi`/`slurm` backends — see
  [runtime-dependencies.md](runtime-dependencies.md) "Backend Assumptions".

## 2. Install Bactopia (v3.2.0)

This wrapper is pinned to **Bactopia v3.2.0**. Do not substitute Bactopia v4
without updating and retesting the wrapper.

### Required: a Bactopia source checkout

The pipeline runs `nextflow run "$BACTOPIA_PIPELINE"`, where `BACTOPIA_PIPELINE`
is a directory that contains `main.nf` and `nextflow.config`. Get one by cloning
the tagged release:

```bash
git clone --branch v3.2.0 https://github.com/bactopia/bactopia.git /path/to/bactopia
```

Then record it in your site config (`config/sites/gadi.local.env` or
`config/sites/slurm.local.env`):

```bash
BACTOPIA_PIPELINE=/path/to/bactopia
BACTOPIA_VERSION=3.2.0
```

The shared Gadi default is `/g/data/rg42/bactopia/bactopia`.

### Optional: the Bactopia conda package

Installing the Bactopia conda package gives you the `bactopia`,
`bactopia datasets`, and `bactopia prepare` command-line helpers. These are handy
for **building** a datasets cache (see below):

```bash
mamba create -n bactopia -c conda-forge -c bioconda bactopia
# or: conda create -n bactopia -c conda-forge -c bioconda bactopia
conda activate bactopia
```

See the official [Bactopia installation docs](https://bactopia.github.io/) for
the authoritative, up-to-date instructions.

## 3. Custom Datasets (`DATASETS_CACHE`)

### What it is

The custom datasets are **not bundled** in this repo (they are ~500 MB). Instead
they are provided as a **download link** you fetch only when you want them:

- **Direct download / releases page:**
  <https://github.com/sethiyap/bactopia-workbench/releases>
- or use the packaged helper below (recommended — it puts the files in the right
  place automatically).

Bactopia takes a `--datasets_cache` directory holding organism-specific data.
This wrapper passes it to **every** Bactopia invocation
([run_bactopia_batch.pbs:124](../scripts/run_bactopia_batch.pbs#L124), and the
Kleborate and extra-tools runners), reading the path from the `DATASETS_CACHE`
config key.

The AGAR custom datasets bundle contains:

- **custom MLST scheme(s)** not in the default `mlst` database
- **reference genomes** used by Bactopia for variant calling / annotation
- **Kleborate / AMR resources**

> **You must set up the cache before an actual run.** Because the runners always
> pass `--datasets_cache "$DATASETS_CACHE"`, the configured path has to point at a
> real cache before you submit. `--dry-run` checks this and **fails early** with a
> message telling you to download it (or point `DATASETS_CACHE` at an existing
> cache) if it is missing — so you find out before jobs are queued, not after.

### Download on demand (reuse if present, else prompt)

Instead of building the cache by hand, use the packaged helper. It **reuses an
existing cache** if one is already present, and otherwise **prompts** before
downloading the bundle from this repo's GitHub Release:

```bash
# Uses DATASETS_CACHE as the target; prompts before downloading.
DATASETS_CACHE=/path/to/bactopia_datasets_custom \
  ./scripts/download_bactopia_datasets.sh

# Non-interactive (for automation):
DATASETS_CACHE=/path/to/bactopia_datasets_custom \
  ./scripts/download_bactopia_datasets.sh --yes
```

Behaviour:

- if `DATASETS_CACHE` already exists and is non-empty, it does nothing (use
  `--force` to re-download)
- otherwise it downloads the release asset and extracts it into `DATASETS_CACHE`
- if the GitHub Release has not been published yet, it fails with a clear message
  (see the maintainer note below), not a stack trace

Useful flags/overrides: `--dest DIR`, `--url URL`, `--tag TAG`, `--asset NAME`,
`--yes`, `--force` (also settable via `DATASETS_CACHE`, `BACTOPIA_DATASETS_URL`,
`BACTOPIA_DATASETS_TAG`, `BACTOPIA_DATASETS_ASSET`, `ASSUME_YES`). Run
`./scripts/download_bactopia_datasets.sh --help` for the full list.

### Where to put it / how to point at it

Whatever path you download into becomes your datasets cache. Tell the pipeline
about it in one of two ways:

- **Site config (persistent):** set `DATASETS_CACHE` in
  `config/sites/gadi.local.env` or `config/sites/slurm.local.env`.
- **Per run (one-off):**

  ```bash
  DATASETS_CACHE=/path/to/bactopia_datasets_custom \
    ./bin/bactopia-workbench submit gadi INPUT_SOURCE METADATA_DIR RESULTS_ROOT 50
  ```

The shared Gadi default is
`/g/data/rg42/bactopia/bactopia_datasets/bactopia_datasets_custom`.

Run `--dry-run` after changing the path — the launcher verifies `DATASETS_CACHE`
exists before submitting
([submit_workbench_pipeline.sh:604](../scripts/submit_workbench_pipeline.sh#L604)).

### Where the datasets come from (other than the AGAR bundle)

The AGAR custom bundle is just a **pre-packaged snapshot** of Bactopia's standard
datasets. You don't have to use it — Bactopia can download/build the same cache
from the upstream sources with its own `bactopia datasets` subcommand:

```bash
conda activate bactopia          # needs the Bactopia conda package (step 2)
bactopia datasets --help
# builds the cache; then point DATASETS_CACHE at the directory it produces
```

`bactopia datasets` fetches these components from their maintainers (the same
pieces the AGAR bundle contains — `mash-refseq*.msh`, `gtdb-*.json.gz`,
`mlst.tar.gz`, `amrfinderplus.tar.gz`):

- **Mash sketch of NCBI RefSeq** (species / genome-size estimation) —
  [NCBI RefSeq](https://www.ncbi.nlm.nih.gov/refseq/)
- **Sourmash signature over GTDB / GenBank** (taxonomic classification) —
  [GTDB](https://gtdb.ecogenomic.org/), [sourmash databases](https://sourmash.readthedocs.io/en/latest/databases.html)
- **AMRFinderPlus database** (AMR genes/mutations) —
  [NCBI AMRFinderPlus](https://www.ncbi.nlm.nih.gov/pathogens/antimicrobial-resistance/AMRFinder/)
- **MLST schemes** — [PubMLST](https://pubmlst.org/)

Background on the datasets system: the
[Bactopia datasets docs](https://bactopia.github.io/v2.2.0/datasets/) (the v3
`bactopia datasets` command supersedes the older workflow). Whichever way you
obtain the cache, point `DATASETS_CACHE` at it.

> Note: the **Kraken2/Bracken database is separate** — it is not part of this
> cache. See the next section.

## 4. Kraken2 / Bracken Database (`KRAKEN2_DB`)

Only needed when the extra-tools bundle runs **kraken2** or **bracken** (taxonomic
classification). It is a large prebuilt index (commonly 8–100+ GB) that Kraken2
loads into RAM — so it is not bundled or auto-pulled; you point `KRAKEN2_DB` at
one.

### Find it if it already exists

A built Kraken2 DB is a directory containing `hash.k2d`, `opts.k2d`, and
`taxo.k2d` (prebuilt indexes also include Bracken's `database*.kmer_distrib`).

```bash
# check a candidate path:
ls -lh "$KRAKEN2_DB"/*.k2d
# or search common locations:
find /g/data /scratch "$HOME" -maxdepth 4 -name hash.k2d 2>/dev/null
```

On the shared rg42 install it is at
`/g/data/rg42/bactopia/kraken_indices/k2_pluspf_16_GB_20251015`.

### Install it if not present

Download a prebuilt Kraken2+Bracken index with the packaged helper (reuses an
existing DB, prompts before the large download):

```bash
KRAKEN2_DB=/path/to/kraken2_db \
  ./scripts/download_kraken2_db.sh \
    --url https://genome-idx.s3.amazonaws.com/kraken/k2_pluspf_16gb_YYYYMMDD.tar.gz
```

Pick a collection and size to match your host RAM (Standard, PlusPF, PlusPFP, …)
and copy its current dated tarball URL from the Kraken2/Bracken index collection:
<https://benlangmead.github.io/aws-indexes/k2>. The `--url` is required because
the indexes are versioned by date. Then set `KRAKEN2_DB` in your site config.

To skip kraken2/bracken entirely instead, leave them out of the tools bundle
(they only run when `--additional-tools yes` / the tool list includes them).

## 5. Kleborate

You do **not** install Kleborate separately. It runs inside Bactopia's container
via `--wf kleborate`
([run_kleborate_batch.pbs:76-85](../scripts/run_kleborate_batch.pbs#L76-L85)),
and Nextflow pulls that image into `SING_CACHE` on first use. "Finding" Kleborate
means: it lives in the cached Singularity image, not on your `PATH`.

The only Kleborate-specific piece in this repo is a version-compatibility shim,
[kleborate_232_compat.sh](../scripts/kleborate_232_compat.sh), which lets
Kleborate 2.3.2 run under a newer Bactopia process definition (it translates the
newer CLI style into the 2.3.x syntax). It is wired in via the
`KLEBORATE_COMPAT_SCRIPT` config key and the Nextflow config; the shared Gadi
default resolves it automatically.

- to point at a different shim: set `KLEBORATE_COMPAT_SCRIPT=/path/to/script.sh`
- to skip Kleborate entirely: submit with `RUN_KLEBORATE=0`

## Maintainer Note: Publishing The Datasets Bundle

The download helper only **consumes** a published bundle; it does not create one.
To publish (or refresh) the AGAR custom datasets so others can download them:

1. Build/populate a datasets cache directory (`bactopia datasets`, custom MLST
   schemes, references, Kleborate/AMR resources).
2. Package it as a gzipped tarball whose contents extract **into** the cache root
   (i.e. `tar -xzf` should drop the dataset subdirectories directly into
   `DATASETS_CACHE`):

   ```bash
   tar -czf agar_bactopia_datasets.tar.gz -C /path/to/bactopia_datasets_custom .
   ```

3. Publish it as a GitHub Release asset on this repo. The helper defaults expect
   tag `datasets-latest` and asset `agar_bactopia_datasets.tar.gz`:

   ```bash
   gh release create datasets-latest agar_bactopia_datasets.tar.gz \
     --repo sethiyap/bactopia-workbench \
     --title "AGAR custom Bactopia datasets" \
     --notes "Custom MLST schemes, reference genomes, Kleborate/AMR resources"
   ```

   To publish under a different tag/asset, users can pass `--tag` / `--asset`
   (or set `BACTOPIA_DATASETS_TAG` / `BACTOPIA_DATASETS_ASSET`).

Because GitHub Release assets are limited to ~2 GB each, split very large caches
across multiple assets (and document the extra download steps) or host them
externally and point users at the URL with `--url` / `BACTOPIA_DATASETS_URL`.
