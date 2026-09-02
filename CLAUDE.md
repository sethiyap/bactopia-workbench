# CLAUDE.md

Guidance for working in this repository.

## Overview

This repo runs a Bactopia-based bacterial genomics pipeline on HPC (Gadi/PBS and
Slurm), consolidates per-tool results across batches, maps them back onto the
sample metadata sheet, and exports a single Excel workbook of results.

Key stages (see `scripts/`):

- `run_bactopia_batch.*` / `run_extra_bactopia_tools.*` — run Bactopia and extra
  typing tools per batch.
- `run_padloc_batch.*` + `merge_padloc_summary.sh` — PADLOC (anti-phage defence
  systems) per batch. PADLOC is **not** a Bactopia v3.2.0 bactopia-tool, so it
  cannot go in `TOOLS_STRING`; it is a standalone stage in the FimTyper mould,
  writing `results_padloc/merged-results/padloc_merged.tsv` (per sample, joined
  onto the sheet) and `results_padloc_genes/merged-results/padloc_genes_merged.tsv`
  (per gene hit, its own workbook sheet). Off by default (`RUN_PADLOC`).
- `consolidate_bactopia_batches.R` — merge per-batch tool outputs into a
  consolidated directory (`tools/results_<tool>/merged-results/...`).
- `map_samplesheet_results.R` — join consolidated tool tables onto the
  metadata samplesheet, producing `*_samplesheet_with_results.tsv` (and, after
  MLST review, `*_samplesheet_with_results_mlst_reviewed.tsv`).
- `export_bactopia_results_workbook.py` — write the final `.xlsx` workbook
  (openpyxl). The mapped results table becomes the main sheet; consolidated
  per-tool tables and the ST131Typer summary become additional sheets.

## Result column ordering convention

**The final result Excel sheet must keep columns from the same tool together.**

The main ("mapped") sheet of the workbook is built by
`map_samplesheet_results.R`. Column grouping is enforced there, not in the
Python exporter:

- Every tool's columns are namespaced with a tool prefix (`mlst_`, `kleborate_`,
  `fimtyper_`, `abritamr_`, `plasmidfinder_`, `bracken_`, `padloc_`) via
  `prefix_non_key_cols()`.
- `preferred_order` lists the curated, tool-grouped column order used at the
  front of the sheet (metadata columns first, then each tool's block in order).
- Any column not covered by `preferred_order` is grouped with its tool by prefix
  (`tool_prefix_order` + `tool_group_rank()`) so same-tool columns stay
  contiguous instead of scattering to the end.
- Review/QC columns always sit at the **very end** of the sheet, after every
  tool block, via `review_tail_cols`: `review_required`, `review_reason`,
  `coverage_x`, `low_coverage`, `mlst_canonical_genus`,
  `phenotype_canonical_genus`, and `mlst_review_note`.
  These are excluded from tool grouping (so, e.g., `mlst_canonical_genus` does
  not fold into the MLST block despite its prefix). `coverage_x` / `low_coverage`
  are the input-read coverage flag (input basepairs ÷ genome size, `< 10×`
  flagged), computed per batch in `run_bactopia_batch.*`, consolidated into
  `coverage_summary.tsv`, and joined onto the sheet in
  `map_samplesheet_results.R`. They appear only when that table exists.
  `mlst_review_note` is appended downstream by `run_review_mlst_from_tsv.sh` as
  the last column of the `*_mlst_reviewed.tsv` file.

When adding a new tool or new per-tool columns:

1. Prefix the tool's columns with a consistent `<tool>_` prefix.
2. Add the important columns to `preferred_order` in the tool's block.
3. Add the tool's prefix to `tool_prefix_order` so any extra columns still group
   with that tool.

This keeps the exported workbook readable — one contiguous block of columns per
tool — regardless of which optional columns a given run happens to emit.

## Nextflow config convention: container environment goes in the `env` scope

**Never set a container's environment from a `beforeScript`.** Nextflow's
`nxf_launch` in `.command.run` is:

```
env - PATH="$PATH" ... singularity exec --no-home --pid ... <image> ...
```

`env -` wipes the environment before Singularity starts, so nothing a
`beforeScript` exports survives — including `SINGULARITYENV_*`, because
Singularity never sees those variables either. `PATH` is the single exception,
forwarded explicitly by `nxf_launch`.

Only the top-level `env { }` scope reaches the container: Nextflow emits it into
`nxf_container_env()`, which is `eval`'d inside. That scope is global (there is
no per-process `env`), so per-process container variables have to be either
global `env` entries or handled inside the tool's own wrapper script.

To check what a task actually got, read `nxf_container_env()` in a real
`work/*/.command.run` — it lists every variable that crossed the boundary.

Set in `env { }` in every site config (`scripts/nextflow.*.all_tools.config`):

