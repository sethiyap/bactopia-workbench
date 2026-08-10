# CLAUDE.md

Guidance for working in this repository.

## Overview

This repo runs a Bactopia-based bacterial genomics pipeline on HPC (Gadi/PBS and
Slurm), consolidates per-tool results across batches, maps them back onto the
sample metadata sheet, and exports a single Excel workbook of results.

Key stages (see `scripts/`):

- `run_bactopia_batch.*` / `run_extra_bactopia_tools.*` — run Bactopia and extra
  typing tools per batch.
- `consolidate_bactopia_batches.R` — merge per-batch tool outputs into a
  consolidated directory (`tools/results_<tool>/merged-results/...`).
- `map_agrf_samplesheet_results.R` — join consolidated tool tables onto the
  metadata samplesheet, producing `*_samplesheet_with_results.tsv` (and, after
  MLST review, `*_samplesheet_with_results_mlst_reviewed.tsv`).
- `export_bactopia_results_workbook.py` — write the final `.xlsx` workbook
  (openpyxl). The mapped results table becomes the main sheet; consolidated
  per-tool tables and the ST131Typer summary become additional sheets.

## Result column ordering convention

**The final result Excel sheet must keep columns from the same tool together.**

The main ("mapped") sheet of the workbook is built by
`map_agrf_samplesheet_results.R`. Column grouping is enforced there, not in the
Python exporter:

- Every tool's columns are namespaced with a tool prefix (`mlst_`, `kleborate_`,
  `fimtyper_`, `abritamr_`, `plasmidfinder_`, `bracken_`) via
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
  `map_agrf_samplesheet_results.R`. They appear only when that table exists.
  `mlst_review_note` is appended downstream by `run_review_mlst_from_tsv.sh` as
  the last column of the `*_mlst_reviewed.tsv` file.

When adding a new tool or new per-tool columns:

1. Prefix the tool's columns with a consistent `<tool>_` prefix.
2. Add the important columns to `preferred_order` in the tool's block.
3. Add the tool's prefix to `tool_prefix_order` so any extra columns still group
   with that tool.

This keeps the exported workbook readable — one contiguous block of columns per
tool — regardless of which optional columns a given run happens to emit.
