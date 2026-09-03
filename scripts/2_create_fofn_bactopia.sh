#!/usr/bin/env bash

set -euo pipefail

RAW_DIR="${1:?Usage: $0 <raw_dir> <output.fofn.tsv>}"
OUT_FOFN="${2:?Usage: $0 <raw_dir> <output.fofn.tsv>}"
INCLUDE_SAMPLE_REGEX="${INCLUDE_SAMPLE_REGEX:-}"
# A sample sequenced across several lanes arrives as several read pairs sharing one
# sample prefix (AGRF splits an AGAR delivery over L001..L00N). Bactopia's own
# `merge-pe` runtype takes comma-separated r1/r2 lists and concatenates them in
# GATHER, so those pairs become one row and one assembly. Set to 0 to emit one row
# per pair instead, which validation then rejects as duplicate sample rows.
MERGE_LANE_SPLIT_SAMPLES="${MERGE_LANE_SPLIT_SAMPLES:-1}"

record_unique_sample() {
  local sample=$1
  local existing
  for existing in "${skipped_samples[@]:-}"; do
    if [[ $existing == "$sample" ]]; then
      return 0
    fi
  done
  skipped_samples+=("$sample")
}

mkdir -p "$(dirname "$OUT_FOFN")"
# Read pairs are collected here first (sample<TAB>r1<TAB>r2), then grouped by sample
# into the manifest below. Grouping needs every pair in hand, so it cannot happen
# while the pairs are still being discovered.
pairs_file=$(mktemp "${OUT_FOFN}.pairs.XXXXXX")
fofn_tmp=$(mktemp "${OUT_FOFN}.tmp.XXXXXX")
trap 'rm -f "$pairs_file" "$fofn_tmp"' EXIT

total_r1=0
included_pairs=0
skipped_pairs=0
skipped_samples=()

while IFS= read -r r1; do
  total_r1=$((total_r1 + 1))
  base=$(basename "$r1")
  sample="${base%%_*}"

  if [[ -n $INCLUDE_SAMPLE_REGEX && ! $sample =~ $INCLUDE_SAMPLE_REGEX ]]; then
    skipped_pairs=$((skipped_pairs + 1))
    record_unique_sample "$sample"
    continue
  fi

  if [[ $r1 == *_R1.fastq.gz ]]; then
    r2="${r1/_R1.fastq.gz/_R2.fastq.gz}"
  elif [[ $r1 == *_R1.fq.gz ]]; then
    r2="${r1/_R1.fq.gz/_R2.fq.gz}"
  else
    echo "Unsupported FASTQ layout: $r1" >&2
    exit 1
  fi

  if [[ ! -f "$r2" ]]; then
    echo "Missing R2 for: $r1" >&2
    exit 1
  fi

  printf "%s\t%s\t%s\n" "$sample" "$r1" "$r2" >> "$pairs_file"
  included_pairs=$((included_pairs + 1))
done < <(find "$RAW_DIR" -maxdepth 1 -type f \( -name "*_R1.fastq.gz" -o -name "*_R1.fq.gz" \) | sort)

if [[ $total_r1 -eq 0 ]]; then
  echo "No R1 FASTQ files were found in: $RAW_DIR" >&2
  exit 1
fi

if [[ $included_pairs -eq 0 ]]; then
  if [[ -n $INCLUDE_SAMPLE_REGEX ]]; then
    echo "No FASTQ pairs matched INCLUDE_SAMPLE_REGEX=$INCLUDE_SAMPLE_REGEX in: $RAW_DIR" >&2
  else
    echo "No FASTQ pairs were written to: $OUT_FOFN" >&2
  fi
  exit 1
fi

# Group the pairs into one row per sample. Samples with a single pair keep runtype
# `paired-end`; samples with several become `merge-pe`, whose r1/r2 are comma-joined
# lists in matching order (Bactopia pairs them by position, so R1 and R2 must be
# listed in the same order -- both come from the same sorted pass above).
awk -F'\t' -v merge="$MERGE_LANE_SPLIT_SAMPLES" '
BEGIN { printf "sample\truntype\tr1\tr2\textra\n" }
{
  if (!(($1) in seen)) { seen[$1] = 1; order[++n] = $1 }
  count[$1]++
  if (merge == "1") {
    r1[$1] = ($1 in r1) ? r1[$1] "," $2 : $2
    r2[$1] = ($1 in r2) ? r2[$1] "," $3 : $3
  } else {
    printf "%s\tpaired-end\t%s\t%s\t\n", $1, $2, $3
  }
}
END {
  if (merge != "1") exit
  for (i = 1; i <= n; i++) {
    s = order[i]
    printf "%s\t%s\t%s\t%s\t\n", s, (count[s] > 1 ? "merge-pe" : "paired-end"), r1[s], r2[s]
  }
}
' "$pairs_file" > "$fofn_tmp"
# Move into place only once the manifest is complete, so a failure here cannot leave
# a half-written FOFN that the next step would treat as the real one.
mv "$fofn_tmp" "$OUT_FOFN"

sample_count=$(( $(awk 'END { print NR }' "$OUT_FOFN") - 1 ))
echo "FOFN pairs included: $included_pairs"
echo "FOFN samples written: $sample_count"
if [[ $skipped_pairs -gt 0 ]]; then
  echo "FOFN pairs skipped by sample filter: $skipped_pairs"
  echo "Skipped sample prefixes:"
  printf '  - %s\n' "${skipped_samples[@]}"
fi

# Several files whose basenames share a prefix up to the first underscore collapse
# onto one sample name. Report which files were folded together (or, when merging is
# off, which ones will fail validation) -- this is the only point where the paths
# behind a sample name are still known.
multi_report=$(awk -F'\t' '
  NR == FNR { n[$1]++; next }
  n[$1] > 1 {
    if (!printed[$1]++) printf "  %s (%d read pairs):\n", $1, n[$1]
    printf "    %s\n", $2
  }
' "$pairs_file" "$pairs_file")
if [[ -n $multi_report ]]; then
  if [[ $MERGE_LANE_SPLIT_SAMPLES == "1" ]]; then
    echo "Samples with multiple read pairs, written as runtype merge-pe (Bactopia concatenates them):"
    printf '%s\n' "$multi_report"
  else
    {
      echo "WARNING: MERGE_LANE_SPLIT_SAMPLES=0 and these samples have more than one read pair,"
      echo "so they were written as one row each and validation will reject the manifest:"
      printf '%s\n' "$multi_report"
    } >&2
  fi
fi
