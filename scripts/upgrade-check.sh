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
# Keep in sync with memory/rtk_upgrade_check.md.
HOT_PATHS=(
  "src/cmds/system/grep"
  "src/cmds/system/read"
  "src/cmds/git/"
  "src/cmds/dotnet/"
  "src/cmds/cloud/"
  "src/core/toml_filter.rs"
  "src/core/utils.rs"
  "filters/"
)

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
echo "develop behind upstream/develop: $DEV_BEHIND commits"
echo "develop ahead  of upstream/develop: $DEV_AHEAD commits"
echo "develop behind upstream/master:  $MASTER_BEHIND commits"
echo

if [ "$DEV_BEHIND" = "0" ] && [ "$MASTER_BEHIND" = "0" ]; then
  green "✓ Fork is current. No upstream commits to merge."
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
git diff --stat develop..upstream/develop | tail -40
echo

bold "── Commits touching HIGH-TRAFFIC filter paths ──"
HOT_HITS=0
for path in "${HOT_PATHS[@]}"; do
  HITS=$(git log --oneline develop..upstream/develop -- "$path" 2>/dev/null)
  if [ -n "$HITS" ]; then
    hot "  $path"
    echo "$HITS" | sed 's/^/    /'
    HOT_HITS=$((HOT_HITS + $(echo "$HITS" | wc -l)))
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
  echo "For each commit listed above:"
  echo "  git show <sha> -- <path>"
  echo "Judge: clippy/whitespace = ignore, regex/format/truncation = real impact."
  echo "If real impact: merge. If clippy-only: defer (verify by snapshot diff)."
  echo
  emit_verification_block
fi
