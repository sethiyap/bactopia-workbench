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
  for candidate in singularity apptainer; do
    if command -v "$candidate" >/dev/null 2>&1; then
      engine=$candidate
      break
    fi
  done
fi
if [[ -z $engine && ( $deep == 1 || $check_only == 0 ) ]]; then
  fail "Neither singularity nor apptainer is on PATH. On Gadi: module load singularity"
fi

# Reverse Nextflow's cache naming (SingularityCache.simpleName): the container URL
# has its protocol stripped and every '/' and ':' replaced with '-', then '.img'
# appended. Two forms appear in this pipeline's configs:
#
#   depot.galaxyproject.org-singularity-<pkg>-<tag>.img
#     -> https://depot.galaxyproject.org/singularity/<pkg>:<tag>   (plain download)
#   quay.io-biocontainers-<pkg>-<tag>.img
#     -> docker://quay.io/biocontainers/<pkg>:<tag>                (engine pull)
#
# Splitting <pkg> from <tag> is the only ambiguous part, because both may contain
# '-'. Biocontainer tags always start with a digit and package names never end in
# one, so the tag is the last '-'-delimited run that starts with a digit.
split_pkg_tag() {
  local rest=$1
  [[ $rest =~ ^(.+)-([0-9][^-]*(--.*)?)$ ]] || return 1
  printf '%s:%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

image_source() {
  local base=$1 stem rest pkg_tag

  stem=${base%.img}
  stem=${stem%.sif}

  case "$stem" in
    depot.galaxyproject.org-singularity-*)
      rest=${stem#depot.galaxyproject.org-singularity-}
      pkg_tag=$(split_pkg_tag "$rest") || return 1
      printf 'https://depot.galaxyproject.org/singularity/%s\n' "$pkg_tag"
      ;;
    quay.io-biocontainers-*)
      rest=${stem#quay.io-biocontainers-}
      pkg_tag=$(split_pkg_tag "$rest") || return 1
      printf 'docker://quay.io/biocontainers/%s\n' "$pkg_tag"
      ;;
    *)
      return 1
      ;;
  esac
}

image_is_usable() {
  local path=$1

  [[ -s $path ]] || return 1
  [[ $deep == 1 ]] || return 0
  "$engine" exec "$path" true >/dev/null 2>&1
}

download_image() {
  local source=$1 dest=$2 tmp

  tmp=$(mktemp "${dest}.repair.XXXXXX") || return 1

  if [[ $source == docker://* ]]; then
    # `pull --force` writes the final path directly, so pull to the temp name.
    if ! "$engine" pull --force "$tmp" "$source" >&2; then
      rm -f "$tmp"
      return 1
    fi
  else
    if ! curl -fsSL --retry 3 -o "$tmp" "$source" >&2; then
      rm -f "$tmp"
      return 1
    fi
  fi

  # Verify BEFORE it goes into the cache, so a bad download is never visible to
  # Nextflow as a cached image.
  if [[ ! -s $tmp ]] || ! "$engine" exec "$tmp" true >/dev/null 2>&1; then
    log "Downloaded image failed verification, discarding: $source"
    rm -f "$tmp"
    return 1
  fi

  chmod 755 "$tmp"
  mv -f "$tmp" "$dest"
}

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
  image_is_usable "$path" || broken+=("$path")
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

  if ! source=$(image_source "$base"); then
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

  if download_image "$source" "$path"; then
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
