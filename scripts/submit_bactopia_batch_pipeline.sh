#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/submit_bactopia_batch_pipeline.sh INPUT_FILE BATCH_SIZE

Environment variables:
  BATCH_PREFIX            Default: batch_bactopia
  BATCH_DIR               Default: <input_dir>/batches
  BATCH_SKIP              Default: 0
  BATCH_START             Optional 1-based batch number to start from, e.g. 3
  BATCH_LIMIT             Optional explicit maximum number of batch files to
                          submit. Default: all batch files implied by the FOFN
                          and BATCH_SIZE
  BATCH_CHAIN             Default: 0
  BATCH_IDS               Optional comma-separated batch ids or labels to run,
                          for example 001 or batch_bactopia_001
  RUN_TOOLS               Default: 1
  RUN_TOOLS_PARALLEL      Default: 0. Set to 1 to submit one non-Kleborate
                          tool job per tool after assembly instead of running
                          the whole tool bundle sequentially in one job
  RUN_ADDITIONAL_TOOLS    Default: 0
  DEFAULT_TOOLS_STRING    Default non-Kleborate tool list:
                          abritamr amrfinderplus bracken checkm mlst plasmidfinder
                          Kleborate is enabled separately through RUN_KLEBORATE
  ADDITIONAL_TOOLS_STRING Default additional non-Kleborate tool list:
                          defensefinder ectyper ismapper mashdist mobsuite mykrobe
                          phispy shigapass shigatyper shigeifinder
  TOOLS_STRING            Optional explicit non-Kleborate tool list for
                          run_extra_bactopia_tools.pbs. Overrides the default
                          and additional bundles when set.
  KRAKEN2_DB              Required if TOOLS_STRING includes kraken2 or bracken
  MYKROBE_SPECIES         Required if TOOLS_STRING includes mykrobe
  DEFENSEFINDER_DB        Optional database path for defensefinder
  RUN_KLEBORATE           Default: 1
  RUN_FIMTYPER            Default: 0
  FIMTYPER_PIPELINE       Required when RUN_FIMTYPER=1
  FIMTYPER_CONFIG         Required when RUN_FIMTYPER=1
  MERGE_FIMTYPER_SCRIPT   Optional merge helper run after FimTyper
  FIMTYPER_PROFILE        Optional Nextflow profile for FimTyper
  FIMTYPER_AFTER          assembly|tools|kleborate|all_tools, default: all_tools
  RUN_COLLECT_ASSEMBLIES  Default: 1
  ASSEMBLIES_OUTDIR       Default: <results_root>/<basename(results_root)>_assemblies
  RUN_ST131_TYPER         Default: 0
  ST131_TYPER_PBS_SCRIPT   Default: <script_dir>/run_st131typer_from_assemblies.pbs
  ST131_TYPER_DIR         Optional directory containing ST131Typer.sh
  ST131_TYPER_SCRIPT      Default: <repo_root>/ST131Typer.sh
  ST131_TYPER_INPUT_DIR    Default: <ASSEMBLIES_OUTDIR>
  ST131_TYPER_OUTPUT_DIR   Default: <results_root>/<basename(results_root)>_st131typer
  RESULTS_ROOT            Default: /scratch/<project>/<user>/bactopia_results
  RUN_CONSOLIDATE         Default: 1
  CONSOLIDATED_OUTDIR     Default: <results_root>/<batch_prefix>_consolidated
  BASE_DIR                Default: repo root above this script
  SAMPLESHEET_DIR         Override batch sheet directory used by run_bactopia_batch.pbs
  PBS_LOG_DIR             Optional directory for scheduler stdout/stderr files
  PBS_MAIL_OPTIONS        Optional PBS-style mail flags, for example ae or abe
  PBS_MAIL_USER           Optional email address for scheduler notifications
  BACTOPIA_INPUT_MODE     illumina|ont|assembly|accession; default: illumina
  MEDAKA_ROUNDS           Optional Medaka rounds for ONT input
  MEDAKA_MODEL            Optional model matching the ONT basecaller model
  ONT_MINLENGTH           Optional minimum ONT read length
  ONT_MINQUAL             Optional minimum average ONT read quality
  USE_PORECHOP            Optional 1 or 0 for ONT adapter removal

