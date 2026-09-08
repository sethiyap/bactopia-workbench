#!/usr/bin/env python3
"""Collect per-sample task failures from every Nextflow trace under a results root.

Per-sample tool modules carry `errorStrategy = 'ignore'` (see the
`perSampleToolFailureStrategy` note in scripts/nextflow.*.all_tools.config), so one
bad sample no longer kills a batch and every stage that depends on it. The cost of
that is silence: the sample simply has empty columns for that tool, with nothing in
the results saying why. This turns that silence back into a row.

Bactopia writes a trace file per run at
    <outdir>/bactopia-runs/<run>-<timestamp>/nf-reports/<wf>-trace.txt
with `process`, `tag` (the sample id), `status`, `exit`, `attempt` and `hash`. Every
task whose final attempt did not COMPLETE is a failure. The trace has no work
directory column, but `hash` is the work directory's two-level prefix (`d5/e26e7d`),
so the task's `.command.err` can be found and the real error read out of it -- the
difference between "checkm produced nothing" and
`pplacer: Sys_error("Input/output error")`.

Writes a TSV of one row per (sample, stage, process) failure. Best-effort by
design: an unreadable trace or a pruned work directory degrades the row rather than
failing the run, because this is diagnostics and must never be what breaks a
pipeline that otherwise succeeded.
"""

from __future__ import annotations

import argparse
import csv
import re
import sys
from pathlib import Path

# Statuses that mean the task delivered its outputs. Anything else is a failure --
# including a task Nextflow retried and then ignored, which is exactly the case this
# script exists to surface.
OK_STATUSES = {"COMPLETED", "CACHED"}

# Lines every container run emits, or that carry no diagnostic content. Dropping
# them is what makes the difference between a usable `failure_reason` cell and one
# full of "INFO: Converting SIF file to temporary sandbox".
NOISE_PATTERNS = (
    re.compile(r"^\s*$"),
    re.compile(r"^(INFO|WARNING|DEBUG):\s", re.I),
    re.compile(r"^\s*(Sketching|Writing|Loading|Computing|computing|calculated|saved|"
               r"\.\.\.|==|Please cite|loaded|finding|outputting|classified)"),
    re.compile(r"^\s*\[?(nextflow|singularity|apptainer)", re.I),
    re.compile(r"^\s*(WARN|warn):", re.I),
)

# Lines worth promoting even if they would otherwise look ordinary: these name the
# actual fault. Ordered most specific first.
SIGNAL_PATTERNS = (
    re.compile(r"Sys_error\(.*\)"),                 # OCaml (pplacer) -- e.g. EIO
    re.compile(r"\b(Fatal error|Uncaught exception)\b", re.I),
    re.compile(r"\b(Traceback \(most recent call last\))"),
    re.compile(r"\b\w*(Error|Exception)\b\s*:"),    # Python/Java style
    re.compile(r"\b(Killed|Segmentation fault|Bus error|core dumped)\b", re.I),
    re.compile(r"\b(No such file or directory|Permission denied|"
               r"Input/output error|Cannot allocate memory|Disk quota exceeded|"
               r"No space left on device)\b", re.I),
    re.compile(r"\b(command not found|error while loading shared libraries)\b", re.I),
)

MAX_REASON_CHARS = 300


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Collect per-sample Nextflow task failures into one TSV."
    )
    parser.add_argument(
        "--results-root",
        required=True,
        help="Pipeline RESULTS_ROOT; searched for Nextflow trace files and work dirs.",
    )
    parser.add_argument(
        "--output",
        required=True,
        help="TSV to write (one row per sample/stage/process failure).",
    )
    parser.add_argument(
        "--work-root",
        action="append",
        default=[],
        help="Extra directory to search for task work dirs. Repeatable. "
             "Defaults to <results-root>/_work.",
    )
    return parser.parse_args()


def find_trace_files(results_root: Path) -> list[Path]:
    """Every Bactopia trace under the results root, newest last.

    Bactopia timestamps each run directory, so a re-run leaves the previous run's
    trace in place. Sorting by mtime and letting later traces win means a sample that
    failed once and succeeded on a re-run is not reported as still failing.
    """
    traces = list(results_root.glob("**/nf-reports/*-trace.txt"))
    traces.sort(key=lambda p: (p.stat().st_mtime if p.exists() else 0))
    return traces


def stage_name(trace_path: Path, results_root: Path) -> str:
    """A human-meaningful stage label for a trace file.

    The run directory is <label>/.../bactopia-runs/<run>-<timestamp>/nf-reports, and
    the part of the path directly under the results root is the stage the pipeline
    submitted (e.g. batch_bactopia_003_tools). Falls back to the trace's own parent.
    """
    try:
        rel = trace_path.relative_to(results_root)
    except ValueError:
        return trace_path.parent.name
    parts = rel.parts
    return parts[0] if parts else trace_path.parent.name


def short_process(process: str) -> str:
    """`BACTOPIATOOLS:CHECKM:CHECKM_LINEAGEWF` -> `CHECKM_LINEAGEWF`."""
    return process.rsplit(":", 1)[-1] if process else ""


