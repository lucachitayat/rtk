#!/usr/bin/env bash
# post-merge-verify.sh — Standardized checks to run AFTER syncing upstream into the fork.
#
# Companion to upgrade-check.sh. Run on the merged branch (develop or a sync branch)
# once `git merge upstream/develop` is done. Verifies the merge didn't break the build
# or silently regress the behavior changes upstream introduced.
#
# Workflow:
#   1. Quality gate    — cargo fmt --check, clippy --all-targets, test --all
#   2. Release build   — enterprise distro build + gated tests (skipped where the feature
#                        doesn't exist), then the default build needed for spot-checks
#   3. Behavior checks — SIGPIPE (no SIGABRT on broken pipe), gh no-id forwarding
#   4. Divergence      — confirm fully merged (behind upstream = 0), fork commits retained
#   5. Version sanity  — fork Cargo.toml version base >= upstream
#
# Usage:  bash scripts/post-merge-verify.sh
# Exit:   0 if all gates pass, 1 otherwise. Each check reports independently.

set -uo pipefail   # NOT -e: run every check and report, don't bail on first failure

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

bold()  { printf "\033[1m%s\033[0m\n" "$*"; }
dim()   { printf "\033[2m%s\033[0m\n" "$*"; }
pass()  { printf "\033[32m  ✓ %s\033[0m\n" "$*"; }
fail()  { printf "\033[31m  ✗ %s\033[0m\n" "$*"; }
warn()  { printf "\033[33m  ⚠ %s\033[0m\n" "$*"; }

# First ~15 error-ish lines of a build/test log → inline digest. The FULL log stays
# in /tmp (out of context); render only enough to diagnose without paginating.
digest() { grep -nE 'error\[|error:|^error|warning:|^test .* FAILED|--> ' "$1" 2>/dev/null | head -15 | sed 's/^/      /' || true; }

# Fork-invariant helpers (quiet — never dump matched lines into output).
inv_exists() { if [ -e "$1" ]; then pass "$2"; else fail "$2 (missing: $1)"; RC=1; fi; }
inv_absent() { if [ -e "$1" ]; then fail "$2 (should be absent: $1)"; RC=1; else pass "$2"; fi; }
inv_grep()   { if grep -rlqF -- "$1" "$2" 2>/dev/null; then pass "$3"; else fail "$3 (pattern gone from $2)"; RC=1; fi; }

RC=0

bold "=== RTK post-merge verify ==="
echo "branch: $(git rev-parse --abbrev-ref HEAD)   head: $(git log -1 --oneline HEAD)"
echo

# ── 1. Quality gate ───────────────────────────────────────────────────────────
bold "── Quality gate ──"
if cargo fmt --all -- --check >/dev/null 2>&1; then pass "cargo fmt --all --check"; else fail "cargo fmt — run 'cargo fmt --all'"; RC=1; fi
if cargo clippy --all-targets >/tmp/pmv_clippy.txt 2>&1; then pass "cargo clippy --all-targets"; else fail "cargo clippy (digest below; full: /tmp/pmv_clippy.txt)"; digest /tmp/pmv_clippy.txt; RC=1; fi
if cargo test --all >/tmp/pmv_test.txt 2>&1; then
  pass "cargo test --all ($(grep -hoE '[0-9]+ passed' /tmp/pmv_test.txt | head -1))"
else
  fail "cargo test (digest below; full: /tmp/pmv_test.txt)"; digest /tmp/pmv_test.txt; RC=1
fi
# Shell-script tests (NOT covered by cargo): the master-only fix detector.
if bash scripts/test-master-only.sh >/tmp/pmv_shtest.txt 2>&1; then
  pass "shell tests ($(grep -hoE '[0-9]+ passed' /tmp/pmv_shtest.txt | head -1) — master-only detector)"
else
  fail "shell tests (digest below; full: /tmp/pmv_shtest.txt)"; digest /tmp/pmv_shtest.txt; RC=1
fi
echo

# ── 2. Release build (needed for behavior checks) ───────────────────────────────
bold "── Release build ──"

