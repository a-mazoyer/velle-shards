#!/usr/bin/env bash
#
# sync-gitignore-shards.sh
#
# Create and maintain one velle shard per gitignore template from
# https://github.com/github/gitignore (repository root + Global/ only).
#
# For each upstream <Name>.gitignore this script:
#   1. ensures a shard dev/gitignore-<slug> exists (via `velle new`)
#   2. writes the upstream content into the shard's source file
#   3. patches shard.toml:  dest=".gitignore", mode="append",
#      description="Append gitignore rules for <Name>"
#
# Reruns are idempotent: new upstream templates are added, changed ones are
# reported (and refreshed with --update), everything else is left alone.

set -euo pipefail

if [[ -z "${BASH_VERSINFO:-}" || "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  echo "error: bash >= 4 required (associative arrays)." >&2
  exit 2
fi

# ---------------------------------------------------------------- config ----

REPO_URL="https://github.com/github/gitignore"
REPO_BRANCH="main"
API_TREE="https://api.github.com/repos/github/gitignore/git/trees/${REPO_BRANCH}?recursive=1"
RAW_BASE="https://raw.githubusercontent.com/github/gitignore/${REPO_BRANCH}"

SHARD_PREFIX="dev/gitignore-"      # shard name = ${SHARD_PREFIX}${slug}

PROJECT_DIR="."
VELLE_SUBDIR=".velle"
MANIFEST_NAME="gitignore-sync.tsv"

# ------------------------------------------------------------ cli options ---

DRY_RUN=0 CHECK=0 UPDATE=0 FORCE=0 USE_GIT=1 KEEP_TEMP=0 VERBOSE=0
LIMIT=0 FILTER=""

usage() {
  cat <<'EOF'
Usage: sync-gitignore-shards.sh [options]

  -C, --project-dir DIR   Directory containing .velle/ (default: .)
      --update            Refresh shard source files whose upstream content changed
      --force             Also re-apply the shard.toml patch to existing shards
      --check             Read-only audit; exit 1 if anything is missing or stale
  -n, --dry-run           Show what would happen, write nothing
      --filter GLOB       Only process upstream paths matching GLOB
                          (e.g. 'Global/*', '*Python*')
      --limit N           Process at most N templates (after filtering)
      --no-git            Fetch via the GitHub API + raw.githubusercontent
                          instead of `git clone` (needs jq; rate-limited)
      --keep-temp         Do not delete the temporary checkout
  -v, --verbose           Verbose output
  -h, --help              This help

Exit codes: 0 ok, 1 drift/failures, 2 usage or environment error.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -C|--project-dir) PROJECT_DIR="${2:?}"; shift 2 ;;
    --update)         UPDATE=1; shift ;;
    --force)          FORCE=1; shift ;;
    --check)          CHECK=1; shift ;;
    -n|--dry-run)     DRY_RUN=1; shift ;;
    --filter)         FILTER="${2:?}"; shift 2 ;;
    --limit)          LIMIT="${2:?}"; shift 2 ;;
    --no-git)         USE_GIT=0; shift ;;
    --keep-temp)      KEEP_TEMP=1; shift ;;
    -v|--verbose)     VERBOSE=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "error: unknown option '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

# --check and --dry-run are both read-only.
WRITE=1
(( DRY_RUN || CHECK )) && WRITE=0

# --------------------------------------------------------------- logging ----

log()  { printf '%s\n' "$*"; }
vlog() { (( VERBOSE )) && printf '  %s\n' "$*" || true; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 2; }

# ------------------------------------------------------------- utilities ----

need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed."; }

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

sha256_str() {
  if command -v sha256sum >/dev/null 2>&1; then printf '%s' "$1" | sha256sum | awk '{print $1}'
  else printf '%s' "$1" | shasum -a 256 | awk '{print $1}'; fi
}

# "C++" -> "cplusplus", "Objective-C" -> "objective-c", "Visual Studio" -> "visual-studio"
slugify() {
  local s="$1"
  s="${s//+/plus}"
  s="${s//#/sharp}"
  printf '%s' "$s" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

# Read a quoted scalar out of a shard.toml (first match wins).
toml_str() {  # toml_str <key> <file>
  sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"([^\"]*)\".*/\1/p" "$2" | head -n1
}

toml_array() {  # toml_array <key> <file>
  sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*(\[[^]]*\]).*/\1/p" "$2" | head -n1
}

# --------------------------------------------------- shard.toml patching ----

