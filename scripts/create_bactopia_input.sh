#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <illumina|ont|assembly> <input_dir> <output.fofn>" >&2
  exit 1
fi

input_type=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
input_dir=$2
output_file=$3
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
illumina_fofn_script=${CREATE_FOFN_SCRIPT:-$script_dir/2_create_fofn_bactopia.sh}

case "$input_type" in
  illumina|ont|assembly) ;;
  *)
    echo "Unsupported local input type: $input_type" >&2
    exit 1
    ;;
esac

if [[ ! -d $input_dir ]]; then
  echo "Input directory not found: $input_dir" >&2
  exit 1
fi

input_dir=$(cd "$input_dir" && pwd)
mkdir -p "$(dirname "$output_file")"

if [[ $input_type == "illumina" ]]; then
  exec bash "$illumina_fofn_script" "$input_dir" "$output_file"
fi

tmp_file=$(mktemp "${TMPDIR:-/tmp}/bactopia-input.XXXXXX")
paths_file=$(mktemp "${TMPDIR:-/tmp}/bactopia-paths.XXXXXX")
trap 'rm -f "$tmp_file" "$paths_file"' EXIT
printf 'sample\truntype\tr1\tr2\textra\n' > "$tmp_file"

case "$input_type" in
  ont)
    find "$input_dir" -maxdepth 1 -type f \( -name '*.fastq.gz' -o -name '*.fq.gz' \) | sort > "$paths_file"
    ;;
  assembly)
    find "$input_dir" -maxdepth 1 -type f \( \
      -name '*.fasta.gz' -o -name '*.fna.gz' -o -name '*.fa.gz' \
      -o -name '*.fasta' -o -name '*.fna' -o -name '*.fa' \) | sort > "$paths_file"
    ;;
esac

count=0
seen_samples=()

sample_seen() {
  local wanted=$1
  local existing
  for existing in "${seen_samples[@]:-}"; do
    [[ $existing == "$wanted" ]] && return 0
  done
  return 1
}

while IFS= read -r input_path; do
  filename=$(basename "$input_path")
  sample=$filename

  case "$input_type" in
    ont)
      sample=${sample%.fastq.gz}
      sample=${sample%.fq.gz}
      ;;
    assembly)
      sample=${sample%.fasta.gz}
      sample=${sample%.fna.gz}
      sample=${sample%.fa.gz}
      sample=${sample%.fasta}
      sample=${sample%.fna}
      sample=${sample%.fa}
      ;;
  esac

  if [[ -z $sample || $sample =~ [[:space:]] ]]; then
    echo "Invalid sample name derived from input file: $filename" >&2
    exit 1
  fi
  if sample_seen "$sample"; then
    echo "Duplicate sample name '$sample' derived from: $input_path" >&2
    exit 1
  fi
  seen_samples+=("$sample")

  if [[ $input_type == "assembly" ]]; then
    case "$input_path" in
      *.gz)
        assembly_path=$input_path
        ;;
      *)
        # Bactopia expects gzipped assemblies. gzip a copy of the uncompressed input
        # into a staging dir next to the manifest (the user's files are left as-is),
        # so both compressed and uncompressed assemblies work as --input-type assembly.
        staging_dir="$(dirname "$output_file")/staged_assemblies"
        mkdir -p "$staging_dir"
        assembly_path="$staging_dir/${filename}.gz"
        gzip -c "$input_path" > "$assembly_path"
        ;;
    esac
    printf '%s\tassembly\t\t\t%s\n' "$sample" "$assembly_path" >> "$tmp_file"
  else
    printf '%s\tont\t%s\t\t\n' "$sample" "$input_path" >> "$tmp_file"
  fi
  count=$((count + 1))
done < "$paths_file"

if [[ $count -eq 0 ]]; then
  case "$input_type" in
    ont) echo "No compressed ONT FASTQ files (*.fastq.gz or *.fq.gz) found in: $input_dir" >&2 ;;
    assembly) echo "No assemblies (*.fasta[.gz], *.fna[.gz], or *.fa[.gz]) found in: $input_dir" >&2 ;;
  esac
  exit 1
fi

mv "$tmp_file" "$output_file"
rm -f "$paths_file"
trap - EXIT
echo "Bactopia ${input_type} samples included: $count"