Example:
  BATCH_SKIP=0 \
  BATCH_LIMIT=2 \
  BATCH_CHAIN=1 \
  RUN_TOOLS=1 \
  RUN_KLEBORATE=1 \
  RUN_FIMTYPER=1 \
  FIMTYPER_PIPELINE=/g/data/<project>/custom_bactopia_refs/fimtyper/fimtyper.nf \
  FIMTYPER_CONFIG=/g/data/<project>/custom_bactopia_refs/fimtyper/fimtyper.gadi.config \
  ./scripts/submit_bactopia_batch_pipeline.sh metadata/samplesheet.fofn 50
EOF
}

tools_string_contains() {
  local tool_name=$1
  shift
  local tool

  for tool in "$@"; do
    if [[ $tool == "$tool_name" ]]; then
      return 0
    fi
  done

  return 1
}

if [[ $# -ne 2 ]]; then
  usage >&2
  exit 1
fi

input_file=$1
batch_size=$2

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$script_dir/lib_scheduler.sh"

BATCH_PREFIX=${BATCH_PREFIX:-batch_bactopia}
BATCH_DIR=${BATCH_DIR:-$(dirname "$input_file")/batches}
BATCH_SKIP=${BATCH_SKIP:-0}
BATCH_START=${BATCH_START:-}
BATCH_LIMIT=${BATCH_LIMIT:-}
BATCH_CHAIN=${BATCH_CHAIN:-0}
BATCH_IDS=${BATCH_IDS:-}
RUN_TOOLS=${RUN_TOOLS:-1}
RUN_TOOLS_PARALLEL=${RUN_TOOLS_PARALLEL:-0}
RUN_ADDITIONAL_TOOLS=${RUN_ADDITIONAL_TOOLS:-0}
DEFAULT_TOOLS_STRING=${DEFAULT_TOOLS_STRING:-abritamr amrfinderplus bracken checkm mlst plasmidfinder}
ADDITIONAL_TOOLS_STRING=${ADDITIONAL_TOOLS_STRING:-defensefinder ectyper ismapper mashdist mobsuite mykrobe phispy shigapass shigatyper shigeifinder}
TOOLS_STRING=${TOOLS_STRING:-}
KRAKEN2_DB=${KRAKEN2_DB:-}
MYKROBE_SPECIES=${MYKROBE_SPECIES:-}
DEFENSEFINDER_DB=${DEFENSEFINDER_DB:-}
RUN_KLEBORATE=${RUN_KLEBORATE:-1}
RUN_FIMTYPER=${RUN_FIMTYPER:-0}
FIMTYPER_PIPELINE=${FIMTYPER_PIPELINE:-}
FIMTYPER_CONFIG=${FIMTYPER_CONFIG:-}
MERGE_FIMTYPER_SCRIPT=${MERGE_FIMTYPER_SCRIPT:-}
FIMTYPER_PROFILE=${FIMTYPER_PROFILE:-}
FIMTYPER_AFTER=${FIMTYPER_AFTER:-all_tools}
RUN_COLLECT_ASSEMBLIES=${RUN_COLLECT_ASSEMBLIES:-1}
RUN_ST131_TYPER=${RUN_ST131_TYPER:-0}
RUN_CONSOLIDATE=${RUN_CONSOLIDATE:-1}
BASE_DIR=${BASE_DIR:-$(cd "$script_dir/.." && pwd)}
SAMPLESHEET_DIR=${SAMPLESHEET_DIR:-$BATCH_DIR}
run_user=${USER_NAME:-${USER:-unknown}}
RESULTS_ROOT=${RESULTS_ROOT:-/scratch/${PROJECT:-rg42}/${run_user}/bactopia_results}
results_root_base=$(basename "$RESULTS_ROOT")
ASSEMBLIES_OUTDIR=${ASSEMBLIES_OUTDIR:-${RESULTS_ROOT}/${results_root_base}_assemblies}
ST131_TYPER_PBS_SCRIPT=${ST131_TYPER_PBS_SCRIPT:-$script_dir/run_st131typer_from_assemblies.pbs}
ST131_TYPER_DIR=${ST131_TYPER_DIR:-}
if [[ -n $ST131_TYPER_DIR ]]; then
  ST131_TYPER_SCRIPT=${ST131_TYPER_SCRIPT:-$ST131_TYPER_DIR/ST131Typer.sh}
else
  ST131_TYPER_SCRIPT=${ST131_TYPER_SCRIPT:-$BASE_DIR/ST131Typer.sh}
fi
ST131_TYPER_INPUT_DIR=${ST131_TYPER_INPUT_DIR:-$ASSEMBLIES_OUTDIR}
ST131_TYPER_OUTPUT_DIR=${ST131_TYPER_OUTPUT_DIR:-${RESULTS_ROOT}/${results_root_base}_st131typer}
CONSOLIDATED_OUTDIR=${CONSOLIDATED_OUTDIR:-${RESULTS_ROOT}/${BATCH_PREFIX}_consolidated}
NEXTFLOW_CONFIG=${NEXTFLOW_CONFIG:-}
BACTOPIA_PIPELINE=${BACTOPIA_PIPELINE:-}
DATASETS_CACHE=${DATASETS_CACHE:-}
SING_CACHE=${SING_CACHE:-}
KLEBORATE_COMPAT_SCRIPT=${KLEBORATE_COMPAT_SCRIPT:-$script_dir/kleborate_232_compat.sh}
PBS_LOG_DIR=${PBS_LOG_DIR:-}
PBS_MAIL_OPTIONS=${PBS_MAIL_OPTIONS:-}
PBS_MAIL_USER=${PBS_MAIL_USER:-}
BACTOPIA_INPUT_MODE=${BACTOPIA_INPUT_MODE:-illumina}
GENOME_SIZE=${GENOME_SIZE:-}
EXTRA_ARGS_STRING=${EXTRA_ARGS_STRING:-}
MEDAKA_ROUNDS=${MEDAKA_ROUNDS:-}
MEDAKA_MODEL=${MEDAKA_MODEL:-}
ONT_MINLENGTH=${ONT_MINLENGTH:-}
ONT_MINQUAL=${ONT_MINQUAL:-}
USE_PORECHOP=${USE_PORECHOP:-}

if [[ ! -f $input_file ]]; then
  echo "Input file not found: $input_file" >&2
  exit 1
fi

if ! [[ $batch_size =~ ^[1-9][0-9]*$ ]]; then
  echo "BATCH_SIZE must be a positive integer: $batch_size" >&2
  exit 1
fi

case "$BACTOPIA_INPUT_MODE" in
  illumina|ont|assembly|accession) ;;
  *)
    echo "BACTOPIA_INPUT_MODE must be illumina|ont|assembly|accession: $BACTOPIA_INPUT_MODE" >&2
    exit 1
    ;;
