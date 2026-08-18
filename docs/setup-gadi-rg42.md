# Setup Guide: Shared rg42 Gadi Users

This guide is for people using the **shared `rg42` install on Gadi**, where the
pipeline, Bactopia, datasets, and dependencies are already installed and the site
config is already set up. You mostly need to know how to get data in, submit, and
copy results back.

For how to actually *run* the pipeline (the universal command, options, metadata
sheet, FOFN, outputs), see the main [README](../README.md). This page only covers
the rg42-specific operational steps.

## Important Shared Paths

- pipeline code: `/g/data/rg42/bactopia-workbench`
- AGAR raw data: `/scratch/rg42/AGAR/raw_data`
- AGAR metadata: `/scratch/rg42/AGAR/metadata`
- AGAR intermediates and results: `/scratch/rg42/AGAR/intermediates`

## 1. Log In To Gadi And Work From Your Home Directory

Use your home directory as the place where you launch commands. This keeps the
default PBS `.o` and `.e` files out of the shared `/g/data` install.

```bash
ssh <nci_username>@gadi.nci.org.au
cd /home/562/<nci_username>
```

## 2. Get Your Data Onto Gadi

Use one of the two options below.

### Option A: Download A New AGRF Delivery

```bash
cd /home/562/<nci_username>

/g/data/rg42/bactopia-workbench/scripts/download_agrf_to_gadi.sh \
  user@source.example.org:/path/to/AGRF_CAGRF26050180_AAHJ2FTM5 \
  2025 \
  B07
```

This creates:

```bash
/scratch/rg42/AGAR/raw_data/2025/B07/AGRF_CAGRF26050180_AAHJ2FTM5
```

Useful notes:

- `REMOTE_SPEC` must be an rsync-compatible source such as `user@host:/path/to/delivery`
- the default destination root is `/scratch/rg42/AGAR/raw_data`
- use `DEST_ROOT=/absolute/path` if you need a different raw-data root
- use `DRY_RUN=1` first if you want to preview the transfer

### Option B: Restore Existing Data From RDS

```bash
cd /home/562/<nci_username>

RDS_SFTP_USER=<your_rds_username> \
/g/data/rg42/bactopia-workbench/scripts/copy_RDS_to_GADI.sh \
  /rds/PRJ-AGAR/PRJ-AGAR/raw_data/2025/B07/AGRF_CAGRF26050180_AAHJ2FTM5 \
  /scratch/rg42/AGAR/raw_data/2025/B07
```

This helper submits a PBS job. It does not run the transfer interactively in
your login shell.

If you prefer password auth instead of SSH keys, run:

```bash
cd /home/562/<nci_username>

RDS_SFTP_USER=<your_rds_username> \
RDS_SFTP_USE_PASSWORD=1 \
/g/data/rg42/bactopia-workbench/scripts/copy_RDS_to_GADI.sh \
  /rds/PRJ-AGAR/PRJ-AGAR/raw_data/2025/B07/AGRF_CAGRF26050180_AAHJ2FTM5 \
  /scratch/rg42/AGAR/raw_data/2025/B07
```

This prompts once on the login node, stores the password in a temporary file,
and removes that file after the PBS job finishes.

Useful notes:

- `RDS_SRC` can be a file or a directory
- `GADI_DEST` is the destination parent directory on Gadi
- set `GADI_LOCAL_NAME` if you want a different name on Gadi
- if the RDS server disconnects with `Too many authentication failures`, set `RDS_SFTP_IDENTITY_FILE=$HOME/.ssh/<your_key>` so the helper uses only that key
- `RDS_SFTP_IDENTITY_FILE` must be the private key itself, not `known_hosts`, `authorized_keys`, `config`, or a `.pub` file
- set `RDS_SFTP_USE_PASSWORD=1` if you want the helper to prompt once for the password before qsub
- set `RDS_RESUME_DOWNLOAD=1` to resume partial downloads
- set `RDS_SKIP_IF_DEST_EXISTS=1` to skip work when the final target already exists
- set `DEBUG_LOG_DIR=/scratch/rg42/${USER}/transfer_logs` if you want the detailed transfer log in a known place
- set `PBS_LOG_DIR=/scratch/rg42/${USER}/pbs_logs` if you want PBS `.o` and `.e` files somewhere explicit

## 3. Prepare The Metadata Folder

