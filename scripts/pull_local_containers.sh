#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/pull_local_containers.sh [OPTIONS]

Pre-stage the Singularity images the local backend pins (mlst, kleborate) into
SING_CACHE, so a scheduler-free `submit local` run works on an OFFLINE host.
After a successful pull, prints the MLST_CONTAINER / KLEBORATE_CONTAINER lines to
add to config/sites/local.local.env.

Existing images are reused (skipped) unless --force is given.

Options:
  --dest DIR        Where to store the .sif files (default: $SING_CACHE, else ~/singularity_cache)
  --engine NAME     Container engine: singularity or apptainer (default: auto-detect)
  --with-fimtyper   Also pull FimTyper (default: the published GHCR image)
  --force           Re-pull and overwrite images that already exist
  --help            Print this message

Environment overrides:
  SING_CACHE                destination dir (same as --dest)
  MLST_CONTAINER_URI        default: docker://quay.io/biocontainers/mlst:2.33.1--hdfd78af_0
  KLEBORATE_CONTAINER_URI   default: docker://quay.io/biocontainers/kleborate:2.3.2--pyhdfd78af_0
  FIMTYPER_CONTAINER_URI    default: docker://ghcr.io/sethiyap/agar-bactopia-fimtyper:1.1
EOF
}

log() {
  # Progress goes to stderr so it never contaminates the paths that pull_one
  # returns via command substitution.
  printf '[pull-local-containers] %s\n' "$*" >&2
}

fail() {
  printf '[pull-local-containers] ERROR: %s\n' "$*" >&2
  exit 1
}

dest="${SING_CACHE:-$HOME/singularity_cache}"
engine=""
with_fimtyper=0
force=0

mlst_uri="${MLST_CONTAINER_URI:-docker://quay.io/biocontainers/mlst:2.33.1--hdfd78af_0}"
kleborate_uri="${KLEBORATE_CONTAINER_URI:-docker://quay.io/biocontainers/kleborate:2.3.2--pyhdfd78af_0}"
fimtyper_uri="${FIMTYPER_CONTAINER_URI:-docker://ghcr.io/sethiyap/agar-bactopia-fimtyper:1.1}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest)
      dest=$2
      shift 2
      ;;
    --engine)
      engine=$2
      shift 2
      ;;
    --with-fimtyper)
      with_fimtyper=1
      shift
      ;;
    --force)
      force=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z $engine ]]; then
  if command -v singularity >/dev/null 2>&1; then
    engine=singularity
  elif command -v apptainer >/dev/null 2>&1; then
    engine=apptainer
  else
    fail "No container engine found. Install singularity or apptainer, or pass --engine."
  fi
fi
command -v "$engine" >/dev/null 2>&1 || fail "Container engine not on PATH: $engine"

mkdir -p "$dest"
dest=$(cd "$dest" && pwd)

# outfile basename derived from the image tag; filename is stable so the printed
# MLST_CONTAINER / KLEBORATE_CONTAINER overrides keep pointing at it.
pull_one() {
  local label=$1 uri=$2 outfile=$3
  local out="${dest}/${outfile}"

  if [[ -f $out && $force -eq 0 ]]; then
    log "${label}: already present, skipping (${out})"
    printf '%s\n' "$out"
    return 0
  fi

  log "${label}: pulling ${uri}"
  local -a cmd=("$engine" pull)
  [[ $force -eq 1 ]] && cmd+=(--force)
  cmd+=("$out" "$uri")
  if ! "${cmd[@]}" >&2; then
    fail "${label}: pull failed for ${uri}"
  fi
  [[ -s $out ]] || fail "${label}: no image written to ${out}"
  printf '%s\n' "$out"
}

log "Engine: $engine"
log "Destination (SING_CACHE): $dest"

mlst_out=$(pull_one "mlst" "$mlst_uri" "mlst-2.33.1--hdfd78af_0.sif")
kleborate_out=$(pull_one "kleborate" "$kleborate_uri" "kleborate-2.3.2--pyhdfd78af_0.sif")

fimtyper_out=""
if [[ $with_fimtyper -eq 1 ]]; then
  [[ -n $fimtyper_uri ]] || fail "FIMTYPER_CONTAINER_URI is empty; unset it to use the default or provide a URI."
  fimtyper_out=$(pull_one "fimtyper" "$fimtyper_uri" "fimtyper.sif")
fi

cat <<EOF

Done. Add these to config/sites/local.local.env (or export before the run):

  SING_CACHE=${dest}
  MLST_CONTAINER=${mlst_out}
  KLEBORATE_CONTAINER=${kleborate_out}
EOF
[[ -n $fimtyper_out ]] && printf '  FIMTYPER_CONTAINER=%s\n' "$fimtyper_out"
echo
