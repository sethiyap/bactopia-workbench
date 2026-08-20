#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/split_bactopia_samplesheet.sh INPUT_FILE BATCH_SIZE OUTPUT_DIR [PREFIX]

Example:
  ./scripts/split_bactopia_samplesheet.sh \
    metadata/agar_samplesheet.fofn \
    50 \
    metadata/batches \
    batch_bactopia

This writes:
  metadata/batches/batch_bactopia_001.fofn
  metadata/batches/batch_bactopia_002.fofn
  ...

CSV samplesheets and tab-delimited Bactopia FOFN files are supported.
If the input has a header row, it is preserved in every batch file.
EOF
}

if [[ $# -lt 3 || $# -gt 4 ]]; then
  usage >&2
  exit 1
fi

input_file=$1
batch_size=$2
output_dir=$3
prefix=${4:-batch}

if [[ ! -f $input_file ]]; then
  echo "Input file not found: $input_file" >&2
  exit 1
fi

if ! [[ $batch_size =~ ^[1-9][0-9]*$ ]]; then
  echo "BATCH_SIZE must be a positive integer: $batch_size" >&2
  exit 1
fi

mkdir -p "$output_dir"

header=$(head -n 1 "$input_file")
if [[ -z $header ]]; then
  echo "Input file is empty: $input_file" >&2
  exit 1
fi

extension=${input_file##*.}
extension=$(printf '%s' "$extension" | tr '[:upper:]' '[:lower:]')

has_header=0
if [[ "$header" == "sample,r1,r2"* ]]; then
  has_header=1
elif [[ "$header" == $'sample\truntype\tr1\tr2'* ]]; then
  has_header=1
elif [[ "$header" == $'accession\t'* ]]; then
  # Bactopia --accessions TSV (accession/runtype/genome_size/species): the header
  # must be repeated in every batch so each batch parses as a headed CSV.
  has_header=1
fi

awk -v header="$header" -v batch_size="$batch_size" -v output_dir="$output_dir" -v prefix="$prefix" -v extension="$extension" -v has_header="$has_header" '
  NR == 1 && has_header == 1 { next }
  NF == 0 { next }
  {
    batch_index = int((row_count) / batch_size) + 1
    file = sprintf("%s/%s_%03d.%s", output_dir, prefix, batch_index, extension)

    if (!(file in seen)) {
      if (has_header == 1) {
        print header > file
      }
      seen[file] = 1
      files[++file_count] = file
    }

    print $0 >> file
    row_count++
  }
  END {
    if (row_count == 0) {
      exit 2
    }

    printf("Created %d batch file(s) covering %d sample row(s)\n", file_count, row_count)
    for (i = 1; i <= file_count; i++) {
      printf("%s\n", files[i])
    }
  }
' "$input_file"
