# Tutorial: Your First Run On NCI Gadi

A step-by-step walkthrough, from logging in to reading your results. Every
command can be copied and pasted as written, once you set one variable in
[Step 2](#step-2-point-the-tutorial-at-your-folder).

No Gadi experience is assumed. If a command does something unexpected, skip to
[If Something Goes Wrong](#if-something-goes-wrong).

## What You Need Before Starting

- An **NCI username** (looks like `abc123`). This is written `<your-username>`
  below — replace it with your own, including the angle brackets.
- Membership of the **`rg42`** project.
- The **session folder** your trainer gives you, for example
  `/scratch/rg42/training/2026-10-07/user1`. Each person has their own.

## Contents

1. [Log in to Gadi](#step-1-log-in-to-gadi)
2. [Point the tutorial at your folder](#step-2-point-the-tutorial-at-your-folder)
3. [Look at what you have been given](#step-3-look-at-what-you-have-been-given)
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

## Step 2: Point The Tutorial At Your Folder

Set one variable so every later command works without editing. Replace the path
with the session folder your trainer gave you:

```bash
export MYSET=/scratch/rg42/training/2026-10-07/user1
```

Check it is right:

```bash
ls $MYSET
```

Expected output — three folders:

```text
fastq  metadata  results
```

> If you log out and back in, run the `export MYSET=...` line again. It is
> forgotten when your session ends.

## Step 3: Look At What You Have Been Given

**Your sequencing reads.** Each sample has two files, `_R1` and `_R2`, which are
the two ends of each DNA fragment:

```bash
ls $MYSET/fastq
```

You should see 8 files — 4 samples × 2 files.

**Your sample sheet.** This lists each sample and the organism the lab recorded
for it:

```bash
cat $MYSET/metadata/*_samplesheet.txt
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
  $MYSET/fastq \
  $MYSET/metadata \
  $MYSET/results \
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
  $MYSET/fastq \
  $MYSET/metadata \
  $MYSET/results \
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
tail -f $MYSET/results/submit_workbench_pipeline_*.log
```

Press `Ctrl-C` to stop watching (this does not stop the run).

### If a stage fails

Each stage writes its own output and error files here:

```bash
ls $MYSET/results/pipeline_logs/scheduler
```

To read the error from a failed stage:

```bash
cat $MYSET/results/pipeline_logs/scheduler/b001_bactopia.e*
```

To see why a finished job ended, using a job ID from `qstat`:

```bash
qstat -fx 141234567 | grep -E 'Exit_status|comment'
```

`Exit_status = 0` means success.

## Step 7: Read Your Results

When `qstat -u $USER` shows no jobs left:

```bash
ls $MYSET/results
```

### The two files worth opening

**1. The Excel workbook** — everything in one spreadsheet:

```bash
ls $MYSET/results/*.xlsx
```

> The filename is built from your results folder's name, so it is
> `results_results.xlsx`. That repetition is expected, not a mistake.

**2. The results table** — the same main sheet as a text file:

```bash
ls $MYSET/results/*_with_results*.tsv
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
cat $MYSET/results/*_review_required.tsv
```

A sample is flagged when the species the sequencing data points to disagrees
with the organism recorded in your sample sheet. **At least one of your samples
is expected to be flagged** — that is deliberate, so you see what the check
does. Compare `bracken_*` (what the data says) against the `Organism` column
(what the lab recorded) and decide which you trust.

## Step 8: Copy Results To Your Own Computer

Run this **in a terminal on your own computer**, not on Gadi:

```bash
scp '<your-username>@gadi.nci.org.au:/scratch/rg42/training/2026-10-07/user1/results/*.xlsx' .
```

Adjust the path to your own set. The quotes matter — they stop your own
computer from trying to interpret the `*`.

To copy the whole results folder:

```bash
scp -r <your-username>@gadi.nci.org.au:/scratch/rg42/training/2026-10-07/user1/results .
```

> `/scratch` on Gadi is not backed up and files there are removed after a period
> of inactivity. Copy anything you want to keep.

## If Something Goes Wrong

**`ls: cannot access ...: No such file or directory`**
`MYSET` is wrong or unset. Re-run the `export MYSET=...` line from Step 2 and
check with `echo $MYSET`.

**`Permission denied`**
Check with your trainer that the folder belongs to you.

**The dry run reports `DRY RUN FAIL`**
Do not submit. Show the failing line to your trainer — it names exactly what is
missing.

**`qstat` shows nothing, but there are no results**
A stage failed. Check the end of the pipeline log:

```bash
tail -30 $MYSET/results/submit_workbench_pipeline_*.log
```

then the stage error files in `$MYSET/results/pipeline_logs/scheduler`.

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
# set up (once per login)
export MYSET=/scratch/rg42/training/2026-10-07/user1

# check, then submit
/g/data/rg42/bactopia-workbench/bin/bactopia-workbench submit gadi \
  --dry-run $MYSET/fastq $MYSET/metadata $MYSET/results 50

/g/data/rg42/bactopia-workbench/bin/bactopia-workbench submit gadi \
  $MYSET/fastq $MYSET/metadata $MYSET/results 50

# monitor
qstat -u $USER
tail -f $MYSET/results/submit_workbench_pipeline_*.log

# results
ls $MYSET/results/*.xlsx
cat $MYSET/results/*_review_required.tsv
```

## Where To Go Next

- [README](../README.md) — all options, input types, and the full command reference
- [docs/setup-gadi-rg42.md](setup-gadi-rg42.md) — getting real data onto Gadi and
  results back to RDS
- [docs/input-formats.md](input-formats.md) — sample sheet and manifest rules in full
