#!/usr/bin/env bash
# Make Bactopia's CheckM .command.sh resilient before it runs.
#
# CheckM's task script runs under `bash -ue`, and three of its commands abort the
# task when they hit an empty/edge case:
#   1. `find ./results/ ... | xargs gzip` runs gzip with no input when no matching
#      files exist (and -or precedence is wrong);
#   2. `mv results/checkm.log ./` fails when CheckM produced no checkm.log;
#   3. the versions.yml `checkm -h` capture aborts if `checkm -h` exits non-zero.
# Make each tolerant. Idempotent; safe if .command.sh is absent.
#
# This lives in its own file (not inline in the *_all_tools.config beforeScript)
# because an inline `<<'PY'` heredoc breaks when Nextflow embeds the beforeScript
# into .command.run -- the PY terminator is not recognised and .command.run
# becomes a syntax error. In a standalone script the heredoc parses normally.
set -u
[ -f .command.sh ] || exit 0
grep -q 'checkm_command_fix applied' .command.sh && exit 0   # idempotent

python3 - <<'PY'
from pathlib import Path

path = Path(".command.sh")
text = path.read_text()

text = text.replace(
    'find ./results/ -name "*.faa" -or -name "*hmmer.analyze.txt" -or -name "*.fasta" | xargs gzip',
    'find ./results/ \\( -name "*.faa" -o -name "*hmmer.analyze.txt" -o -name "*.fasta" \\) -print0 | xargs -0 -r gzip || true',
)
text = text.replace(
    "mv results/checkm.log ./",
    "mv results/checkm.log ./ || true",
)
# NOTE: deliberately do NOT touch the `checkm: $(echo $(checkm -h 2>&1) | sed ...)`
# versions.yml line. The `echo $(...)` collapses checkm -h's multi-line output onto
# one line before sed; removing it makes the checkm: value multi-line and breaks the
# YAML that CUSTOM_DUMPSOFTWAREVERSIONS then parses. Bactopia's original line works.

# CheckM's multiprocessing.Manager opens an AF_UNIX socket under TMPDIR. Our TMPDIR
# ($NXF_WORK/tmp) is a deep path that, plus Python's pymp-*/listener-* suffix,
# overruns the 108-char sun_path limit ("OSError: AF_UNIX path too long"). Point
# CheckM at the short container /tmp so the socket path string stays well under it.
# (Concurrent CheckM tasks stay unique via Python's random pymp-* subdir name.)
text = text.replace(
    "checkm \\\n    lineage_wf",
    "export TMPDIR=/tmp\ncheckm \\\n    lineage_wf",
    1,
)

text += "\n# checkm_command_fix applied\n"
path.write_text(text)
PY
