#!/bin/bash
#SBATCH --time=08:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=8G

set -euo pipefail
export PBS_O_WORKDIR="${SLURM_SUBMIT_DIR:-$PWD}"
export PBS_JOBID="${SLURM_JOB_ID:-}"
exec bash "$(dirname "$0")/run_map_samplesheet_results.pbs"
