#!/usr/bin/env bash
#
# setup_training_session.sh
#
# Prepare a bactopia-workbench training session on NCI Gadi: carve an existing
# AGAR delivery into one input set per user, and pre-populate each user's own
# Singularity cache so nobody's run dies pulling containers from a compute node.
#
# The goal is that users run the documented production command - three paths and
# a batch size, no flags - so nothing here requires --site-config or SING_CACHE
# on the command line.
#
# RUN THIS FROM A GADI LOGIN NODE. Compute nodes have no outbound internet, so
# the container staging step cannot work anywhere else.
#
#   ./scripts/setup_training_session.sh -n 1 -u 'abc123 def456 ghi789 jkl012'
#   ./scripts/setup_training_session.sh --dry-run -u 'abc123'   # change nothing
#   ./scripts/setup_training_session.sh --help
#
# Defaults point at the 2024 B07 delivery. Every option below is also an
# environment variable; a command-line option wins over the environment:
#
#   USERS              (none)  NCI usernames, space separated. Each one's own
#                              default SING_CACHE is seeded by hard link, which
#                              is what lets the submit command stay bare.
#   SRC_FASTQ_DIR      /scratch/rg42/AGAR/raw_data/2024/B07/B07
#   SRC_SHEET          /scratch/rg42/AGAR/metadata/2024/B07/B07_samplesheet.txt
#   OUT_ROOT           /scratch/rg42/training/<today>
#   BACTOPIA_PIPELINE  /g/data/rg42/bactopia/bactopia
#   SEED_CACHE         /scratch/rg42/$USER/singularity_cache
#   PROD_SITE_CONFIG   /g/data/rg42/bactopia-workbench/config/sites/gadi.local.env
#   TRAINING_CLONE     /g/data/rg42/bactopia-workbench
#   SAMPLES_PER_USER   1   samples each person gets, 1-4. One keeps the session
#                          short: every Nextflow task is its own PBS job, so this
#                          is the main thing deciding how long people wait.
#   INJECT_MISMATCH    1   deliberately mislabel one organism per set. Only takes
#                          effect at SAMPLES_PER_USER=4, where the target sample
#                          is included
#   SKIP_PRESTAGE      0   set to 1 to skip the container download step
#   DRY_RUN            0   set to 1 to change nothing
#
# What it does NOT do: shorten the #PBS walltime headers. That needs a separate
# copy of the install - see the notes printed at the end.

set -euo pipefail

# Group-writable: users run as themselves but write samplesheet.fofn into
# their metadata dir and results into their results dir, both created here.
umask 0002

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------
project=${PROJECT:-rg42}
scratch_root=${SCRATCH_ROOT:-/scratch}
src_fastq_dir=${SRC_FASTQ_DIR:-${scratch_root}/${project}/AGAR/raw_data/2024/B07/B07}
src_sheet=${SRC_SHEET:-${scratch_root}/${project}/AGAR/metadata/2024/B07/B07_samplesheet.txt}
out_root=${OUT_ROOT:-${scratch_root}/${project}/training/$(date +%Y-%m-%d)}
bactopia_pipeline=${BACTOPIA_PIPELINE:-/g/data/${project}/bactopia/bactopia}
seed_cache=${SEED_CACHE:-${scratch_root}/${project}/${USER:-unknown}/singularity_cache}
prod_site_config=${PROD_SITE_CONFIG:-/g/data/${project}/bactopia-workbench/config/sites/gadi.local.env}
# The install the printed submit commands point at. Defaults to the shared
# production one, which is what most sessions will use. Point it at a separate
# clone with shorter #PBS walltimes if queue wait is the binding constraint.
training_clone=${TRAINING_CLONE:-/g/data/${project}/bactopia-workbench}
# NCI usernames of the people running the session, space separated. Each one's
# own default SING_CACHE is seeded so they can run the bare production command.
users=${USERS:-}
# Samples per person, 1 to 4. One is the default: every Nextflow task becomes its
# own PBS job, so a smaller set means fewer jobs waiting in the queue, which is
# what actually decides how long a session takes.
samples_per_user=${SAMPLES_PER_USER:-1}
inject_mismatch=${INJECT_MISMATCH:-1}
# Also build a combined set of every user's samples, so the trainer can run it
# once beforehand and know exactly what each person's output should look like.
build_reference=${BUILD_REFERENCE:-1}
skip_prestage=${SKIP_PRESTAGE:-0}
dry_run=${DRY_RUN:-0}

