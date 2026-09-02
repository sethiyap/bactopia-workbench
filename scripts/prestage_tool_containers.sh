#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/prestage_tool_containers.sh [OPTIONS] [TOOL ...]

Pre-stage the Singularity images a set of Bactopia tools needs into SING_CACHE.

Why this exists: Nextflow pulls a container from the DRIVER process, before the
first task is submitted. On a host with no outbound internet -- every Gadi compute
node -- that pull fails and ends the session with

  Failed to pull singularity image ... network is unreachable
  succeededCount=0; failedCount=0; ignoredCount=0
  Exit Code : null

No `errorStrategy = 'ignore'` can catch that, because no task ever ran: process
directives only apply to tasks that execute. A tool whose image is present but
whose task fails is ignorable; a tool whose image is absent takes the stage down,
and with it every afterok-dependent stage (FimTyper, consolidation, mapping, MLST
review, workbook). The only fix is to have the image already in the cache.

Container URIs are read out of the Bactopia install, so this tracks whatever
versions your Bactopia pins rather than a list here that would go stale.

Run it from a LOGIN node (compute nodes cannot reach the internet).

Options:
  --bactopia DIR  Bactopia install to read container URIs from
                  (default: $BACTOPIA_PIPELINE)
  --dir DIR       Cache directory (default: $SING_CACHE, else
                  /scratch/$PROJECT/$USER/singularity_cache)
  --tools "LIST"  Space-separated tool names. Default: $TOOLS_STRING, else
                  DEFAULT_TOOLS_STRING + ADDITIONAL_TOOLS_STRING from
                  config/defaults.env
  --check-only    Report what is missing and exit non-zero; download nothing
  --deep          Also verify cached images by running them (catches truncation)
  --engine NAME   singularity or apptainer (default: auto-detect)
  --yes           Do not prompt before downloading
  --help          Print this message

Positional TOOL arguments override --tools.

Exit status is non-zero if any required image is still missing at the end.
EOF
}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib_singularity_cache.sh
source "$script_dir/lib_singularity_cache.sh"

log()  { printf '[prestage-containers] %s\n' "$*" >&2; }
fail() { printf '[prestage-containers] ERROR: %s\n' "$*" >&2; exit 1; }

bactopia_dir=${BACTOPIA_PIPELINE:-}
cache_dir=${SING_CACHE:-/scratch/${PROJECT:-rg42}/${USER}/singularity_cache}
tools_string=${TOOLS_STRING:-}
check_only=0
deep=0
assume_yes=0
engine=""
declare -a tool_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bactopia)   bactopia_dir=$2; shift 2 ;;
    --dir)        cache_dir=$2; shift 2 ;;
    --tools)      tools_string=$2; shift 2 ;;
    --check-only) check_only=1; shift ;;
    --deep)       deep=1; shift ;;
    --engine)     engine=$2; shift 2 ;;
    --yes|-y)     assume_yes=1; shift ;;
    --help|-h)    usage; exit 0 ;;
    -*)           usage >&2; fail "Unknown option: $1" ;;
    *)            tool_args+=("$1"); shift ;;
  esac
done

[[ -n $bactopia_dir ]] || fail "Set BACTOPIA_PIPELINE or pass --bactopia DIR"
[[ -d $bactopia_dir ]] || fail "Bactopia install not found: $bactopia_dir"

