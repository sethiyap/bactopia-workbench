#!/usr/bin/env bash
# Add --skip-model-version-check to Bactopia's DefenseFinder run command.
#
# defense-finder's `run` calls check_last_version_models(), which queries the GitHub
# API to see whether newer models exist. Across many samples this exhausts GitHub's
# unauthenticated hourly rate limit and the task aborts with:
#   macsypy.error.MacsyDataLimitError: You reach the maximum number of request ...
# The models are already installed locally in the same task (macsydata install just
# above), so the online check is unnecessary -- skip it. This also makes the stage
# work offline. Idempotent; safe if .command.sh is absent.
#
# Lives in its own script (not inline in the *_all_tools.config beforeScript) so the
# heredoc parses normally, matching checkm_command_fix.sh / kraken_report_fix.sh.
set -u
[ -f .command.sh ] || exit 0
grep -q 'defensefinder_command_fix applied' .command.sh && exit 0

python3 - <<'PY'
from pathlib import Path

path = Path(".command.sh")
text = path.read_text()

if "--skip-model-version-check" not in text:
    # Insert the flag just before --models-dir on the `defense-finder run` line
    # (that argument is unique to the run command; the macsydata installs use --target).
    text = text.replace(
        "--models-dir defense-finder/",
        "--skip-model-version-check \\\n    --models-dir defense-finder/",
        1,
    )

text += "\n# defensefinder_command_fix applied\n"
path.write_text(text)
PY
