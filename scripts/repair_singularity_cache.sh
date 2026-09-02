#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/repair_singularity_cache.sh [OPTIONS] [IMAGE_NAME ...]

Find and repair broken Singularity images in SING_CACHE.

A pull attempted from a machine with no outbound internet (every Gadi *compute*
node) leaves a 0-byte file behind in the cache. Nextflow then treats that stub as
a cached image and never retries the pull, so every task using it dies with

  FATAL: ... could not open image ...: image format not recognized

and exits 255 -- deterministically, on every later run, until the stub is
removed. This script finds those stubs, re-downloads them, and verifies the
result. Run it from a Gadi LOGIN node (compute nodes cannot reach the internet).

Downloads land on a temp file and are moved into place only after they verify, so
an interrupted repair cannot re-poison the cache.

Options:
  --dir DIR      Cache directory (default: $SING_CACHE, else
                 /scratch/$PROJECT/$USER/singularity_cache)
  --check-only   Report broken images and exit non-zero; change nothing
  --deep         Also verify non-empty images by running the container. Slower,
                 and catches truncated downloads that a size check misses.
  --engine NAME  singularity or apptainer (default: auto-detect)
  --yes          Do not prompt before replacing a broken image
  --help         Print this message

With no IMAGE_NAME arguments every image in the cache is examined. Otherwise only
the named ones are (basename, e.g.
depot.galaxyproject.org-singularity-phispy-4.2.21--py310h0dbaff4_2.img).

Exit status is non-zero if any image is still broken when the script finishes.
EOF
}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib_singularity_cache.sh
source "$script_dir/lib_singularity_cache.sh"

log()  { printf '[repair-sing-cache] %s\n' "$*" >&2; }
fail() { printf '[repair-sing-cache] ERROR: %s\n' "$*" >&2; exit 1; }

cache_dir=${SING_CACHE:-/scratch/${PROJECT:-rg42}/${USER}/singularity_cache}
check_only=0
deep=0
assume_yes=0
engine=""
declare -a wanted=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)        cache_dir=$2; shift 2 ;;
    --check-only) check_only=1; shift ;;
    --deep)       deep=1; shift ;;
    --engine)     engine=$2; shift 2 ;;
    --yes|-y)     assume_yes=1; shift ;;
    --help|-h)    usage; exit 0 ;;
    -*)           usage >&2; fail "Unknown option: $1" ;;
    *)            wanted+=("$1"); shift ;;
  esac
done

[[ -d $cache_dir ]] || fail "Cache directory not found: $cache_dir"

if [[ -z $engine ]]; then
  engine=$(sc_detect_engine || true)
fi
if [[ -z $engine && ( $deep == 1 || $check_only == 0 ) ]]; then
  fail "Neither singularity nor apptainer is on PATH. On Gadi: module load singularity"
fi

declare -a images=()
if [[ ${#wanted[@]} -gt 0 ]]; then
  for name in "${wanted[@]}"; do
    images+=("$cache_dir/$(basename "$name")")
  done
else
  while IFS= read -r path; do
    images+=("$path")
  done < <(find "$cache_dir" -maxdepth 1 -type f \( -name '*.img' -o -name '*.sif' \) | sort)
fi

if [[ ${#images[@]} -eq 0 ]]; then
  log "No .img/.sif files found in: $cache_dir"
  exit 0
fi

log "Cache: $cache_dir"
log "Checking ${#images[@]} image(s)${deep:+ }$([[ $deep == 1 ]] && echo '(deep verification enabled)')"

declare -a broken=() unresolved=() repaired=() still_broken=()

for path in "${images[@]}"; do
  if [[ ! -e $path ]]; then
    log "Not in cache, treating as missing: $(basename "$path")"
    broken+=("$path")
    continue
  fi
  sc_image_is_usable "$path" "$engine" "$deep" || broken+=("$path")
done

if [[ ${#broken[@]} -eq 0 ]]; then
  log "All images are usable."
  exit 0
fi

log ""
log "Broken or missing image(s): ${#broken[@]}"
for path in "${broken[@]}"; do
  size=$( [[ -e $path ]] && wc -c < "$path" | tr -d " " 2>/dev/null || echo "absent" )
  printf '  %-90s %s bytes\n' "$(basename "$path")" "$size" >&2
done
log ""

if [[ $check_only == 1 ]]; then
  log "Check-only mode; nothing changed. Re-run without --check-only from a LOGIN node to repair."
  exit 1
fi

if [[ $assume_yes != 1 ]]; then
  read -r -p "[repair-sing-cache] Re-download the image(s) listed above? [y/N] " reply
  case "$reply" in
    y|Y|yes|YES) ;;
    *) log "Aborted; nothing changed."; exit 1 ;;
  esac
fi

for path in "${broken[@]}"; do
  base=$(basename "$path")

  if ! source=$(sc_image_source "$base"); then
    log "Cannot derive a source URL for: $base (pull it by hand)"
    unresolved+=("$base")
    still_broken+=("$base")
    continue
  fi

  log "Repairing $base"
  log "  from $source"

  # Remove the stub first: leaving it in place means an aborted repair still shows
  # Nextflow a cached image, which is exactly how this cache got poisoned.
  rm -f "$path"

  if sc_download_image "$source" "$path" "$engine"; then
    log "  ok ($(wc -c < "$path" | tr -d " ") bytes)"
    repaired+=("$base")
  else
    log "  FAILED -- the stub is removed, so Nextflow will attempt its own pull next run"
    still_broken+=("$base")
  fi
done

log ""
log "Repaired: ${#repaired[@]}   Still broken: ${#still_broken[@]}"
if [[ ${#still_broken[@]} -gt 0 ]]; then
  for base in "${still_broken[@]}"; do
    printf '  %s\n' "$base" >&2
  done
  if [[ ${#unresolved[@]} -gt 0 ]]; then
    log "Images with an unrecognised name pattern must be pulled manually into $cache_dir"
  fi
  exit 1
fi

log "Cache is clean. Resubmit the pipeline."
