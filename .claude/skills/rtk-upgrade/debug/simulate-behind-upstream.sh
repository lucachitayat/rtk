#!/usr/bin/env bash
# simulate-behind-upstream.sh — put HEAD genuinely behind upstream/develop so the
# decision path that only runs on a NON-current fork can be observed.
#
# Guards exercised:
#   scripts/upgrade-check.sh → the HEAD-relative divergence line, the CURRENT early-exit,
#                              the merge preview, its branch-name banner, and INVESTIGATE/DEFER
#
# Incident this reproduces (2026-07-24): the merge preview was moved to follow HEAD, but the
# CURRENT early-exit above it still keyed on `develop`. On a branch behind upstream while
# `develop` was current, check printed CURRENT and exited before ever reaching the preview —
# the fix was dead code in exactly the scenario it was written for. Running check normally
# after a successful sync reports CURRENT and proves nothing.
#
# Detached HEAD is deliberate: it also covers the `detached@<sha>` branch-label path, and it
# cannot move a real branch.
#
# Usage:  bash simulate-behind-upstream.sh {setup [commit-ish] | teardown}
#         Default commit-ish: the merge-base of HEAD and upstream/develop.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

WT_DIR="/tmp/rtk-debug-behind-upstream"

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
dim()  { printf "\033[2m%s\033[0m\n" "$*"; }
grn()  { printf "\033[32m%s\033[0m\n" "$*"; }
red()  { printf "\033[31m%s\033[0m\n" "$*"; }

teardown() {
  git worktree remove --force "$WT_DIR" 2>/dev/null
  if [ -d "$WT_DIR" ]; then red "✗ $WT_DIR still present — remove by hand"; return 1; fi
  grn "✓ torn down"
}

setup() {
  teardown >/dev/null 2>&1   # idempotent

  git rev-parse --verify upstream/develop >/dev/null 2>&1 || {
    red "✗ upstream/develop not fetched — run: git fetch upstream develop"; return 1; }

  local target behind
  target="${1:-}"

  if [ -z "$target" ]; then
    # Default #1: the merge-base. Correct BEFORE a sync; useless right after one, because once
    # the fork is fully merged the merge-base IS upstream's tip (0 behind).
    target=$(git merge-base HEAD upstream/develop)
    if [ "$(git rev-list --count "${target}..upstream/develop")" = "0" ]; then
      # Default #2: the fork state immediately before the last sync. `apply` writes merge commits
      # with the stable subject "merge: sync <ref> @ <sha> (<n> commits)", so that merge's FIRST
      # parent is the pre-sync tip — exactly the state we want to reproduce.
      local last_sync
      last_sync=$(git log --merges --format='%H %s' | grep -m1 '^[0-9a-f]* merge: sync' | cut -d' ' -f1)
      if [ -n "$last_sync" ]; then
        target="${last_sync}^1"
        dim "  (fork is current; defaulting to the pre-sync tip $(git rev-parse --short "$target"))"
      fi
    fi
  fi

  git rev-parse --verify "$target" >/dev/null 2>&1 || { red "✗ bad commit-ish: $target"; return 1; }

  behind=$(git rev-list --count "${target}..upstream/develop")
  if [ "$behind" = "0" ]; then
    red "✗ $target is not behind upstream/develop — nothing to reproduce."
    dim "   Pass an explicit pre-sync commit-ish, e.g. the first parent of a 'merge: sync' commit:"
    dim "     git log --merges --oneline | grep 'merge: sync'"
    return 1
  fi

  git worktree add --detach "$WT_DIR" "$target" >/dev/null 2>&1 || {
    red "✗ could not create worktree at $WT_DIR"; return 1; }

  # Test the WORKING-TREE scripts, not the (older) ones committed at $target — otherwise you
  # are exercising the very version whose bug you are trying to reproduce a fix for.
  cp scripts/upgrade-check.sh scripts/rtk-upgrade.sh "$WT_DIR/scripts/" || return 1

  bold "=== behind-upstream scenario ready ==="
  echo "  worktree : $WT_DIR"
  echo "  HEAD     : $(git rev-parse --short "$target") (detached, $behind commits behind upstream/develop)"
  echo
  dim "Run from the worktree:"
  echo "  cd $WT_DIR && bash scripts/rtk-upgrade.sh check"
  echo
  dim "Expect: a HEAD-relative 'behind upstream/develop' line, a merge preview naming the"
  dim "branch it was computed for, and RECOMMENDATION: INVESTIGATE — never CURRENT."
  dim "Do NOT run apply here; the tree is dirty by design and the scenario is read-only."
  echo
  dim "Then: bash ${BASH_SOURCE[0]} teardown"
}

case "${1:-}" in
  setup)    shift; setup "${1:-}" ;;
  teardown) teardown ;;
  *)        echo "usage: bash $(basename "${BASH_SOURCE[0]}") {setup [commit-ish] | teardown}"; exit 2 ;;
esac