- `JAVA_TOOL_OPTIONS = '-XX:-UsePerfData'` — required. Every container runs with
  `--pid`, so each task gets its own PID namespace and JVM PIDs restart low,
  while the host `/tmp` is shared into all of them. Concurrent Java tools
  (Prokka's `minced`, BBTools) collide on `/tmp/hsperfdata_$USER/<pid>` and the
  loser prints a `[warning][perf,memops]` line **on stdout**. Prokka 1.14.6 reads
  its minced version with `minced --version | sed -n '1p'` (no `2>&1`), parses
  the warning as the version, and aborts the task. Not worth an upstream report:
  Prokka 1.14.6 is pinned by Bactopia and effectively frozen. Applies to all
  executors — Nextflow passes `--pid` regardless — but it is reliable on `local`
  (all `maxForks` tasks share one `/tmp`) and intermittent on slurm/gadi (only
  co-scheduled tasks on the same node).
- `TERM = 'dumb'` — suppresses `tput` noise from tools that probe the terminal.
- `KLEBORATE_REAL` — the real binary `kleborate_232_compat.sh` exec's. The
  wrapper's `${KLEBORATE_REAL:-/usr/local/bin/kleborate}` fallback is only a
  fallback; the `env` entry is what makes overriding it work.

`scripts/` and `bactopia_config/` duplicate `commonBeforeScript`, the `env` scope,
and the `singularity { }` block across the remaining configs, so every fix of this
kind has to be applied several times. A shared `nextflow.common.config` pulled in
with `includeConfig` would stop them drifting.

**Which Gadi config is live.** `wrappers/submit.gadi.sh` exports
`PIPELINE_ROOT=$project_root` (the clone you launch from), and `config/sites/gadi*.env`
resolves `NEXTFLOW_CONFIG` against it. That pointed at
`bactopia_config/nextflow.gadi.alltools.config` while slurm and local pointed at
`scripts/nextflow.*.all_tools.config` — so the Gadi copy silently fell weeks behind
the one being maintained, missing the exit-255 retry, `jobfs`, the CheckM fix, and
the DefenseFinder / organism-typer `errorStrategy` blocks, and hardcoding one user's
`/scratch` and `/home` paths. The site envs now point at
`scripts/nextflow.gadi.all_tools.config`, and the `bactopia_config/` path is an
`includeConfig` shim so stale references still get the current config. **Edit the
`scripts/` config; never add settings to the shim.**

## Bracken crashes on 100%-classified samples (the `kraken_report_fix.sh` shim)

Bactopia's `kraken-bracken-summary.py` (teton container) reads the unclassified
count from the Kraken2 report's `U`-rank row, then does `unclassified_count +
<float>`. Kraken2 **omits the `U` row entirely when 0 reads are unclassified** —
common for ONT samples that classify to 100% — so `unclassified_count` is `None`
and the task aborts with `TypeError: ... 'NoneType' and 'float'`, failing the
whole batch. It's DB-build-dependent, not platform-dependent: the same sample can
classify 100% against one `k2_pluspf` build and <100% against another, so it
surfaces intermittently and looks host-specific when it isn't.

Fix: every `nextflow.*.all_tools.config` (and `bactopia_config/`) carries a
`withName: /.*:BRACKEN:BRACKEN_MODULE/` block that runs `scripts/kraken_report_fix.sh`
(prepend a `0`-count `U` row — the correct value) before the summary, plus
`errorStrategy = 'ignore'` as a backstop. **Apply this to all config copies**, and
note the fix only takes effect once the deployment (`/g/data/rg42/bactopia-workbench`)
is pulled up to date — a stale checkout runs the unpatched summary and crashes.

## PBS "Post job file processing error" = stage-out failed, not the job

```
PBS Job Id: 177942309.gadi-pbs
Job Name:   tb001_bracken
Post job file processing error; job 177942309.gadi-pbs on host gadi-cpu-clx-1439
```

This comes from the PBS MoM's epilogue, *after* the job body has finished: PBS
could not deliver the job's `.o`/`.e` to their destination. It says nothing about
whether the tool ran, and it destroys the only log that would have. It is
unrelated to the Bracken `TypeError` above — a `tb<batch>_bracken` job hitting
this has not necessarily failed at all.

Two things caused it here, both now fixed:

- **The destination was `$HOME`.** With `PBS_LOG_DIR` unset, `scheduler_submit`
  ([`scripts/lib_scheduler.sh`](scripts/lib_scheduler.sh)) omitted `-o`/`-e`
  entirely and PBS fell back to the submission directory. Gadi `/home` has a
  10 GB quota; over it, the copy fails. `submit_workbench_pipeline.sh` and
  `submit_bactopia_batch_pipeline.sh` now default `PBS_LOG_DIR` to
  `<RESULTS_ROOT>/pipeline_logs/scheduler`, which is on the project scratch every
  stage already requests via `-l storage=`. Never let `-o`/`-e` go unset: the
  submission directory is not guaranteed to be mounted inside the job either.
- **`NXF_HOME` defaulted to `$HOME/.nextflow`,** so every Nextflow stage grew
  home on every run. The four Nextflow stage scripts now put it beside
  `SING_CACHE` (`$(dirname "$SING_CACHE")/nextflow_home`, i.e. on scratch).

`submit_workbench_pipeline.sh` also runs `check_home_write_headroom` next to the
inode preflight: a real 1 MiB write into `$HOME` (an empty file can still be
created at quota), warning rather than failing, since nothing the pipeline needs
lives there any more.

Triage when it happens again: `qstat -xf <jobid>` for `Exit_status`,
`Output_Path` and `comment`; then the stage's own Nextflow log, which never goes
through PBS stage-out, at
`<RESULTS_ROOT>/_work/bactopia_tools/<batch>_tools_<tool>/.nextflow.log` with the
task dirs under `work/<tool>/*/.command.err`.

The Nextflow stage scripts (`run_extra_bactopia_tools.pbs`,
`run_fimtyper_batch.pbs`, `run_kleborate_batch.pbs`) also publish `.nextflow.log`
from an `EXIT` trap rather than only after a successful `nextflow run`. Under
`set -e` a failed run exited before the closing `rsync`, so precisely the runs
worth diagnosing published nothing.

`scripts/copy_RDS_to_GADI.sh` and `scripts/submit_transfer_gadi_to_rds.sh` still
leave `PBS_LOG_DIR` empty and so remain exposed to the same fallback.

## A failed pull poisons `SING_CACHE` (zero-byte `.img` stubs)

Gadi **compute** nodes have no outbound internet, and Nextflow pulls a container
from the *driver* process — which for the tool stages is a compute-node job. When
that pull fails, Singularity has already created the destination file, so a
**0-byte `.img` stub** is left in `SING_CACHE`. Nextflow then treats the stub as a
cached image and never attempts the pull again, so every task using it dies with

```
FATAL: ... could not open image ...: image format not recognized
```

and exit status **255**, on that run and every run after it. The retry rule in
`nextflow.*.all_tools.config` (`exitStatus in [125, 126, 255] && attempt <= 3`)
does not help — it exists for the transient loop-device failure, and this is
deterministic. Symptoms that make it look like something else:

- It is **per tool**, and only the tools whose images happened to be pulled while
  offline, so it reads as "tool X is broken" or "ONT input is broken" when the
  real variable is which images were already cached.
- Tools carrying `errorStrategy = 'ignore'` (`ECTYPER`, `SHIGATYPER`,
  `SHIGEIFINDER`, `SHIGAPASS`, `DEFENSEFINDER_RUN`) exit 0 and publish nothing
  instead of failing, so a poisoned image there is **silent**.
- The stage dies, `afterok` deletes FimTyper, which deletes consolidation, and the
  only mail you get is `Job deleted as result of dependency`.

Repair with `scripts/repair_singularity_cache.sh` **from a login node** — it finds
stubs (`--deep` also runs each image to catch truncated downloads), rederives the
source URL from Nextflow's cache naming, and downloads to a temp file that is
verified before it is moved into place, so an interrupted repair cannot
re-poison the cache. `submit_workbench_pipeline.sh` refuses to submit while any
zero-byte image is in `SING_CACHE` (`check_singularity_cache`).

**A missing image fails earlier than any `errorStrategy`.** Nextflow pulls
containers from the driver process, before the first task is submitted, so a failed
pull ends the session with `Exit Code: null`, `ignoredCount=0`, and no task ever
executed. No `withName:` directive can catch it — `errorStrategy = 'ignore'` only
applies to tasks that ran. A tool whose image is present but whose *task* fails is
ignorable; a tool whose image is absent is not. That is the whole difference between
DefenseFinder (image absent, killed the batch) and ShigEiFinder (image present, task
ignored, batch survived) on the same run.

`scripts/prestage_tool_containers.sh` closes this: it reads the container URIs out
of the Bactopia install (so it tracks whatever versions Bactopia pins, rather than a
list here that would go stale), computes Nextflow's cache filename for each, and
downloads whatever is absent. `submit_workbench_pipeline.sh` runs it in
`--check-only` mode as a preflight (`check_tool_containers`) and **warns** —
deliberately not a hard failure, since the URIs are discovered heuristically and a
discovery miss must not block a submission that would have worked. Set
`PRESTAGE_CONTAINERS=1` to have the submission stage them instead, from a login node.

`scripts/lib_singularity_cache.sh` holds the cache-name mangling and the
download-then-verify-then-move logic shared by both cache scripts; keep it there
rather than copying it into a second file.

Pre-stage images for any tool beyond `DEFAULT_TOOLS_STRING` before running them on
Gadi. `ADDITIONAL_TOOLS_STRING` (`RUN_ADDITIONAL_TOOLS=1`) pulls in ten tools whose
images are not otherwise cached — that is the difference between a run that works
and one that does not, not the input read type.
