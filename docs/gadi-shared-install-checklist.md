# Gadi Shared Install Checklist

Use this checklist when setting up a shared `bactopia-workbench` checkout on
Gadi for lab-wide use.

## Shared Project Layout

Recommended shared locations:

```text
/g/data/rg42/
  bactopia-workbench/
  bactopia/
  bactopia/kraken_indices/
  bactopia_datasets/bactopia_datasets_custom/
  bactopia_datasets/miniforge3/
  bactopia_datasets/envs/mlst_env/
```

Optional shared external references:

```text
/g/data/rg42/custom_bactopia_refs/fimtyper/
```

## What Must Be In The Shared Project

The shared checkout should contain the full repo:

- `bin/bactopia-workbench`
- `wrappers/submit.gadi.sh`
- `config/defaults.env`
- `config/sites/gadi.env.example`
- `config/sites/gadi.local.env`
- `scripts/`
- `README.md`
- `docs/runtime-dependencies.md`

Do not copy only selected scripts. Keep the whole repo together.

## What Must Exist Outside The Repo

These are required runtime dependencies and should be available on Gadi:

- shared Bactopia install
- shared datasets/custom cache
- shared Kraken2/Bracken DB
- shared FimTyper pipeline/config if not vendored into the repo
- module environment with `nextflow`, `singularity`, and `R`
- writable scratch locations for users
- optional Miniforge/Conda MLST review environment
- Python with `openpyxl` for final workbook export

## Shared Miniforge

If the MLST review environment should be usable by multiple people, do not keep
Miniforge under one user's home directory. Put it in a shared group-readable
location such as:

```text
/g/data/rg42/bactopia_datasets/miniforge3
```

Recommended pattern:

- install Miniforge in a shared `/g/data` directory owned by the lab/project group
- keep the parent directories group-traversable
- use setgid on the shared directory so new files keep the project group
- create the review environment in a shared path as well, for example
  `/g/data/rg42/bactopia_datasets/envs/mlst_env`
- point `MINIFORGE_ROOT` at the shared Miniforge install and `MLST_ENV` at the
  shared environment name or full environment path

Typical permission target for shared directories:

```text
drwxr-sr-x
```

That gives the owner read/write/execute, and gives group members read/execute
plus setgid inheritance for new files. If multiple people need to update the
shared Conda installation itself, the directory must also be group-writable.

For a shared writable MLST environment, use a group-writable setgid directory
instead, for example:

```text
drwxrwsr-x
```

Typical commands for the shared review environment:

```bash
chgrp -R rg42 /g/data/rg42/bactopia_datasets/envs/mlst_env
chmod -R g+rwX /g/data/rg42/bactopia_datasets/envs/mlst_env
find /g/data/rg42/bactopia_datasets/envs/mlst_env -type d -exec chmod g+s {} +
chmod 2775 /g/data/rg42/bactopia_datasets/envs
```

That keeps the environment writable by project group members and makes new
files/directories inherit group `rg42`. When updating the shared environment,
use `umask 0002` so new files stay group-writable.

After creating the shared MLST review environment, verify it directly:

```bash
source /g/data/rg42/bactopia_datasets/miniforge3/etc/profile.d/conda.sh
conda activate /g/data/rg42/bactopia_datasets/envs/mlst_env
mlst --version
python --version
```

Expected result: the shared environment activates cleanly, `mlst` is available,
and `python` resolves from the shared environment rather than a home-directory
install.

## Gadi Setup Steps

1. Clone the repo into the shared Gadi location.

```bash
cd /g/data/rg42
git clone https://github.com/sethiyap/bactopia-workbench.git bactopia-workbench
cd /g/data/rg42/bactopia-workbench
```

2. Review the shared live config:

```bash
vi config/sites/gadi.local.env
```

3. Confirm these paths are correct in `config/sites/gadi.local.env`:

- `BACTOPIA_PIPELINE`
- `DATASETS_CACHE`
- `KRAKEN2_DB`
- `MINIFORGE_ROOT`
- `MLST_ENV`
- `NEXTFLOW_CONFIG`
- `KLEBORATE_COMPAT_SCRIPT`
- `FIMTYPER_PIPELINE`
- `FIMTYPER_CONFIG`
- `MERGE_FIMTYPER_SCRIPT`
- `SING_CACHE`

4. Confirm the required software/modules exist on Gadi:

```bash
module avail nextflow
module avail singularity
module avail R
```

5. Test the public CLI help:

```bash
/g/data/rg42/bactopia-workbench/bin/bactopia-workbench
/g/data/rg42/bactopia-workbench/wrappers/submit.gadi.sh --help
```

6. Run one small test submission:

```bash
cd /home/562/ps1744
/g/data/rg42/bactopia-workbench/bin/bactopia-workbench submit gadi \
  /scratch/rg42/AGAR/raw_data/2025/B07/AGRF_CAGRF26050180_AAHJ2FTM5 \
  /scratch/rg42/AGAR/metadata/2025/B07 \
  /scratch/rg42/AGAR/intermediates/2025/B07 \
  50
```

7. If needed, enable the extra tool bundle:

```bash
/g/data/rg42/bactopia-workbench/bin/bactopia-workbench submit gadi --additional-tools yes \
  /scratch/rg42/AGAR/raw_data/2025/B07/AGRF_CAGRF26050180_AAHJ2FTM5 \
  /scratch/rg42/AGAR/metadata/2025/B07 \
  /scratch/rg42/AGAR/intermediates/2025/B07 \
  50
```

## Notes

- `config/sites/gadi.local.env` is the real shared config for the Gadi install.
- Users should only need to pass raw-data, metadata, and results paths plus an
  optional additional-tools choice.
- Large reference data and databases should stay outside the repo and be
  referenced from `gadi.local.env`.
- Run the public submit command from your home directory, for example
  `/home/562/ps1744`, rather than from `/g/data/rg42/bactopia-workbench`.
  That keeps launcher logs and default PBS `.o`/`.e` files out of the shared
  install path.
- For a one-off personal submission against a shared config, pass
  `--mail-user <email>` and optionally `--mail-options <events>` on the
  `/g/data/rg42/bactopia-workbench/bin/bactopia-workbench submit gadi ...`
  command instead.
- If Gadi reports an inode overload or scratch quota hold, check `df -Pi`,
  `lquota`, and `nci_account -P <project>` and clean old scratch `work/`,
  `batch_bactopia_*`, and other small-file-heavy run directories before
  rerunning.
