#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/install_optional_local_tools.sh [OPTIONS]

Installs local optional helpers for non-Gadi/non-rg42 use:
  - Miniforge
  - a dedicated Conda env containing mlst + seqkit + openpyxl
  - ST131Typer cloned from GitHub

Defaults:
  INSTALL_ROOT      <repo_root>/.local
  MINIFORGE_ROOT    <install_root>/miniforge3
  MLST_ENV          <install_root>/mlst_env
  ST131_REPO_DIR    <install_root>/ST131Typer
  ST131 script link <repo_root>/ST131Typer.sh

Options:
  --install-root DIR     Override the parent install root
  --miniforge-root DIR   Override the Miniforge install path
  --mlst-env DIR         Override the mlst/seqkit Conda env path
  --st131-dir DIR        Override the ST131Typer clone path
  --force                Reinstall/update even if targets already exist
  --help                 Print this message
EOF
}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)

install_root_default="${repo_root}/.local"
install_root="${INSTALL_ROOT:-$install_root_default}"
miniforge_root="${MINIFORGE_ROOT:-${install_root}/miniforge3}"
mlst_env="${MLST_ENV:-${install_root}/mlst_env}"
st131_repo_dir="${ST131_REPO_DIR:-${install_root}/ST131Typer}"
st131_script_link="${ST131_TYPER_SCRIPT_LINK:-${repo_root}/ST131Typer.sh}"
st131_repo_url="${ST131_REPO_URL:-https://github.com/JohnsonSingerLab/ST131Typer.git}"
force=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-root)
      install_root=$2
      shift 2
      ;;
    --miniforge-root)
      miniforge_root=$2
      shift 2
      ;;
    --mlst-env)
      mlst_env=$2
      shift 2
      ;;
    --st131-dir)
      st131_repo_dir=$2
      shift 2
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

log() {
  printf '[install-optional-tools] %s\n' "$*"
}

fail() {
  printf '[install-optional-tools] ERROR: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

resolve_miniforge_installer() {
  local os arch
  os=$(uname -s)
  arch=$(uname -m)

  case "${os}:${arch}" in
    Linux:x86_64)
      printf '%s\n' "Miniforge3-Linux-x86_64.sh"
      ;;
    Linux:aarch64|Linux:arm64)
      printf '%s\n' "Miniforge3-Linux-aarch64.sh"
      ;;
    Darwin:x86_64)
      printf '%s\n' "Miniforge3-MacOSX-x86_64.sh"
      ;;
    Darwin:arm64)
      printf '%s\n' "Miniforge3-MacOSX-arm64.sh"
      ;;
    *)
      fail "Unsupported platform for automatic Miniforge install: ${os} ${arch}"
      ;;
  esac
}

install_miniforge() {
  local installer_name installer_url tmp_installer
  if [[ -f "${miniforge_root}/etc/profile.d/conda.sh" && $force -eq 0 ]]; then
    log "Miniforge already present at ${miniforge_root}"
    return
  fi

  mkdir -p "$(dirname "$miniforge_root")"
  need_cmd curl
  installer_name=$(resolve_miniforge_installer)
  installer_url="https://github.com/conda-forge/miniforge/releases/latest/download/${installer_name}"
  tmp_installer=$(mktemp "${TMPDIR:-/tmp}/miniforge-installer.XXXXXX.sh")

  log "Downloading ${installer_name}"
  curl -L "$installer_url" -o "$tmp_installer"
  chmod +x "$tmp_installer"

  if [[ -d "$miniforge_root" && $force -eq 1 ]]; then
    log "Updating existing Miniforge install at ${miniforge_root}"
    bash "$tmp_installer" -b -u -p "$miniforge_root"
  else
    log "Installing Miniforge at ${miniforge_root}"
    bash "$tmp_installer" -b -p "$miniforge_root"
  fi

  rm -f "$tmp_installer"
}

install_mlst_env() {
  # shellcheck disable=SC1091
  source "${miniforge_root}/etc/profile.d/conda.sh"

  if [[ -d "$mlst_env" ]]; then
    if [[ $force -eq 1 ]]; then
      log "Updating existing mlst/seqkit/openpyxl env at ${mlst_env}"
      conda install -y -p "$mlst_env" -c conda-forge -c bioconda mlst seqkit openpyxl
    else
      log "mlst/seqkit/openpyxl env already present at ${mlst_env}"
    fi
  else
    log "Creating mlst/seqkit/openpyxl env at ${mlst_env}"
    conda create -y -p "$mlst_env" -c conda-forge -c bioconda mlst seqkit openpyxl
  fi

  # mlst + seqkit drive MLST review / ST131Typer; openpyxl is used by the workbook
  # exporter, which runs $mlst_env/bin/python3 -- so it must live in this same env.
  conda run -p "$mlst_env" mlst --version >/dev/null
  conda run -p "$mlst_env" seqkit version >/dev/null
  conda run -p "$mlst_env" python3 -c "import openpyxl" >/dev/null
}

install_st131typer() {
  need_cmd git

  if [[ -d "${st131_repo_dir}/.git" ]]; then
    if [[ $force -eq 1 ]]; then
      log "Updating existing ST131Typer clone at ${st131_repo_dir}"
      git -C "$st131_repo_dir" pull --ff-only
    else
      log "ST131Typer already cloned at ${st131_repo_dir}"
    fi
  else
    mkdir -p "$(dirname "$st131_repo_dir")"
    log "Cloning ST131Typer into ${st131_repo_dir}"
    git clone "$st131_repo_url" "$st131_repo_dir"
  fi

  [[ -f "${st131_repo_dir}/ST131Typer.sh" ]] || fail "ST131Typer.sh not found in ${st131_repo_dir}"
  chmod +x "${st131_repo_dir}/ST131Typer.sh"

  ln -sfn "${st131_repo_dir}/ST131Typer.sh" "$st131_script_link"
  log "Linked ${st131_script_link} -> ${st131_repo_dir}/ST131Typer.sh"
}

mkdir -p "$install_root"

install_miniforge
install_mlst_env
install_st131typer

cat <<EOF

Local optional tool install complete.

Use these paths with the pipeline:
  MINIFORGE_ROOT=${miniforge_root}
  MLST_ENV=${mlst_env}
  ST131_TYPER_SCRIPT=${st131_repo_dir}/ST131Typer.sh

Repo-default ST131Typer path now resolves via:
  ${st131_script_link}

Verification:
  source "${miniforge_root}/etc/profile.d/conda.sh"
  conda run -p "${mlst_env}" mlst --version
  conda run -p "${mlst_env}" seqkit version
  conda run -p "${mlst_env}" python3 -c "import openpyxl; print('openpyxl', openpyxl.__version__)"
  "${st131_repo_dir}/ST131Typer.sh" -v
  "${st131_repo_dir}/ST131Typer.sh" -c
EOF