# Rewrites description / dest / mode in place, preserving velle's column
# alignment and the trailing "# create | append | region" comment. Fails
# loudly if any target key is absent or duplicated, so a change in velle's
# template can never silently produce a wrong shard. `requires` is left
# exactly as velle generated it.
patch_toml() {  # patch_toml <shard.toml> <description>
  local toml="$1" desc="$2"
  local tmp="${toml}.tmp.$$"

  # description is a filename; escape defensively anyway.
  local esc="${desc//\\/\\\\}"; esc="${esc//\"/\\\"}"

  if ! awk -v desc="$esc" '
        BEGIN { nd = 0; ndest = 0; nmode = 0 }
        /^[[:space:]]*description[[:space:]]*=/ {
            printf "description = \"%s\"\n", desc; nd++;    next }
        /^[[:space:]]*dest[[:space:]]*=/ {
            printf "dest = \".gitignore\"\n";      ndest++; next }
        /^[[:space:]]*mode[[:space:]]*=/ {
            c = ""; h = index($0, "#")
            if (h > 0) c = "   " substr($0, h)
            printf "mode = \"append\"%s\n", c;     nmode++; next }
        { print }
        END {
            if (nd    != 1) { printf "expected 1 description line, found %d\n", nd    > "/dev/stderr"; exit 3 }
            if (ndest != 1) { printf "expected 1 dest line, found %d\n",        ndest > "/dev/stderr"; exit 3 }
            if (nmode != 1) { printf "expected 1 mode line, found %d\n",        nmode > "/dev/stderr"; exit 3 }
        }
      ' "$toml" > "$tmp"
  then
    rm -f "$tmp"
    return 1
  fi

  mv "$tmp" "$toml"
}


toml_conformant() {  # toml_conformant <shard.toml> <description>
  local toml="$1" desc="$2"
  [[ "$(toml_str description "$toml")" == "$desc" ]] || return 1
  [[ "$(toml_str dest        "$toml")" == ".gitignore" ]] || return 1
  [[ "$(toml_str mode        "$toml")" == "append"     ]] || return 1
  return 0
}

# --------------------------------------------------------------- staging ---
# `velle new` takes a path to an existing file and derives src/dest from its
# basename, so the upstream file is staged at the project root under its
# original name for the duration of the call, then removed.

STAGE_PATH=""
STAGE_BACKUP=""

stage_file() {   # stage_file <upstream_file> <basename>
  local src="$1" base="$2"
  STAGE_PATH="./${base}"
  STAGE_BACKUP=""
  if [[ -e "$STAGE_PATH" ]]; then
    STAGE_BACKUP="$(mktemp "${TMPDIR:-/tmp}/velle-stage.XXXXXX")"
    mv "$STAGE_PATH" "$STAGE_BACKUP"
    vlog "moved pre-existing ${STAGE_PATH} aside"
  fi
  cp "$src" "$STAGE_PATH"
}

unstage_file() {
  [[ -n "$STAGE_PATH" ]] || return 0
  rm -f "$STAGE_PATH"
  if [[ -n "$STAGE_BACKUP" && -e "$STAGE_BACKUP" ]]; then
    mv "$STAGE_BACKUP" "$STAGE_PATH"
    vlog "restored ${STAGE_PATH}"
  fi
  STAGE_PATH=""; STAGE_BACKUP=""
}


# ------------------------------------------------------------- fetch step ---

WORK=""
cleanup() {
  unstage_file
  [[ -n "$WORK" && -d "$WORK" ]] || return 0
  if (( KEEP_TEMP )); then log "temporary checkout kept at: $WORK"
  else rm -rf "$WORK"; fi
}
trap cleanup EXIT

