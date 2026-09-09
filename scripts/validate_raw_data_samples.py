#!/usr/bin/env python3
"""Cross-check a raw data directory against the metadata samplesheet, both ways.

`validate_metadata_samples.py` runs inside a submission, on the already-built
FOFN, and tests one direction only: every input sample must appear in the sheet.
A sheet row whose reads never arrived passes it, never reaches the FOFN, and is
simply absent from the final workbook with nothing to say why.

This script is the pre-flight for the other direction. Run it by hand after a
transfer and before `submit_workbench_pipeline.sh`:

    scripts/validate_raw_data_samples.py --raw-dir <dir> --metadata <sheet>

Sample names are derived exactly as the pipeline derives them, so the comparison
reflects what would really run:

  illumina  basename up to the first underscore  (2_create_fofn_bactopia.sh)
  ont       basename minus .fastq.gz / .fq.gz    (create_bactopia_input.sh)
  assembly  basename minus .fasta/.fna/.fa[.gz]  (create_bactopia_input.sh)

Exit status: 0 clean (warnings allowed), 1 problems found, 2 usage or IO error.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from validate_metadata_samples import read_metadata_sample_rows  # noqa: E402

# Mirrors the discovery globs in 2_create_fofn_bactopia.sh and
# create_bactopia_input.sh. Both search one level only (`find -maxdepth 1`), so
# a delivery left in per-sample subdirectories is invisible to the pipeline and
# has to look that way here too.
R1_SUFFIXES = ("_R1.fastq.gz", "_R1.fq.gz")
ONT_SUFFIXES = (".fastq.gz", ".fq.gz")
ASSEMBLY_SUFFIXES = (
    ".fasta.gz",
    ".fna.gz",
    ".fa.gz",
    ".fasta",
    ".fna",
    ".fa",
)
# submit_workbench_pipeline.sh's default AGAR_SAMPLE_REGEX. Anything not matching
# it is dropped from the FOFN in AGAR mode, so --agar stops this script reporting
# controls and undetermined files as missing metadata.
AGAR_SAMPLE_REGEX = r"^[0-9]{2}GNB-[0-9]+R?$"


def strip_suffix(name: str, suffixes: tuple[str, ...]) -> str:
    for suffix in suffixes:
        if name.lower().endswith(suffix.lower()):
            return name[: -len(suffix)]
    return name


def discover(
    raw_dir: Path, input_type: str
) -> tuple[dict[str, list[tuple[Path, ...]]], list[str]]:
    """Map sample name -> its units on disk, plus any hard errors.

    A unit is one read pair for illumina (so len() counts lane splits, not files)
    and one file for ont/assembly. Both halves of a pair are kept so the
    zero-byte check sees R2 as well as R1.
    """
    errors: list[str] = []
    samples: dict[str, list[tuple[Path, ...]]] = defaultdict(list)

    try:
        entries = sorted(entry for entry in raw_dir.iterdir() if entry.is_file())
    except OSError as error:
        raise ValueError(f"Cannot read raw data directory: {error}") from error

    if input_type == "illumina":
        for path in entries:
            matched = next(
                (suffix for suffix in R1_SUFFIXES if path.name.endswith(suffix)), None
            )
            if matched is None:
                continue
            # The sample name is the prefix up to the first underscore, so several
            # lanes of one isolate collapse onto a single name -- that is the
            # merge-pe case, not a duplicate.
            sample = path.name.split("_", 1)[0]
            mate = path.with_name(path.name.replace("_R1.", "_R2.", 1))
            if mate.is_file():
                samples[sample].append((path, mate))
            else:
                errors.append(f"missing R2 for {path.name} (expected {mate.name})")
                samples[sample].append((path,))
    else:
        suffixes = ONT_SUFFIXES if input_type == "ont" else ASSEMBLY_SUFFIXES
        for path in entries:
            if not any(path.name.lower().endswith(s.lower()) for s in suffixes):
                continue
            samples[strip_suffix(path.name, suffixes)].append((path,))
        # create_bactopia_input.sh aborts on a duplicate sample name for these two
        # input types, so surface it here rather than at submission.
        for sample, units in sorted(samples.items()):
            if len(units) > 1:
                joined = ", ".join(unit[0].name for unit in units)
                errors.append(f"duplicate sample name '{sample}' from: {joined}")

    return dict(samples), errors


def compile_regex(pattern: str | None, label: str) -> re.Pattern[str] | None:
    if not pattern:
        return None
    try:
        return re.compile(pattern)
    except re.error as error:
        raise ValueError(f"Invalid {label}: {error}") from error


def report(title: str, lines: list[str], limit: int) -> None:
    print(f"\n{title} ({len(lines)})")
    for line in lines[:limit]:
        print(f"  {line}")
    if len(lines) > limit:
        print(f"  ... and {len(lines) - limit} more (raise --max-list to see them)")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Check a raw data directory and the metadata sheet against each other.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("--raw-dir", required=True, type=Path)
    parser.add_argument("--metadata", required=True, type=Path)
    parser.add_argument(
        "--input-type", default="illumina", choices=("illumina", "ont", "assembly")
    )
    parser.add_argument(
        "--include-regex",
        default=os.environ.get("INCLUDE_SAMPLE_REGEX", ""),
        help="Keep only samples matching this (default: $INCLUDE_SAMPLE_REGEX).",
    )
    parser.add_argument(
        "--exclude-regex",
        default=os.environ.get("EXCLUDE_SAMPLE_REGEX", ""),
        help="Drop samples matching this (default: $EXCLUDE_SAMPLE_REGEX).",
    )
    parser.add_argument(
        "--agar",
        action="store_true",
        help=f"Apply the AGAR-mode include filter, {AGAR_SAMPLE_REGEX}",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Treat sheet rows with no reads as an error, not a warning.",
    )
    parser.add_argument("--max-list", type=int, default=40, help="Names to print per section.")
    parser.add_argument("--json", type=Path, help="Also write the full result as JSON.")
    args = parser.parse_args()

    if not args.raw_dir.is_dir():
        print(f"Raw data directory not found: {args.raw_dir}", file=sys.stderr)
        return 2
    if not args.metadata.is_file():
        print(f"Metadata sheet not found: {args.metadata}", file=sys.stderr)
        return 2

    try:
        include_regex = compile_regex(
            AGAR_SAMPLE_REGEX if args.agar else args.include_regex, "--include-regex"
        )
        exclude_regex = compile_regex(args.exclude_regex, "--exclude-regex")
        sheet_rows = read_metadata_sample_rows(args.metadata)
        on_disk, disk_errors = discover(args.raw_dir, args.input_type)
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 2

    if not sheet_rows:
        print(f"Metadata sheet contains no sample names: {args.metadata}", file=sys.stderr)
        return 2

    # Apply the pipeline's own filters before comparing, so samples it would drop
    # anyway are not reported as missing from the sheet.
    filtered_out: list[str] = []
    kept: dict[str, list[tuple[Path, ...]]] = {}
    for sample, units in on_disk.items():
        if include_regex and not include_regex.search(sample):
            filtered_out.append(sample)
        elif exclude_regex and exclude_regex.search(sample):
            filtered_out.append(sample)
        else:
            kept[sample] = units

    sheet_samples = {name for _, name in sheet_rows}
    disk_samples = set(kept)

    missing_from_sheet = sorted(disk_samples - sheet_samples)
    missing_from_disk = sorted(sheet_samples - disk_samples)
    matched = sorted(disk_samples & sheet_samples)

    seen: dict[str, int] = {}
    duplicate_rows = []
    for line_number, name in sheet_rows:
        if name in seen:
            duplicate_rows.append(f"{name} (lines {seen[name]} and {line_number})")
        else:
            seen[name] = line_number

    empty_files = sorted(
        path.name
        for units in kept.values()
        for unit in units
        for path in unit
        if path.stat().st_size == 0
    )
    lane_split = sorted(
        (sample, len(units)) for sample, units in kept.items() if len(units) > 1
    )

    print(f"raw dir:   {args.raw_dir}")
    print(f"sheet:     {args.metadata}")
    print(f"type:      {args.input_type}")
    if include_regex:
        print(f"include:   {include_regex.pattern}")
    if exclude_regex:
        print(f"exclude:   {exclude_regex.pattern}")
    print()
    print(f"samples on disk:       {len(disk_samples)}")
    print(f"samples in sheet:      {len(sheet_samples)}")
    print(f"matched:               {len(matched)}")
    print(f"on disk, not in sheet: {len(missing_from_sheet)}")
    print(f"in sheet, not on disk: {len(missing_from_disk)}")

    if missing_from_sheet:
        report(
            "ERROR  on disk but not in the sheet -- submission will be refused",
            [
                f"{s}  ({', '.join(unit[0].name for unit in kept[s])})"
                for s in missing_from_sheet
            ],
            args.max_list,
        )
    if missing_from_disk:
        label = "ERROR" if args.strict else "WARNING"
        report(
            f"{label}  in the sheet but no reads on disk -- silently absent from the workbook",
            missing_from_disk,
            args.max_list,
        )
    if disk_errors:
        report("ERROR  incomplete or ambiguous files", disk_errors, args.max_list)
    if empty_files:
        report("ERROR  zero-byte files", empty_files, args.max_list)
    if duplicate_rows:
        report("WARNING  duplicate sample names in the sheet", duplicate_rows, args.max_list)
    if filtered_out:
        report(
            "INFO  filtered out before comparison (include/exclude regex)",
            sorted(filtered_out),
            args.max_list,
        )
    if lane_split and args.input_type == "illumina":
        report(
            "INFO  lane-split samples, merged into one merge-pe row each",
            [f"{sample}: {count} pairs" for sample, count in lane_split],
            args.max_list,
        )

    if args.json:
        payload = {
            "raw_dir": str(args.raw_dir),
            "metadata": str(args.metadata),
            "input_type": args.input_type,
            "matched": matched,
            "missing_from_sheet": missing_from_sheet,
            "missing_from_disk": missing_from_disk,
            "file_errors": disk_errors,
            "empty_files": empty_files,
            "duplicate_sheet_rows": duplicate_rows,
            "filtered_out": sorted(filtered_out),
            "lane_split": {sample: count for sample, count in lane_split},
        }
        try:
            args.json.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        except OSError as error:
            print(f"Could not write --json report: {error}", file=sys.stderr)
            return 2
        print(f"\nJSON report: {args.json}")

    failed = bool(missing_from_sheet or disk_errors or empty_files)
    failed = failed or (args.strict and bool(missing_from_disk))
    print()
    if failed:
        print("FAIL: fix the errors above before submitting.")
        return 1
    if missing_from_disk:
        print(
            "OK with warnings: every sample on disk has a metadata row. "
            f"{len(missing_from_disk)} sheet row(s) have no reads and will not appear "
            "in the results -- confirm that is intended."
        )
        return 0
    print("OK: the raw data directory and the metadata sheet agree.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