script_dir=$(cd "$(dirname "$0")" && pwd)

cache_dir="$out_root/shared/singularity_cache"
answer_key="$out_root/ANSWER_KEY.tsv"

n_sets=4

# Each set lists up to four samples; SAMPLES_PER_USER decides how many are taken,
# from the front. Position 1 is a DIFFERENT organism in every set, so a one-sample
# session still gives the four people four different results to compare:
#
#   user1  E. coli           user3  K. oxytoca
#   user2  K. pneumoniae     user4  S. marcescens
#
# Positions 2-4 fill out a realistic mix when SAMPLES_PER_USER is larger: more
# E. coli (MLST + FimTyper + ST131Typer), a K. pneumoniae (Kleborate), and one
# other genus.
samples_for_set() {
  case $1 in
    1) printf '%s\n' '24GNB-1752 24GNB-1753 24GNB-1744 24GNB-1760' ;;
    2) printf '%s\n' '24GNB-1745 24GNB-1754 24GNB-1756 24GNB-1478' ;;
    3) printf '%s\n' '24GNB-1775 24GNB-1757 24GNB-1758 24GNB-1633' ;;
    4) printf '%s\n' '24GNB-1764 24GNB-1763 24GNB-1765 24GNB-1634' ;;
  esac
}

# The sample deliberately mislabelled when INJECT_MISMATCH=1, named explicitly
# rather than by position: if SAMPLES_PER_USER does not reach it, that set simply
# gets no mismatch. All four targets sit at position 4, so a one-sample session
# gives everyone a clean, correctly labelled result, and the review logic only
# appears once SAMPLES_PER_USER is 4.
mislabel_target_for_set() {
  case $1 in
    1) printf '%s\n' '24GNB-1760' ;;
    2) printf '%s\n' '24GNB-1478' ;;
    3) printf '%s\n' '24GNB-1633' ;;
    4) printf '%s\n' '24GNB-1634' ;;
  esac
}

# The wrong genus written into the sheet for that sample.
mislabel_for_set() {
  case $1 in
    1) printf '%s\n' 'Escherichia coli' ;;
    2) printf '%s\n' 'Klebsiella pneumoniae' ;;
    3) printf '%s\n' 'Escherichia coli' ;;
    4) printf '%s\n' 'Escherichia coli' ;;
  esac
}

# The first N samples of a set.
included_samples_for_set() {
  set -- $(samples_for_set "$1")
  i=0
  for s in "$@"; do
    i=$(( i + 1 ))
    [ "$i" -gt "$samples_per_user" ] && break
    printf '%s\n' "$s"
  done
}