The metadata sheet rules are universal — see
[Metadata Sheet](../README.md#metadata-sheet) on the main page and
[docs/input-formats.md](input-formats.md). On rg42, place the folder under
`/scratch/rg42/AGAR/metadata/<year>/<batch>`.

## 4. Where The Shared Pipeline Lives

The shared install is expected at:

```bash
/g/data/rg42/bactopia-workbench
```

If it has not been installed yet on Gadi, a short shared install is:

```bash
cd /g/data/rg42
git clone https://github.com/sethiyap/bactopia-workbench.git bactopia-workbench
cd /home/562/<nci_username>
```

Maintainers deploying or upgrading the shared install should follow
[docs/gadi-shared-install-checklist.md](gadi-shared-install-checklist.md).

## 5. Site Config (Usually Already Done)

If the shared `rg42` install has already been configured, you can skip this. If
you are maintaining the install, create and review the local Gadi site config:

```bash
cp /g/data/rg42/bactopia-workbench/config/sites/gadi.env.example \
  /g/data/rg42/bactopia-workbench/config/sites/gadi.local.env
```

Then confirm these keys in `config/sites/gadi.local.env` are correct:

- `BACTOPIA_PIPELINE`
- `DATASETS_CACHE`
- `KRAKEN2_DB`
- `NEXTFLOW_CONFIG`
- `KLEBORATE_COMPAT_SCRIPT`
- `FIMTYPER_PIPELINE`
- `FIMTYPER_CONFIG`
- `MERGE_FIMTYPER_SCRIPT`
- `SING_CACHE`

If `DATASETS_CACHE` does not exist yet, download the custom datasets with
`/g/data/rg42/bactopia-workbench/scripts/download_bactopia_datasets.sh`
(reuses an existing cache if present). See
[docs/bactopia-setup.md](bactopia-setup.md) for details.

## 6. Submit The Pipeline

The command and all options are universal — see
[Running The Pipeline](../README.md#running-the-pipeline). A typical rg42
submission looks like:

```bash
cd /home/562/<nci_username>

/g/data/rg42/bactopia-workbench/bin/bactopia-workbench submit gadi \
  /scratch/rg42/AGAR/raw_data/2025/B07/AGRF_CAGRF26050180_AAHJ2FTM5 \
  /scratch/rg42/AGAR/metadata/2025/B07 \
  /scratch/rg42/AGAR/intermediates/2025/B07 \
  50
```

For ST131Typer on rg42, the usual shared clone is
`ST131_TYPER_DIR=/g/data/rg42/ST131Typer`. All other ST131Typer options are on
the main page.

## 7. Copy Finished Results Back To RDS

After the run finishes on Gadi, use the packaged upload helper. The recommended
pattern is `export ...` followed by `qsub -V`.

This is safer than `qsub -v` when you need to pass larger environment values
such as long include lists.

Copy a finished results root:

```bash
export SRC_PATH=/scratch/rg42/AGAR/intermediates/2025/B07
export RDS_DEST=/rds/PRJ-AGAR/PRJ-AGAR/intermediates/2025/B07
export RDS_SFTP_USER=<your_rds_username>
# Optional when the RDS server reports "Too many authentication failures":
# export RDS_SFTP_IDENTITY_FILE=$HOME/.ssh/<your_private_key>
export DEBUG_LOG_DIR=/scratch/rg42/${USER}/transfer_logs
export RDS_UPLOAD_MANIFEST_DIR=/scratch/rg42/${USER}/.rds_transfer_manifests
mkdir -p "$DEBUG_LOG_DIR" "$RDS_UPLOAD_MANIFEST_DIR"
qsub -V /g/data/rg42/bactopia-workbench/scripts/jobsubmission_transfer_gadi_to_rds.pbs
```

Or use password auth from a login shell:

```bash
export SRC_PATH=/scratch/rg42/AGAR/intermediates/2025/B07
export RDS_DEST=/rds/PRJ-AGAR/PRJ-AGAR/intermediates/2025/B07
export RDS_SFTP_USER=<your_rds_username>
export RDS_SFTP_USE_PASSWORD=1
export DEBUG_LOG_DIR=/scratch/rg42/${USER}/transfer_logs
export RDS_UPLOAD_MANIFEST_DIR=/scratch/rg42/${USER}/.rds_transfer_manifests
mkdir -p "$DEBUG_LOG_DIR" "$RDS_UPLOAD_MANIFEST_DIR"
/g/data/rg42/bactopia-workbench/scripts/submit_transfer_gadi_to_rds.sh
```

Copy only the main deliverables first:

```bash
export SRC_PATH=/scratch/rg42/AGAR/intermediates/2025/B07
export RDS_DEST=/rds/PRJ-AGAR/PRJ-AGAR/intermediates/2025/B07
export RDS_SFTP_USER=<your_rds_username>
# Optional when the RDS server reports "Too many authentication failures":
# export RDS_SFTP_IDENTITY_FILE=$HOME/.ssh/<your_private_key>
export RDS_INCLUDE_DIRS='<prefix>_samplesheet_with_results.tsv,batch_bactopia_consolidated'
export DEBUG_LOG_DIR=/scratch/rg42/${USER}/transfer_logs
export RDS_UPLOAD_MANIFEST_DIR=/scratch/rg42/${USER}/.rds_transfer_manifests
mkdir -p "$DEBUG_LOG_DIR" "$RDS_UPLOAD_MANIFEST_DIR"
qsub -V /g/data/rg42/bactopia-workbench/scripts/jobsubmission_transfer_gadi_to_rds.pbs
```

Here, `<prefix>` means the part before `_samplesheet.txt` in your metadata
filename.

Transfer notes:

- `RDS_SFTP_USER` is required for uploads
- if the upload log shows `Too many authentication failures`, set `RDS_SFTP_IDENTITY_FILE=$HOME/.ssh/<your_key>` before `qsub -V`
- `RDS_SFTP_IDENTITY_FILE` must point to the SSH private key itself, not `known_hosts`, `authorized_keys`, `config`, or a `.pub` file
- set `RDS_SFTP_USE_PASSWORD=1` and submit through `scripts/submit_transfer_gadi_to_rds.sh` if you prefer a password prompt
- passwords are not hardcoded in the script; password mode uses a temporary file that is deleted after the job completes
- the wrapper defaults to scratch-backed debug and manifest locations if you do not override them
- by default, `_work` and `.nextflow.log*` are excluded from upload
- `RDS_IGNORE_MANIFEST=1` forces a reupload when files were already recorded in the manifest
- `RDS_INCLUDE_DIRS` is source-relative and works for exact paths, not shell globs

## Inode Warnings On Gadi

The launcher runs an inode preflight against `RESULTS_ROOT`. An inode limit is
a file-count limit, not a disk-size limit.

If you hit an inode warning or failure on Gadi:

- check `df -Pi /scratch/rg42/...`
- check `lquota`
- check `nci_account -P rg42`
- delete stale small-file-heavy directories first, especially old `work/` trees and old batch result folders

The warning threshold is earlier than the hard-stop threshold. That gives you a
chance to clean scratch before the run fails later.
