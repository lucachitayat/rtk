#!/usr/bin/env bash
# upgrade-check.sh — Decide whether to merge upstream into this RTK fork.
#
# Workflow:
#   1. Fetch upstream
#   2. Show divergence (develop vs upstream/develop, develop vs upstream/master)
#   3. List new upstream commits and the files they touch
#   4. Highlight commits touching high-traffic filter paths (where output really changes)
#   5. Pull `rtk gain --history` so the high-traffic list is live, not stale
#   6. Print a defer-or-upgrade recommendation
#
# Usage:  bash scripts/upgrade-check.sh
# No flags. Read the output and decide.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# High-traffic paths — touching these changes output the user actually sees.
# DRIFT GUARD: update this list (and the FORK_INVARIANTS in post-merge-verify.sh)
# whenever you add or remove a high-traffic fork filter.
HOT_PATHS=(
  "src/cmds/system/grep"
  "src/cmds/system/read"
  "src/cmds/system/find"
  "src/cmds/git/"
  "src/cmds/dotnet/"
  "src/cmds/cloud/"
  "src/core/toml_filter.rs"
  "src/core/utils.rs"
  "filters/"
)

# Classify one commit's impact on a hot path: behavioral (bias: investigate) vs
# confidently inert (clippy/whitespace). A HINT that AUGMENTS — never replaces —
# inspection; the recommendation always prints the `git show` escape hatch.
classify_commit() {
  local sha="$1" path="$2" code
  code=$(git show --format= "$sha" -- "$path" 2>/dev/null | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' || true)
  if [ -z "$code" ]; then
    echo "[whitespace?]"
  elif printf '%s\n' "$code" | grep -qE 'Regex::new|format!|write!|writeln!|truncate|\.take\(|\.skip\(|=>|[<>]=|push_str|MAX|LIMIT|const |struct |fn |return ' ; then
    echo "[behavioral?]"
  else
    echo "[clippy-only?]"
  fi
}

bold()   { printf "\033[1m%s\033[0m\n" "$*"; }
dim()    { printf "\033[2m%s\033[0m\n" "$*"; }
hot()    { printf "\033[33m%s\033[0m\n" "$*"; }
green()  { printf "\033[32m%s\033[0m\n" "$*"; }

bold "=== RTK upgrade-check ==="
echo "repo: $REPO_ROOT"
echo "branch: $(git rev-parse --abbrev-ref HEAD)"
echo "fork head: $(git log -1 --oneline HEAD)"
echo

bold "── Fetching upstream ──"
if ! git remote get-url upstream >/dev/null 2>&1; then
  echo "FAIL: 'upstream' remote not configured. Run: git remote add upstream git@github.com:rtk-ai/rtk.git"
  exit 1
fi
# Fetch branches only; skip tags to avoid local-tag conflicts (e.g. 'latest').
git fetch upstream develop master 2>&1 | tail -5 || true
echo

bold "── Divergence ──"
DEV_BEHIND=$(git rev-list --count develop..upstream/develop 2>/dev/null || echo "?")
DEV_AHEAD=$(git rev-list --count upstream/develop..develop 2>/dev/null || echo "?")
MASTER_BEHIND=$(git rev-list --count develop..upstream/master 2>/dev/null || echo "?")
echo "develop behind upstream/develop: $DEV_BEHIND commits  (develop is the merge source)"
echo "develop ahead  of upstream/develop: $DEV_AHEAD commits"
dim "develop behind upstream/master:  $MASTER_BEHIND commits  (informational — fork syncs from develop)"
# Version delta — apply will retrack fork to <develop-base>-dev-fork.N (see SKILL.md § Versioning).
FORK_VER=$(grep -m1 '^version' Cargo.toml | sed -E 's/.*"(.*)".*/\1/')
UP_DEV_VER=$(git show upstream/develop:Cargo.toml 2>/dev/null | grep -m1 '^version' | sed -E 's/.*"(.*)".*/\1/')
UP_MAS_VER=$(git show upstream/master:Cargo.toml 2>/dev/null | grep -m1 '^version' | sed -E 's/.*"(.*)".*/\1/')
dim "version: fork ${FORK_VER:-?} | develop ${UP_DEV_VER:-?} | master ${UP_MAS_VER:-?}"
echo

# The fork syncs from upstream/develop; master-ahead is informational only, never a merge source.
if [ "$DEV_BEHIND" = "0" ]; then
  green "✓ Fork is current vs upstream/develop (the merge source)."
  if [ "$MASTER_BEHIND" != "0" ] && [ "$MASTER_BEHIND" != "?" ]; then
    dim "  ($MASTER_BEHIND commits ahead on upstream/master — not a sync source; ignore unless retargeting.)"
  fi
  echo
  echo "RECOMMENDATION: CURRENT"
  exit 0
fi

bold "── New upstream/develop commits ──"
if [ "$DEV_BEHIND" != "0" ]; then
  git log --pretty=format:'%h %ai %s' develop..upstream/develop
  echo
else
  dim "(none)"
fi
echo

bold "── Files touched by new upstream/develop commits ──"
dim "(three-dot upstream-side delta since the merge-base — only what the merge brings in; fork-only files are NOT listed)"
# THREE-DOT (develop...upstream/develop): files changed on the UPSTREAM side since the
# merge-base — i.e. exactly what the merge brings in. Two-dot (develop..upstream/develop)
# symmetrically diffs the two endpoints and renders the fork's own commits as huge
# "deletions" (FORK_NOTES.md, scripts/, az_cmd.rs, …) — misleading, and it once triggered
# a false-alarm investigation. This list mirrors the merge-tree preview below.
git diff --stat develop...upstream/develop | tail -40
echo

bold "── Commits touching HIGH-TRAFFIC filter paths ──"
HOT_HITS=0
for path in "${HOT_PATHS[@]}"; do
  HITS=$(git log --oneline develop..upstream/develop -- "$path" 2>/dev/null || true)
  if [ -n "$HITS" ]; then
    hot "  $path"
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      sha="${line%% *}"
      tag=$(classify_commit "$sha" "$path")
      echo "    $line  $tag"
      HOT_HITS=$((HOT_HITS + 1))
    done <<< "$HITS"
  fi
done
if [ "$HOT_HITS" = "0" ]; then
  green "  ✓ None. No high-traffic filter paths touched."
fi
echo

# Read-only 3-way merge simulation — authoritative answer to "will this conflict?".
# Needs git >= 2.38. Exit 0 = clean (prints a bare tree OID); exit 1 = conflicts
# (OID line followed by the conflicted paths under --name-only).
bold "── Merge preview (read-only dry run) ──"
CONFLICTS=""
MERGE_OUT=$(git merge-tree --write-tree --name-only develop upstream/develop 2>/dev/null) && MT_RC=0 || MT_RC=$?
if [ "$MT_RC" = "0" ]; then
  green "  ✓ Clean 3-way merge — zero conflicts."
elif [ "$MT_RC" = "1" ]; then
  CONFLICTS=$(printf '%s\n' "$MERGE_OUT" | tail -n +2 | sed '/^$/d')
  CONFLICT_N=$(printf '%s\n' "$CONFLICTS" | grep -c . || true)
  hot "  ⚠ Merge has conflicts in $CONFLICT_N file(s) — resolve these on merge:"
  printf '%s\n' "$CONFLICTS" | sed 's/^/      /'
else
  dim "  (merge-tree unavailable — needs git >= 2.38; current $(git --version | awk '{print $3}'))"
  CONFLICTS="?"
fi
echo

bold "── Live top-10 commands (from rtk gain) ──"
if command -v rtk >/dev/null 2>&1; then
  rtk gain --history 2>/dev/null | sed -n '/By Command/,/^Recent/p' | head -20 || dim "(rtk gain failed)"
else
  dim "(rtk not on PATH — skipping live usage check)"
fi
echo

# Emit a ready-to-paste post-merge verification block, tailored to the commits found.
emit_verification_block() {
  bold "── Post-merge verification (copy-paste) ──"
  echo "  cargo fmt --all && cargo clippy --all-targets && cargo test --all"
  local subjects
  subjects=$(git log --pretty=format:'%h %s' develop..upstream/develop 2>/dev/null)
  if printf '%s\n' "$subjects" | grep -qiE 'sigpipe|broken.?pipe'; then
    echo "  # SIGPIPE fix detected → must NOT exit 134:"
    echo "      target/release/rtk grep -rn 'fn ' src/ | head -3 >/dev/null; echo \$?"
  fi
  if printf '%s\n' "$subjects" | grep -qiE '\bgh\b|\bglab\b'; then
    echo "  # gh/glab change detected → must NOT print 'number required':"
    echo "      target/release/rtk gh pr view 2>&1 | head -5"
  fi
  echo "  # Or run the full gate + checks in one shot:  bash scripts/post-merge-verify.sh"
}

bold "── Recommendation ──"
if [ "$HOT_HITS" = "0" ]; then
  green "DEFER. Upstream has $DEV_BEHIND new commits but none touch high-traffic filter paths."
  echo "Merging now buys no behavioral value for this user's top commands."
  if [ -n "$CONFLICTS" ] && [ "$CONFLICTS" != "?" ]; then
    echo "(Merge would also need conflict resolution — see preview above.)"
  fi
  echo
  echo "Re-run this when:"
  echo "  - rtk init bug bites you (then init --dry-run / Cursor BOM fix may matter)"
  echo "  - a future run shows hot-path hits"
  echo "  - rolling cadence: monthly checkpoint"
else
  hot "INVESTIGATE. Upstream touches $HOT_HITS commit(s) in high-traffic filter paths."
  if [ -z "$CONFLICTS" ]; then
    green "  Merge is conflict-free (see preview) — low cost to take."
  elif [ "$CONFLICTS" != "?" ]; then
    hot "  Merge also has conflicts to resolve (see preview) — factor into cost."
  fi
  echo "Tags above are HINTS (bias: investigate). To confirm any commit:"
  echo "  git show <sha> -- <path>"
  echo "Judge: clippy/whitespace = ignore, regex/format/truncation = real impact."
  echo "If real impact: merge. If clippy-only: defer (verify by snapshot diff)."
  echo
  emit_verification_block
fi

# Machine-stable trailer — the dispatcher (rtk-upgrade.sh) parses this last line.
echo
if [ "$HOT_HITS" = "0" ]; then
  echo "RECOMMENDATION: DEFER"
else
  echo "RECOMMENDATION: INVESTIGATE"
fi
