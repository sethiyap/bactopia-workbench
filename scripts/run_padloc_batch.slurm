#!/bin/bash
#SBATCH --time=24:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G

set -euo pipefail
export PBS_O_WORKDIR="${SLURM_SUBMIT_DIR:-$PWD}"
export PBS_JOBID="${SLURM_JOB_ID:-}"
exec bash "$(dirname "$0")/run_padloc_batch.pbs"
