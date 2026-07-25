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
# `|| exit` is not cosmetic here. Every check below is a relative path, so a cd that failed
# would run the whole gate against whatever directory the caller happened to be in — and the
# fork-invariant checks would report on files that are not this repo's. Fail rather than
# verify the wrong tree.
cd "$REPO_ROOT" || { echo "FATAL: cannot cd to repo root '$REPO_ROOT'" >&2; exit 1; }

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
# DRIFT GUARD: inv_absent's detector (`[ -e ]`) is total — it cannot silently misbehave, so
# it needs no canary. The drift surface is the PATH ARGUMENT, not the check itself. Both MCP
# absence assertions below (the "MCP bridge dir removed" / "MCP rewrite cmd removed" checks)
# hardcode "src/mcp" and "src/hooks/mcp_rewrite_cmd.rs", so an upstream reintroduction of the
# bridge under a different path/name passes both silently. That is what inv_grep_absent
# covers: the same invariant stated over VOCABULARY instead of over a path, so it survives a
# rename. Widen the path set here if upstream renames it — do NOT add a canary to inv_absent.
inv_absent() { if [ -e "$1" ]; then fail "$2 (should be absent: $1)"; RC=1; else pass "$2"; fi; }
inv_grep()   { if grep -rlqF -- "$1" "$2" 2>/dev/null; then pass "$3"; else fail "$3 (pattern gone from $2)"; RC=1; fi; }
# Content-level absence — the mirror of inv_grep: fails when the pattern IS found. Unlike
# inv_absent this detector is NOT total: `grep` exits 2 on a path that does not exist and 1
# when there is simply no match, and neither this helper nor the caller can tell those apart.
# The path argument's existence must therefore be asserted separately, with inv_exists.
inv_grep_absent() { if grep -rlqE -- "$1" "$2" 2>/dev/null; then fail "$3 (found in $2)"; RC=1; else pass "$3"; fi; }

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
# Shell-script tests (NOT covered by cargo). Discovered by GLOB, never by name: the previous
# form hardcoded `scripts/test-master-only.sh` and labelled it "master-only detector", so a
# sibling fixture added later would have sat in the tree unwired while the gate kept printing
# one green line.
#
# Discovery is DEFAULT-INCLUDE. Anything matching scripts/test-*.sh runs unless it is named
# in SH_TEST_EXCLUDE below, so a new fixture is wired the moment it lands and forgetting to
# register it is not a failure mode. The excluded five need an installed `rtk` on PATH or an
# external toolchain (41–144 rtk invocations each; test-install.sh exercises install.sh
# rather than an in-tree detector) — they are integration suites, not hermetic fixtures.
# Each exclusion's existence is asserted, so a rename over there goes stale LOUDLY here
# instead of quietly dropping a fixture back out of the run.
#
# Two further assertions make the discovery itself checkable:
#   - the number of fixtures run must be non-zero (a rename of the whole family, or a glob
#     that stops matching, is a failure and not "all shell tests passed");
#   - each fixture must REPORT a non-zero passing count. A fixture is a positive control for
#     a detector, so one that exits 0 having asserted nothing is the exact failure mode these
#     fixtures exist to catch. CONTRACT: every wired scripts/test-*.sh prints "<N> passed".
SH_TEST_EXCLUDE="test-all.sh test-aristote.sh test-install.sh test-ruby.sh test-tracking.sh"
for x in $SH_TEST_EXCLUDE; do
  [ -f "scripts/$x" ] || { fail "shell-test exclusion is stale — scripts/$x no longer exists"; RC=1; }
done
sh_fixtures=0
for t in scripts/test-*.sh; do
  [ -f "$t" ] || continue   # an unmatched glob expands to the literal pattern
  t_name=$(basename "$t")
  case " $SH_TEST_EXCLUDE " in *" $t_name "*) continue ;; esac
  sh_fixtures=$((sh_fixtures + 1))
  t_log="/tmp/pmv_shtest_${t_name%.sh}.txt"
  if bash "$t" >"$t_log" 2>&1; then
    t_passed=$(grep -hoE '[0-9]+ passed' "$t_log" | head -1 | grep -oE '[0-9]+')
    if [ -n "$t_passed" ] && [ "$t_passed" -gt 0 ]; then
      pass "shell test $t_name ($t_passed passed)"
    else
      fail "shell test $t_name exited 0 but reported no passing assertions (full: $t_log)"; RC=1
    fi
  else
    fail "shell test $t_name (digest below; full: $t_log)"; digest "$t_log"; RC=1
  fi