esac

if ! [[ $BATCH_SKIP =~ ^[0-9]+$ ]]; then
  echo "BATCH_SKIP must be a non-negative integer: $BATCH_SKIP" >&2
  exit 1
fi

if [[ -n $BATCH_START ]] && ! [[ $BATCH_START =~ ^[1-9][0-9]*$ ]]; then
  echo "BATCH_START must be a positive integer batch number: $BATCH_START" >&2
  exit 1
fi

if [[ -n $BATCH_LIMIT ]] && ! [[ $BATCH_LIMIT =~ ^[1-9][0-9]*$ ]]; then
  echo "BATCH_LIMIT must be a positive integer: $BATCH_LIMIT" >&2
  exit 1
fi

if [[ ${BATCH_CHAIN:-0} != 0 && ${BATCH_CHAIN:-0} != 1 ]]; then
  echo "BATCH_CHAIN must be 0 or 1: ${BATCH_CHAIN}" >&2
  exit 1
fi

if [[ ${RUN_ADDITIONAL_TOOLS:-0} != 0 && ${RUN_ADDITIONAL_TOOLS:-0} != 1 ]]; then
  echo "RUN_ADDITIONAL_TOOLS must be 0 or 1: ${RUN_ADDITIONAL_TOOLS}" >&2
  exit 1
