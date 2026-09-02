#!/usr/bin/env bash

# Shared Singularity-cache helpers, sourced by repair_singularity_cache.sh and
# prestage_tool_containers.sh. Keep the cache-naming and download-and-verify logic
# here only: two hand-maintained copies of the same rules is exactly how the Gadi
# nextflow config fell weeks behind the one being edited.

# Nextflow's SingularityCache.simpleName: strip the protocol, replace every ':' and
# '/' with '-', append '.img'. This is the filename Nextflow looks for in cacheDir,
# so it is also the name a pre-staged image must have to be found.
sc_cache_name() {
  local url=$1 name

  name=${url#*://}
  name=${name//:/-}
  name=${name////-}
  printf '%s.img\n' "$name"
}

# Reverse of sc_cache_name for the two registries this pipeline uses. Splitting
# <pkg> from <tag> is the only ambiguous part, since both may contain '-';
# biocontainer tags always start with a digit and package names never end in one.
sc_split_pkg_tag() {
  local rest=$1

  [[ $rest =~ ^(.+)-([0-9][^-]*(--.*)?)$ ]] || return 1
  printf '%s:%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

sc_image_source() {
  local base=$1 stem rest pkg_tag

  stem=${base%.img}
  stem=${stem%.sif}

  case "$stem" in
    depot.galaxyproject.org-singularity-*)
      rest=${stem#depot.galaxyproject.org-singularity-}
      pkg_tag=$(sc_split_pkg_tag "$rest") || return 1
      printf 'https://depot.galaxyproject.org/singularity/%s\n' "$pkg_tag"
      ;;
    quay.io-biocontainers-*)
      rest=${stem#quay.io-biocontainers-}
      pkg_tag=$(sc_split_pkg_tag "$rest") || return 1
      printf 'docker://quay.io/biocontainers/%s\n' "$pkg_tag"
      ;;
    *)
      return 1
      ;;
  esac
}

sc_detect_engine() {
  local candidate

  if [[ -n ${SC_ENGINE:-} ]]; then
    printf '%s\n' "$SC_ENGINE"
    return 0
  fi
  for candidate in singularity apptainer; do
    if command -v "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

# Usable = non-empty, and (when deep) actually runnable. A 0-byte stub left by a
# pull that failed offline passes no check but the file-exists one Nextflow does.
sc_image_is_usable() {
  local path=$1 engine=${2:-} deep=${3:-0}

  [[ -s $path ]] || return 1
  [[ $deep == 1 && -n $engine ]] || return 0
  "$engine" exec "$path" true >/dev/null 2>&1
}

# Download to a temp file, verify by running it, and only then move it into the
# cache. An interrupted or failed download must never be visible to Nextflow as a
# cached image -- that is the poisoning this whole helper exists to undo.
sc_download_image() {
  local source=$1 dest=$2 engine=$3 tmp

  tmp=$(mktemp "${dest}.staging.XXXXXX") || return 1

  if [[ $source == docker://* || $source == shub://* ]]; then
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

  if [[ ! -s $tmp ]] || ! "$engine" exec "$tmp" true >/dev/null 2>&1; then
    rm -f "$tmp"
    return 1
  fi

  chmod 755 "$tmp"
  mv -f "$tmp" "$dest"
}
