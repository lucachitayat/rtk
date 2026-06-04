#!/usr/bin/env bash
# rtk-upgrade.sh — thin orchestrator for the RTK fork upgrade flow.
#
# Two subcommands, so the agent runs at most two commands and never improvises:
#   check  — fetch + upgrade-check.sh; ends with a machine-stable RECOMMENDATION + `next:` line
#            (the agent runs the printed `next:` command — it does not re-derive it).
#   apply  — re-preview at merge time, merge upstream/develop with a SCRIPTED abort path, then
#            post-merge-verify.sh. Leaves the merge COMMITTED-BUT-UNPUSHED; the push is gated by
#            the human / skill, never here.
#
# The real work lives in the companions: scripts/upgrade-check.sh, scripts/post-merge-verify.sh.
# Orchestration contract: .claude/skills/rtk-upgrade-2/SKILL.md.
#
# Usage:  bash scripts/rtk-upgrade.sh {check | apply [ref]}
#   ref — optional explicit merge target (default: upstream/develop). Per-invocation only.

set -uo pipefail   # NOT -e: a no-match grep must not abort the orchestrator.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

bold()  { printf "\033[1m%s\033[0m\n" "$*"; }
dim()   { printf "\033[2m%s\033[0m\n" "$*"; }
fail()  { printf "\033[31m✗ %s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }

usage() { echo "usage: bash scripts/rtk-upgrade.sh {check | apply [ref]}"; exit 2; }

cmd_check() {
  # upgrade-check.sh fetches upstream and prints the full decision report, ending with a
  # machine-stable `RECOMMENDATION: CURRENT|DEFER|INVESTIGATE` line we map to a next command.
  local out rec
  out=$(bash scripts/upgrade-check.sh)
  printf '%s\n' "$out"
  rec=$(printf '%s\n' "$out" | grep -E '^RECOMMENDATION:' | tail -1 | awk '{print $2}')
  echo
  bold "── Next ──"
  case "$rec" in
    INVESTIGATE)  echo "next: bash scripts/rtk-upgrade.sh apply" ;;
    DEFER|CURRENT) echo "next: (none — fork needs no merge)" ;;
    *)            echo "next: (no recommendation parsed — read the report above)" ;;
  esac
}

cmd_apply() {
  # Merge target — defaults to upstream/develop (the sync source). An optional ref
  # ARGUMENT retargets the merge (e.g. `apply upstream/master`, or a local branch when
  # testing). It is explicit per-invocation — never ambient — so it cannot silently
  # leak into a later run. The default target is refreshed from the remote first; an
  # explicit override is assumed already-local and is not fetched.
  local target="${1:-upstream/develop}"

  bold "=== RTK upgrade apply ==="
  echo "branch: $(git rev-parse --abbrev-ref HEAD)   target: $target"

  if [ "$target" = "upstream/develop" ]; then
    git fetch upstream develop 2>&1 | tail -3 || true
  fi

  # Refuse to entangle a merge with uncommitted work.
  if [ -n "$(git status --porcelain)" ]; then
    fail "working tree not clean — commit or stash first. Tree untouched."
    exit 1
  fi

  # Re-run the read-only preview at merge time against HEAD (authoritative, unlike a stale check).
  git merge-tree --write-tree --name-only HEAD "$target" >/tmp/rtk_mt.txt 2>/dev/null
  local mt_rc=$?
  if [ "$mt_rc" = "0" ]; then
    green "✓ Merge preview clean — proceeding."
  elif [ "$mt_rc" = "1" ]; then
    fail "merge preview shows conflicts — refusing to auto-merge. Conflicting paths:"
    tail -n +2 /tmp/rtk_mt.txt | sed '/^$/d' | sed 's/^/    /'
    echo "Resolve by hand, or merge manually. Tree untouched."
    exit 1
  else
    dim "(merge-tree unavailable — needs git >= 2.38; proceeding with a guarded real merge.)"
  fi

  local n sha
  n=$(git rev-list --count "HEAD..$target" 2>/dev/null || echo "?")
  sha=$(git rev-parse --short "$target" 2>/dev/null || echo "?")

  bold "── Merging $target ($n commits @ $sha) ──"
  if git merge --no-ff "$target" -m "merge: sync $target @ $sha ($n commits)"; then
    green "✓ Merge committed (NOT pushed)."
  else
    local conflicts
    conflicts=$(git diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ' ')
    git merge --abort 2>/dev/null || true
    fail "merge aborted — conflicts in: ${conflicts:-<unknown>}. Tree restored to pre-merge HEAD."
    exit 1
  fi
  echo

  bash scripts/post-merge-verify.sh
  local rc=$?
  echo
  if [ "$rc" = "0" ]; then
    green "✓ All gates passed. Merge is committed but UNPUSHED — confirm before pushing."
  else
    fail "Gates failed (rc=$rc). The merge is already committed."
    dim "  To undo the merge: git reset --hard ORIG_HEAD   (returns to pre-merge HEAD)"
  fi
  exit "$rc"
}

case "${1:-}" in
  check) cmd_check ;;
  apply) cmd_apply "${2:-}" ;;
  *)     usage ;;
esac