fi

if [[ ${RUN_TOOLS_PARALLEL:-0} != 0 && ${RUN_TOOLS_PARALLEL:-0} != 1 ]]; then
  echo "RUN_TOOLS_PARALLEL must be 0 or 1: ${RUN_TOOLS_PARALLEL}" >&2
  exit 1
fi

if [[ ${RUN_COLLECT_ASSEMBLIES:-0} != 0 && ${RUN_COLLECT_ASSEMBLIES:-0} != 1 ]]; then
  echo "RUN_COLLECT_ASSEMBLIES must be 0 or 1: ${RUN_COLLECT_ASSEMBLIES}" >&2
  exit 1
fi

if [[ ${RUN_ST131_TYPER:-0} != 0 && ${RUN_ST131_TYPER:-0} != 1 ]]; then
  echo "RUN_ST131_TYPER must be 0 or 1: ${RUN_ST131_TYPER}" >&2
  exit 1
fi

if [[ -n $BATCH_START && $BATCH_SKIP != 0 ]]; then
  echo "Use either BATCH_START or BATCH_SKIP, not both." >&2
  exit 1
fi

if [[ -n $BATCH_START && -n $BATCH_IDS ]]; then
  echo "Use either BATCH_START or BATCH_IDS, not both." >&2
  exit 1
fi

if [[ $BATCH_SKIP != 0 && -n $BATCH_IDS ]]; then
  echo "Use either BATCH_SKIP or BATCH_IDS, not both." >&2
  exit 1
fi

if [[ $RUN_FIMTYPER != 0 && $FIMTYPER_AFTER != "assembly" && $FIMTYPER_AFTER != "tools" && $FIMTYPER_AFTER != "kleborate" && $FIMTYPER_AFTER != "all_tools" ]]; then
  echo "FIMTYPER_AFTER must be 'assembly', 'tools', 'kleborate', or 'all_tools'." >&2
  exit 1
fi

if [[ $RUN_FIMTYPER != 0 && ( -z $FIMTYPER_PIPELINE || -z $FIMTYPER_CONFIG ) ]]; then
  echo "FIMTYPER_PIPELINE and FIMTYPER_CONFIG are required when RUN_FIMTYPER is enabled." >&2
  exit 1
fi

if [[ -z $TOOLS_STRING ]]; then
  TOOLS_STRING=$DEFAULT_TOOLS_STRING
  if [[ $RUN_ADDITIONAL_TOOLS != 0 ]]; then
    TOOLS_STRING="${TOOLS_STRING} ${ADDITIONAL_TOOLS_STRING}"
  fi
fi

# shellcheck disable=SC2206
TOOLS_LIST=($TOOLS_STRING)

if [[ $RUN_TOOLS != 0 ]]; then
  if [[ -z $KRAKEN2_DB ]] && ( tools_string_contains "kraken2" "${TOOLS_LIST[@]}" || tools_string_contains "bracken" "${TOOLS_LIST[@]}" ); then
    echo "KRAKEN2_DB is required when TOOLS_STRING includes kraken2 or bracken." >&2
    exit 1
  fi

  if [[ -z $MYKROBE_SPECIES ]] && tools_string_contains "mykrobe" "${TOOLS_LIST[@]}"; then
    echo "MYKROBE_SPECIES is required when TOOLS_STRING includes mykrobe." >&2
    exit 1
  fi