# Enterprise distro build. Without this, the FIRST thing that catches a merge which broke
# `--features enterprise` is export-enterprise.sh step 6d — i.e. at release time, long after
# the sync. Deliberately runs BEFORE the default release build: both write
# target/release/rtk, and §3's behavior spot-checks must exercise the DEFAULT binary.
#
# Scope, deliberately narrow — two assertions, both green by construction on a healthy tree:
#   1. the release build under --features enterprise COMPILES (the actual distro risk, and
#      what exercises build.rs's egress guard);
#   2. the fork-only enterprise/hardening tests pass under that feature.
# We do NOT run the whole suite with --features enterprise. auto_allow_enabled() is
# `!cfg!(feature = "enterprise") && env RTK_NO_AUTO_ALLOW unset`, so under the feature it is
# false BY DESIGN and ~7 upstream auto-allow tests fail there by construction. A gate step
# that is permanently red is worse than no gate step at all.
# Both invocations run with RTK_NO_AUTO_ALLOW unset so a dev shell that exports it (the
# runtime equivalent of the same opt-out) cannot poison the default-build comparison.
#
# DRIFT GUARD: `develop` carries no [features] block at all and this same script runs there,
# where `--features enterprise` would hard-fail with an unknown-feature error. Gate on the
# Cargo.toml probe below — NEVER on the branch name. Also update the test filter if the
# fork-only tests move out of src/hooks/hook_cmd/tests/fork_tests.rs.
if awk '/^\[features\]/{f=1;next} /^\[/{f=0} f && /^[[:space:]]*enterprise[[:space:]]*=/{ok=1} END{exit !ok}' Cargo.toml; then
  if env -u RTK_NO_AUTO_ALLOW cargo build --release --features enterprise >/tmp/pmv_ent_build.txt 2>&1; then
    pass "cargo build --release --features enterprise"
  else
    fail "enterprise build (digest below; full: /tmp/pmv_ent_build.txt)"; digest /tmp/pmv_ent_build.txt; RC=1
  fi
  if env -u RTK_NO_AUTO_ALLOW cargo test --bin rtk --features enterprise hook_cmd::tests::fork_tests >/tmp/pmv_ent_test.txt 2>&1; then
    pass "enterprise-gated tests ($(grep -hoE '[0-9]+ passed' /tmp/pmv_ent_test.txt | head -1) — hook_cmd fork_tests)"
  else
    fail "enterprise-gated tests (digest below; full: /tmp/pmv_ent_test.txt)"; digest /tmp/pmv_ent_test.txt; RC=1
  fi
else
  dim "  (skipped — no 'enterprise' feature in Cargo.toml)"
fi

if cargo build --release >/tmp/pmv_build.txt 2>&1; then pass "cargo build --release"; else fail "release build (digest below; full: /tmp/pmv_build.txt)"; digest /tmp/pmv_build.txt; RC=1; fi
BIN="target/release/rtk"
echo

# ── Fork invariants ─────────────────────────────────────────────────────────────
# DRIFT GUARD: edit these checks when you add or remove a fork feature. A green merge
# that silently drops a fork feature is the exact failure mode this section prevents.
# (Source-level — runs even when the release build above failed.)
bold "── Fork invariants ──"
inv_exists "src/cmds/cloud/az_cmd.rs"                  "Azure filter az_cmd.rs present"
inv_grep   "Commands::Az" "src/main.rs"                "Az command wired in main.rs"
inv_absent "src/mcp"                                   "MCP bridge dir removed (fork)"
inv_absent "src/hooks/mcp_rewrite_cmd.rs"              "MCP rewrite cmd removed (fork)"
inv_grep   "libc::SIGPIPE, libc::SIG_DFL" "src/main.rs" "SIGPIPE reset handler present"
inv_grep   "handle_signal" "src/main.rs"               "SIGINT/SIGTERM child-kill handler present"
inv_grep   "build_parallel" "src/cmds/system/find_cmd.rs" "find parallel-walk perf (untested-for-removal)"
inv_exists "src/core/args_utils.rs"                    "args_utils (-- restoration) present"
inv_exists "FORK_NOTES.md"                             "FORK_NOTES.md present"
# Conflict markers in src/ AND the canonical version files — quiet (-l), never dump matches.
# Match ONLY the unambiguous `<<<<<<<` / `>>>>>>>` markers, never bare `=======`: a real git
# conflict always carries the angle-bracket pair, whereas `=======` also appears as a legit
# setext-heading / decorative separator in source & docs (false-positived here on 2026-07-12,
# and again on 2026-07-24 against the pytest banner fixture upstream added in
# src/cmds/python/uv_cmd.rs — "===== test session starts =====").
if grep -rlqE '^(<{7}|>{7})' src/ Cargo.toml Cargo.lock .release-please-manifest.json 2>/dev/null; then fail "conflict markers present in src/ or version files"; RC=1; else pass "no conflict markers in src/ or version files"; fi
# Fork version marker — the §5 base-version check strips '-fork.N', so assert it survives here.
if grep -m1 '^version' Cargo.toml | grep -qF -- '-fork'; then pass "Cargo.toml version carries -fork marker"; else fail "Cargo.toml lost -fork version suffix"; RC=1; fi
echo

