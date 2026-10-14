#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/download_agrf_to_gadi.sh REMOTE_SPEC YEAR BATCH
  ./scripts/download_agrf_to_gadi.sh REMOTE_SPEC YEAR BATCH DEST_NAME
  ./scripts/download_agrf_to_gadi.sh --dest DIR REMOTE_SPEC

Examples:
  ./scripts/download_agrf_to_gadi.sh \
    user@source.example.org:/path/to/AGRF_CAGRF26050180_AAHJ2FTM5 \
    2025 \
    B07

  ./scripts/download_agrf_to_gadi.sh \
    user@source.example.org:/path/to/AGRF_CAGRF26050180_AAHJ2FTM5 \
    2025 \
    B07 \
    AGRF_CAGRF26050180_AAHJ2FTM5

  ./scripts/download_agrf_to_gadi.sh \
    --dest /scratch/rg42/anywhere/i/like \
    user@source.example.org:/path/to/AGRF_CAGRF26050180_AAHJ2FTM5

What it does:
  1. Works out the destination directory, in one of two ways:
       --dest DIR    copy straight into DIR, exactly as given
       otherwise     DEST_ROOT/<YEAR>/<BATCH>/<DEST_NAME>, the AGAR raw_data tree
  2. Creates that directory
  3. Uses rsync over ssh to copy the remote delivery into it

Options:
  -d, --dest DIR   Destination directory, used verbatim. No YEAR/BATCH/DEST_NAME
                   levels are appended, so YEAR and BATCH are not required.
                   A relative path is resolved against the current directory.
                   Equivalent to setting DEST_DIR.
  -h, --help       Print this help

Arguments:
  REMOTE_SPEC  rsync-compatible remote source, usually user@host:/path/to/delivery
  YEAR         Processing year, for example 2025. Not used with --dest
  BATCH        Batch id, for example B07. Not used with --dest
  DEST_NAME    Optional target directory name. Default: basename(REMOTE_SPEC).
               Not used with --dest

Environment variables:
  DEST_DIR     Same as --dest. The option wins if both are set
  PROJECT      Default: rg42
  DEST_ROOT    Default: /scratch/<PROJECT>/AGAR/raw_data. May be overridden
               to another absolute destination root. Ignored with --dest
  RSYNC_RSH    Optional custom remote shell, for example "ssh -p 2222"
  RSYNC_ARGS   Optional extra rsync args appended to the command
  DRY_RUN      Set to 1 to print the rsync plan without copying. The
               destination directory is not created either
EOF
}

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
  echo "$*" >&2
  exit 1
}

dest_dir=${DEST_DIR:-}
declare -a positional=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest|-d)  [[ $# -ge 2 ]] || { usage >&2; fail "Missing argument for $1"; }
                dest_dir=$2; shift 2 ;;
    --dest=*)   dest_dir=${1#--dest=}; shift ;;
    --help|-h)  usage; exit 0 ;;
    --)         shift; positional+=("$@"); break ;;
    -*)         usage >&2; fail "Unknown option: $1" ;;
    *)          positional+=("$1"); shift ;;
  esac
done

if [[ ${#positional[@]} -eq 0 ]]; then
  usage >&2
  exit 1
fi

remote_spec=${positional[0]}

PROJECT=${PROJECT:-rg42}
DEST_ROOT=${DEST_ROOT:-/scratch/${PROJECT}/AGAR/raw_data}
RSYNC_RSH=${RSYNC_RSH:-}
RSYNC_ARGS=${RSYNC_ARGS:-}
DRY_RUN=${DRY_RUN:-0}

if ! command -v rsync >/dev/null 2>&1; then
  fail "Required command not found: rsync"
fi

if [[ -n $dest_dir ]]; then
  if [[ ${#positional[@]} -ne 1 ]]; then
    usage >&2
    fail "With --dest, pass REMOTE_SPEC only. YEAR, BATCH and DEST_NAME are not used: ${positional[*]:1}"
  fi

  dest_dir=${dest_dir%/}
  [[ -n $dest_dir ]] || fail "--dest must not be the root directory"
else
  if [[ ${#positional[@]} -lt 3 || ${#positional[@]} -gt 4 ]]; then
    usage >&2
    exit 1
  fi

  year=${positional[1]}
  batch=${positional[2]}
  dest_name=${positional[3]:-}

  if [[ -z $dest_name ]]; then
    source_path=${remote_spec#*:}
    source_path=${source_path%/}
    dest_name=$(basename "$source_path")
  fi

  if [[ ! $year =~ ^20[0-9]{2}$ ]]; then
    fail "YEAR must look like 2025: $year"
  fi

  if [[ ! $batch =~ ^[Bb][0-9]{2}$ ]]; then
    fail "BATCH must look like B07: $batch"
  fi

  if [[ -z $dest_name || $dest_name == "." || $dest_name == "/" ]]; then
    fail "Could not derive DEST_NAME from REMOTE_SPEC. Pass DEST_NAME explicitly."
  fi

  if [[ $DEST_ROOT != /* ]]; then
    fail "DEST_ROOT must be an absolute path: $DEST_ROOT"
  fi

  dest_dir="${DEST_ROOT%/}/${year}/${batch}/${dest_name}"
fi

if [[ $DRY_RUN != 1 ]]; then
  mkdir -p "$dest_dir"
fi

if [[ -d $dest_dir ]]; then
  dest_dir=$(cd "$dest_dir" && pwd)
elif [[ $dest_dir != /* ]]; then
  dest_dir="${PWD%/}/${dest_dir#./}"
fi

rsync_cmd=(rsync -av --partial --progress)
if [[ -n $RSYNC_RSH ]]; then
  rsync_cmd+=(-e "$RSYNC_RSH")
fi
if [[ -n $RSYNC_ARGS ]]; then
  # shellcheck disable=SC2206
  extra_rsync_args=($RSYNC_ARGS)
  rsync_cmd+=("${extra_rsync_args[@]}")
fi
if [[ $DRY_RUN == 1 ]]; then
  rsync_cmd+=(--dry-run)
fi

remote_with_trailing_slash=${remote_spec%/}/
rsync_cmd+=("$remote_with_trailing_slash" "$dest_dir/")

log "Remote source: $remote_spec"
log "Destination: $dest_dir"
if [[ $DRY_RUN == 1 ]]; then
  log "DRY_RUN=1, no files will be copied and the destination is not created"
fi

"${rsync_cmd[@]}"

log "Raw data transfer completed: $dest_dir"