log()  { printf '[training-setup] %s\n' "$*"; }
warn() { printf '[training-setup] WARNING: %s\n' "$*" >&2; }
fail() { printf '[training-setup] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage:
  ./scripts/setup_training_session.sh [OPTIONS]

Carve an existing AGAR delivery into one input set per user, and pre-populate
each user's own Singularity cache so they can run the bare production command.

Run it from a GADI LOGIN NODE: compute nodes have no outbound internet, so the
container staging step cannot work anywhere else.

Options:
  -n, --samples-per-user N   Samples each person gets, 1-4 (default: ${samples_per_user}).
                             One keeps the session short - every Nextflow task
                             becomes its own PBS job, so this is the main thing
                             deciding how long people wait.
  -u, --users "A B C D"      NCI usernames, space separated. Each one's own default
                             SING_CACHE is seeded, which is what lets their submit
                             command stay bare. Without this, no caches are seeded.
      --reads DIR            Source FASTQ delivery
                             (default: ${src_fastq_dir})
      --sheet FILE           Source metadata samplesheet
                             (default: ${src_sheet})
      --out-root DIR         Where to build the sets
                             (default: ${out_root})
      --install DIR          Install the printed submit commands should use
                             (default: ${training_clone})
      --no-mismatch          Do not deliberately mislabel any organism. Mislabelling
                             only takes effect at --samples-per-user 4 anyway, where
                             the target sample is included.
      --no-reference         Skip the combined reference set. By default one is built
                             holding every user's samples, with the same labels they
                             were given, so you can run it once beforehand and know
                             what each person's output should look like.
      --dry-run              Print what would happen; change nothing
  -h, --help                 Print this message

Every option also has an environment variable - see the comments at the top of
this script. A command-line option wins over the environment.

Examples:
  # one sample each for four people
  ./scripts/setup_training_session.sh -n 1 -u "abc123 def456 ghi789 jkl012"

  # look first, change nothing
  ./scripts/setup_training_session.sh --dry-run -u "abc123"

  # four samples each, from a different delivery
  ./scripts/setup_training_session.sh -n 4 -u "abc123 def456" \\
    --reads /scratch/rg42/AGAR/raw_data/2025/B08/B08 \\
    --sheet /scratch/rg42/AGAR/metadata/2025/B08/B08_samplesheet.txt
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--samples-per-user)
      [ $# -ge 2 ] || fail "$1 needs a value"
      samples_per_user=$2; shift 2 ;;
    -u|--users)
      [ $# -ge 2 ] || fail "$1 needs a value"
      users=$2; shift 2 ;;
    --reads)
      [ $# -ge 2 ] || fail "$1 needs a value"
      src_fastq_dir=$2; shift 2 ;;
    --sheet)
      [ $# -ge 2 ] || fail "$1 needs a value"
      src_sheet=$2; shift 2 ;;
    --out-root)
      [ $# -ge 2 ] || fail "$1 needs a value"
      out_root=$2; cache_dir="$out_root/shared/singularity_cache"
      answer_key="$out_root/ANSWER_KEY.tsv"; shift 2 ;;
    --install)
      [ $# -ge 2 ] || fail "$1 needs a value"
      training_clone=$2; shift 2 ;;
    --no-mismatch)
      inject_mismatch=0; shift ;;
    --no-reference)
      build_reference=0; shift ;;
    --dry-run)
      dry_run=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    -*)
      usage >&2; echo >&2; fail "Unknown option: $1" ;;
    *)
      usage >&2; echo >&2; fail "Unexpected argument: $1 (this script takes options, not positional arguments)" ;;
  esac
done

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

# Echo the single top-level R1 for a sample.
# Exit 1 = none found, exit 2 = more than one (lane split).
# Only the top level, because the FOFN builder globs with `find -maxdepth 1`.
resolve_r1() {
  sample=$1
  found=""
  count=0
  for f in "$src_fastq_dir/${sample}_"*_R1.fastq.gz "$src_fastq_dir/${sample}_"*_R1.fq.gz; do
    if [ -f "$f" ]; then
      found=$f
      count=$(( count + 1 ))
    fi
  done
  [ "$count" -eq 0 ] && return 1
  [ "$count" -gt 1 ] && return 2
  printf '%s\n' "$found"
  return 0
}

mate_of() {
  case $1 in
    *_R1.fastq.gz) printf '%s\n' "${1%_R1.fastq.gz}_R2.fastq.gz" ;;
    *_R1.fq.gz)    printf '%s\n' "${1%_R1.fq.gz}_R2.fq.gz" ;;
    *)             return 1 ;;
  esac
}