done
if [ "$sh_fixtures" -eq 0 ]; then
  fail "shell tests — no scripts/test-*.sh fixtures matched (the family moved or was renamed)"; RC=1
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
#   1. the release build under --features enterprise COMPILES (the actual distro risk).
#      NOTE: this does NOT exercise build.rs's egress lockfile scan, and the reason changed
#      on 2026-07-24. It is no longer "the guard returns early unless CARGO_FEATURE_TELEMETRY
#      is set" — the guard now gates on whether the manifest DECLARES a telemetry feature. The
#      dev fork declares one, so Cargo.lock legitimately carries ureq and rustls even with the
#      feature off, and the guard deliberately SKIPS here rather than being permanently red.
#      Watch the build output say so: `EGRESS GUARD: SKIPPED`. The scan runs in the exported
#      distribution, where no such feature exists, and export step 6e asserts that it did.
#      This step only proves the enterprise feature set compiles;
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
    # `cargo test` with a filter that matches nothing still exits 0 ("0 passed") — a
    # relocated test module would print a green check over an assertion that never ran.
    # Extract the count and require it non-zero, not just the exit code.
    ent_passed=$(grep -hoE '[0-9]+ passed' /tmp/pmv_ent_test.txt | head -1 | grep -oE '[0-9]+')
    if [ -n "$ent_passed" ] && [ "$ent_passed" -gt 0 ]; then
      pass "enterprise-gated tests ($ent_passed passed — hook_cmd fork_tests)"
    else
      fail "enterprise-gated tests — filter 'hook_cmd::tests::fork_tests' matched 0 tests (filter is stale, not necessarily the code — update it if the module moved)"; RC=1
    fi
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
# Scan-target existence comes FIRST: every content-level check below treats a negative grep
# as "the invariant holds", and grep cannot distinguish "no match" (exit 1) from "that path
# does not exist" (exit 2). Without this line an upstream reorganisation of src/ would print
# a row of green checks over scans that examined nothing.
inv_exists "src"                                       "scan target present (src/)"
inv_exists "src/cmds/cloud/az_cmd.rs"                  "Azure filter az_cmd.rs present"
inv_grep   "Commands::Az" "src/main.rs"                "Az command wired in main.rs"
inv_absent "src/mcp"                                   "MCP bridge dir removed (fork)"
inv_absent "src/hooks/mcp_rewrite_cmd.rs"              "MCP rewrite cmd removed (fork)"
# The two checks above are by hardcoded path; this one is by vocabulary, so a reintroduction
# under any other name still fails. Verified non-vacuous when added: the alternation fires on
# a planted `mcp_rewrite` line, and src/ carried 123 .rs files with zero live matches.
inv_grep_absent 'mcp_rewrite|McpProxy|Commands::Mcp' "src" "no MCP bridge vocabulary in src/ (path-independent)"
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
# `grep` exits 2 (not just non-zero) when a path argument doesn't exist, and the else
# branch below can't tell that apart from "clean" — assert the scan targets exist first,
# so a path rename upstream fails loudly instead of silently scanning nothing.
# (src/ is already asserted at the top of this section.)
inv_exists "Cargo.toml"                       "conflict-marker scan target present (Cargo.toml)"
inv_exists "Cargo.lock"                       "conflict-marker scan target present (Cargo.lock)"
inv_exists ".release-please-manifest.json"    "conflict-marker scan target present (.release-please-manifest.json)"
# scripts/ is in the scanned set because it was NOT, and that cost a commit: resolving the
# develop→harden merge of THIS file left a marker pair behind in it and the gate reported
# "no conflict markers" — the domain excluded the very script doing the scanning. The
# verification files are the ones a merge conflict hurts most, since a broken gate reports
# green. build.rs is in for the same reason — it carries the compile-time egress guard. Docs
# stay out: they carry setext headings and fenced diff samples that look like markers.
inv_exists "scripts"                          "conflict-marker scan target present (scripts/)"
inv_exists "build.rs"                         "conflict-marker scan target present (build.rs)"
if grep -rlqE '^(<{7}|>{7})' src/ scripts/ build.rs Cargo.toml Cargo.lock .release-please-manifest.json 2>/dev/null; then fail "conflict markers present in src/, scripts/, build.rs or version files"; RC=1; else pass "no conflict markers in src/, scripts/, build.rs or version files"; fi
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
