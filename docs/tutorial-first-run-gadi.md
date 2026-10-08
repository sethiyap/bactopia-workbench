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
8. [Copy results to your own computer](#step-8-copy-results-to-your-own-computer)
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

Go to your home directory:

```bash
cd ~
```

## Step 2: Set Your Three Paths

Set three variables so every later command works without editing. **This is the
only step you change** — everything after it is copy-paste.

| Variable | What it points at |
|---|---|
| `READS` | The folder holding your `*_R1.fastq.gz` / `*_R2.fastq.gz` files |
| `METADATA` | The **folder** holding your `*_samplesheet.txt` — not the file itself |
| `OUT` | Where results should be written. Name this after your dataset |

### If you were given a training set

```bash
export READS=/scratch/rg42/training/2026-10-07/user1/fastq
export METADATA=/scratch/rg42/training/2026-10-07/user1/metadata
export OUT=/scratch/rg42/training/2026-10-07/user1/U1
```

Replace `user1`/`U1` with the set you were given.

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
```

For a training set you should see 8 files — 4 samples × 2 files.

**Your sample sheet.** This lists each sample and the organism the lab recorded
for it:

```bash
cat $METADATA/*_samplesheet.txt
```

```text
Sample name	Organism
24GNB-1752	Escherichia coli
24GNB-1753	Escherichia coli
24GNB-1744	Klebsiella pneumoniae
24GNB-1760	Escherichia coli
```

The **sample name** is the part of the FASTQ filename before the first
underscore. In `24GNB-1752_AAHHL2JM5_GTGCAGACAG-TACCATCCGT_L001_R1.fastq.gz`
the sample name is `24GNB-1752`. The names in this sheet must match exactly, or
the pipeline cannot join your results to your metadata.

**Your results folder** is empty for now. Everything the run produces lands
there.

## Step 4: Check Everything Is Ready (Dry Run)

Before submitting anything, run the same command with `--dry-run`. This checks
your inputs, the reference databases and the software, then stops without
queuing any work. It takes a minute or two.

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
into one job. You have 4, so they all go into a single batch.

You will see many lines like:

```text
[INFO] DRY RUN PASS: DATASETS_CACHE found: /g/data/rg42/bactopia_datasets/...
[INFO] DRY RUN PASS: KRAKEN2_DB found: /g/data/rg42/bactopia/kraken_indices/...
```

**What to look for at the very end:**

- `DRY RUN PASS` lines are good — each is one thing confirmed present.
- `DRY RUN WARN` is usually fine. It means an optional step will be skipped.
- `DRY RUN FAIL` must be fixed before you continue. Show it to your trainer.

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

## Step 7: Read Your Results

When `qstat -u $USER` shows no jobs left:

```bash
ls $OUT
```

### The two files worth opening

**1. The Excel workbook** — everything in one spreadsheet:

```bash
ls $OUT/*.xlsx
```

> The filename is your `OUT` folder's name plus `_results.xlsx` — so `OUT`
> ending in `U1` gives `U1_results.xlsx`, and `.../2025/B07` gives
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

```bash
cat $OUT/*_review_required.tsv
```

A sample is flagged when the species the sequencing data points to disagrees
with the organism recorded in your sample sheet. **At least one of your samples
is expected to be flagged** — that is deliberate, so you see what the check
does. Compare `bracken_*` (what the data says) against the `Organism` column
(what the lab recorded) and decide which you trust.

## Step 8: Copy Results To Your Own Computer

First, on Gadi, print the full path you need — `$OUT` does not exist on your own
computer, so you have to paste the real path:

```bash
echo $OUT
```

Then, **in a terminal on your own computer**, not on Gadi, using that path:

```bash
scp '<your-username>@gadi.nci.org.au:<paste-the-path-here>/*.xlsx' .
```

The quotes matter — they stop your own computer from trying to interpret the
`*` before it reaches Gadi.

To copy the whole results folder:

```bash
scp -r <your-username>@gadi.nci.org.au:<paste-the-path-here> .
```

> `/scratch` on Gadi is not backed up and files there are removed after a period
> of inactivity. Copy anything you want to keep.

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
export READS=/scratch/rg42/training/2026-10-07/user1/fastq
export METADATA=/scratch/rg42/training/2026-10-07/user1/metadata
export OUT=/scratch/rg42/training/2026-10-07/user1/U1

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

## Where To Go Next

- [README](../README.md) — all options, input types, and the full command reference
- [docs/setup-gadi-rg42.md](setup-gadi-rg42.md) — getting real data onto Gadi and
  results back to RDS
- [docs/input-formats.md](input-formats.md) — sample sheet and manifest rules in full
