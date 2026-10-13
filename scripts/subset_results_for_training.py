#!/usr/bin/env python3
"""Cut a finished run's results down to a few samples, for teaching.

A training session needs output to read, which normally means running the
pipeline first. When a full batch has already been processed, this is the same
thing for free: take that run's workbook and mapped tables, keep only the rows
for the samples the trainees were given, and write the result somewhere they can
point `OUT` at. No scheduler, no service units.

Filenames are preserved, so every command in docs/tutorial-first-run-gadi.md
works unchanged against the output directory:

    ls $OUT/*.xlsx
    cat $OUT/*_review_required.tsv

Usage:
  ./scripts/subset_results_for_training.py \\
      --results /scratch/rg42/AGAR/intermediates/2024/B07 \\
      --samples-from /scratch/rg42/training/2026-10-12 \\
      --out /scratch/rg42/training/2026-10-12/reference_results

  ./scripts/subset_results_for_training.py \\
      --results /path/to/finished/run \\
      --samples 24GNB-1752,24GNB-1745,24GNB-1775 \\
      --out /path/to/output

Exits non-zero if a requested sample is absent from the source run, since a
silently short reference is worse than none.
"""

from __future__ import annotations

import argparse
import csv
import shutil
import sys
from pathlib import Path

# Header spellings that identify the sample column. Compared lowercased with
# runs of whitespace collapsed, matching read_metadata_sample_rows() in
# validate_metadata_samples.py.
SAMPLE_HEADERS = {
    "sample name",
    "sample",
    "sample_name",
    "samplename",
    "name",
    "isolate",
    "strain",
    "tag",
    "query",
}

# Tables that are one row per run rather than per sample; copied whole.
COPY_WHOLE = {"software versions", "versions", "citations"}


def norm(value: object) -> str:
    return " ".join(str(value if value is not None else "").split()).lower()


def find_sample_column(header: list[object]) -> int | None:
    """Index of the sample column, or None if this table is not per-sample."""
    for index, cell in enumerate(header):
        if norm(cell) in SAMPLE_HEADERS:
            return index
    return None


def collect_samples_from_sheets(root: Path) -> list[str]:
    """Sample ids from every *_samplesheet.txt under root, in file order."""
    samples: list[str] = []
    seen: set[str] = set()
    sheets = sorted(root.rglob("*_samplesheet.txt"))
    if not sheets:
        raise SystemExit(f"No *_samplesheet.txt found under {root}")

    for sheet in sheets:
        with sheet.open(newline="", encoding="utf-8-sig") as handle:
            first = handle.readline()
            delimiter = "\t" if "\t" in first else ","
            handle.seek(0)
            rows = list(csv.reader(handle, delimiter=delimiter))
        if not rows:
            continue
        # Row 1 is always a header here, matching how the pipeline reads these.
        for row in rows[1:]:
            if not row:
                continue
            sample = row[0].strip()
            if sample and sample not in seen:
                seen.add(sample)
                samples.append(sample)
    return samples


def subset_delimited(src: Path, dest: Path, wanted: set[str]) -> tuple[int, set[str]]:
    """Filter one TSV/CSV. Returns (rows kept, sample ids seen)."""
    with src.open(newline="", encoding="utf-8-sig") as handle:
        first = handle.readline()
        delimiter = "\t" if "\t" in first else ","
        handle.seek(0)
        rows = list(csv.reader(handle, delimiter=delimiter))

    if not rows:
        dest.write_text("")
        return 0, set()

    header = rows[0]
    column = find_sample_column(header)
    if column is None:
        column = 0  # these tables lead with the sample id even when unlabelled

    kept = [header]
    seen: set[str] = set()
    for row in rows[1:]:
        if len(row) <= column:
            continue
        sample = row[column].strip()
        if sample in wanted:
            kept.append(row)
            seen.add(sample)

    with dest.open("w", newline="", encoding="utf-8") as handle:
        csv.writer(handle, delimiter=delimiter, lineterminator="\n").writerows(kept)
    return len(kept) - 1, seen