# Organism for a sample from the source sheet (col1 = sample, col2 = organism).
# Tolerates tab or comma delimiters and CRLF endings.
organism_of() {
  awk -v want="$1" '
    { sub(/\r$/, "") }
    {
      line = $0
      gsub(/,/, "\t", line)
      n = split(line, f, "\t")
      key = f[1]
      gsub(/^[ \t]+|[ \t]+$/, "", key)
      if (key == want) {
        val = (n >= 2 ? f[2] : "")
        gsub(/^[ \t]+|[ \t]+$/, "", val)
        print val
        exit
      }
    }
  ' "$src_sheet"
}

link_or_copy() {
  src=$1; dest=$2
  [ -e "$dest" ] && return 0
  if [ "$dry_run" -ne 0 ]; then
    printf '[dry-run] link %s -> %s\n' "$(basename "$src")" "$dest"
    return 0
  fi
  cp -l "$src" "$dest" 2>/dev/null || cp "$src" "$dest"
}

mkdirp() {
  if [ "$dry_run" -ne 0 ]; then
    printf '[dry-run] mkdir -p %s\n' "$*"
  else
    mkdir -p "$@"
    chmod 2775 "$@" 2>/dev/null || true
  fi
}

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------
log "Source FASTQs : $src_fastq_dir"
log "Source sheet  : $src_sheet"
log "Destination   : $out_root"
log "Shared cache  : $cache_dir"
[ "$dry_run" -ne 0 ] && log "DRY RUN - nothing will be created"
echo

[ -d "$src_fastq_dir" ] || fail "No such FASTQ directory: $src_fastq_dir"
[ -f "$src_sheet" ]     || fail "No such samplesheet: $src_sheet"

if [ ! -d "$bactopia_pipeline" ]; then
  warn "BACTOPIA_PIPELINE not found: $bactopia_pipeline"
  warn "Container prestaging will be skipped. Set BACTOPIA_PIPELINE and re-run."
  skip_prestage=1
fi

# --------------------------------------------------------------------------
# Resolve every sample before copying anything, so a bad list fails fast.
#
# Filenames carry the flowcell and index, e.g.
#   24GNB-1752_AAHHL2JM5_GTGCAGACAG-TACCATCCGT_L001_R1.fastq.gz
# The FOFN builder takes the sample name as the basename up to the FIRST
# underscore, so the original filenames already yield the right sample ids and
# are copied through unchanged - no renaming needed.
# --------------------------------------------------------------------------
case "$samples_per_user" in
  1|2|3|4) : ;;
  *) fail "SAMPLES_PER_USER must be 1, 2, 3 or 4 (got: $samples_per_user)" ;;
esac

log "Resolving samples in $src_fastq_dir ($samples_per_user per user) ..."
problems=""
total=0
set_i=1
while [ "$set_i" -le "$n_sets" ]; do
  for s in $(included_samples_for_set "$set_i"); do
    total=$(( total + 1 ))
    rc=0
    r1=$(resolve_r1 "$s") || rc=$?
    case $rc in
      1) problems="${problems}  - $s: no R1 found
" ; continue ;;
      2) problems="${problems}  - $s: multiple R1 files (lane split - needs merge-pe)
