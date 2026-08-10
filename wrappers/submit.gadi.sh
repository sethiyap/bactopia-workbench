#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./wrappers/submit.gadi.sh [OPTIONS] INPUT_SOURCE METADATA_DIR RESULTS_ROOT [BATCH_SIZE]
  ./wrappers/submit.gadi.sh --input-type ont /path/to/ont /path/to/metadata /path/to/results
  ./wrappers/submit.gadi.sh --input-type assembly /path/to/assemblies /path/to/metadata /path/to/results
  ./wrappers/submit.gadi.sh --input-type accession /path/to/accessions.txt /path/to/metadata /path/to/results
  ./wrappers/submit.gadi.sh --is-agar-project 0 RAW_FASTQ_DIR METADATA_DIR RESULTS_ROOT [BATCH_SIZE]
  ./wrappers/submit.gadi.sh --site-config config/sites/gadi.local.env RAW_FASTQ_DIR METADATA_DIR RESULTS_ROOT [BATCH_SIZE]
  ./wrappers/submit.gadi.sh --mail-user you@example.org [--mail-options ae] RAW_FASTQ_DIR METADATA_DIR RESULTS_ROOT [BATCH_SIZE]

Options:
  --input-type TYPE             illumina|ont|assembly|accession; default: illumina
  --medaka-rounds N             Medaka rounds for ONT input; default: Bactopia default (0)
  --medaka-model MODEL          Medaka model matching the ONT basecaller model
  --ont-minlength N             Minimum ONT read length passed to Bactopia
  --ont-minqual N               Minimum average ONT read quality passed to Bactopia
  --use-porechop yes|no         Enable or disable Bactopia Porechop for ONT reads
  --genome-size N               Expected genome size (bp). Drives BOTH the coverage QC
                                gate (min basepairs = N x 10) AND rasusa subsampling
                                (coverage x N), so use a realistic size -- 0/1 delete
                                reads, they do not disable QC. Default: 5 Mb. To relax
                                QC gates set EXTRA_ARGS_STRING (e.g. --coverage 0
                                --min_basepairs 0 --min_reads 0).
  --dry-run                    Validate config, inputs, and dependencies without submitting jobs
  --is-agar-project auto|1|0   Override AGAR auto-detection for mixed or non-AGAR inputs
EOF
}

wrapper_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
project_root=$(cd "$wrapper_dir/.." && pwd)
site_config=${SITE_CONFIG:-$project_root/config/sites/gadi.local.env}
additional_tools_override=
is_agar_project_override=
mail_user_override=
mail_options_override=
dry_run=0
input_type_override=
medaka_rounds_override=
medaka_model_override=
ont_minlength_override=
ont_minqual_override=
use_porechop_override=
genome_size_override=

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --site-config)
      site_config=$2
      shift 2
      ;;
    --additional-tools)
      additional_tools_override=$2
      shift 2
      ;;
    --input-type)
      input_type_override=$2
      shift 2
      ;;
    --medaka-rounds)
      medaka_rounds_override=$2
      shift 2
      ;;
    --medaka-model)
      medaka_model_override=$2
      shift 2
      ;;
    --ont-minlength)
      ont_minlength_override=$2
      shift 2
      ;;
    --ont-minqual)
      ont_minqual_override=$2
      shift 2
      ;;
    --use-porechop)
      use_porechop_override=$2
      shift 2
      ;;
    --genome-size)
      genome_size_override=$2
      shift 2
      ;;
    --is-agar-project)
      is_agar_project_override=$2
      shift 2
      ;;
    --mail-user)
      mail_user_override=$2
      shift 2
      ;;
    --mail-options)
      mail_options_override=$2
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

if [[ $# -lt 3 || $# -gt 4 ]]; then
  usage >&2
  exit 1
fi

if [[ ! -f $site_config ]]; then
  cat >&2 <<EOF
Site config not found: $site_config

Create it with:
  cp $project_root/config/sites/gadi.env.example $project_root/config/sites/gadi.local.env
EOF
  exit 1
fi

export PIPELINE_ROOT=$project_root
export PIPELINE_CONFIG=$site_config
set -a
# shellcheck disable=SC1090
source "$project_root/config/defaults.env"
# shellcheck disable=SC1090
source "$site_config"
set +a

# Keep PBS mail settings per-submission only; do not inherit them from shared site config.
unset PBS_MAIL_USER
unset PBS_MAIL_OPTIONS

case "${additional_tools_override:-}" in
  yes|YES|true|TRUE|1) export RUN_ADDITIONAL_TOOLS=1 ;;
  no|NO|false|FALSE|0) export RUN_ADDITIONAL_TOOLS=0 ;;
  "") ;;
  *)
    echo "--additional-tools must be yes|no|1|0" >&2
    exit 1
    ;;
esac

case "${is_agar_project_override:-}" in
  auto|1|0|true|TRUE|false|FALSE|agar|other) export IS_AGAR_PROJECT=$is_agar_project_override ;;
  "") ;;
  *)
    echo "--is-agar-project must be auto|1|0" >&2
    exit 1
    ;;
esac

resolved_input_type=${input_type_override:-${INPUT_TYPE:-illumina}}
resolved_input_type=$(printf '%s' "$resolved_input_type" | tr '[:upper:]' '[:lower:]')
[[ $resolved_input_type == "accessions" ]] && resolved_input_type=accession
case "$resolved_input_type" in
  illumina|ont|assembly|accession) export INPUT_TYPE=$resolved_input_type ;;
  *)
    echo "--input-type must be illumina|ont|assembly|accession" >&2
    exit 1
    ;;
esac

for numeric_option in "${medaka_rounds_override:-}" "${ont_minlength_override:-}" "${ont_minqual_override:-}" "${genome_size_override:-}"; do
  if [[ -n $numeric_option && ! $numeric_option =~ ^[0-9]+$ ]]; then
    echo "Numeric options must be non-negative integers: $numeric_option" >&2
    exit 1
  fi
done

[[ -n $genome_size_override ]] && export GENOME_SIZE=$genome_size_override
[[ -n $medaka_rounds_override ]] && export MEDAKA_ROUNDS=$medaka_rounds_override
[[ -n $medaka_model_override ]] && export MEDAKA_MODEL=$medaka_model_override
[[ -n $ont_minlength_override ]] && export ONT_MINLENGTH=$ont_minlength_override
[[ -n $ont_minqual_override ]] && export ONT_MINQUAL=$ont_minqual_override

case "${use_porechop_override:-}" in
  yes|YES|true|TRUE|1) export USE_PORECHOP=1 ;;
  no|NO|false|FALSE|0) export USE_PORECHOP=0 ;;
  "") ;;
  *)
    echo "--use-porechop must be yes|no|1|0" >&2
    exit 1
    ;;
esac

if [[ -n ${mail_user_override:-} ]]; then
  export PBS_MAIL_USER=$mail_user_override
fi

if [[ -n ${mail_options_override:-} ]]; then
  export PBS_MAIL_OPTIONS=$mail_options_override
elif [[ -n ${mail_user_override:-} && -z ${PBS_MAIL_OPTIONS:-} ]]; then
  export PBS_MAIL_OPTIONS=ae
fi

export RUN_AGAR_DIR=$project_root
batch_size=${4:-${BATCH_SIZE_DEFAULT:-50}}

cmd=("$project_root/scripts/submit_agar_full_pipeline.sh" --config "$site_config")
if [[ $dry_run == 1 ]]; then
  cmd+=(--dry-run)
fi
cmd+=("$1" "$2" "$3" "$batch_size")

exec "${cmd[@]}"