if [[ ${#tool_args[@]} -gt 0 ]]; then
  tools_string="${tool_args[*]}"
elif [[ -z $tools_string ]]; then
  defaults_file="$script_dir/../config/defaults.env"
  if [[ -f $defaults_file ]]; then
    # shellcheck disable=SC1090
    default_tools=$(DEFAULT_TOOLS_STRING="" ADDITIONAL_TOOLS_STRING="" bash -c \
      "source '$defaults_file' >/dev/null 2>&1; printf '%s %s' \"\$DEFAULT_TOOLS_STRING\" \"\$ADDITIONAL_TOOLS_STRING\"" || true)
    tools_string=$default_tools
  fi
fi
[[ -n ${tools_string// /} ]] || fail "No tools to check. Pass --tools or set TOOLS_STRING."

# shellcheck disable=SC2206
declare -a tools=($tools_string)

if [[ -z $engine ]]; then
  engine=$(sc_detect_engine || true)
fi
if [[ -z $engine ]]; then
  if [[ $check_only == 1 && $deep == 0 ]]; then
    log "No singularity/apptainer on PATH; checking file presence only."
  else
    fail "Neither singularity nor apptainer is on PATH. On Gadi: module load singularity"
  fi
fi

mkdir -p "$cache_dir"

# Bactopia's modules follow the nf-core idiom, declaring both a depot.galaxyproject
# (singularity) and a quay.io (docker) URI for the same package:
#
#   container "${ workflow.containerEngine == 'singularity' && !task.ext... ?
#       'https://depot.galaxyproject.org/singularity/phispy:4.2.21--py310h0dbaff4_2' :
#       'quay.io/biocontainers/phispy:4.2.21--py310h0dbaff4_2' }"
#
# Under -profile singularity only the depot side is ever pulled, so staging the quay
# twin downloads an image Nextflow will never look for. Keep the quay URI only when a
# package has no depot form at all.
prefer_depot_uris() {
  local -a all=("$@")
  local uri pkgtag
  local depot_pkgtags=" "

  for uri in "${all[@]}"; do
    case "$uri" in
      https://depot.galaxyproject.org/*)
        depot_pkgtags="${depot_pkgtags}${uri##*/} "
        ;;
    esac
  done

  for uri in "${all[@]}"; do
    pkgtag=${uri##*/}
    case "$uri" in
      https://depot.galaxyproject.org/*)
        printf '%s\n' "$uri"
        ;;
      *)
        [[ $depot_pkgtags == *" $pkgtag "* ]] && continue
        printf '%s\n' "$uri"
        ;;
    esac
  done
}

# A subworkflow directory usually holds only `include` statements; the container
# directive lives in the module it points at (mashdist -> modules/.../mash/dist).
# Follow one level of includes so those modules are searched too.
include_target_dirs() {
  local -a dirs=("$@")
  local nf inc_path resolved

  [[ ${#dirs[@]} -gt 0 ]] || return 0

  while IFS= read -r nf; do
    while IFS= read -r inc_path; do
      [[ -n $inc_path ]] || continue
      resolved=$(cd "$(dirname "$nf")" 2>/dev/null && cd "$(dirname "$inc_path")" 2>/dev/null && pwd) || continue
      printf '%s\n' "$resolved"
    done < <(grep -hoE "from +['\"][^'\"]+['\"]" "$nf" 2>/dev/null \
               | sed -E "s/^from +['\"]//; s/['\"]$//")
  done < <(find "${dirs[@]}" -maxdepth 2 -name '*.nf' 2>/dev/null)
}

tool_container_uris() {
  local tool=$1
  local -a search=() extra=()
  local d uri
  local -a found=()

  # Most specific first: a subworkflow or module directory named for the tool.
  while IFS= read -r d; do
    search+=("$d")
  done < <(find "$bactopia_dir" -maxdepth 8 -type d \
             \( -path '*/subworkflows/*' -o -path '*/modules/*' \) \
             -iname "$tool" 2>/dev/null)

  # Fall back to any module path mentioning the tool (e.g. mobsuite -> mob_suite).
  if [[ ${#search[@]} -eq 0 ]]; then
    while IFS= read -r d; do
      search+=("$d")
    done < <(find "$bactopia_dir" -maxdepth 8 -type d \
               \( -path '*/subworkflows/*' -o -path '*/modules/*' \) \
               -iname "*${tool}*" 2>/dev/null)
  fi

  [[ ${#search[@]} -gt 0 ]] || return 1

  while IFS= read -r d; do
    [[ -n $d && -d $d ]] && extra+=("$d")
  done < <(include_target_dirs "${search[@]}" | sort -u)

  [[ ${#extra[@]} -gt 0 ]] && search+=("${extra[@]}")

  while IFS= read -r uri; do
    [[ -n $uri ]] && found+=("$uri")
  done < <({
    grep -rhoE 'https://depot\.galaxyproject\.org/singularity/[A-Za-z0-9._:+-]+' "${search[@]}" 2>/dev/null || true
    grep -rhoE '(docker://)?quay\.io/biocontainers/[A-Za-z0-9._:+-]+' "${search[@]}" 2>/dev/null || true
  } | sed 's/[.,)"'"'"']*$//' | sort -u)

  [[ ${#found[@]} -gt 0 ]] || return 1
  prefer_depot_uris "${found[@]}"
}

# A tool whose container the site config pins explicitly never pulls Bactopia's own
# declaration, so reporting that one as missing is noise (it was reporting mlst at
# Bactopia's 2.23.0 while the config pins 2.33.1).
#
# Detect the override from the config rather than from a hardcoded list of versions
# here -- a second copy of those pins is exactly the drift that put the Gadi config
# weeks behind. The configs all use the same `<TOOL>_CONTAINER` env-var convention:
#
#   def mlstContainer = System.getenv('MLST_CONTAINER') ?: "${singCache}/mlst-...sif"
#
# so an exported value wins, and otherwise the mere presence of that variable name
# in NEXTFLOW_CONFIG tells us the tool is pinned, without needing to know to what.
tool_container_override() {
  local tool=$1 var value

  var=$(printf '%s' "$tool" | tr '[:lower:]-' '[:upper:]_')_CONTAINER

  # A tool name with characters that cannot appear in a shell identifier would make
  # the eval below a syntax error, so leave those alone rather than dying on them.
  if [[ ! $var =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
    printf '\n'
    return 0
  fi

  eval "value=\${${var}:-}"

  if [[ -n $value ]]; then
    printf '%s\n' "$value"
    return 0
  fi

  if [[ -n ${NEXTFLOW_CONFIG:-} && -f ${NEXTFLOW_CONFIG:-} ]] \
     && grep -q "$var" "$NEXTFLOW_CONFIG" 2>/dev/null; then
    printf 'CONFIG_PINNED\n'
    return 0
  fi

  printf '\n'
}

declare -a missing_names=() missing_sources=() missing_tools=()
declare -a no_uri_tools=()
present=0

log "Bactopia : $bactopia_dir"
log "Cache    : $cache_dir"
log "Tools    : ${tools[*]}"
log ""

for tool in "${tools[@]}"; do
  override=$(tool_container_override "$tool")
  if [[ $override == "CONFIG_PINNED" ]]; then
    log "$tool: container pinned by $(basename "$NEXTFLOW_CONFIG"); Bactopia's own image is not used"
    present=$((present + 1))
    continue
  fi
  if [[ -n $override ]]; then
    if [[ -e $override ]]; then
      log "$tool: pinned by config to $override (skipping Bactopia's own image)"
      present=$((present + 1))
    else
      log "$tool: pinned by config to $override -- WHICH DOES NOT EXIST"
      missing_names+=("$(basename "$override")")
      missing_sources+=("")
      missing_tools+=("$tool")
    fi
    continue
  fi

  # Plain arrays and a string of seen names, not mapfile/declare -A: this has to run
  # under the bash 3.2 that ships on macOS as well as Gadi's bash 4.
  uris=()
  while IFS= read -r uri; do
    [[ -n $uri ]] && uris+=("$uri")
  done < <(tool_container_uris "$tool" || true)

  if [[ ${#uris[@]} -eq 0 ]]; then
    log "$tool: no container URI found in the Bactopia install (skipping)"
    no_uri_tools+=("$tool")
    continue
  fi

  # One depot URI per package is the norm; if both registries appear for the same
  # package, the depot form is the one Nextflow resolves under -profile singularity.
  seen_names=" "
  for uri in "${uris[@]}"; do
    name=$(sc_cache_name "$uri")
    [[ $seen_names == *" $name "* ]] && continue
    seen_names="${seen_names}${name} "

    if sc_image_is_usable "$cache_dir/$name" "$engine" "$deep"; then
      present=$((present + 1))
      continue
    fi

    missing_names+=("$name")
    missing_sources+=("$uri")
    missing_tools+=("$tool")
    log "$tool: MISSING $name"
  done
done

log ""
log "Present: ${present}   Missing: ${#missing_names[@]}"

if [[ ${#no_uri_tools[@]} -gt 0 ]]; then
  log "No URI discovered for: ${no_uri_tools[*]} -- check these by hand if they fail."
fi

if [[ ${#no_uri_tools[@]} -eq ${#tools[@]} ]]; then
  log ""
  log "No container URI resolved for ANY requested tool. That is a discovery failure,"
  log "not a clean cache -- check the tool names and --bactopia path."
  exit 1
fi

if [[ ${#missing_names[@]} -eq 0 ]]; then
  log "Every discovered image is staged."
  exit 0
fi

if [[ $check_only == 1 ]]; then
  log ""
  log "Missing images would abort their stage at pull time (no errorStrategy can catch it)."
  log "Stage them from a LOGIN node: ${BASH_SOURCE[0]} --dir ${cache_dir} --yes"
  exit 1
fi

[[ -n $engine ]] || fail "Downloading needs singularity or apptainer on PATH."

if [[ $assume_yes != 1 ]]; then
  read -r -p "[prestage-containers] Download ${#missing_names[@]} image(s) into ${cache_dir}? [y/N] " reply
  case "$reply" in
    y|Y|yes|YES) ;;
    *) log "Aborted; nothing downloaded."; exit 1 ;;
  esac
fi

failed=0
for i in "${!missing_names[@]}"; do
  name=${missing_names[$i]}
  source=${missing_sources[$i]}
  if [[ -z $source ]]; then
    log "Cannot stage ${missing_tools[$i]}: $name is pinned by config, not derivable from a registry"
    failed=$((failed + 1))
    continue
  fi
  log "Staging ${missing_tools[$i]}: $name"
  log "  from $source"
  if sc_download_image "$source" "$cache_dir/$name" "$engine"; then
    log "  ok"
  else
    log "  FAILED"
    failed=$((failed + 1))
  fi
done

log ""
if (( failed > 0 )); then
  log "${failed} image(s) could not be staged."
  exit 1
fi
log "All images staged. Resubmit the pipeline."