" ; continue ;;
    esac
    r2=$(mate_of "$r1") || { problems="${problems}  - $s: unrecognised R1 suffix
"; continue; }
    [ -f "$r2" ] || problems="${problems}  - $s: R1 present but R2 missing
"
  done
  set_i=$(( set_i + 1 ))
done

if [ -n "$problems" ]; then
  printf '[training-setup] ERROR: could not resolve these samples:\n' >&2
  printf '%s' "$problems" >&2
  fail "Fix samples_for_set() at the top of this script, or point SRC_FASTQ_DIR elsewhere."
fi
log "All $total samples resolved."

# Warn if the SOURCE sheet looks headerless, because that is a live problem for
# production runs, not just for training. read_metadata_sample_rows() in
# scripts/validate_metadata_samples.py does `enumerate(rows[1:])`: row 1 is
# ALWAYS consumed as a header, whether or not it looks like one. A headerless
# sheet therefore loses its first sample silently. The generated training sheets
# below always carry a header for this reason.
# A header cell is words; a sample id carries digits. Keying off that avoids
# false alarms on whatever the real header happens to be called.
first_field=$(head -n 1 "$src_sheet" | tr -d '\r' | sed 's/[,\t].*//' | tr -d ' ')
case "$first_field" in
  *[0-9]*)
    warn "Source sheet's first row looks like DATA, not a header:"
    warn "  $(head -n 1 "$src_sheet")"
    warn "validate_metadata_samples.py always treats row 1 as a header, so that"
    warn "sample is being dropped from $(basename "$src_sheet") in production too."
    warn "Worth adding a 'Sample name<TAB>Organism' header to the source sheet."
    ;;
  *) : ;;  # header present, nothing to do
esac
echo

# --------------------------------------------------------------------------
# Build the per-user sets.
#
# Each user gets their OWN metadata dir. samplesheet.fofn is created in
# METADATA_DIR and reused if present, so a shared metadata dir would make
# users silently inherit each other's batch list.
#
# FASTQs are hard-linked, never symlinked: the FOFN builder's `find -type f`
# does not match symlinks, so a symlinked set yields an empty FOFN. Hard links
# cost no extra space or inodes, and work because this is one filesystem.
# --------------------------------------------------------------------------
mkdirp "$out_root"
if [ "$dry_run" -eq 0 ]; then
  printf 'set\tsample\tsheet_organism\ttrue_organism\tnote\n' > "$answer_key"
fi

# A combined set holding every user's samples, for the trainer to run once
# beforehand. Worth doing as ONE submission rather than four: each submission is
# a chain of ~10 driver jobs that queue separately, so four parallel chains
# compete for the same queue while one chain does not. The sheet carries the same
# organism labels the users were given - including any deliberate mislabel - so
# each reference row is exactly what that user should see.
if [ "$build_reference" -ne 0 ]; then
  ref_root="$out_root/reference"
  ref_fq="$ref_root/fastq"
  ref_md="$ref_root/metadata"
  ref_res="$ref_root/REF"
  ref_sheet="$ref_md/REF_samplesheet.txt"
  mkdirp "$ref_fq" "$ref_md" "$ref_res"
  [ "$dry_run" -eq 0 ] && printf 'Sample name\tOrganism\n' > "$ref_sheet"
fi