def subset_workbook(src: Path, dest: Path, wanted: set[str]) -> tuple[dict[str, int], set[str]]:
    """Filter every per-sample sheet of a workbook. Returns (per-sheet counts, ids seen)."""
    try:
        from openpyxl import load_workbook
    except ImportError:
        raise SystemExit(
            "openpyxl is required to subset the workbook.\n"
            "On Gadi use the MLST env's interpreter, which already has it:\n"
            "  /g/data/rg42/bactopia_datasets/envs/mlst_env/bin/python3 "
            "scripts/subset_results_for_training.py ..."
        )

    workbook = load_workbook(src)
    counts: dict[str, int] = {}
    seen: set[str] = set()

    for worksheet in workbook.worksheets:
        rows = list(worksheet.iter_rows(values_only=True))
        if not rows:
            continue
        if norm(worksheet.title) in COPY_WHOLE:
            counts[worksheet.title] = max(len(rows) - 1, 0)
            continue

        header = list(rows[0])
        column = find_sample_column(header)
        if column is None:
            # Not a per-sample table; leave it as it is.
            counts[worksheet.title] = max(len(rows) - 1, 0)
            continue

        keep = [rows[0]]
        for row in rows[1:]:
            if len(row) <= column:
                continue
            value = row[column]
            sample = str(value).strip() if value is not None else ""
            if sample in wanted:
                keep.append(row)
                seen.add(sample)

        worksheet.delete_rows(1, worksheet.max_row)
        for row in keep:
            worksheet.append(row)
        counts[worksheet.title] = len(keep) - 1

    workbook.save(dest)
    return counts, seen


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Subset a finished run's results to a few samples, for training.",
    )
    parser.add_argument("--results", required=True, type=Path,
                        help="RESULTS_ROOT of the finished run to take results from")
    parser.add_argument("--out", required=True, type=Path,
                        help="Directory to write the subset into (created if absent)")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--samples",
                       help="Comma- or space-separated sample ids")
    group.add_argument("--samples-from", type=Path,
                       help="Directory to read *_samplesheet.txt files from, "
                            "e.g. a training tree")
    parser.add_argument("--dry-run", action="store_true",
                        help="Report what would be written, change nothing")
    args = parser.parse_args()

    if not args.results.is_dir():
        raise SystemExit(f"No such results directory: {args.results}")

    if args.samples:
        samples = [s for s in args.samples.replace(",", " ").split() if s]
    else:
        samples = collect_samples_from_sheets(args.samples_from)
    if not samples:
        raise SystemExit("No sample ids given")
    wanted = set(samples)

    print(f"Source run : {args.results}")
    print(f"Samples    : {len(samples)} -> {', '.join(samples)}")
    print(f"Destination: {args.out}")
    print()

    # The files the tutorial tells people to open, plus the review table.
    patterns = [
        "*_samplesheet_with_results_mlst_reviewed.tsv",
        "*_samplesheet_with_results.tsv",
        "*_samplesheet_with_results_review_required.tsv",
        "*_results.xlsx",
    ]
    targets: list[Path] = []
    for pattern in patterns:
        targets.extend(sorted(p for p in args.results.glob(pattern) if p.is_file()))
    if not targets:
        raise SystemExit(
            f"Found no results files under {args.results}.\n"
            "Expected at least one of: " + ", ".join(patterns)
        )

    if not args.dry_run:
        args.out.mkdir(parents=True, exist_ok=True)

    found: set[str] = set()
    for src in targets:
        dest = args.out / src.name
        if args.dry_run:
            print(f"  [dry-run] {src.name}")
            continue
        if src.suffix.lower() == ".xlsx":
            counts, seen = subset_workbook(src, dest, wanted)
            found |= seen
            print(f"  {src.name}")
            for sheet, n in counts.items():
                print(f"      {sheet:<34} {n:>5} rows")
        else:
            n, seen = subset_delimited(src, dest, wanted)
            found |= seen
            print(f"  {src.name:<52} {n:>5} rows")

    if args.dry_run:
        print("\nDry run - nothing written.")
        return 0

    missing = sorted(wanted - found)
    print()
    if missing:
        print(f"WARNING: {len(missing)} sample(s) not found in the source run:")
        for sample in missing:
            print(f"  - {sample}")
        print("\nThe subset is incomplete. Check these samples were part of that run.")
        return 1

    print(f"All {len(samples)} samples found. Point users' OUT at:")
    print(f"  {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
