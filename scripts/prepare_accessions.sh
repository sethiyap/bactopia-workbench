#!/usr/bin/env bash

# Convert a simple accession list (one accession per line) into the tab-separated
# file Bactopia 3.2.0 requires for --accessions:
#
#   accession<TAB>runtype<TAB>genome_size<TAB>species   (header row)
#   <accession><TAB><runtype><TAB><TAB><species>        (one row per accession)
#
# Bactopia only accepts Assembly (GCF_/GCA_) or Experiment (SRX/ERX/DRX) accessions.
# Run accessions (SRR/ERR/DRR) are auto-resolved to their Experiment accession via the
# ENA API (which also gives species + instrument platform, so ONT runs are tagged).
#
# Usage: prepare_accessions.sh <input_list> <output_tsv> [<map_tsv>]

set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 <input_list> <output_tsv> [<map_tsv>]" >&2
  exit 1
fi

input_list=$1
output_tsv=$2
map_tsv=${3:-}

[[ -f $input_list ]] || { echo "Accession list not found: $input_list" >&2; exit 1; }
mkdir -p "$(dirname "$output_tsv")"
[[ -n $map_tsv ]] && mkdir -p "$(dirname "$map_tsv")"

ena_api=${ENA_API_BASE:-https://www.ebi.ac.uk/ena/portal/api/filereport}

# resolve_run <run_accession> -> prints "experiment<TAB>platform<TAB>species" (or empty on failure)
resolve_run() {
  local run=$1 line
  line=$(curl -fsSL --max-time 30 \
    "${ena_api}?accession=${run}&result=read_run&fields=experiment_accession,instrument_platform,scientific_name" \
    2>/dev/null | tail -n +2 | head -n 1 || true)
  # ENA columns: run_accession, experiment_accession, instrument_platform, scientific_name
  printf '%s' "$line" | awk -F'\t' 'NF>=2 { printf "%s\t%s\t%s\n", $2, $3, $4 }'
}

tmp_out=$(mktemp "${TMPDIR:-/tmp}/accessions.XXXXXX")
tmp_map=$(mktemp "${TMPDIR:-/tmp}/accmap.XXXXXX")
trap 'rm -f "$tmp_out" "$tmp_map"' EXIT

printf 'accession\truntype\tgenome_size\tspecies\n' > "$tmp_out"
printf 'input_accession\tbactopia_accession\tspecies\n' > "$tmp_map"

count=0
while IFS= read -r raw || [[ -n $raw ]]; do
  # strip CR/whitespace, skip blanks and comments
  acc=$(printf '%s' "$raw" | tr -d '\r' | awk '{$1=$1; print}')
  [[ -z $acc || $acc == \#* ]] && continue

  runtype=""
  species=""
  resolved=""

  case "$acc" in
    GCF_*|GCA_*)
      resolved=$acc
      ;;
    SRX*|ERX*|DRX*)
      resolved=$acc
      ;;
    SRR*|ERR*|DRR*)
      exp=""; platform=""; sci=""
      IFS=$'\t' read -r exp platform sci < <(resolve_run "$acc") || true
      if [[ -z ${exp:-} ]]; then
        echo "ERROR: could not resolve run accession '$acc' to an Experiment accession via ENA." >&2
        echo "       Provide an Experiment (SRX/ERX/DRX) or Assembly (GCF_/GCA_) accession, or check the ID." >&2
        exit 1
      fi
      resolved=$exp
      species=${sci:-}
      [[ ${platform:-} == "OXFORD_NANOPORE" ]] && runtype="ont"
      echo "[prepare-accessions] $acc -> $resolved${species:+  ($species)}" >&2
      ;;
    *)
      echo "ERROR: unrecognized accession '$acc'." >&2
      echo "       Expected Assembly (GCF_/GCA_), Experiment (SRX/ERX/DRX), or Run (SRR/ERR/DRR)." >&2
      exit 1
      ;;
  esac

  printf '%s\t%s\t\t%s\n' "$resolved" "$runtype" "$species" >> "$tmp_out"
  printf '%s\t%s\t%s\n' "$acc" "$resolved" "$species" >> "$tmp_map"
  count=$((count + 1))
done < "$input_list"

if [[ $count -eq 0 ]]; then
  echo "No accessions found in: $input_list" >&2
  exit 1
fi

mv "$tmp_out" "$output_tsv"
[[ -n $map_tsv ]] && mv "$tmp_map" "$map_tsv"
trap - EXIT
rm -f "$tmp_out" "$tmp_map" 2>/dev/null || true

echo "[prepare-accessions] Wrote $count accession(s) to Bactopia format: $output_tsv" >&2
[[ -n $map_tsv ]] && echo "[prepare-accessions] Resolution map: $map_tsv" >&2