set_i=1
while [ "$set_i" -le "$n_sets" ]; do
  mislabel=$(mislabel_for_set "$set_i")
  mislabel_target=$(mislabel_target_for_set "$set_i")
  set_root="$out_root/user${set_i}"
  fq_dir="$set_root/fastq"
  md_dir="$set_root/metadata"
  # Named after the set, because the workbook, assemblies and ST131Typer dirs are
  # all basename(RESULTS_ROOT) + a suffix. A dir called "results" would produce
  # results_results.xlsx; "U1" produces U1_results.xlsx, matching the way a
  # production run under .../intermediates/2025/B07 yields B07_results.xlsx.
  res_dir="$set_root/U${set_i}"
  sheet="$md_dir/U${set_i}_samplesheet.txt"

  log "user${set_i}:"
  mkdirp "$fq_dir" "$md_dir" "$res_dir"

  # The header is mandatory, not cosmetic: row 1 is always skipped when the
  # sheet is read, so a headerless sheet loses its first sample.
  if [ "$dry_run" -eq 0 ]; then
    printf 'Sample name\tOrganism\n' > "$sheet"
  fi

  for s in $(included_samples_for_set "$set_i"); do
    r1=$(resolve_r1 "$s")
    r2=$(mate_of "$r1")

    link_or_copy "$r1" "$fq_dir/$(basename "$r1")"
    link_or_copy "$r2" "$fq_dir/$(basename "$r2")"

    true_org=$(organism_of "$s")
    [ -n "$true_org" ] || warn "no organism in sheet for $s - left blank"
    sheet_org=$true_org
    note='-'

    # Mislabel this set's designated sample, if SAMPLES_PER_USER reached it, so
    # review_required and mlst_review_note actually fire during the session.
    if [ "$inject_mismatch" -ne 0 ] && [ "$s" = "$mislabel_target" ]; then
      sheet_org=$mislabel
      note='deliberate genus mismatch - expect review_required'
    fi

    if [ "$dry_run" -eq 0 ]; then
      printf '%s\t%s\n' "$s" "$sheet_org" >> "$sheet"
      printf 'user%s\t%s\t%s\t%s\t%s\n' \
        "$set_i" "$s" "$sheet_org" "$true_org" "$note" >> "$answer_key"
    fi

    # Same sample, same label, into the combined reference set.
    if [ "$build_reference" -ne 0 ]; then
      link_or_copy "$r1" "$ref_fq/$(basename "$r1")"
      link_or_copy "$r2" "$ref_fq/$(basename "$r2")"
      [ "$dry_run" -eq 0 ] && printf '%s\t%s\n' "$s" "$sheet_org" >> "$ref_sheet"
    fi

    printf '    %-14s %-30s %s\n' "$s" "${sheet_org:-<blank>}" "$note"
  done

  log "  sheet: $sheet"
  echo
  set_i=$(( set_i + 1 ))
done

if [ "$dry_run" -eq 0 ]; then
  chmod 0640 "$answer_key" 2>/dev/null || true
fi
log "Trainer answer key: $answer_key"
echo

# --------------------------------------------------------------------------
# Shared Singularity cache.
#
# SING_CACHE defaults to a path under $USER, so four separate accounts each get
# an empty cache, and four runs die on container pulls that cannot work from a
# compute node
# - and a failed pull leaves a 0-byte .img stub that poisons the cache for every
# later run. Seeding from an already-populated cache is far faster and safer
# than four fresh downloads.
# --------------------------------------------------------------------------
log "Preparing shared Singularity cache: $cache_dir"
mkdirp "$cache_dir"

if [ -d "$seed_cache" ] && [ "$seed_cache" != "$cache_dir" ]; then
  stub_count=$(find "$seed_cache" -maxdepth 1 -type f -size 0 2>/dev/null | wc -l | tr -d ' ')
  if [ "$stub_count" -gt 0 ]; then
    warn "$stub_count zero-byte image stub(s) in $seed_cache will NOT be copied:"
    find "$seed_cache" -maxdepth 1 -type f -size 0 2>/dev/null \
      | while IFS= read -r stub; do printf '    %s\n' "$(basename "$stub")" >&2; done
    warn "Repair them with scripts/repair_singularity_cache.sh before the session."
  fi

  log "Seeding from $seed_cache (hard links, skipping zero-byte stubs) ..."
  if [ "$dry_run" -ne 0 ]; then
    printf '[dry-run] hard-link non-empty images from %s into %s\n' "$seed_cache" "$cache_dir"
  else
    # ln rather than copy: same filesystem, so this costs no extra disk. -size +0c
    # is what keeps a poisoned 0-byte stub from propagating. A later pull by
    # Nextflow writes a new inode, so it cannot mutate the seed cache's images.
    find "$seed_cache" -maxdepth 1 -type f -size +0c -exec ln -f {} "$cache_dir"/ \; 2>/dev/null \
      || warn "hard-link seed failed; falling back to copy" \
      && true
    if [ -z "$(find "$cache_dir" -maxdepth 1 -type f 2>/dev/null)" ]; then
      rsync -a --min-size=1 "$seed_cache"/ "$cache_dir"/
    fi
    chmod -R g+rwX "$cache_dir" 2>/dev/null || true
    log "Cache now holds $(find "$cache_dir" -maxdepth 1 -type f | wc -l | tr -d ' ') file(s)"
  fi