fetch_upstream() {
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/gitignore-sync.XXXXXX")"
  mkdir -p "$WORK/src"

  if (( USE_GIT )); then
    need git
    log "Cloning ${REPO_URL} (${REPO_BRANCH}, depth 1) ..."
    git clone --quiet --depth 1 --single-branch --branch "$REPO_BRANCH" \
      "$REPO_URL" "$WORK/src" \
      || die "git clone failed (try --no-git)"
  else
    need curl; need jq
    log "Listing tree via the GitHub API ..."
    local auth=() paths
    [[ -n "${GITHUB_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    paths="$(curl -fsSL "${auth[@]}" "$API_TREE" \
              | jq -r '.tree[] | select(.type=="blob") | .path' \
              | grep -E '^(Global/)?[^/]+\.gitignore$' || true)"
    [[ -n "$paths" ]] || die "API returned no matching paths (rate limited? set GITHUB_TOKEN)"
    local n=0 p
    while IFS= read -r p; do
      mkdir -p "$WORK/src/$(dirname "$p")"
      curl -fsSL "${auth[@]}" "${RAW_BASE}/${p}" -o "$WORK/src/$p" \
        || die "download failed: $p"
      n=$((n + 1))
    done <<< "$paths"
    log "Downloaded $n files."
  fi
}

collect_paths() {  # -> sorted upstream paths, root + Global/ only
  (
    cd "$WORK/src"
    find . -maxdepth 1 -type f -name '*.gitignore' | sed 's|^\./||'
    [[ -d Global ]] && find Global -maxdepth 1 -type f -name '*.gitignore'
  ) | sed 's|^\./||' | sort
}

# ------------------------------------------------------------------- main ---

[[ -d "$PROJECT_DIR" ]] || die "no such directory: $PROJECT_DIR"
cd "$PROJECT_DIR"
[[ -d "$VELLE_SUBDIR" ]] || die "no ${VELLE_SUBDIR}/ in $(pwd) — run from the project root or pass -C DIR"
(( WRITE )) && need velle

MANIFEST="${VELLE_SUBDIR}/${MANIFEST_NAME}"

fetch_upstream

mapfile -t ALL_PATHS < <(collect_paths)
(( ${#ALL_PATHS[@]} )) || die "no .gitignore templates found upstream"

# --- filter / limit -----------------------------------------------------
PATHS=()
for p in "${ALL_PATHS[@]}"; do
  if [[ -n "$FILTER" ]]; then
    # shellcheck disable=SC2254
    case "$p" in $FILTER) ;; *) continue ;; esac
  fi
  PATHS+=("$p")
  if (( LIMIT > 0 && ${#PATHS[@]} >= LIMIT )); then break; fi
done
(( ${#PATHS[@]} )) || die "filter '$FILTER' matched nothing"

SUBSET=0
[[ -n "$FILTER" ]] && SUBSET=1
(( LIMIT > 0 )) && SUBSET=1

log "Found ${#ALL_PATHS[@]} templates upstream; processing ${#PATHS[@]}."

# --- slug assignment (two passes, deterministic) ------------------------
declare -A BASE_COUNT=() SLUG_OF=() TAKEN=()

for p in "${PATHS[@]}"; do
  b="$(slugify "$(basename "$p" .gitignore)")"
  BASE_COUNT["$b"]=$(( ${BASE_COUNT["$b"]:-0} + 1 ))
done

for p in "${PATHS[@]}"; do
  b="$(slugify "$(basename "$p" .gitignore)")"
  cand="$b"
  if (( ${BASE_COUNT["$b"]} > 1 )); then
    d="$(dirname "$p")"; [[ "$d" == "." ]] && d="root"
    cand="${b}-$(slugify "$d")"
  fi
  if [[ -n "${TAKEN[$cand]:-}" ]]; then
    cand="${cand}-$(sha256_str "$p" | cut -c1-6)"    # stable last resort
  fi
  TAKEN["$cand"]="$p"
  SLUG_OF["$p"]="$cand"
done

# --- process ------------------------------------------------------------
N_CREATED=0 N_FILLED=0 N_UPDATED=0 N_OUTDATED=0 N_OK=0 N_REPATCHED=0
N_NONCONF=0 N_FAILED=0 N_MISSING=0

MANIFEST_TMP="$(mktemp "${TMPDIR:-/tmp}/gitignore-manifest.XXXXXX")"

for p in "${PATHS[@]}"; do
  slug="${SLUG_OF[$p]}"
  pretty="$(basename "$p" .gitignore)"
  shard_name="${SHARD_PREFIX}${slug}"
  shard_dir="${VELLE_SUBDIR}/shards/${shard_name}"
  shard_toml="${shard_dir}/shard.toml"
  src_file="${WORK}/src/${p}"
  desc="Append gitignore rules for ${pretty}"

  created_now=0

  # 1. create the shard if it does not exist -----------------------------
  if [[ ! -f "$shard_toml" ]]; then
    upstream_base="$(basename "$p")"          # e.g. Python.gitignore

    if (( CHECK )); then
      log "MISSING   ${shard_name}  (<- ${p})"
      N_MISSING=$((N_MISSING + 1))
      printf '%s\t%s\t%s\t%s\n' "$slug" "$p" "$(sha256_file "$src_file")" "$shard_name" >> "$MANIFEST_TMP"
      continue
    fi
    if (( DRY_RUN )); then
      log "would stage ${p} as ./${upstream_base}"
      log "would run:  velle new ${shard_name} ${upstream_base}"
      log "would patch ${shard_toml}"
      N_CREATED=$((N_CREATED + 1))
      printf '%s\t%s\t%s\t%s\n' "$slug" "$p" "$(sha256_file "$src_file")" "$shard_name" >> "$MANIFEST_TMP"
      continue
    fi

    vlog "velle new ${shard_name} ${upstream_base}"
    stage_file "$src_file" "$upstream_base"
    if ! out="$(velle new "$shard_name" "$upstream_base" 2>&1)"; then
      unstage_file
      warn "velle new failed for ${shard_name}: ${out}"
      N_FAILED=$((N_FAILED + 1))
      continue
    fi
    unstage_file

    if [[ ! -f "$shard_toml" ]]; then
      warn "velle new reported success but ${shard_toml} does not exist"
      N_FAILED=$((N_FAILED + 1))
      continue
    fi
    created_now=1
    N_CREATED=$((N_CREATED + 1))
  fi


  # 2. locate the shard's source file (trust shard.toml, not a guess) ----
  rel_src="$(toml_str src "$shard_toml")"
  [[ -n "$rel_src" ]] || rel_src="files/$(basename "$p")"
  target="${shard_dir}/${rel_src}"

  # 3. sync content ------------------------------------------------------
  up_sha="$(sha256_file "$src_file")"
  if [[ ! -f "$target" ]]; then
    if (( WRITE )); then
      mkdir -p "$(dirname "$target")"
      cp "$src_file" "$target"
      (( created_now )) || N_FILLED=$((N_FILLED + 1))
      vlog "wrote ${target}"
    else
      log "MISSING   ${shard_name}  source file ${rel_src}"
      N_MISSING=$((N_MISSING + 1))
    fi
  else
    if [[ "$(sha256_file "$target")" != "$up_sha" ]]; then
      if (( UPDATE && WRITE )); then
        cp "$src_file" "$target"
        log "UPDATED   ${shard_name}  (<- ${p})"
        N_UPDATED=$((N_UPDATED + 1))
      else
        log "OUTDATED  ${shard_name}  (<- ${p})   [--update to refresh]"
        N_OUTDATED=$((N_OUTDATED + 1))
      fi
    else
      N_OK=$((N_OK + 1))
    fi
  fi

  # 4. patch shard.toml --------------------------------------------------
  if (( created_now )) || (( FORCE )); then
    if (( WRITE )); then
      if patch_toml "$shard_toml" "$desc"; then
        (( created_now )) || N_REPATCHED=$((N_REPATCHED + 1))
      else
        warn "could not patch ${shard_toml} (unexpected template layout)"
        N_FAILED=$((N_FAILED + 1))
      fi
    fi
  elif ! toml_conformant "$shard_toml" "$desc"; then
    log "NONCONF   ${shard_name}  shard.toml differs from policy   [--force to rewrite]"
    N_NONCONF=$((N_NONCONF + 1))
  fi

  printf '%s\t%s\t%s\t%s\n' "$slug" "$p" "$up_sha" "$shard_name" >> "$MANIFEST_TMP"
done

# --- orphan detection (only meaningful on a full run) -------------------
N_ORPHAN=0
if (( ! SUBSET )); then
  shards_root="${VELLE_SUBDIR}/shards/${SHARD_PREFIX%/*}"
  leaf_prefix="${SHARD_PREFIX##*/}"
  if [[ -d "$shards_root" ]]; then
    while IFS= read -r d; do
      [[ -n "$d" ]] || continue
      name="$(basename "$d")"
      slug="${name#"$leaf_prefix"}"
      full="${SHARD_PREFIX}${slug}"
      [[ -n "${TAKEN[$slug]:-}" ]] && continue
      log "ORPHAN    ${full}  no longer present upstream"
      N_ORPHAN=$((N_ORPHAN + 1))
    done < <(find "$shards_root" -mindepth 1 -maxdepth 1 -type d -name "${leaf_prefix}*" | sort)
  fi
fi

# --- manifest -----------------------------------------------------------
if (( WRITE )); then
  sort -o "$MANIFEST_TMP" "$MANIFEST_TMP"
  mv "$MANIFEST_TMP" "$MANIFEST"
  vlog "manifest written to ${MANIFEST}"
else
  rm -f "$MANIFEST_TMP"
fi

# --- summary ------------------------------------------------------------
log ""
log "Summary"
log "  created      : ${N_CREATED}"
log "  filled       : ${N_FILLED}"
log "  updated      : ${N_UPDATED}"
log "  outdated     : ${N_OUTDATED}"
log "  up to date   : ${N_OK}"
log "  re-patched   : ${N_REPATCHED}"
log "  nonconformant: ${N_NONCONF}"
log "  missing      : ${N_MISSING}"
log "  orphaned     : ${N_ORPHAN}"
log "  failed       : ${N_FAILED}"

status=0
(( N_FAILED )) && status=1
if (( CHECK )) && (( N_MISSING || N_OUTDATED || N_NONCONF || N_ORPHAN )); then status=1; fi
exit "$status"
