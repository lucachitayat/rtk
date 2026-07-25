#!/usr/bin/env bash
# simulate-stale-origin.sh — build a branch that is BEHIND its own origin, so the
# stale-base guards can actually be observed firing.
#
# Guards exercised:
#   scripts/upgrade-check.sh  → the "⚠ STALE BASE" block in the Divergence section
#   scripts/rtk-upgrade.sh    → assert_not_behind_origin (apply refuses, tree untouched)
#
# Incident this reproduces (2026-07-24): local `develop` was one commit behind
# `origin/develop`; `check` never looked at `origin`, so a 231-commit upstream sync ran onto
# a stale base, duplicated a fix that had already landed two weeks earlier, and only failed
# at `git push` after every gate had passed.
#
# Everything created is LOCAL: a scratch worktree, a throwaway branch, and a remote-tracking
# ref (a plain local pointer under refs/remotes/ — no network, no push, no real branch moved).
#
# Usage:  bash simulate-stale-origin.sh {setup | teardown}

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

WT_DIR="/tmp/rtk-debug-stale-origin"
BRANCH="debug/stale-origin"
FAKE_REF="refs/remotes/origin/${BRANCH}"
BEHIND_BY="${BEHIND_BY:-2}"   # how many commits the branch should trail its remote

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
dim()  { printf "\033[2m%s\033[0m\n" "$*"; }
grn()  { printf "\033[32m%s\033[0m\n" "$*"; }
red()  { printf "\033[31m%s\033[0m\n" "$*"; }

teardown() {
  git worktree remove --force "$WT_DIR" 2>/dev/null
  git update-ref -d "$FAKE_REF" 2>/dev/null
  git branch -D "$BRANCH" 2>/dev/null
  # Confirm nothing survived — a stray fake remote ref would silently skew a later real check.
  local leftover
  leftover=$(git for-each-ref --format='%(refname)' | grep -c "$BRANCH")
  if [ "$leftover" = "0" ]; then grn "✓ torn down (no leftover refs or worktrees)"
  else red "✗ $leftover leftover ref(s) matching $BRANCH — remove by hand"; return 1; fi
}

setup() {
  teardown >/dev/null 2>&1   # idempotent

  local tip base
  tip=$(git rev-parse HEAD)
  base=$(git rev-parse "HEAD~${BEHIND_BY}" 2>/dev/null) || {
    red "✗ current branch has fewer than ${BEHIND_BY} commits — set BEHIND_BY lower"; return 1; }

  # The remote-tracking ref points at the NEWER commit; the working branch sits BEHIND it.
  git update-ref "$FAKE_REF" "$tip" || return 1
  git worktree add "$WT_DIR" -b "$BRANCH" "$base" >/dev/null 2>&1 || {
    red "✗ could not create worktree at $WT_DIR"; return 1; }

  # Test the WORKING-TREE scripts, not what happens to be committed at $base.
  cp scripts/upgrade-check.sh scripts/rtk-upgrade.sh "$WT_DIR/scripts/" || return 1
  # …and commit them, or apply's clean-tree guard fires before the guard under test.
  # This also makes the branch AHEAD as well as behind — the diverged case, which is the
  # harder one and the one that actually bit us.
  git -C "$WT_DIR" add -A >/dev/null 2>&1
  git -C "$WT_DIR" commit -q -m "debug: scenario scaffold (not for merge)" >/dev/null 2>&1

  bold "=== stale-origin scenario ready ==="
  echo "  worktree : $WT_DIR"
  echo "  branch   : $BRANCH  ($(git rev-list --count "${BRANCH}..${FAKE_REF}") behind, $(git rev-list --count "${FAKE_REF}..${BRANCH}") ahead of its origin)"
  echo
  dim "Run these from the worktree:"
  echo "  cd $WT_DIR && bash scripts/rtk-upgrade.sh check    # expect: ⚠ STALE BASE"
  echo "  cd $WT_DIR && bash scripts/rtk-upgrade.sh apply    # expect: ✗ refusing to merge onto a stale base"
  echo
  dim "Then: bash ${BASH_SOURCE[0]} teardown"
}

case "${1:-}" in
  setup)    setup ;;
  teardown) teardown ;;
  *)        echo "usage: bash $(basename "${BASH_SOURCE[0]}") {setup | teardown}"; exit 2 ;;
esac