else
  warn "No seed cache at $seed_cache - every image will have to be downloaded."
fi
echo

if [ "$skip_prestage" -ne 0 ]; then
  warn "Skipping container prestaging (SKIP_PRESTAGE=1 or Bactopia install missing)."
else
  log "Staging any missing bactopia-tools images (needs a login node) ..."
  if [ "$dry_run" -ne 0 ]; then
    printf '[dry-run] %s --bactopia %s --dir %s --yes\n' \
      "$script_dir/prestage_tool_containers.sh" "$bactopia_pipeline" "$cache_dir"
  elif [ ! -x "$script_dir/prestage_tool_containers.sh" ]; then
    warn "Not found or not executable: $script_dir/prestage_tool_containers.sh"
  else
    SING_CACHE="$cache_dir" "$script_dir/prestage_tool_containers.sh" \
      --bactopia "$bactopia_pipeline" \
      --dir "$cache_dir" \
      --yes || warn "prestage reported missing images - see output above."
    chmod -R g+rwX "$cache_dir" 2>/dev/null || true
  fi
fi
echo

# --------------------------------------------------------------------------
# Seed each user's OWN default cache path.
#
# The point is that users run the documented production command - three paths
# and a batch size, no flags - so nothing may depend on passing --site-config
# or SING_CACHE. The production site config resolves
#   SING_CACHE=${SING_CACHE:-/scratch/$PROJECT/$USER_NAME/singularity_cache}
# per account, so the only way to leave the command bare is for that path to
# already be populated for each account.
#
# Hard links, so this costs no extra disk: /scratch/$PROJECT is one filesystem,
# the images are shared inodes, and a later pull by one user writes a new inode
# rather than mutating anyone else's image.
# --------------------------------------------------------------------------
[ -f "$prod_site_config" ] || warn "Production site config not found: $prod_site_config"

if [ -z "$users" ]; then
  warn "USERS is unset, so no per-account caches were seeded."
  warn "Each user's first run would then try to pull containers from a compute"
  warn "node, which has no internet. Re-run with the NCI usernames, e.g.:"
  warn "  USERS='abc123 def456 ghi789 jkl012' $0"
else
  log "Seeding per-account caches by hard link (no extra disk):"
  for u in $users; do
    user_cache="${scratch_root}/${project}/${u}/singularity_cache"

    if [ "$dry_run" -ne 0 ]; then
      printf '[dry-run] cp -al %s/. %s/\n' "$cache_dir" "$user_cache"
      continue
    fi

    if ! mkdir -p "$user_cache" 2>/dev/null; then
      warn "  $u: cannot create $user_cache (permissions)."
      warn "    Have $u run: mkdir -p $user_cache && cp -al $cache_dir/. $user_cache/"
      continue
    fi

    # Group-writable + setgid so the account can add its own images later.
    chmod 2775 "$user_cache" 2>/dev/null || true

    if cp -al "$cache_dir"/. "$user_cache"/ 2>/dev/null; then
      n=$(find "$user_cache" -maxdepth 1 -type f | wc -l | tr -d ' ')
      printf '    %-12s %s (%s images)\n' "$u" "$user_cache" "$n"
    else
      warn "  $u: hard-link seed into $user_cache failed."
      warn "    Have $u run: cp -al $cache_dir/. $user_cache/"
    fi
  done
fi
echo

# --------------------------------------------------------------------------
# Report
# --------------------------------------------------------------------------
if [ "$dry_run" -eq 0 ]; then
  log "Disk used by the training tree:"
  du -sh "$out_root" 2>/dev/null | sed 's/^/    /' || true
  log "Inode headroom:"
  df -Pi "$out_root" 2>/dev/null | sed 's/^/    /' || true
  echo
