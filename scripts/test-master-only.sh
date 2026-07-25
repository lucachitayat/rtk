#!/usr/bin/env bash
# test-master-only.sh — hermetic tests for check_master_only (scripts/lib/master-only.sh).
#
# Builds a throwaway git repo with synthetic fork / upstream-develop /
# upstream-master branches and asserts the master-only detector:
#   1. flags an UNPORTED master-only security commit (🔴, counts as security)
#   2. flags an UNPORTED master-only plain fix       (⚠, not security)
#   3. SUPPRESSES a fix already cited by SHA in a fork commit body
#      (the `git cherry-pick -x` / hand-port-with-reference convention)
#   4. SUPPRESSES every master commit once it is merged into the fork (ancestry)
#   5. SUPPRESSES release-please / chore / ci noise
#
# Real master-only fixes are rare, so this fixture is the primary proof the
# alert path works. Run standalone:  bash scripts/test-master-only.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/master-only.sh
source "$REPO_ROOT/scripts/lib/master-only.sh"

PASS=0
FAIL=0
check() { # check <description> <result(0=ok)>
  if [ "$2" = "0" ]; then PASS=$((PASS + 1)); printf "  \033[32mok\033[0m   %s\n" "$1"
  else FAIL=$((FAIL + 1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# `cd` into the fixture repo rather than exporting GIT_DIR / GIT_WORK_TREE. Those two are
# inherited by every child process and, if a sibling fixture is ever SOURCED from the same
# shell instead of run as a subprocess, they would silently redirect that fixture's — or the
# gate's own — git commands at this throwaway repo.
cd "$TMP"
git init -q
git config user.email t@t.t
git config user.name t
# This machine has commit.gpgsign=true globally; a runner without a signing key would abort
# every commit below and the fixture would fail for a reason having nothing to do with the
# detector under test.
git config commit.gpgsign false
# DOMAIN CONTROL: prove the fixture is operating on the throwaway repo and not on the real
# one. Everything below commits, merges and branches freely, so a `git init` that silently
# did not take effect must abort rather than run against the working tree. `pwd -P` on both
# sides because macOS mktemp hands back a /var symlink into /private/var.
fixture_root="$(cd "$(git rev-parse --show-toplevel)" && pwd -P)"
if [ "$fixture_root" != "$(cd "$TMP" && pwd -P)" ]; then
  echo "FATAL: fixture git root is '$fixture_root', expected '$TMP' — refusing to run" >&2
  exit 1
fi

commit() { # commit <subject> [body] ; each touches a UNIQUE file (mktemp) so
           # branches never conflict and subshell ($(commit ...)) calls stay distinct.
  local f
  f=$(mktemp "$TMP/fXXXXXX")
  echo "$f" > "$f"
  git add -A
  if [ -n "${2:-}" ]; then git commit -q -m "$1" -m "$2"; else git commit -q -m "$1"; fi
  git rev-parse --short HEAD
}

# --- shared base ---
commit "init" >/dev/null
BASE=$(git rev-parse --short HEAD)

# --- upstream/develop: one ordinary feature ---
git checkout -q -b upstream-develop
commit "feat(x): develop feature" >/dev/null

# --- upstream/master: branches from BASE, carries master-only commits ---
git checkout -q -b upstream-master "$BASE"
SEC_UNPORTED=$(commit "fix(security): harden the thing")
FIX_UNPORTED=$(commit "fix(parser): off-by-one")
SEC_PORTED=$(commit "fix(security): patch CVE-2026-9999")
commit "chore(master): release 9.9.9" >/dev/null
commit "ci: bump action" >/dev/null

# --- fork develop: from BASE; ports ONE master fix by body-reference ---
git checkout -q -b fork "$BASE"
commit "fix(security): port CVE patch" "Port of upstream/master ${SEC_PORTED} adapted for the fork." >/dev/null

echo "── Scenario A: unported detection + body-reference & noise suppression ──"
# Redirect (not $(...)) so the function runs in THIS shell and MASTER_* counters
# propagate — exactly how upgrade-check.sh calls it.
check_master_only fork upstream-develop upstream-master > "$TMP/outA.txt"
OUT=$(cat "$TMP/outA.txt")
printf '%s\n' "$OUT" | sed 's/^/    /'
echo "  (MASTER_UNPORTED=$MASTER_UNPORTED MASTER_SECURITY=$MASTER_SECURITY)"
echo

printf '%s' "$OUT" | grep -q "🔴 SECURITY  ${SEC_UNPORTED}" && r=0 || r=1
check "unported security commit flagged 🔴" "$r"

printf '%s' "$OUT" | grep -q "⚠ unported  ${FIX_UNPORTED}" && r=0 || r=1
check "unported plain fix flagged ⚠ (not security)" "$r"

printf '%s' "$OUT" | grep -q "✓ ported    ${SEC_PORTED}" && r=0 || r=1
check "SHA-in-body port suppressed (✓ ported)" "$r"

[ "$MASTER_UNPORTED" = "2" ] && r=0 || r=1
check "exactly 2 unported (CVE-port + chore + ci suppressed)" "$r"

[ "$MASTER_SECURITY" = "1" ] && r=0 || r=1
check "exactly 1 unported security" "$r"

printf '%s' "$OUT" | grep -qiE 'release|chore|\bci\b' && r=1 || r=0
check "release/chore/ci noise never printed" "$r"

# --- Scenario B: ancestry suppression via a direct merge ---
echo "── Scenario B: ancestry suppression (direct merge) ──"
git checkout -q -b fork2 "$BASE"
git merge -q --no-edit upstream-master   # all master SHAs become ancestors of fork2
check_master_only fork2 upstream-develop upstream-master >/dev/null
echo "  (MASTER_UNPORTED=$MASTER_UNPORTED MASTER_SECURITY=$MASTER_SECURITY)"
[ "$MASTER_UNPORTED" = "0" ] && r=0 || r=1
check "all master commits suppressed by ancestry after merge" "$r"

# --- Scenario C: no master-only commits at all ---
echo "── Scenario C: empty (develop == master) ──"
check_master_only upstream-develop upstream-develop upstream-develop >/dev/null
[ "$MASTER_UNPORTED" = "0" ] && r=0 || r=1
check "no false positives when there is nothing master-only" "$r"

echo
echo "── Result: $PASS passed, $FAIL failed ──"
[ "$FAIL" = "0" ]