fi

"$script_dir/split_bactopia_samplesheet.sh" "$input_file" "$batch_size" "$BATCH_DIR" "$BATCH_PREFIX" >/tmp/bactopia_batch_split.$$ 

mapfile -t batch_files < <(tail -n +2 /tmp/bactopia_batch_split.$$)
rm -f /tmp/bactopia_batch_split.$$

if [[ ${#batch_files[@]} -eq 0 ]]; then
  echo "No batch files were created." >&2
  exit 1
fi

selected_batch_files=()

if [[ -n $BATCH_IDS ]]; then
  IFS=',' read -r -a requested_batches <<< "$BATCH_IDS"
  for batch_file in "${batch_files[@]}"; do
    batch_base=$(basename "$batch_file" .csv)
    batch_base=${batch_base%.fofn}
    batch_base=${batch_base%.tsv}
    batch_base=${batch_base%.txt}
    batch_id=${batch_base##*_}
    run_label=${BATCH_PREFIX}_${batch_id}

    for requested in "${requested_batches[@]}"; do
      requested=${requested//[[:space:]]/}
      if [[ -z $requested ]]; then
        continue
      fi
      if [[ $requested == "$batch_id" || $requested == "$run_label" || $requested == "$batch_base" ]]; then
        selected_batch_files+=("$batch_file")
        break
      fi
    done
  done
else
  batch_offset=$BATCH_SKIP
  if [[ -n $BATCH_START ]]; then
    batch_offset=$((10#$BATCH_START - 1))
  fi

  if [[ -n $BATCH_LIMIT ]]; then
    selected_batch_files=("${batch_files[@]:$batch_offset:$BATCH_LIMIT}")
  else
    selected_batch_files=("${batch_files[@]:$batch_offset}")
    BATCH_LIMIT=${#selected_batch_files[@]}
  fi
fi

if [[ ${#selected_batch_files[@]} -eq 0 ]]; then
  if [[ -n $BATCH_IDS ]]; then
    echo "No batch files matched BATCH_IDS=${BATCH_IDS}." >&2
  elif [[ -n $BATCH_START ]]; then
    echo "No batch files selected after applying BATCH_START=${BATCH_START} and BATCH_LIMIT=${BATCH_LIMIT}." >&2
  else
    echo "No batch files selected after applying BATCH_SKIP=${BATCH_SKIP} and BATCH_LIMIT=${BATCH_LIMIT}." >&2
  fi
  exit 1
fi

echo "Submitting ${#selected_batch_files[@]} batch pipeline(s) from ${#batch_files[@]} total batch file(s)"

terminal_jobs=()
assembly_jobs=()
previous_batch_terminal_job=
st131typer_job=

for batch_file in "${selected_batch_files[@]}"; do
  batch_base=$(basename "$batch_file" .csv)
  batch_base=${batch_base%.fofn}
  batch_base=${batch_base%.tsv}
  batch_base=${batch_base%.txt}
  batch_id=${batch_base##*_}
  run_label=${BATCH_PREFIX}_${batch_id}
  results_main=${RESULTS_ROOT}/${run_label}/results_main
  tools_outdir=${RESULTS_ROOT}/${run_label}_tools
  kleborate_outdir=${RESULTS_ROOT}/${run_label}_kleborate
  fimtyper_outdir=${RESULTS_ROOT}/${run_label}_fimtyper
  assembly_job_name=$(printf 'b%s_bactopia' "$batch_id")
  tools_job_name=$(printf 'tools_b%s' "$batch_id")
  kleborate_job_name=$(printf 'klebo_b%s' "$batch_id")
  fimtyper_job_name=$(printf 'fimtyper_b%s' "$batch_id")

  assembly_dependency=
  if [[ $BATCH_CHAIN == 1 && -n "$previous_batch_terminal_job" ]]; then
    assembly_dependency=$previous_batch_terminal_job
  fi

  assembly_job=$(scheduler_submit \
    "$assembly_job_name" \
    "$assembly_dependency" \
    "BASE_DIR=${BASE_DIR},SAMPLESHEET_DIR=${SAMPLESHEET_DIR},SAMPLESHEET_PREFIX=${BATCH_PREFIX},BATCH_ID=${batch_id},BATCH_INPUT_FILE=${batch_file},RESULTS_ROOT=${RESULTS_ROOT},NEXTFLOW_CONFIG=${NEXTFLOW_CONFIG},BACTOPIA_PIPELINE=${BACTOPIA_PIPELINE},DATASETS_CACHE=${DATASETS_CACHE},SING_CACHE=${SING_CACHE},BACTOPIA_INPUT_MODE=${BACTOPIA_INPUT_MODE},GENOME_SIZE=${GENOME_SIZE},EXTRA_ARGS_STRING=${EXTRA_ARGS_STRING},MEDAKA_ROUNDS=${MEDAKA_ROUNDS},MEDAKA_MODEL=${MEDAKA_MODEL},ONT_MINLENGTH=${ONT_MINLENGTH},ONT_MINQUAL=${ONT_MINQUAL},USE_PORECHOP=${USE_PORECHOP}" \
    "$script_dir/run_bactopia_batch.pbs" \
    "$PBS_LOG_DIR" \
    "$PBS_MAIL_OPTIONS" \
    "$PBS_MAIL_USER")
  echo "${run_label}: assembly job ${assembly_job}"
  assembly_jobs+=("${assembly_job}")

  dependency_job=$assembly_job
  tools_job=
  tools_jobs=()
  kleborate_job=

  if [[ $RUN_TOOLS != 0 ]]; then
    if [[ $RUN_TOOLS_PARALLEL != 0 ]]; then
      for tool in "${TOOLS_LIST[@]}"; do
        if [[ $tool == "kleborate" ]]; then
          echo "${run_label}: skipping kleborate in parallel non-kleborate tool submission; use RUN_KLEBORATE." >&2
          continue
        fi

        tool_tag=${tool//[^A-Za-z0-9]/_}
        tool_tag=${tool_tag:0:8}
        parallel_tool_job_name=$(printf 'tb%s_%s' "$batch_id" "$tool_tag")
        parallel_tool_run_label="${run_label}_tools_${tool}"

        tool_job_id=$(scheduler_submit \
          "$parallel_tool_job_name" \
          "$assembly_job" \
          "BASE_DIR=${BASE_DIR},RESULTS_MAIN=${results_main},RUN_LABEL=${parallel_tool_run_label},RESULTS_OUT=${tools_outdir},RESULTS_ROOT=${RESULTS_ROOT},TOOLS_STRING=${tool},KRAKEN2_DB=${KRAKEN2_DB},MYKROBE_SPECIES=${MYKROBE_SPECIES},DEFENSEFINDER_DB=${DEFENSEFINDER_DB},NEXTFLOW_CONFIG=${NEXTFLOW_CONFIG},BACTOPIA_PIPELINE=${BACTOPIA_PIPELINE},DATASETS_CACHE=${DATASETS_CACHE},SING_CACHE=${SING_CACHE}" \
          "$script_dir/run_extra_bactopia_tools.pbs" \
          "$PBS_LOG_DIR" \
          "$PBS_MAIL_OPTIONS" \
          "$PBS_MAIL_USER")
        tools_jobs+=("$tool_job_id")
        echo "${run_label}: tool ${tool} job ${tool_job_id}"
      done

      if [[ ${#tools_jobs[@]} -gt 0 ]]; then
        tools_job=$(IFS=:; echo "${tools_jobs[*]}")
      fi
    else
      tools_job=$(scheduler_submit \
        "$tools_job_name" \
        "$assembly_job" \
        "BASE_DIR=${BASE_DIR},RESULTS_MAIN=${results_main},RUN_LABEL=${run_label}_tools,RESULTS_OUT=${tools_outdir},RESULTS_ROOT=${RESULTS_ROOT},TOOLS_STRING=${TOOLS_STRING},KRAKEN2_DB=${KRAKEN2_DB},MYKROBE_SPECIES=${MYKROBE_SPECIES},DEFENSEFINDER_DB=${DEFENSEFINDER_DB},NEXTFLOW_CONFIG=${NEXTFLOW_CONFIG},BACTOPIA_PIPELINE=${BACTOPIA_PIPELINE},DATASETS_CACHE=${DATASETS_CACHE},SING_CACHE=${SING_CACHE}" \
        "$script_dir/run_extra_bactopia_tools.pbs" \
        "$PBS_LOG_DIR" \
        "$PBS_MAIL_OPTIONS" \
        "$PBS_MAIL_USER")
      echo "${run_label}: non-kleborate tools job ${tools_job}"
    fi
  fi

  if [[ $RUN_KLEBORATE != 0 ]]; then
    kleborate_job=$(scheduler_submit \
      "$kleborate_job_name" \
      "$assembly_job" \
      "BASE_DIR=${BASE_DIR},RESULTS_MAIN=${results_main},RUN_LABEL=${run_label}_kleborate,RESULTS_OUT=${kleborate_outdir},RESULTS_ROOT=${RESULTS_ROOT},NEXTFLOW_CONFIG=${NEXTFLOW_CONFIG},BACTOPIA_PIPELINE=${BACTOPIA_PIPELINE},DATASETS_CACHE=${DATASETS_CACHE},SING_CACHE=${SING_CACHE},KLEBORATE_COMPAT_SCRIPT=${KLEBORATE_COMPAT_SCRIPT}" \
      "$script_dir/run_kleborate_batch.pbs" \
      "$PBS_LOG_DIR" \
      "$PBS_MAIL_OPTIONS" \
      "$PBS_MAIL_USER")
    echo "${run_label}: kleborate job ${kleborate_job}"
  fi

  case "$FIMTYPER_AFTER" in
    assembly)
      dependency_job=$assembly_job
      ;;
    tools)
      if [[ -n "$tools_job" ]]; then
        dependency_job=$tools_job
      fi
      ;;
    kleborate)
      if [[ -n "$kleborate_job" ]]; then
        dependency_job=$kleborate_job
      fi
      ;;
    all_tools)
      if [[ -n "$tools_job" && -n "$kleborate_job" ]]; then
        dependency_job="${tools_job}:${kleborate_job}"
      elif [[ -n "$tools_job" ]]; then
        dependency_job=$tools_job
      elif [[ -n "$kleborate_job" ]]; then
        dependency_job=$kleborate_job
      fi
      ;;
  esac

  if [[ $RUN_FIMTYPER != 0 ]]; then
    if [[ -z "$dependency_job" ]]; then
      echo "${run_label}: could not determine FimTyper dependency." >&2
      exit 1
    fi
  fi

  if [[ $RUN_FIMTYPER != 0 ]]; then
    fimtyper_job=$(scheduler_submit \
      "$fimtyper_job_name" \
      "$dependency_job" \
      "BASE_DIR=${BASE_DIR},RESULTS_MAIN=${results_main},RUN_LABEL=${run_label}_fimtyper,RESULTS_OUT=${fimtyper_outdir},RESULTS_ROOT=${RESULTS_ROOT},FIMTYPER_PIPELINE=${FIMTYPER_PIPELINE},FIMTYPER_CONFIG=${FIMTYPER_CONFIG},MERGE_FIMTYPER_SCRIPT=${MERGE_FIMTYPER_SCRIPT},FIMTYPER_PROFILE=${FIMTYPER_PROFILE},SING_CACHE=${SING_CACHE}" \
      "$script_dir/run_fimtyper_batch.pbs" \
      "$PBS_LOG_DIR" \
      "$PBS_MAIL_OPTIONS" \
      "$PBS_MAIL_USER")
    echo "${run_label}: fimtyper job ${fimtyper_job}"
    dependency_job=$fimtyper_job
  fi

  terminal_jobs+=("${dependency_job}")
  previous_batch_terminal_job=$dependency_job
done

if [[ $RUN_COLLECT_ASSEMBLIES != 0 && ${#assembly_jobs[@]} -gt 0 ]]; then
  dependency_string=$(IFS=:; echo "${assembly_jobs[*]}")
  assemblies_job=$(scheduler_submit \
    "" \
    "$dependency_string" \
    "INPUT_PATH=${RESULTS_ROOT},OUTPUT_DIR=${ASSEMBLIES_OUTDIR}" \
    "$script_dir/run_fetch_batch_assemblies.pbs" \
    "$PBS_LOG_DIR" \
    "$PBS_MAIL_OPTIONS" \
    "$PBS_MAIL_USER")
  echo "assemblies job ${assemblies_job}: ${ASSEMBLIES_OUTDIR}"
fi

if [[ $RUN_ST131_TYPER != 0 ]]; then
  if [[ -z ${assemblies_job:-} ]]; then
    echo "RUN_ST131_TYPER=1 requires RUN_COLLECT_ASSEMBLIES=1 so the assemblies folder can be created first." >&2
    exit 1
  fi
  if [[ ! -f $ST131_TYPER_SCRIPT ]]; then
    echo "ST131_TYPER_SCRIPT not found: $ST131_TYPER_SCRIPT" >&2
    echo "Define ST131_TYPER_DIR=/path/to/ST131Typer or ST131_TYPER_SCRIPT=/path/to/ST131Typer.sh" >&2
    exit 1
  fi
  echo "Found ST131Typer.sh at: $ST131_TYPER_SCRIPT"
  st131typer_job=$(scheduler_submit \
    "" \
    "$assemblies_job" \
    "ASSEMBLIES_DIR=${ST131_TYPER_INPUT_DIR},RESULTS_ROOT=${RESULTS_ROOT},ST131_TYPER_SCRIPT=${ST131_TYPER_SCRIPT},ST131_TYPER_OUTPUT_DIR=${ST131_TYPER_OUTPUT_DIR}" \
    "$ST131_TYPER_PBS_SCRIPT" \
    "$PBS_LOG_DIR" \
    "$PBS_MAIL_OPTIONS" \
    "$PBS_MAIL_USER")
  echo "st131typer job ${st131typer_job}: ${ST131_TYPER_OUTPUT_DIR}"
fi

if [[ $RUN_CONSOLIDATE != 0 && ${#terminal_jobs[@]} -gt 0 ]]; then
  dependency_string=$(IFS=:; echo "${terminal_jobs[*]}")
  consolidate_job=$(scheduler_submit \
    "" \
    "$dependency_string" \
    "BASE_DIR=${BASE_DIR},RESULTS_ROOT=${RESULTS_ROOT},BATCH_PREFIX=${BATCH_PREFIX},CONSOLIDATED_OUTDIR=${CONSOLIDATED_OUTDIR},CONSOLIDATE_SCRIPT=${script_dir}/consolidate_bactopia_batches.R" \
    "$script_dir/run_consolidate_batches.pbs" \
    "$PBS_LOG_DIR" \
    "$PBS_MAIL_OPTIONS" \
    "$PBS_MAIL_USER")
  echo "consolidation job ${consolidate_job}: ${CONSOLIDATED_OUTDIR}"
fi
