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

`scripts/` and `bactopia_config/` currently duplicate `commonBeforeScript`, the
`env` scope, and the `singularity { }` block verbatim across seven configs, so
every fix of this kind has to be applied seven times. A shared
`nextflow.common.config` pulled in with `includeConfig` would stop them drifting.