fi

if [ "$build_reference" -ne 0 ]; then
  cat <<EOF
=============================================================================
TRAINER: run this once, before the session
=============================================================================

The reference set holds every user's samples with the labels they were given,
so its workbook tells you exactly what each person's output should look like.

Run it as ONE submission. Each submission is a chain of about ten driver jobs
that queue separately, so one chain beats four people's chains competing.

  export EXTRA_ARGS_STRING='--coverage 20'
  ${training_clone}/bin/bactopia-workbench submit gadi \\
    ${ref_root}/fastq \\
    ${ref_root}/metadata \\
    ${ref_res} \\
    50

Results land in ${ref_res}, with the workbook at REF_results.xlsx.
Check it against ANSWER_KEY.tsv: every row marked as a deliberate mismatch
should come back with review_required set.

Time it. That number is the only honest basis for deciding whether the sample
count is right, and for telling users how long to expect to wait.

EOF
fi

cat <<'NOTES'
=============================================================================
If the session is too slow, in order of effect
=============================================================================

The executor is pbspro, so every Nextflow task is its own PBS job and queue
wait dominates. Compute is not usually the problem: four samples assembled in
55 minutes while their CheckM tasks sat in the queue for 22 hours.

1. DROP CHECKM. It is the heaviest task and the hardest to schedule, asking
   4 CPUs, 32 GB and 24h walltime for about ten minutes of work.

     export TOOLS_STRING='abritamr amrfinderplus bracken mlst plasmidfinder'

   You lose the checkm_ completeness/contamination columns.

2. SHORTEN THE TASK WALLTIMES AND USE EXPRESS. This is the root cause. Note
   that `time` in the config is NOT what PBS sees: clusterOptions hardcodes
   walltime=, and that is the -l PBS honours, so the string is what to edit.

     cp /g/data/rg42/bactopia-workbench/scripts/nextflow.gadi.all_tools.config \
        /scratch/rg42/training/nextflow.training.config
     sed -i -e 's/walltime=24:00:00/walltime=02:00:00/g' \
            -e 's/walltime=12:00:00/walltime=02:00:00/g' \
            -e "s/queue = 'normal'/queue = 'express'/" \
        /scratch/rg42/training/nextflow.training.config
     export NEXTFLOW_CONFIG=/scratch/rg42/training/nextflow.training.config

3. SHORTEN THE CHAIN. Each optional stage is another driver job with its own
   queue wait. RUN_ST131_TYPER=0 and RUN_COLLECT_ASSEMBLIES=0 cost the least
   teaching value; RUN_KLEBORATE=0 and RUN_FIMTYPER=0 cost the most.

4. SUBSAMPLE THE READS. Smallest effect of the four, since compute is not the
   bottleneck, but it does cut assembly time:

     export EXTRA_ARGS_STRING='--coverage 20'

These are all environment variables, so they stay in the trainer's hands and
the command users type stays bare.

=============================================================================
What each user runs (dry run first)
=============================================================================
NOTES

echo
set_i=1
while [ "$set_i" -le "$n_sets" ]; do
  cat <<EOF
# --- user${set_i} ---
${training_clone}/bin/bactopia-workbench submit gadi \\
  --dry-run \\
  ${out_root}/user${set_i}/fastq \\
  ${out_root}/user${set_i}/metadata \\
  ${out_root}/user${set_i}/U${set_i} \\
  50

EOF
  set_i=$(( set_i + 1 ))
done

cat <<EOF
That is the documented production command shape - three paths and a batch size,
no flags - which is the whole point of seeding each account's own cache. Drop
--dry-run to submit for real.

Anything you want applied to every user's run goes in the environment before
they submit, so their command stays bare - see the slowness notes above.

Leave --additional-tools off: it pulls in ten tools whose images are not cached.
EOF
