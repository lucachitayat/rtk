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

bold "── Live top-10 commands (from rtk gain) ──"
if command -v rtk >/dev/null 2>&1; then
  rtk gain --history 2>/dev/null | sed -n '/By Command/,/^Recent/p' | head -20 || dim "(rtk gain failed)"
else
  dim "(rtk not on PATH — skipping live usage check)"
fi
echo

bold "── Recommendation ──"
if [ "$HOT_HITS" = "0" ]; then
  green "DEFER. Upstream has $DEV_BEHIND new commits but none touch high-traffic filter paths."
  echo "Merging now buys no behavioral value for this user's top commands and risks conflict"
  echo "with fork-specific code (MCP rewrite/proxy, az filter, FORK_NOTES.md)."
  echo
  echo "Re-run this when:"
  echo "  - rtk init bug bites you (then init --dry-run / Cursor BOM fix may matter)"
  echo "  - a future run shows hot-path hits"
  echo "  - rolling cadence: monthly checkpoint"
else
  hot "INVESTIGATE. Upstream touches $HOT_HITS commit(s) in high-traffic filter paths."
  echo "For each commit listed above:"
  echo "  git show <sha> -- <path>"
  echo "Judge: clippy/whitespace = ignore, regex/format/truncation = real impact."
  echo "If real impact: merge. If clippy-only: defer (verify by snapshot diff)."
fi
