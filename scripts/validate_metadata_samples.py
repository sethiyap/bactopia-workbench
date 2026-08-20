#!/usr/bin/env python3

import argparse
import csv
import re
import sys
from pathlib import Path


def normalize_sample(value: str) -> str:
    value = value.strip()
    return re.sub(r"\.(?:fna|fa|fasta)(?:\.gz)?$", "", value, flags=re.IGNORECASE)


def read_metadata_samples(path: Path) -> set[str]:
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        first_line = handle.readline()
        if not first_line:
            raise ValueError(f"Metadata sheet is empty: {path}")
        delimiter = "\t" if "\t" in first_line else ","
        handle.seek(0)
        rows = list(csv.reader(handle, delimiter=delimiter))

    if not rows or not rows[0]:
        raise ValueError(f"Metadata sheet has no columns: {path}")

    headers = [re.sub(r"\s+", " ", item.strip()).lower() for item in rows[0]]
    sample_index = headers.index("sample name") if "sample name" in headers else 0
    samples = {
        normalize_sample(row[sample_index])
        for row in rows[1:]
        if len(row) > sample_index and normalize_sample(row[sample_index])
    }
    if not samples:
        raise ValueError(f"Metadata sheet contains no sample names: {path}")
    return samples


def read_input_samples(path: Path, input_type: str) -> set[str]:
    samples: list[str] = []
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        if input_type == "accession":
            lines = handle.read().splitlines()
            first = lines[0].lstrip("﻿").strip() if lines else ""
            if first.split("\t", 1)[0].lower() == "accession":
                # Bactopia --accessions TSV (accession/runtype/genome_size/species):
                # take the accession column, skipping the header row.
                for row in lines[1:]:
                    acc = row.split("\t", 1)[0].strip()
                    if acc:
                        samples.append(acc)
            else:
                # Backward-compatible: one accession per line.
                for line_number, line in enumerate(lines, start=1):
                    value = line.strip()
                    if not value:
                        continue
                    if any(character.isspace() for character in value):
                        raise ValueError(
                            f"Accession file line {line_number} must contain one accession only: {value}"
                        )
                    samples.append(value)
        else:
            reader = csv.reader(handle, delimiter="\t")
            header = next(reader, None)
            if not header or not header[0].lstrip("\ufeff").strip().lower() == "sample":
                raise ValueError(f"Invalid Bactopia samples header: {path}")
            for row in reader:
                if row and row[0].strip():
                    samples.append(normalize_sample(row[0]))

    if not samples:
        raise ValueError(f"Input contains no samples: {path}")
    if len(samples) != len(set(samples)):
        duplicates = sorted({sample for sample in samples if samples.count(sample) > 1})
        raise ValueError("Duplicate input sample names: " + ", ".join(duplicates))
    return set(samples)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Check that every Bactopia input sample exists in the required metadata sheet."
    )
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument(
        "--input-type", required=True, choices=("illumina", "ont", "assembly", "accession")
    )
    parser.add_argument("--metadata", required=True, type=Path)
    args = parser.parse_args()

    try:
        metadata_samples = read_metadata_samples(args.metadata)
        input_samples = read_input_samples(args.input, args.input_type)
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1

    missing = sorted(input_samples - metadata_samples)
    if missing:
        print(
            "Input samples missing from metadata 'Sample name' column: " + ", ".join(missing),
            file=sys.stderr,
        )
        return 1

    print(f"Metadata covers all {len(input_samples)} input sample(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

