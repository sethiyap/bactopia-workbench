#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/download_bactopia_datasets.sh [OPTIONS]

Fetches the AGAR custom Bactopia datasets (custom MLST schemes, reference
genomes, and Kleborate/AMR resources) from a GitHub Release and extracts them
into the Bactopia datasets cache (DATASETS_CACHE).

Behaviour:
  - If DATASETS_CACHE already exists and is non-empty, the download is skipped
    (reuse-if-present) unless --force is given.
  - Otherwise you are prompted before the download starts, unless --yes /
    ASSUME_YES=1 is set (for non-interactive automation).

Options:
  --dest DIR        Target datasets cache dir (default: $DATASETS_CACHE)
  --url URL         Full download URL of the datasets archive
                    (default: $BACTOPIA_DATASETS_URL, derived from the repo/tag/asset)
  --tag TAG         GitHub Release tag (default: $BACTOPIA_DATASETS_TAG)
  --asset NAME      Release asset filename (default: $BACTOPIA_DATASETS_ASSET)
  --yes             Do not prompt before downloading
  --force           Re-download and overwrite even if the cache already exists
  --help            Print this message

Environment overrides (same as the flags):
  DATASETS_CACHE, BACTOPIA_DATASETS_URL, BACTOPIA_DATASETS_REPO,
  BACTOPIA_DATASETS_TAG, BACTOPIA_DATASETS_ASSET, ASSUME_YES

On success, prints the DATASETS_CACHE=... line to add to your site config
(config/sites/gadi.local.env or config/sites/slurm.local.env).
EOF
}

log() {
  printf '[bactopia-datasets] %s\n' "$*"
}

fail() {
  printf '[bactopia-datasets] ERROR: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

# Defaults. The datasets are published as a GitHub Release asset on this repo.
repo="${BACTOPIA_DATASETS_REPO:-sethiyap/bactopia-workbench}"
tag="${BACTOPIA_DATASETS_TAG:-datasets-latest}"
asset="${BACTOPIA_DATASETS_ASSET:-agar_bactopia_datasets.tar.gz}"
url="${BACTOPIA_DATASETS_URL:-https://github.com/${repo}/releases/download/${tag}/${asset}}"
dest="${DATASETS_CACHE:-}"
assume_yes="${ASSUME_YES:-0}"
force=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest)
      dest=$2
      shift 2
      ;;
    --url)
      url=$2
      shift 2
      ;;
    --tag)
      tag=$2
      url="https://github.com/${repo}/releases/download/${tag}/${asset}"
      shift 2
      ;;
    --asset)
      asset=$2
      url="https://github.com/${repo}/releases/download/${tag}/${asset}"
      shift 2
      ;;
    --yes)
      assume_yes=1
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

if [[ -z $dest ]]; then
  fail "No target set. Pass --dest DIR or set DATASETS_CACHE."
fi

# Reuse-if-present: skip work when a populated cache already exists.
if [[ -d $dest && -n $(ls -A "$dest" 2>/dev/null) ]]; then
  if [[ $force -eq 0 ]]; then
    log "Datasets cache already present and non-empty: $dest"
    log "Nothing to do. Use --force to re-download."
    exit 0
  fi
  log "Cache exists but --force was given; re-downloading into: $dest"
fi

need_cmd curl
need_cmd tar

log "Datasets source: $url"
log "Datasets target: $dest"

if [[ $assume_yes -ne 1 ]]; then
  printf '[bactopia-datasets] Download the AGAR custom datasets now? [y/N] '
  read -r reply
  case "$reply" in
    y|Y|yes|YES) ;;
    *)
      log "Aborted by user. No files were downloaded."
      exit 0
      ;;
  esac
fi

mkdir -p "$dest"
tmp_archive=$(mktemp "${TMPDIR:-/tmp}/agar-bactopia-datasets.XXXXXX.tar.gz")
cleanup() {
  rm -f "$tmp_archive"
}
trap cleanup EXIT

log "Downloading archive..."
# -f makes curl fail (non-zero) on HTTP errors such as 404 instead of saving the
# error page as if it were the archive.
if ! curl -fL --retry 3 -o "$tmp_archive" "$url"; then
  cat >&2 <<EOF
[bactopia-datasets] ERROR: Could not download the datasets archive from:
  $url

If you are a maintainer, the GitHub Release / asset may not be published yet.
See docs/bactopia-setup.md ("Maintainer note") for how to package a populated
datasets cache and publish it with:
  gh release create ${tag} <archive.tar.gz> --repo ${repo}

Otherwise, override the source with --url / --tag / --asset, or point
DATASETS_CACHE at an existing datasets cache instead of downloading.
EOF
  exit 1
fi

if [[ ! -s $tmp_archive ]]; then
  fail "Downloaded archive is empty: $url"
fi

log "Extracting into $dest ..."
tar -xzf "$tmp_archive" -C "$dest"

if [[ -z $(ls -A "$dest" 2>/dev/null) ]]; then
  fail "Extraction produced no files in $dest. The archive may be malformed."
fi

log "Done. Datasets cache is ready at: $dest"
cat <<EOF

Add this line to your site config (config/sites/gadi.local.env or
config/sites/slurm.local.env), or export it before submitting:

  DATASETS_CACHE=${dest}

EOF
