# Data Transfer Between Gadi And RDS

Moving data in and out of Gadi is **not part of a pipeline submission**. It runs
as its own PBS job on the `copyq` queue, before or after the run:

```
RDS  ──(restore raw reads)──▶  Gadi /scratch  ──▶  pipeline  ──▶  results
                                                                    │
RDS  ◀───────────────(archive results)──────────────────────────────┘
```

Both directions talk to RDS over **SFTP**, so nothing needs to be mounted on
Gadi, and both must run from `copyq` — Gadi compute nodes have no outbound
network, and login nodes will kill a long transfer.

Applies to any NCI project. If you are not on `rg42`, read
[Non-rg42 projects](#non-rg42-projects) first — the two PBS files carry `rg42`
in their `#PBS` directives and you have to override them at submission.

## Contents

- [Before you start](#before-you-start)
- [RDS → Gadi: restore data](#rds--gadi-restore-data)
- [Verify the transfer with md5sums](#verify-the-transfer-with-md5sums)
- [Check the raw data against the metadata sheet](#check-the-raw-data-against-the-metadata-sheet)
- [Gadi → RDS: archive results](#gadi--rds-archive-results)
- [Non-rg42 projects](#non-rg42-projects)
- [Authentication](#authentication)
- [Variable reference](#variable-reference)
- [Troubleshooting](#troubleshooting)

## Before you start

You need:

- an **RDS username** — this is your institutional RDS account, usually *not*
  your NCI username. Every command below needs `RDS_SFTP_USER`; nothing falls
  back to a default.
- a working **auth method** — an SSH key registered with RDS, or your RDS
  password. See [Authentication](#authentication).
- somewhere on `/scratch` to write. Never let logs or manifests land in `$HOME`:
  Gadi `/home` has a 10 GB quota, and a transfer job that overruns it fails in
  the PBS epilogue *after* the data has moved.

The scripts, by role:

| | RDS → Gadi | Gadi → RDS |
|---|---|---|
| submit from a login node | `scripts/copy_RDS_to_GADI.sh` | `scripts/submit_transfer_gadi_to_rds.sh` |
| PBS payload | (same file, re-entered inside the job) | `scripts/jobsubmission_transfer_gadi_to_rds.pbs` |
| worker | (same file) | `scripts/transfer_gadi_to_rds.sh` |

`copy_RDS_to_GADI.sh` is one self-submitting file: run it on a login node and it
`qsub`s **itself**, then does the transfer inside the job. It decides which role
it is playing from `PBS_JOBID`, so it never runs the transfer in your login
shell.

Paths below use the shared rg42 install (`/g/data/rg42/bactopia-workbench`).
On your own deployment, substitute your clone.

## RDS → Gadi: restore data

Stage raw reads (or any archived directory) onto `/scratch` before submitting a
pipeline run.

```bash
RDS_SFTP_USER=<your_rds_username> \
/g/data/rg42/bactopia-workbench/scripts/copy_RDS_to_GADI.sh \
  /rds/<PROJECT>/<PROJECT>/raw_data/2025/B07/<delivery_dir> \
  /scratch/<nci_project>/<user>/raw_data/2025/B07
```

The two arguments are the **RDS source** (a file or a directory) and the **Gadi
destination parent** — the source's basename is created inside it. It prints a
job id and exits; watch it with `qstat`.

Useful behaviour:

- **Resumable.** `RDS_RESUME_DOWNLOAD=1` (the default) uses `sftp get -a`, so a
  re-run continues a partial file instead of starting over.
- **A directory restore refuses to overwrite.** If the target already exists it
  stops rather than merging into it. Use a fresh destination, rename with
  `GADI_LOCAL_NAME`, or set `RDS_SKIP_IF_DEST_EXISTS=1` to make an already-present
  target a no-op (useful when scripting a restore that may already have run).
- It writes a `<name>_download_info.txt` beside the restored data recording what
  came from where and when.
- `DEBUG_LOG_DIR` defaults to `logs/` **in the directory you submitted from**.
  If you submit from `$HOME`, set it explicitly:
  `DEBUG_LOG_DIR=/scratch/<proj>/$USER/transfer_logs`.

A job that exits 0 means `sftp` reported no error, not that the data is complete.
Before submitting a pipeline run, work through
[Verify the transfer with md5sums](#verify-the-transfer-with-md5sums) and
[Check the raw data against the metadata sheet](#check-the-raw-data-against-the-metadata-sheet).

## Verify the transfer with md5sums

**Nothing in this repo checks checksums for you.** The transfer scripts confirm
that `sftp` reported success, not that the bytes are intact and complete. Do this
by hand after every restore, before building the FOFN.

AGRF ships a checksum manifest with each delivery (`checksums.md5`,
`*_checksums.txt`, or similar). The paths inside it are **relative**, so you must
run `md5sum -c` from the directory those paths are relative to — usually the
delivery directory itself:

```bash
cd /scratch/<proj>/<user>/raw_data/2025/B07/<delivery_dir>
md5sum -c checksums.md5 2>&1 | tee md5check.log
```

For a large delivery, `--quiet` prints only the failures:

```bash
md5sum --quiet -c checksums.md5
```

Then confirm the count matches what the manifest promised — a clean `--quiet` run
proves nothing if only three of 400 files were even looked at:

```bash
wc -l < checksums.md5                        # files the manifest expects
grep -c ': OK$'               md5check.log   # verified
grep -c ': FAILED$'           md5check.log   # present, but hash differs
grep -c 'FAILED open or read' md5check.log   # not there at all
```

The first number must equal the sum of the other three. Keep `2>&1` on the
`tee` — the `No such file or directory` and `WARNING:` lines go to **stderr**,
and without it they scroll past while the log looks clean.

### Reading the output

The two failure modes look similar and mean completely different things:

| Line | Meaning | What to do |
|---|---|---|
| `<file>: OK` | hash matched | nothing |
| `<file>: FAILED` | file is present, hash **differs** | corrupt or truncated — re-transfer that file |
| `<file>: FAILED open or read` | file **is not there** | no comparison happened; see below |

`FAILED open or read` plus the trailing `WARNING: N listed files could not be
read` means the manifest names files that are not in the directory you ran from.
Nothing is corrupt. In order of likelihood: you ran from the wrong directory; the
delivery is genuinely incomplete; or the files arrived under different names.
Check before assuming a re-transfer is needed:

```bash
find /scratch/<proj>/<user>/raw_data -name '23GNB-1538*' -o -name '24GNB-411*'
```

If both mates of a sample are missing together, that is a per-sample drop rather
than random truncation. If only some lanes are missing (`_L001_` absent while
`_L002_`…`_L005_` are present), the sample will still reach the FOFN as
`merge-pe` and be assembled from fewer reads than intended, with no warning at
all — see [input-formats.md](input-formats.md).

To verify only the files that did arrive, and deal with the absent ones
separately:

```bash
md5sum -c --ignore-missing checksums.md5
```

### Catch truncated files without a manifest

If a delivery came without checksums, gzip's own integrity check is the next best
thing — it will not detect a silently substituted file, but it does catch every
truncated one:

```bash
find . -name '*.fastq.gz' -size 0            # zero-byte files
find . -name '*.fastq.gz' -size -1000c       # absurdly small (bytes, not blocks)
find . -name '*.fastq.gz' -print0 | xargs -0 -P 4 -n 1 gzip -t
```

`gzip -t` prints nothing for a good file, so any output is a problem — a
truncated download reports `unexpected end of file`. Use the `c` (bytes) suffix
for the size checks: `-size -1k` rounds every non-empty file up to one block, so
it silently means the same thing as `-size 0`.

### Do this off the login node

Hashing a whole delivery is IO- and CPU-heavy, and Gadi login nodes kill
long-running processes. For anything more than a handful of files, run the check
on `copyq` alongside the transfer:

```bash
qsub -P <proj> -q copyq -l walltime=2:00:00,ncpus=1,mem=8GB \
  -l storage=gdata/<proj>+scratch/<proj> \
  -o /scratch/<proj>/$USER/transfer_logs -e /scratch/<proj>/$USER/transfer_logs \
  -- /bin/bash -c 'cd /scratch/<proj>/<user>/raw_data/2025/B07/<delivery_dir> && md5sum -c checksums.md5'
```

Never let `-o`/`-e` default to the submission directory — see
[Troubleshooting](#troubleshooting).

### The other direction (Gadi → RDS)

The upload manifest records *which files were sent*, not their hashes, so it will
happily mark a truncated upload as done. To check an archive, generate a manifest
before the upload and verify it after restoring:

```bash
# on Gadi, before archiving
cd "$SRC_PATH"
find . -type f ! -path './_work/*' -print0 \
  | sort -z | xargs -0 md5sum > /scratch/<proj>/$USER/transfer_logs/archive.md5
```

On macOS there is no `md5sum`; use `md5 -r <file>`, which prints the same
`<hash>  <path>` layout.

## Check the raw data against the metadata sheet

Checksums prove the files are intact. They say nothing about whether the files on
disk are the samples the metadata sheet describes. Run this before
`submit_workbench_pipeline.sh`.

The pipeline's own preflight (`scripts/validate_metadata_samples.py`, invoked from
`submit_workbench_pipeline.sh`) checks **one direction only**: every sample in the
Bactopia input must appear in the sheet's `Sample name` column. A sample that is
in the sheet but has **no reads on disk** passes validation silently, never enters
the FOFN, and simply has no row in the final workbook. That is exactly what four
missing FASTQ files look like downstream, so check both directions yourself.

### `validate_raw_data_samples.py`

`scripts/validate_raw_data_samples.py` does both directions and reports the
missing names on each side. It needs nothing but Python 3 — run it on a login
node, before submitting:

```bash
scripts/validate_raw_data_samples.py \
  --raw-dir  /scratch/<proj>/<user>/raw_data/2025/B07/<delivery_dir> \
  --metadata /scratch/<proj>/<user>/metadata/<prefix>_samplesheet.txt \
  --agar
```

```
samples on disk:       4
samples in sheet:      4
matched:               3
on disk, not in sheet: 1
in sheet, not on disk: 1

ERROR  on disk but not in the sheet -- submission will be refused (1)
  25GNB-002  (25GNB-002_XXX_L001_R1.fastq.gz)

WARNING  in the sheet but no reads on disk -- silently absent from the workbook (1)
  27GNB-900

ERROR  incomplete or ambiguous files (1)
  missing R2 for 26GNB-77_QQQ_L001_R1.fastq.gz (expected 26GNB-77_QQQ_L001_R2.fastq.gz)
```

It derives sample names exactly as the pipeline does, so the comparison reflects
what would really run — basename up to the first underscore for `illumina`, and
the basename minus its extension for `--input-type ont` / `assembly`. It also
reports missing R2 mates, zero-byte files, duplicate sample names (in the sheet,
and on disk for ont/assembly), and which samples are lane-split into a single
`merge-pe` row.

| Flag | Purpose |
|---|---|
| `--input-type` | `illumina` (default), `ont`, `assembly` |
| `--agar` | Apply the AGAR-mode include filter, `^[0-9]{2}GNB-[0-9]+R?$`, so controls and undetermined reads are not reported as missing metadata |
| `--include-regex` / `--exclude-regex` | Default to `$INCLUDE_SAMPLE_REGEX` / `$EXCLUDE_SAMPLE_REGEX`, so the report matches what the submission will filter |
| `--strict` | Treat sheet rows with no reads as an error rather than a warning |
| `--json <path>` | Write the full result as JSON as well |
| `--max-list` | Names printed per section (default 40) |

Exit status is **0** when clean or only warnings, **1** when there are errors,
**2** on a usage or IO problem — so it drops straight into a submission wrapper.

By default a sheet row with no reads is a *warning*, not an error: an AGAR sheet
routinely covers more samples than any one delivery contains. Use `--strict` when
the sheet is meant to describe exactly this delivery.

### Doing it by hand

The same comparison without the script, if you want to see the working. Sample
names are derived the way `scripts/2_create_fofn_bactopia.sh` derives them: the
FASTQ basename up to the **first underscore**.

```bash
RAW_DIR=/scratch/<proj>/<user>/raw_data/2025/B07/<delivery_dir>
SHEET=/scratch/<proj>/<user>/metadata/<prefix>_samplesheet.txt
WORK=/scratch/<proj>/$USER/transfer_logs

# sample names that actually have reads on disk
find "$RAW_DIR" -maxdepth 1 -type f \( -name '*_R1.fastq.gz' -o -name '*_R1.fq.gz' \) \
  | xargs -n 1 basename | sed 's/_.*//' | sort -u > "$WORK/on_disk.txt"

# sample names in the metadata sheet's "Sample name" column (TSV; strips BOM and CRs)
sed $'1s/^\xef\xbb\xbf//; s/\r$//' "$SHEET" \
  | awk -F'\t' '
      NR==1 { for (i=1;i<=NF;i++) if (tolower($i)=="sample name") c=i;
              if (!c) { print "No \"Sample name\" column found" > "/dev/stderr"; exit 1 }
              next }
      c && $c != "" { print $c }' \
  | sort -u > "$WORK/in_sheet.txt"
```

If your sheet is a CSV rather than a TSV, change `-F'\t'` to `-F','` (the
validator auto-detects the delimiter; this one-liner does not).

Then compare:

```bash
echo "matched:            $(comm -12 "$WORK/on_disk.txt" "$WORK/in_sheet.txt" | wc -l)"
echo "reads with no row:  $(comm -23 "$WORK/on_disk.txt" "$WORK/in_sheet.txt" | wc -l)"
echo "rows with no reads: $(comm -13 "$WORK/on_disk.txt" "$WORK/in_sheet.txt" | wc -l)"

comm -23 "$WORK/on_disk.txt" "$WORK/in_sheet.txt"   # on disk, not in the sheet
comm -13 "$WORK/on_disk.txt" "$WORK/in_sheet.txt"   # in the sheet, not on disk
```

- **On disk, not in the sheet** — `submit_workbench_pipeline.sh` will refuse to
  submit (`Input samples missing from metadata 'Sample name' column`). Add the
  rows, or exclude the samples with `EXCLUDE_SAMPLE_REGEX`.
- **In the sheet, not on disk** — silently dropped. Either the reads never
  arrived (cross-check against the md5 `FAILED open or read` list above), or the
  sample belongs to a different delivery, or the name in the sheet does not match
  the FASTQ prefix. Decide deliberately; nothing downstream will remind you.

### Two more checks worth running

Both mates present for every pair — `2_create_fofn_bactopia.sh` aborts on a
missing R2, so catching it here saves a failed submission:

```bash
for r1 in "$RAW_DIR"/*_R1.fastq.gz; do
  r2=${r1/_R1.fastq.gz/_R2.fastq.gz}
  [[ -f $r2 ]] || echo "missing R2: $(basename "$r1")"
done
```

Lanes per sample — anything with more than one pair is lane-split and will be
merged into a single `merge-pe` row. Confirm the counts are what the delivery note
says, since a sample missing one of its lanes still looks fine:

```bash
find "$RAW_DIR" -maxdepth 1 -name '*_R1.fastq.gz' \
  | xargs -n 1 basename | sed 's/_.*//' | sort | uniq -c | sort -rn | head -20
```

## Gadi → RDS: archive results

Copy a finished results root back to RDS. Set the source, destination and
username, then submit:

```bash
export SRC_PATH=/scratch/<nci_project>/<user>/intermediates/2025/B07
export RDS_DEST=/rds/<PROJECT>/<PROJECT>/intermediates/2025/B07
export RDS_SFTP_USER=<your_rds_username>
export DEBUG_LOG_DIR=/scratch/<nci_project>/$USER/transfer_logs
export RDS_UPLOAD_MANIFEST_DIR=/scratch/<nci_project>/$USER/.rds_transfer_manifests
mkdir -p "$DEBUG_LOG_DIR" "$RDS_UPLOAD_MANIFEST_DIR"

qsub -V /g/data/rg42/bactopia-workbench/scripts/jobsubmission_transfer_gadi_to_rds.pbs
```

Use `scripts/submit_transfer_gadi_to_rds.sh` instead of `qsub -V` when you want
the password prompt (see [Authentication](#authentication)); it takes the same
exported variables.

What the upload does that a plain `rsync` would not:

- **It keeps a manifest.** Every uploaded file is recorded under
  `RDS_UPLOAD_MANIFEST_DIR`, keyed by source→destination pair. Re-running after
  a timeout, a dropped connection, or a walltime kill queues only what has not
  landed yet. `RDS_IGNORE_MANIFEST=1` forces a full re-upload.
- **It uploads the deliverables first.** The mapped samplesheet
  (`*_samplesheet_with_results.tsv`) goes first, then the consolidated results
  directory (`*_consolidated/`), then everything else newest-first. If the job
  runs out of walltime, you still have the results you actually needed.
- **It skips the junk by default.** `_work` (the Nextflow work tree) and
  `.nextflow.log*` are excluded — see `RDS_EXCLUDE_DIRS` / `RDS_EXCLUDE_FILES`.
- **It chunks the SFTP session** (`RDS_SFTP_CHUNK_SIZE`, 2000 files per session
  from the PBS wrapper) so one dropped connection does not lose the whole run.

### Copy only the main deliverables

For a quick hand-off before archiving the full run:

```bash
export SRC_PATH=/scratch/<nci_project>/<user>/intermediates/2025/B07
export RDS_DEST=/rds/<PROJECT>/<PROJECT>/intermediates/2025/B07
export RDS_SFTP_USER=<your_rds_username>
export RDS_INCLUDE_DIRS='<prefix>_samplesheet_with_results.tsv,batch_bactopia_consolidated'
qsub -V /g/data/rg42/bactopia-workbench/scripts/jobsubmission_transfer_gadi_to_rds.pbs
```

`<prefix>` is the part of your metadata filename before `_samplesheet.txt`.
Because the manifest persists, a later full run uploads only what this one did
not.

### Copy only what changed

`RDS_COPY_SINCE='2026-09-01'` (or `'2026-09-01 14:00:00'`) restricts the upload
to files newer than that timestamp — useful after re-running one stage of an
already-archived batch.

## Non-rg42 projects

Both PBS files hardcode the shared project in their `#PBS` directives:

```
#PBS -P rg42
#PBS -l storage=gdata/rg42+scratch/rg42
```

A job submitted under another NCI project is rejected, or starts without its
own filesystems mounted. **Command-line `qsub` options override in-file `#PBS`
directives**, so pass your project and mounts at submission — do not edit the
files:

Archive (Gadi → RDS):

```bash
export SRC_PATH=/scratch/<proj>/<user>/intermediates/2025/B07
export RDS_DEST=/rds/<PROJECT>/<PROJECT>/intermediates/2025/B07
export RDS_SFTP_USER=<your_rds_username>
export DEBUG_LOG_DIR=/scratch/<proj>/$USER/transfer_logs
export RDS_UPLOAD_MANIFEST_DIR=/scratch/<proj>/$USER/.rds_transfer_manifests
export TRANSFER_SCRIPT=<your_clone>/scripts/transfer_gadi_to_rds.sh
mkdir -p "$DEBUG_LOG_DIR" "$RDS_UPLOAD_MANIFEST_DIR"

qsub -P <proj> -l storage=gdata/<proj>+scratch/<proj> \
  -o "$DEBUG_LOG_DIR" -e "$DEBUG_LOG_DIR" -V \
  <your_clone>/scripts/jobsubmission_transfer_gadi_to_rds.pbs
```

Restore (RDS → Gadi) — submit the file directly rather than running it, so your
options apply. It sees `PBS_JOBID` inside the job and runs the transfer instead
of re-submitting:

```bash
export RDS_SRC=/rds/<PROJECT>/<PROJECT>/raw_data/2025/B07/<delivery_dir>
export GADI_DEST=/scratch/<proj>/<user>/raw_data/2025/B07
export RDS_SFTP_USER=<your_rds_username>
export DEBUG_LOG_DIR=/scratch/<proj>/$USER/transfer_logs
mkdir -p "$DEBUG_LOG_DIR"

qsub -P <proj> -l storage=gdata/<proj>+scratch/<proj> \
  -o "$DEBUG_LOG_DIR" -e "$DEBUG_LOG_DIR" -V \
  <your_clone>/scripts/copy_RDS_to_GADI.sh
```

Other non-rg42 notes:

- `TRANSFER_SCRIPT` — the PBS wrapper looks for the worker beside itself, then
  under `PBS_O_WORKDIR`, then `/g/data/<project>/bactopia-workbench/scripts/`.
  Setting it explicitly removes the guesswork.
- Manifest and password-file locations default to `/scratch/<project>/$USER/...`
  and fall back to `$HOME` if that is not writable — set
  `RDS_UPLOAD_MANIFEST_DIR` explicitly to keep them off `/home`.
- `RDS_SFTP_HOST` defaults to `research-data-ext.sydney.edu.au`. Override it if
  your RDS is at another institution.
- The password-prompt helper (`submit_transfer_gadi_to_rds.sh`) calls `qsub`
  without a `-P` override, so on a non-rg42 project use the key-based route
  above, or create the password file yourself and pass
  `RDS_SFTP_PASSWORD_FILE` to a manual `qsub`.

## Authentication

### Where credentials go

**Nothing goes in this repository.** No RDS username, key path, or password is
read from `config/sites/*.env`, `config/defaults.env`, or any file under
`scripts/` — unlike the pipeline's own settings, the transfer helpers read
credentials **only from your shell environment**. So there is no file in the
clone to edit, and no file to accidentally commit.

| What | Where it goes | Secret? |
|---|---|---|
| RDS username | `export RDS_SFTP_USER=...` — safe to persist in your `~/.bashrc` on Gadi | no |
| SSH key path | `export RDS_SFTP_IDENTITY_FILE=...` — safe to persist the same way | no (the path isn't; the key file is) |
| SSH private key | `$HOME/.ssh/` on Gadi, mode `600` | **yes** |
| RDS password | typed at a prompt; never stored by you | **yes** |

To stop retyping the two non-secret ones, add them once to `~/.bashrc` on Gadi:

```bash
cat >> ~/.bashrc <<'EOF'
export RDS_SFTP_USER=<your_rds_username>
export RDS_SFTP_IDENTITY_FILE=$HOME/.ssh/<your_private_key>
EOF
```

Both directions pass your environment to the job with `qsub -V`, so anything
exported in your login shell reaches the transfer.

Never do these:

- put a password in `~/.bashrc`, in a script, or in any file inside the clone
- pass a password as a command-line argument — it is visible in `ps` and lands
  in your shell history
- share a key or password between users; each person uses their own RDS account,
  and the manifests and logs are per-user paths under `/scratch`

### Option A: SSH key (preferred — works unattended)

Generate a key on Gadi if you do not have one, then register the **public** half
with RDS through your institution's RDS interface (for University of Sydney RDS,
via the research data management request process — it is not something these
scripts can do for you):

```bash
ssh-keygen -t ed25519 -f ~/.ssh/rds_key -C "rds transfer"
chmod 600 ~/.ssh/rds_key
cat ~/.ssh/rds_key.pub          # register this half with RDS
```

Then point the helper at the private half:

```bash
export RDS_SFTP_USER=<your_rds_username>
export RDS_SFTP_IDENTITY_FILE=$HOME/.ssh/rds_key
```

It adds `-i <file> -o IdentitiesOnly=yes`, so only that key is offered. Point it
at the **private key itself** — not `known_hosts`, `authorized_keys`, `config`,
or a `.pub` file; the script rejects those by name.

Check it works before submitting a job:

```bash
sftp -i ~/.ssh/rds_key -o IdentitiesOnly=yes \
  <your_rds_username>@research-data-ext.sydney.edu.au
```

### Option B: Password (prompts once, on the login node)

Set `RDS_SFTP_USE_PASSWORD=1` and submit through the helper rather than `qsub`.
It prompts once, with the input hidden:

```bash
# upload
export RDS_SFTP_USER=<your_rds_username>
export RDS_SFTP_USE_PASSWORD=1
/g/data/rg42/bactopia-workbench/scripts/submit_transfer_gadi_to_rds.sh
```

```bash
# download
RDS_SFTP_USER=<your_rds_username> RDS_SFTP_USE_PASSWORD=1 \
  /g/data/rg42/bactopia-workbench/scripts/copy_RDS_to_GADI.sh <src> <dest>
```

What happens to the password:

1. read from the prompt (never echoed, never in your history)
2. written to a `mode 600` file under `/scratch/<project>/$USER/.rds_sftp_secrets`
   — or `$HOME/.rds_sftp_secrets` if that scratch path is not writable
3. its **path** is passed to the PBS job as `RDS_SFTP_PASSWORD_FILE`; the
   password itself never appears in a `qsub` argument or in the job script
4. deleted when the job finishes, because the helper also sets
   `RDS_SFTP_DELETE_PASSWORD_FILE=1`

If a job is killed before cleanup, remove the leftover yourself:

```bash
ls -l /scratch/<project>/$USER/.rds_sftp_secrets/
rm -f /scratch/<project>/$USER/.rds_sftp_secrets/rds_sftp_password.*
```

**Reusing a password file** (needed on non-rg42, where the prompt helper cannot
set `-P`): create it yourself rather than letting it into your history, and let
the job delete it.

```bash
mkdir -p /scratch/<proj>/$USER/.rds_sftp_secrets
( umask 077; read -rs -p 'RDS password: ' p; printf '%s\n' "$p" \
    > /scratch/<proj>/$USER/.rds_sftp_secrets/rds_pw; unset p )
export RDS_SFTP_PASSWORD_FILE=/scratch/<proj>/$USER/.rds_sftp_secrets/rds_pw
export RDS_SFTP_DELETE_PASSWORD_FILE=1
```

## Variable reference

Common to both directions:

| Variable | Default | Purpose |
|---|---|---|
| `RDS_SFTP_USER` | *(required)* | RDS account name |
| `RDS_SFTP_HOST` | `research-data-ext.sydney.edu.au` | RDS SFTP endpoint |
| `RDS_SFTP_IDENTITY_FILE` | *(ssh default)* | SSH private key |
| `RDS_SFTP_USE_PASSWORD` | `0` | Prompt for a password before `qsub` |
| `RDS_SFTP_PASSWORD_FILE` | *(none)* | Reuse an existing password file |
| `RDS_SFTP_OPTS` | *(none)* | Extra `sftp` options, e.g. `-v` |
| `DEBUG_LOG_DIR` | see below | Detailed per-run transfer log |
| `PBS_LOG_DIR` | *(unset → submission dir)* | PBS `.o`/`.e` destination |

Gadi → RDS only:

| Variable | Default | Purpose |
|---|---|---|
| `SRC_PATH` | *(required)* | Gadi source directory |
| `RDS_DEST` | *(required)* | RDS destination directory |
| `TRANSFER_SCRIPT` | auto-discovered | Path to `transfer_gadi_to_rds.sh` |
| `RDS_UPLOAD_MANIFEST_DIR` | `/scratch/<project>/$USER/.rds_transfer_manifests` | Where upload manifests live |
| `RDS_UPLOAD_MANIFEST` | derived from src+dest | An explicit manifest file |
| `RDS_IGNORE_MANIFEST` | `0` | `1` re-uploads everything |
| `RDS_PRIORITIZE_UPLOADS` | `1` | `0` keeps discovery order |
| `RDS_INCLUDE_DIRS` | *(none)* | Comma-separated paths to keep |
| `RDS_EXCLUDE_DIRS` | `_work` | Comma-separated dirs to skip |
| `RDS_EXCLUDE_FILES` | `.nextflow.log,.nextflow.log.*` | File globs to skip |
| `RDS_EXCLUDE_PATHS` | *(none)* | Path globs to skip |
| `RDS_COPY_SINCE` | *(all files)* | Only files newer than this timestamp |
| `RDS_SFTP_CHUNK_SIZE` | `2000` from the PBS wrapper | Files per SFTP session |
| `KEEP_DEBUG_LOG` | `0` | `1` keeps the log of a successful run |

RDS → Gadi only:

| Variable | Default | Purpose |
|---|---|---|
| `RDS_SRC` | *(required)* | RDS source file or directory |
| `GADI_DEST` | *(required)* | Gadi destination **parent** directory |
| `GADI_LOCAL_NAME` | source basename | Rename on arrival (a name, not a path) |
| `RDS_RESUME_DOWNLOAD` | `1` | Resume partial files (`sftp get -a`) |
| `RDS_SKIP_IF_DEST_EXISTS` | `0` | `1` makes an existing target a no-op |

## Troubleshooting

**`Too many authentication failures`** — your SSH agent offered too many keys
before the right one. Set `RDS_SFTP_IDENTITY_FILE` to the specific private key;
the helper adds `IdentitiesOnly=yes` so only that key is tried.

**The login is rejected in password mode** — the helper tries
keyboard-interactive first, then plain password. If correct credentials still
fail, the RDS account requires key auth; use `RDS_SFTP_IDENTITY_FILE`.

**`Post job file processing error`** — PBS could not deliver the job's `.o`/`.e`
files, almost always because they were headed for a `$HOME` that is at its 10 GB
quota. It happens in the epilogue, *after* the transfer, so the data may well
have arrived. Set `PBS_LOG_DIR` (and `DEBUG_LOG_DIR`) to a `/scratch` path and
resubmit; the manifest means the re-run only moves what did not land. See
`CLAUDE.md` → "PBS Post job file processing error".

**The upload job hit walltime** — just resubmit. The manifest skips everything
already uploaded, and priority ordering means the samplesheet and consolidated
results went first.

**Nothing was queued** — the upload exits early with `No new files need
uploading` when the manifest already covers every eligible file. Use
`RDS_IGNORE_MANIFEST=1` to force it, or check your `RDS_INCLUDE_DIRS` /
`RDS_EXCLUDE_*` filters.

**Where the real error is** — the PBS `.o`/`.e` only carry the wrapper's summary.
The detailed `sftp` log is the file the job reports as `DEBUG_RUN_LOG`, under
`DEBUG_LOG_DIR`. It is deleted after a *successful* upload unless you set
`KEEP_DEBUG_LOG=1`; a failed run always keeps it and tails the last 40 lines
into the PBS output.

## See also

- [setup-gadi-rg42.md](setup-gadi-rg42.md) — shared rg42 install, with these
  transfers written out against the real AGAR paths
- [setup-gadi-other.md](setup-gadi-other.md) — deploying under your own NCI
  project