# ── 3. Behavior spot-checks ─────────────────────────────────────────────────────
bold "── Behavior spot-checks ──"
if [ -x "$BIN" ]; then
  # SIGPIPE: writing to a closed pipe must not SIGABRT (exit 134).
  "$BIN" grep -rn "fn " src/ 2>/dev/null | head -3 >/dev/null
  ec=$?
  if [ "$ec" = "134" ]; then fail "SIGPIPE: rtk grep | head crashed with SIGABRT (134)"; RC=1
  else pass "SIGPIPE: rtk grep | head exits $ec (no SIGABRT)"; fi

  # gh no-id: rtk must forward to gh, not pre-reject with "number required".
  if "$BIN" gh pr view 2>&1 | head -5 | grep -qi "number required"; then
    fail "gh no-id: rtk still pre-rejects 'gh pr view' with 'number required'"; RC=1
  else
    pass "gh no-id: rtk forwards 'gh pr view' (no pre-rejection)"
  fi

  # args_utils: `rtk grep <pat> -- <file>` must restore the -- separator (fork fix #1 cmd).
  if "$BIN" grep "fn main" -- src/main.rs 2>/dev/null | grep -q "fn main"; then
    pass "args_utils: 'rtk grep <pat> -- <file>' restores -- and matches"
  else
    fail "args_utils: 'rtk grep <pat> -- <file>' broke -- handling"; RC=1
  fi
else
  warn "release binary missing — skipping behavior checks"
fi
echo

# ── 4. Divergence ───────────────────────────────────────────────────────────────
bold "── Divergence vs upstream/develop ──"
if git rev-parse --verify upstream/develop >/dev/null 2>&1; then
  BEHIND=$(git rev-list --count HEAD..upstream/develop 2>/dev/null || echo "?")
  AHEAD=$(git rev-list --count upstream/develop..HEAD 2>/dev/null || echo "?")
  if [ "$BEHIND" = "0" ]; then pass "fully merged — 0 commits behind upstream/develop"; else warn "still $BEHIND behind upstream/develop"; fi
  pass "$AHEAD fork commits ahead of upstream/develop"
else
  warn "upstream/develop not fetched — run upgrade-check.sh first"
fi
echo

# ── 5. Version sanity ─────────────────────────────────────────────────────────
bold "── Version sanity ──"
fork_ver=$(grep -m1 '^version' Cargo.toml | sed -E 's/.*"(.*)".*/\1/')
up_ver=$(git show upstream/develop:Cargo.toml 2>/dev/null | grep -m1 '^version' | sed -E 's/.*"(.*)".*/\1/')
if [ -n "$up_ver" ]; then
  fork_base=${fork_ver%%-*}; up_base=${up_ver%%-*}
  lowest=$(printf '%s\n%s\n' "$fork_base" "$up_base" | sort -V | head -1)
  if [ "$fork_base" != "$up_base" ] && [ "$lowest" = "$fork_base" ]; then
    # A deferred fork legitimately trails upstream's base between syncs — WARN, never fail.
    warn "fork version ($fork_ver) base is BELOW upstream ($up_ver) — deferred, or bump on next sync"
  else
    pass "fork version $fork_ver >= upstream $up_ver (base)"
  fi
else
  dim "  (could not read upstream Cargo.toml version)"
fi

# Cross-file version consistency — reconcile MUST keep the three canonical sites in lockstep.
# This is the hard guarantee (the base check above stays a WARN to tolerate deferred forks).
manifest_ver=$(grep -oE '"\." *: *"[^"]*"' .release-please-manifest.json 2>/dev/null | sed -E 's/.*"([^"]*)" *$/\1/')
# `\r?` before each newline: tolerate CRLF Cargo.lock on Windows checkouts (else lock_ver=<none>).
lock_ver=$(perl -0777 -ne 'print $1 if /\[\[package\]\]\r?\nname = "rtk"\r?\nversion = "([^"]*)"/' Cargo.lock 2>/dev/null)
if [ "$fork_ver" = "$manifest_ver" ] && [ "$fork_ver" = "$lock_ver" ]; then
  case "$fork_ver" in
    *-dev-fork.*) pass "version consistent + fork-marked across Cargo.toml, manifest, Cargo.lock ($fork_ver)" ;;
    *) fail "version consistent but lost -dev-fork marker ($fork_ver)"; RC=1 ;;
  esac
else
  fail "version mismatch — Cargo.toml=$fork_ver manifest=${manifest_ver:-<none>} Cargo.lock=${lock_ver:-<none>}"; RC=1
fi
echo

if [ "$RC" = "0" ]; then bold "✓ All gates passed."; else bold "✗ Some gates failed — see above."; fi
exit $RC
