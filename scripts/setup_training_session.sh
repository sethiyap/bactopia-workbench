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
#   USERS='abc123 def456 ghi789 jkl012' ./scripts/setup_training_session.sh
#   DRY_RUN=1 USERS='...' ./scripts/setup_training_session.sh   # change nothing
#
# Defaults point at the 2024 B07 delivery. Override with env vars:
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
#   INJECT_MISMATCH    1   deliberately mislabel one organism per set
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
inject_mismatch=${INJECT_MISMATCH:-1}
skip_prestage=${SKIP_PRESTAGE:-0}
dry_run=${DRY_RUN:-0}

script_dir=$(cd "$(dirname "$0")" && pwd)

cache_dir="$out_root/shared/singularity_cache"
answer_key="$out_root/ANSWER_KEY.tsv"

n_sets=4

# Four sets of four. Each set: 2x E. coli (MLST + FimTyper + ST131Typer),
# 1x K. pneumoniae (Kleborate), 1x other genus (exercises the MLST review and
# canonical-genus logic). The 4th sample of each set is the one deliberately
# mislabelled when INJECT_MISMATCH=1.
samples_for_set() {
  case $1 in
    1) printf '%s\n' '24GNB-1752 24GNB-1753 24GNB-1744 24GNB-1760' ;;
    2) printf '%s\n' '24GNB-1754 24GNB-1756 24GNB-1745 24GNB-1478' ;;
    3) printf '%s\n' '24GNB-1757 24GNB-1758 24GNB-1633 24GNB-1775' ;;
    4) printf '%s\n' '24GNB-1763 24GNB-1765 24GNB-1634 24GNB-1764' ;;
  esac
}

# Wrong-genus label applied to the 4th sample of each set.
mislabel_for_set() {
  case $1 in
    1) printf '%s\n' 'Escherichia coli' ;;
    2) printf '%s\n' 'Klebsiella pneumoniae' ;;
    3) printf '%s\n' 'Escherichia coli' ;;
    4) printf '%s\n' 'Escherichia coli' ;;
  esac
}

log()  { printf '[training-setup] %s\n' "$*"; }
warn() { printf '[training-setup] WARNING: %s\n' "$*" >&2; }
fail() { printf '[training-setup] ERROR: %s\n' "$*" >&2; exit 1; }

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
log "Resolving samples in $src_fastq_dir ..."
problems=""
total=0
set_i=1
while [ "$set_i" -le "$n_sets" ]; do
  for s in $(samples_for_set "$set_i"); do
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

set_i=1
while [ "$set_i" -le "$n_sets" ]; do
  mislabel=$(mislabel_for_set "$set_i")
  set_root="$out_root/user${set_i}"
  fq_dir="$set_root/fastq"
  md_dir="$set_root/metadata"
  res_dir="$set_root/results"
  sheet="$md_dir/U${set_i}_samplesheet.txt"

  log "user${set_i}:"
  mkdirp "$fq_dir" "$md_dir" "$res_dir"

  # The header is mandatory, not cosmetic: row 1 is always skipped when the
  # sheet is read, so a headerless sheet loses its first sample.
  if [ "$dry_run" -eq 0 ]; then
    printf 'Sample name\tOrganism\n' > "$sheet"
  fi

  n=0
  for s in $(samples_for_set "$set_i"); do
    n=$(( n + 1 ))
    r1=$(resolve_r1 "$s")
    r2=$(mate_of "$r1")

    link_or_copy "$r1" "$fq_dir/$(basename "$r1")"
    link_or_copy "$r2" "$fq_dir/$(basename "$r2")"

    true_org=$(organism_of "$s")
    [ -n "$true_org" ] || warn "no organism in sheet for $s - left blank"
    sheet_org=$true_org
    note='-'

    # Mislabel the 4th sample of each set so review_required and
    # mlst_review_note actually fire during the session.
    if [ "$inject_mismatch" -ne 0 ] && [ "$n" -eq 4 ]; then
      sheet_org=$mislabel
      note='deliberate genus mismatch - expect review_required'
    fi

    if [ "$dry_run" -eq 0 ]; then
      printf '%s\t%s\n' "$s" "$sheet_org" >> "$sheet"
      printf 'user%s\t%s\t%s\t%s\t%s\n' \
        "$set_i" "$s" "$sheet_org" "$true_org" "$note" >> "$answer_key"
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

cat <<'NOTES'
=============================================================================
Two manual steps this script deliberately does not do
=============================================================================

1. REHEARSE ONE SET END TO END and time it. That number decides whether four
   samples each is right, and it is the only way to know: nothing here can
   predict a per-batch runtime.

2. OPTIONAL - SHORTEN THE WALLTIME if queue wait turns out to be the binding
   constraint. scheduler_submit (scripts/lib_scheduler.sh) passes only
   -o/-e/-m/-M/-N/-W/-v to qsub. There is NO hook for -q or -l walltime:
   resources are fixed in the #PBS headers. run_bactopia_batch.pbs asks for 24h
   and run_extra_bactopia_tools.pbs for 48h, and PBS schedules on the request
   rather than the need, so four samples can sit behind a 24h reservation.

   That cannot be fixed without editing those headers, so do it in a copy
   rather than in the shared install:

     cp -a /g/data/rg42/bactopia-workbench /g/data/rg42/bactopia-workbench-short
     # trim walltime in the copy's scripts/run_bactopia_batch.pbs (~4h)
     # and scripts/run_extra_bactopia_tools.pbs (~2h)

   Then re-run this script with TRAINING_CLONE=/g/data/rg42/bactopia-workbench-short
   so the printed commands point at the copy.

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
  ${out_root}/user${set_i}/results \\
  50

EOF
  set_i=$(( set_i + 1 ))
done

cat <<EOF
That is the documented production command shape - three paths and a batch size,
no flags - which is the whole point of seeding each account's own cache.

Drop --dry-run to submit for real. To cut assembly time, add the subsampling
override, the cheapest runtime lever available without touching the FASTQs:

  EXTRA_ARGS_STRING='--coverage 40' \\
  ${training_clone}/bin/bactopia-workbench submit gadi \\
    ${out_root}/user1/fastq \\
    ${out_root}/user1/metadata \\
    ${out_root}/user1/results \\
    50

Leave --additional-tools off: it pulls in ten tools whose images are not cached.
EOF