def tool_of(process: str) -> str:
    """The tool a process belongs to, lowercased, for a per-sample `failed_steps` list.

    `BACTOPIATOOLS:CHECKM:CHECKM_LINEAGEWF` -> `checkm`;
    `BACTOPIA:ANNOTATOR:PROKKA_MODULE` -> `annotator`. The middle segment is the
    subworkflow, which is what a reader recognises as "the tool"; a two-segment name
    falls back to the process itself.
    """
    if not process:
        return ""
    parts = [p for p in process.split(":") if p]
    if len(parts) >= 3:
        return parts[-2].lower()
    return short_process(process).lower().replace("_module", "")


def resolve_work_dir(task_hash: str, work_roots: list[Path]) -> Path | None:
    """Find a task's work directory from its trace `hash` (`d5/e26e7d`).

    The hash is a prefix, so the full directory name has to be globbed for. Stages
    keep work under different roots (bactopia_batches/, bactopia_tools/<tool>/), and
    the tool ones nest one level deeper, hence the recursive glob.
    """
    if not task_hash or "/" not in task_hash:
        return None
    prefix, rest = task_hash.split("/", 1)
    for root in work_roots:
        if not root.is_dir():
            continue
        for candidate in root.glob(f"**/{prefix}/{rest}*"):
            if candidate.is_dir():
                return candidate
    return None


def extract_reason(work_dir: Path | None) -> str:
    """Pull the most diagnostic line(s) out of a failed task's stderr.

    Prefers a line matching a known fault signature (an OCaml `Sys_error`, a Python
    traceback's exception line, an ENOMEM/EIO message); otherwise falls back to the
    last few non-noise lines, which is usually where a tool prints its complaint.
    """
    if work_dir is None:
        return ""
    err_path = work_dir / ".command.err"
    if not err_path.is_file():
        return ""
    try:
        lines = err_path.read_text(errors="replace").splitlines()
    except OSError:
        return ""

    def is_noise(line: str) -> bool:
        return any(p.search(line) for p in NOISE_PATTERNS)

    meaningful = [ln.strip() for ln in lines if not is_noise(ln)]

    for pattern in SIGNAL_PATTERNS:
        for line in reversed(meaningful):
            if pattern.search(line):
                return tsv_safe(line)

    if meaningful:
        return tsv_safe(" | ".join(meaningful[-2:]))
    return ""


def tsv_safe(text: str) -> str:
    """Make a stderr line safe to drop into a TSV cell.

    Tool output contains tabs and quotes (CheckM's is
    `Sys_error("Input/output error")`), and this table is read back by
    utils::read.delim and openpyxl. Writing with QUOTE_NONE keeps the file plainly
    tab-delimited, which means the cell itself must carry no tabs or newlines.
    """
    collapsed = " ".join(text.split())
    return collapsed[:MAX_REASON_CHARS]


def read_trace(trace_path: Path) -> list[dict[str, str]]:
    try:
        with trace_path.open(newline="", errors="replace") as handle:
            return list(csv.DictReader(handle, delimiter="\t"))
    except OSError:
        return []


def main() -> int:
    args = parse_args()
    results_root = Path(args.results_root)
    if not results_root.is_dir():
        raise SystemExit(f"--results-root must be an existing directory: {results_root}")

    work_roots = [Path(p) for p in args.work_root] or [results_root / "_work"]

    # Keyed by (sample, stage, process) so a later trace -- a re-run of the same stage
    # -- overwrites an earlier verdict, and a task that was retried is recorded once,
    # at its final attempt.
    failures: dict[tuple[str, str, str], dict[str, str]] = {}
    resolved: dict[tuple[str, str, str], bool] = {}

    for trace_path in find_trace_files(results_root):
        stage = stage_name(trace_path, results_root)
        for row in read_trace(trace_path):
            sample = (row.get("tag") or "").strip()
            process = (row.get("process") or "").strip()
            status = (row.get("status") or "").strip().upper()
            if not sample or not process:
                continue
            key = (sample, stage, process)
            if status in OK_STATUSES:
                # A later successful attempt clears an earlier failed one.
                resolved[key] = True
                failures.pop(key, None)
                continue
            if resolved.get(key):
                continue
            failures[key] = {
                "sample": sample,
                "stage": stage,
                "tool": tool_of(process),
                "process": short_process(process),
                "status": status,
                "exit": (row.get("exit") or "").strip(),
                "attempt": (row.get("attempt") or "").strip(),
                "hash": (row.get("hash") or "").strip(),
            }

    rows = []
    for record in failures.values():
        work_dir = resolve_work_dir(record.pop("hash"), work_roots)
        record["failure_reason"] = extract_reason(work_dir)
        record["work_dir"] = str(work_dir) if work_dir else ""
        rows.append(record)

    rows.sort(key=lambda r: (r["sample"], r["stage"], r["process"]))

    fields = ["sample", "stage", "tool", "process", "status", "exit", "attempt",
              "failure_reason", "work_dir"]
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, delimiter="\t",
                                lineterminator="\n", extrasaction="ignore",
                                quoting=csv.QUOTE_NONE, quotechar="", escapechar=None)
        writer.writeheader()
        writer.writerows(rows)

    print(f"Wrote {len(rows)} task failure(s) to {output}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
