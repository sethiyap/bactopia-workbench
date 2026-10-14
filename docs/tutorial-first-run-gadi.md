# Tutorial: Your First Run On NCI Gadi

A step-by-step walkthrough, from logging in to reading your results. Every
command can be copied and pasted as written, once you set three paths in
[Step 2](#step-2-set-your-three-paths).

Works for a training set or for your own data — only Step 2 changes.

No Gadi experience is assumed. If a command does something unexpected, skip to
[If Something Goes Wrong](#if-something-goes-wrong).

## What You Need Before Starting

- An **NCI username** (looks like `abc123`). This is written `<your-username>`
  below — replace it with your own, including the angle brackets.
- Membership of the **`rg42`** project.
- Three locations, covered in Step 2: where your **reads** are, where your
  **sample sheet** is, and where **results** should go.

## Contents

1. [Log in to Gadi](#step-1-log-in-to-gadi)
2. [Set your three paths](#step-2-set-your-three-paths)
3. [Look at your inputs](#step-3-look-at-your-inputs)
4. [Check everything is ready](#step-4-check-everything-is-ready-dry-run)
5. [Submit the run](#step-5-submit-the-run)
6. [Check the status](#step-6-check-the-status)
7. [Read your results](#step-7-read-your-results)
8. [Copy results off Gadi](#step-8-copy-results-off-gadi)
9. [If something goes wrong](#if-something-goes-wrong)

---

## Step 1: Log In To Gadi

From a terminal on your own computer:

```bash
ssh <your-username>@gadi.nci.org.au
```

Enter your NCI password when asked. You will land on a **login node** — the
prompt looks like `[abc123@gadi-login-01 ~]$`.

Login nodes are for small commands only. The actual analysis runs on **compute
nodes**, which you never log into directly: you *submit* work to them and the
scheduler runs it when resources are free. That is what Step 5 does.

Find out where you are:

```bash
pwd
```

That prints something like `/home/562/abc123` — your home directory on Gadi.
The number in the middle is your project group and differs between people, so
there is no single path that works for everyone. Worth noting yours now; it is
where you will land every time you log in.

Nothing in this tutorial needs you to be in a particular directory. Every path
is given in full, so the commands work from wherever you happen to be.

### One-time check: do you have the software containers?

The pipeline runs its tools inside pre-built container images. Gadi's compute
nodes have **no internet access**, so they cannot download these themselves —
the images have to be sitting in your own cache before you submit anything.

Your trainer may have done this for you already. Check:

```bash
ls /scratch/rg42/$USER/singularity_cache | wc -l
```

**If it printed a number around 30**, you already have them. Skip ahead to
Step 2.

**If it printed `0`, or `No such file or directory`**, run these four lines:

```bash
SHARED=/scratch/rg42/training/2026-10-12/shared/singularity_cache
MINE=/scratch/rg42/$USER/singularity_cache
mkdir -p $MINE
rsync -a --link-dest=$SHARED $SHARED/ $MINE/
```

Only the first line changes between sessions — the date in it must match the
one your trainer gave you. Your own `START_HERE.txt` has it filled in already:

```bash
cat <your set folder>/START_HERE.txt
```

`$USER` is your own login and fills itself in, so the other three lines are
copied as they are.

This takes a second and uses no extra disk — it points at images that already
exist rather than copying them — and it is safe to run twice. Check it worked:

```bash
ls $MINE | wc -l
```

This matters because a missing cache does **not** stop your run from being
submitted. The dry run in Step 4 passes, the jobs queue happily, and the
failure only appears part-way through with a container error. Checking now
saves an afternoon of confusion.

## Step 2: Set Your Three Paths

Set three variables so every later command works without editing. **This is the
only step you change** — everything after it is copy-paste.

| Variable | What it points at |
|---|---|
| `READS` | The folder holding your `*_R1.fastq.gz` / `*_R2.fastq.gz` files |
| `METADATA` | The **folder** holding your `*_samplesheet.txt` — not the file itself |
| `OUT` | Where results should be written. For a training set this is your own folder; for your own data, name it after the dataset |

### If you were given a training set

```bash
export READS=/scratch/rg42/training/2026-10-12/$USER/fastq
export METADATA=/scratch/rg42/training/2026-10-12/$USER/metadata
export OUT=/scratch/rg42/training/2026-10-12/$USER
```

Your folder is named after your NCI login, and `$USER` fills that in by itself,
so copy those three lines exactly as they are. The only part to check is the
date, which must match the one your trainer gave you.

Your set's `START_HERE.txt` has them filled in too, if you would rather paste
from there.

### If you are running your own data

```bash
export READS=/scratch/rg42/AGAR/raw_data/2025/B07/AGRF_CAGRF26050180_AAHJ2FTM5
export METADATA=/scratch/rg42/AGAR/metadata/2025/B07
export OUT=/scratch/rg42/AGAR/intermediates/2025/B07
```

Any readable path works for `READS` and `METADATA`; `OUT` needs to be somewhere
you can write, normally under `/scratch/rg42`. It is created if it does not
exist.

> **`OUT`'s folder name becomes your output filenames.** The workbook is the
> folder's name plus `_results.xlsx`, so `.../2025/B07` gives `B07_results.xlsx`.
> Avoid naming it `results`, or you get `results_results.xlsx`.

Check all three:

```bash
ls $READS | head
ls $METADATA
echo "results will go to: $OUT"
```

`$READS` should list FASTQ files, and `$METADATA` should contain exactly one
`*_samplesheet.txt`.

> If you log out and back in, run the three `export` lines again. They are
> forgotten when your session ends.

## Step 3: Look At Your Inputs

**Your sequencing reads.** Each sample has two files, `_R1` and `_R2`, which are
the two ends of each DNA fragment:

```bash
ls $READS
ls $READS | wc -l
```

There are two files for every sample, so a one-sample training set shows **2**
and a four-sample set shows 8.

**Your sample sheet.** This lists each sample and the organism the lab recorded
for it:

```bash
cat $METADATA/*_samplesheet.txt
```

```text
Sample name	Organism
24GNB-1745	Klebsiella pneumoniae
```

A header row, then one row per sample. For a training set that is one row.

The **sample name** is the part of the FASTQ filename before the first
underscore. In `24GNB-1745_AAHHL2JM5_CAGTGGCACT-TAACAATAGG_L001_R1.fastq.gz`
the sample name is `24GNB-1745`. The names in this sheet must match exactly, or
the pipeline cannot join your results to your metadata.

**Cross-check the two against each other.** Rather than comparing by eye, there
is a script for it:

```bash
/g/data/rg42/bactopia-workbench/scripts/validate_raw_data_samples.py \
  --raw-dir $READS \
  --metadata $METADATA/*_samplesheet.txt
```

```text
samples on disk:       1
samples in sheet:      1
matched:               1
on disk, not in sheet: 0
in sheet, not on disk: 0

OK: the raw data directory and the metadata sheet agree.
```

You want **`matched`** to equal your sample count and the last two lines to be
`0`. The two failure modes it catches:

- **on disk, not in sheet** — reads the pipeline will process but cannot label,
  so they arrive in the results with no metadata
- **in sheet, not on disk** — a row that will silently vanish from the workbook,
  because there are no reads to process

Both are easy to create by hand and hard to spot afterwards, which is why this
is worth running before every real submission, not just this exercise.

**Your results folder** is empty for now. Everything the run produces lands
there, named after the folder — so `$USER` gives you `<your login>_results.xlsx`.

## Step 4: Check Everything Is Ready (Dry Run)

Always dry-run first. It checks your whole setup **without queuing a single
job**, so there is no cost and nothing to undo. It takes a minute or two.

Run it from a login node — which is where you already are, and any folder will
do, since every path below is absolute:

```bash
/g/data/rg42/bactopia-workbench/bin/bactopia-workbench submit gadi \
  --dry-run \
  $READS \
  $METADATA \
  $OUT \
  50
```

Reading the three paths: **where the reads are**, **where the sample sheet is**,
**where results should go**. The `50` is the batch size — how many samples go
into one job. A training set is well under that, so everything goes into a
single batch.

### What it checks

- The site config, and every path that config points to
- Your sample sheet, and that each input sample has a row in it
- Manifest (FOFN) creation, or reuse of one already there
- Key dependencies, including the datasets cache (`DATASETS_CACHE`), the
  Kraken2 database and the tools used to build the final workbook
- The PADLOC install and database, if you added `--padloc`

You will see many lines like:

```text
[INFO] DRY RUN PASS: DATASETS_CACHE found: /g/data/rg42/bactopia_datasets/...
[INFO] DRY RUN PASS: KRAKEN2_DB found: /g/data/rg42/bactopia/kraken_indices/...
```

### Reading the result

- `DRY RUN PASS` — one thing confirmed present. You want a lot of these.
- `DRY RUN WARN` — usually fine. An optional step will be skipped.
- `DRY RUN FAIL` — must be fixed before you continue.

**If it passes:** run the same command again without `--dry-run`. That is
Step 5.

**If it fails:** fix the item it names and dry-run again. Nothing was queued,
so there is nothing to clean up and no harm in repeating it as often as you
like. If the failure is not something you can fix — a missing database, a
broken path in the shared config — show the line to your trainer.

Do not go to Step 5 until the dry run reports no failures.

## Step 5: Submit The Run

The same command, without `--dry-run`:

```bash
/g/data/rg42/bactopia-workbench/bin/bactopia-workbench submit gadi \
  $READS \
  $METADATA \
  $OUT \
  50
```

### What you are typing

A whole run is one command — a backend, then three folders:

```text
bactopia-workbench submit gadi [OPTIONS] INPUT_SOURCE METADATA_DIR RESULTS_ROOT [BATCH_SIZE]
```

| Part | | |
|---|---|---|
| `submit gadi` | the backend | Gadi's PBS scheduler |
| `INPUT_SOURCE` | `$READS` | folder of FASTQ or FASTA files |
| `METADATA_DIR` | `$METADATA` | folder holding the `*_samplesheet.txt` |
| `RESULTS_ROOT` | `$OUT` | where batches, TSVs and the workbook go |
| `BATCH_SIZE` | `50` | optional: samples per job, default 50 |

Run it from any folder — there is no `cd` to get right, because all three paths
are absolute.

This returns **almost immediately**. That is expected and does not mean it has
finished — it has handed your work to the scheduler and printed the job IDs.
The analysis itself takes much longer.

Each stage waits for the previous one to succeed, so you submit once and the
whole chain runs by itself. You can log out; the jobs keep going.

Note the job IDs it prints. Each looks like `141234567`.

## Step 6: Check The Status

### Are my jobs running?

```bash
qstat -u $USER
```

```text
Job id      Name            User     Time Use S Queue
----------- --------------- -------- -------- - -----
141234567   b001_bactopia   abc123   00:12:45 R normal-exec
141234568   tools_b001      abc123          0 H normal-exec
```

The **S** column is the state:

| S | Meaning |
|---|---|
| `Q` | Queued — waiting for free resources. Normal. Just wait. |
| `R` | Running. |
| `H` | Held — waiting for an earlier stage to finish. Normal in this pipeline. |
| `E` | Exiting — finishing up. |

**Empty output means no jobs are left** — either everything finished, or
something stopped. Go to Step 7 and check for your results.

`H` is not an error here. Later stages are deliberately held until the stage
before them succeeds.

### Which stage is which?

Jobs appear roughly in this order. `b001` is batch 1:

| Job name | What it does |
|---|---|
| `b001_bactopia` | Quality control, assembly, annotation. **The long one.** |
| `tools_b001` | Typing tools: MLST, AMR genes, plasmids, species ID |
| `klebo_b001` | Kleborate (*Klebsiella* typing) |
| `fimtyper_b001` | FimTyper (*E. coli* fimH typing) |
| `merge_bactopia_results` | Combines results across batches |
| `metadata_mapping` | Joins results onto your sample sheet |
| `review_mlst` | Re-checks samples where typing and recorded organism disagree |
| `fetch_asm`, `st131typer` | Collects assemblies, runs ST131Typer |
| `export_results_xlsx` | Writes the final Excel workbook |

### What is happening right now?

The pipeline writes a running log into your results folder:

```bash
tail -f $OUT/submit_workbench_pipeline_*.log
```

Press `Ctrl-C` to stop watching (this does not stop the run).

### If a stage fails

Each stage writes its own output and error files here:

```bash
ls $OUT/pipeline_logs/scheduler
```

To read the error from a failed stage:

```bash
cat $OUT/pipeline_logs/scheduler/b001_bactopia.e*
```

To see why a finished job ended, using a job ID from `qstat`:

```bash
qstat -fx 141234567 | grep -E 'Exit_status|comment'
```

`Exit_status = 0` means success.

### Your run will probably outlast the session

This is normal and is not a problem. Gadi is shared, so your jobs wait in the
queue behind other people's, and the wait is usually far longer than the
analysis itself. A run submitted during a training session often finishes that
evening or the next day.

So you are not expected to see your own results today. Your trainer has a
**reference run** already completed on the same data, and that is what Step 7
walks you through. Everything you learn there applies to your own output when
it arrives.

You can safely log out — the jobs keep running. To check back later:

```bash
ssh <your-username>@gadi.nci.org.au
export OUT=<your results path from Step 2>
qstat -u $USER
ls $OUT
```

An empty `qstat` plus files in `$OUT` means it finished. An empty `qstat` with
no results means a stage failed — see above, and tell your trainer.

## Step 7: Read Your Results

Once `qstat -u $USER` shows no jobs left, your own results are here:

```bash
ls $OUT
```

If your run has not finished yet, follow this step on the **reference output**
your trainer will give you instead — same data, same pipeline, already
complete. Point `OUT` at it and every command below works unchanged:

```bash
export OUT=/scratch/rg42/training/2026-10-12/reference_results
```

### The two files worth opening

**1. The Excel workbook** — everything in one spreadsheet:

```bash
ls $OUT/*.xlsx
```

> The filename is your `OUT` folder's name plus `_results.xlsx` — so `OUT`
> ending in `jc9911` gives `jc9911_results.xlsx`, and `.../2025/B07` gives
> `B07_results.xlsx`.

**2. The results table** — the same main sheet as a text file:

```bash
ls $OUT/*_with_results*.tsv
```

Prefer `*_mlst_reviewed.tsv` if it exists; it is the version after the MLST
review step. Otherwise use `*_with_results.tsv`.

### What is in the table

Your original sample sheet, plus one block of columns per tool, plus review
columns at the very end:

- `mlst_*` — sequence type
- `kleborate_*` — *Klebsiella* typing
- `abritamr_*` — antimicrobial resistance genes
- `plasmidfinder_*` — plasmid replicons
- `bracken_*` — species identification from the reads
- `coverage_x`, `low_coverage` — sequencing depth; flagged below 10×
- `review_required`, `review_reason` — see below

### Samples flagged for review

A sample is flagged when what the sequencing data says disagrees with the
organism recorded in your sample sheet. These rows are wide, so read them in
columns rather than as raw text:

```bash
column -t -s $'\t' $OUT/*_review_required.tsv | less -S
```

`less -S` stops lines wrapping; scroll sideways with the arrow keys and quit
with `q`.

For each flagged row, read across these four:

| Column | |
|---|---|
| `Organism` | what the lab recorded in your sheet |
| `mlst_scheme` | the typing scheme MLST matched, which implies a genus |
| `review_reason` | why it was flagged |
| `mlst_review_note` | what the review step concluded |

A genus mismatch looks like a sheet saying *Escherichia coli* while
`mlst_scheme` names a *Klebsiella* scheme. Whether the sheet or the data is
wrong is a judgement call — the pipeline flags it rather than deciding.

**An empty file, or no file at all, means nothing was flagged.** That is the
normal, good outcome, not a sign something went missing.

Two things worth knowing about flagged samples:

- **A flag is not a failure.** The run completes, the sample is processed, and
  the results are all there. It is marked for a human to look at, nothing more.
- Your trainer may have **deliberately mislabelled one sample** so the check
  fires for somebody. If yours is flagged, ask them to check it against the
  answer key before assuming your data is at fault.

### Comparing against a finished run

Your trainer has a reference run over the same samples. Same file names, same
layout, so you can look at it exactly as you look at your own:

```bash
export REF=/scratch/rg42/training/2026-10-12/reference_results
ls $REF
column -t -s $'\t' $REF/*_review_required.tsv | less -S
```

Leave those files where they are rather than copying them — everyone is reading
the same copy.

One difference to expect: the number of `batch_bactopia_*` folders. Those come
from the batch size, so a run covering more samples than yours is split into
more batches. Everything else should line up.

## Step 8: Copy Results Off Gadi

> `/scratch` on Gadi is not backed up, and files there are deleted after a
> period of inactivity. Copy anything you want to keep.

First, on Gadi, print the full path — `$OUT` does not exist on your own
computer, so you need the real text:

```bash
echo $OUT
```

### To your own computer

Run this **on your own computer**, not on Gadi. A worked example for a user
`jc9911` whose `echo $OUT` printed
`/scratch/rg42/training/2026-10-12/jc9911`:

```bash
scp 'jc9911@gadi.nci.org.au:/scratch/rg42/training/2026-10-12/jc9911/*.xlsx' .
```

Substitute your own login and your own path. The single quotes matter — without
them your computer tries to expand the `*` locally, where it means nothing,
instead of letting Gadi expand it.

The results table too:

```bash
scp 'jc9911@gadi.nci.org.au:/scratch/rg42/training/2026-10-12/jc9911/*.tsv' .
```

> Avoid `scp -r` on the whole folder. It includes `_work`, Nextflow's scratch
> directory, which holds thousands of files and can be tens of gigabytes. The
> workbook and the TSVs are what you want.

### To the RDS project directory

This is how results are archived for real work, and it is **optional for the
training session**. Read the two points below before starting — either one may
mean you should skip this step entirely.

**You need an RDS account.** RDS is a separate system from NCI, with its own
username. It is not your NCI login. **If you do not have an RDS account, this
section does not apply to you** — skip it and use
[your own computer](#to-your-own-computer) above instead. Check with your
trainer if you are not sure whether you have one.

**Use your own project's RDS path.** `RDS_DEST` must be a directory your own
RDS account is allowed to write to, inside your own project. Do not upload into
another project's directory. For a training run, do not upload into a live data
directory either — training output mixed in with real project data is a nuisance
to pick back out. Ask your trainer for a path to use, or skip this step.

Run this on a Gadi **login node**:

```bash
export SRC_PATH=$OUT
export RDS_DEST=<destination your trainer gives you>
export RDS_SFTP_USER=<your RDS username>
export TRANSFER_SCRIPT=/g/data/rg42/bactopia-workbench/scripts/transfer_gadi_to_rds.sh

qsub -V /g/data/rg42/bactopia-workbench/scripts/jobsubmission_transfer_gadi_to_rds.pbs
```

This submits a job on the `copyq` queue rather than copying straight away, so
`qstat -u $USER` shows its progress like any other stage. `_work` and the
Nextflow logs are excluded automatically, so only real results are uploaded.

If you would rather type your password than use an SSH key:

```bash
export SRC_PATH=$OUT
export RDS_DEST=<destination your trainer gives you>
export RDS_SFTP_USER=<your RDS username>
export RDS_SFTP_USE_PASSWORD=1

/g/data/rg42/bactopia-workbench/scripts/submit_transfer_gadi_to_rds.sh
```

That prompts once on the login node and removes the stored password when the
job finishes.

Two things that trip people up:

- **`Too many authentication failures`** — the RDS server is rejecting your
  keys before reaching the right one. Point it at one key:
  `export RDS_SFTP_IDENTITY_FILE=$HOME/.ssh/<your_private_key>`. It must be the
  private key itself, not `.pub`, `known_hosts` or `config`.
- **A second upload copies nothing** — an upload manifest records what already
  went across, so re-running skips it. `export RDS_IGNORE_MANIFEST=1` forces it.

Full reference, including every variable and uploading only selected
subdirectories: [docs/gadi-rds-transfer.md](gadi-rds-transfer.md).

## If Something Goes Wrong

**`ls: cannot access ...: No such file or directory`**
One of your three paths is wrong or unset. Check what they are set to:

```bash
echo "READS=$READS"; echo "METADATA=$METADATA"; echo "OUT=$OUT"
```

If any prints empty, re-run the `export` lines from Step 2.

**`Permission denied`**
You can read `READS` and `METADATA` but cannot write to `OUT`. Point `OUT`
somewhere under `/scratch/rg42` that belongs to you, or ask your trainer.

**The dry run reports `DRY RUN FAIL`**
Do not submit. Show the failing line to your trainer — it names exactly what is
missing.

**`qstat` shows nothing, but there are no results**
A stage failed. Check the end of the pipeline log:

```bash
tail -30 $OUT/submit_workbench_pipeline_*.log
```

then the stage error files in `$OUT/pipeline_logs/scheduler`.

**Jobs sit in `Q` for a long time**
Normal — you are sharing the machine. `qstat -u $USER` to keep checking. Check
the project has compute budget left with `nci_account -P rg42`.

**`Disk quota exceeded`**
Check with `lquota`.

**I submitted twice by mistake**
Delete the extra jobs with `qdel <jobid>`, using the IDs from `qstat -u $USER`.

---

## Quick Reference

```bash
# set up (once per login) - the only lines you edit
export READS=/scratch/rg42/training/2026-10-12/$USER/fastq
export METADATA=/scratch/rg42/training/2026-10-12/$USER/metadata
export OUT=/scratch/rg42/training/2026-10-12/$USER

# check, then submit
/g/data/rg42/bactopia-workbench/bin/bactopia-workbench submit gadi \
  --dry-run $READS $METADATA $OUT 50

/g/data/rg42/bactopia-workbench/bin/bactopia-workbench submit gadi \
  $READS $METADATA $OUT 50

# monitor
qstat -u $USER
tail -f $OUT/submit_workbench_pipeline_*.log

# results
ls $OUT/*.xlsx
cat $OUT/*_review_required.tsv
```

## When You Run A Real Batch

### Other kinds of input

This tutorial uses paired-end Illumina reads, which is the default and needs no
flag. The same command takes other input types by adding one option — only the
input folder and the flag change:

```bash
# Illumina paired-end reads (the default, no flag needed)
/g/data/rg42/bactopia-workbench/bin/bactopia-workbench submit gadi \
  /path/to/fastqs /path/to/metadata /path/to/results 50

# ONT reads, one file per sample
/g/data/rg42/bactopia-workbench/bin/bactopia-workbench submit gadi \
  --input-type ont \
  /path/to/ont_fastqs /path/to/metadata /path/to/results_ont 20

# Assemblies you already have, as FASTA
/g/data/rg42/bactopia-workbench/bin/bactopia-workbench submit gadi \
  --input-type assembly \
  /path/to/assemblies /path/to/metadata /path/to/results 50
```

The metadata sheet is required for every input type, and its sample names must
still match. See [docs/input-formats.md](input-formats.md) for the naming rules
each type expects.

### Running many samples at once

When you come to run a real delivery — tens or hundreds of samples — add
**one** setting:

```bash
export RUN_TOOLS_PARALLEL=1

/g/data/rg42/bactopia-workbench/bin/bactopia-workbench submit gadi \
  $READS $METADATA $OUT 50
```

**What it does.** By default the typing tools (MLST, AMR genes, plasmids,
species ID, and so on) run one after another inside a single job. With
`RUN_TOOLS_PARALLEL=1` each tool becomes its own job and they all run at the
same time.

**Why it matters on a big batch.** With hundreds of samples each tool takes a
long time on its own, so running six of them back to back is what makes that
stage slow. Letting them overlap can save hours.

**Why this tutorial leaves it off.** Each of those jobs asks the scheduler for
48 hours, 8 CPUs and 32 GB. For five samples the tools finish in minutes, so
six such requests just means six longer waits in the queue instead of one — it
is slower, not faster. Small runs: leave it off. Real batches: turn it on.

If a real batch is still slow with it on, the queue rather than the computing is
usually the limit — see
[Run Non-Kleborate Tools In Parallel](../README.md#run-non-kleborate-tools-in-parallel)
for the other knobs.

## Where To Go Next

- [README](../README.md) — all options, input types, and the full command reference
- [docs/setup-gadi-rg42.md](setup-gadi-rg42.md) — getting real data onto Gadi and
  results back to RDS
- [docs/input-formats.md](input-formats.md) — sample sheet and manifest rules in full
