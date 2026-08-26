#!/usr/bin/env bash

set -euo pipefail

# Merge PADLOC per-sample CSV output into the two tables the consolidation stage
# expects:
#
#   <summary_tsv>  one row per sample: sample, n_systems, systems, n_genes
#                  -> results_padloc/merged-results/padloc_merged.tsv
#                  (joined onto the mapped sheet as padloc_* columns)
#   <genes_tsv>    one row per defence-system gene hit: sample + PADLOC's columns
#                  -> results_padloc_genes/merged-results/padloc_genes_merged.tsv
#                  (kept as its own workbook sheet, never joined 1:1)
#
# PADLOC writes "<sample>_padloc.csv" ONLY when it finds at least one defence
# system ("Complete: Nothing found for ..." otherwise), so the sample list is
# read from a file rather than from the CSVs: a sample with no systems must still
# get a summary row with n_systems=0, not disappear from the sheet.
#
# The CSVs come from readr::write_csv, so fields containing commas, quotes or
# newlines are quoted -- hence the quote-aware parser below rather than a plain
# comma split. Tabs/newlines inside a field are flattened to spaces so the TSV
# output stays rectangular.

usage() {
  cat <<'EOF'
Usage:
  ./scripts/merge_padloc_summary.sh <padloc_out_dir> <samples_file> <summary_tsv> <genes_tsv>

  padloc_out_dir  Directory holding PADLOC's <sample>_padloc.csv files
  samples_file    Newline-separated list of every sample PADLOC was run on
  summary_tsv     Output: one row per sample (created even if nothing was found)
  genes_tsv       Output: one row per gene hit (NOT created when nothing was found)
EOF
}

if [[ ${1:-} == "--help" || ${1:-} == "-h" ]]; then
  usage
  exit 0
fi

if [[ $# -lt 4 ]]; then
  usage >&2
  exit 1
fi

padloc_out_dir=$1
samples_file=$2
summary_tsv=$3
genes_tsv=$4

if [[ ! -d $padloc_out_dir ]]; then
  echo "[merge-padloc] PADLOC output directory not found: $padloc_out_dir" >&2
  exit 1
fi

if [[ ! -f $samples_file ]]; then
  echo "[merge-padloc] Sample list not found: $samples_file" >&2
  exit 1
fi

mkdir -p "$(dirname "$summary_tsv")" "$(dirname "$genes_tsv")"

# nullglob so a run where PADLOC found nothing at all expands to no CSVs; /dev/null
# is passed first so awk always has an input file and never blocks reading stdin.
shopt -s nullglob
padloc_csvs=("$padloc_out_dir"/*_padloc.csv)
shopt -u nullglob

awk \
  -v samples_file="$samples_file" \
  -v summary_out="$summary_tsv" \
  -v genes_out="$genes_tsv" '
# Split one CSV record into arr[1..n], honouring quoted fields and "" escapes.
function csv_split(rec, arr,   n, i, c, f, inq, len) {
  n = 0; f = ""; inq = 0; len = length(rec)
  for (i = 1; i <= len; i++) {
    c = substr(rec, i, 1)
    if (inq) {
      if (c == "\"") {
        if (substr(rec, i + 1, 1) == "\"") { f = f "\""; i++ } else { inq = 0 }
      } else {
        f = f c
      }
    } else {
      if (c == "\"") { inq = 1 }
      else if (c == ",") { arr[++n] = f; f = "" }
      else { f = f c }
    }
  }
  arr[++n] = f
  return n
}

# Flatten anything that would break the TSV grid.
function clean(s) {
  gsub(/\r/, "", s)
  gsub(/\n/, " ", s)
  gsub(/\t/, " ", s)
  return s
}

BEGIN {
  n_order = 0
  while ((getline line < samples_file) > 0) {
    if (line != "") { order[++n_order] = line }
  }
  close(samples_file)
  genes_started = 0
}

# New file: reset the record buffer and re-arm header detection.
FNR == 1 {
  sample = FILENAME
  sub(/.*\//, "", sample)
  sub(/_padloc\.csv$/, "", sample)
  buf = ""
  header_done = 0
}

{
  # Accumulate until the buffered record has balanced quotes, so a field
  # containing a newline is not treated as two records.
  buf = (buf == "") ? $0 : buf "\n" $0
  if (gsub(/"/, "\"", buf) % 2 != 0) { next }

  nf = csv_split(buf, F)
  buf = ""

  if (!header_done) {
    header_done = 1
    nh = nf
    for (i = 1; i <= nf; i++) { H[i] = F[i] }
    next
  }

  if (!genes_started) {
    genes_started = 1
    line = "sample"
    for (i = 1; i <= nh; i++) { line = line "\t" clean(H[i]) }
    print line > genes_out
  }

  # system.number is assigned per (seqid, system, cluster) group, so distinct
  # (seqid, system.number) pairs count system instances; rows count gene hits.
  syskey = sample SUBSEP F[2] SUBSEP F[1]
  if (!(syskey in seen_sys)) { seen_sys[syskey] = 1; nsys[sample]++ }

  namekey = sample SUBSEP F[3]
  if (!(namekey in seen_name)) {
    seen_name[namekey] = 1
    syslist[sample] = (syslist[sample] == "") ? F[3] : syslist[sample] ";" F[3]
  }

  ngenes[sample]++

  line = clean(sample)
  for (i = 1; i <= nf; i++) { line = line "\t" clean(F[i]) }
  print line > genes_out
}

END {
  print "sample\tn_systems\tsystems\tn_genes" > summary_out
  for (i = 1; i <= n_order; i++) {
    s = order[i]
    printf "%s\t%d\t%s\t%d\n", s, nsys[s] + 0, syslist[s], ngenes[s] + 0 > summary_out
  }
}
' /dev/null ${padloc_csvs[@]+"${padloc_csvs[@]}"}

summary_rows=$(($(wc -l < "$summary_tsv") - 1))
echo "[merge-padloc] Wrote per-sample summary ($summary_rows samples): $summary_tsv"

if [[ -s $genes_tsv ]]; then
  gene_rows=$(($(wc -l < "$genes_tsv") - 1))
  echo "[merge-padloc] Wrote per-gene table ($gene_rows hits): $genes_tsv"
else
  # No systems anywhere in this batch. Leave no empty table behind for the
  # consolidation stage to try to rbind.
  rm -f "$genes_tsv"
  echo "[merge-padloc] No defence systems found in any sample; no per-gene table written."
fi
