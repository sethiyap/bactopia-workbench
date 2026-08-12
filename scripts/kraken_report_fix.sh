#!/usr/bin/env bash
# Prepend a zero U (unclassified) row to every Kraken2 report in the current
# directory that lacks one.
#
# Bactopia's kraken-bracken-summary.py (the "Adjust bracken to include
# unclassified and produce summary" step) reads the unclassified count from the
# Kraken2 report's U-rank row, then does `unclassified_count + <float>`. Kraken2
# omits the U row when 100% of a sample's reads classify, so unclassified_count
# is None and the script aborts with a TypeError -- taking the whole task down
# because .command.sh runs under `bash -ue`.
#
# Adding a 0-count U row yields the correct value (0 unclassified) and lets the
# summary run. Idempotent (skips reports that already have a U row) and safe when
# no report is present. Invoked from the BRACKEN_MODULE beforeScript in the
# *_all_tools.config files, injected into .command.sh before the summary call.
set -u
shopt -s nullglob

for report in *.kraken2.report.txt; do
  # Column 4 is the rank code; "U" is the unclassified row. Skip if already present.
  if awk -F'\t' '$4 == "U" { found = 1 } END { exit(found ? 0 : 1) }' "$report"; then
    continue
  fi
  { printf '0.00\t0\t0\tU\t0\tunclassified\n'; cat "$report"; } > "${report}.__ufix" \
    && mv "${report}.__ufix" "$report"
done

exit 0
