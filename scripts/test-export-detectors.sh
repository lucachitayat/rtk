#!/usr/bin/env bash
# test-export-detectors.sh — positive controls for the enterprise export's residual detector
# (scripts/lib/export-scan.sh), which export-enterprise.sh step 6a relies on.
#
# WHY THIS EXISTS
#   6a is an ABSENCE assertion: it reports PASS when it finds nothing. Everything that can go
#   wrong with it — wrong flags, wrong scanned root, wrong pattern, missing tool — produces the
#   same empty result as a genuinely clean tree. A real residual (docs/TELEMETRY.md, 189 lines
#   long) shipped to customers under a green PASS for exactly that reason. So the detector needs
#   a control of its own, and the control needs to have been SEEN TO FAIL.
#
# CANARY SPEC — five constraints, each one earned by a canary that was falsified:
#   1. planted INSIDE the scanned root, under a NON-HIDDEN filename. The real scan is a
#      directory traversal; ripgrep applies its hidden-file filter to traversals but not to
#      explicitly-named paths (measured on rg 15.2.0: explicit hidden file rc=0, same file via
#      traversal rc=1). A canary outside the root, or hidden inside it, probes a path the real
#      scan cannot reach.
#   2. MIXED CASE. A lowercase canary against a lowercase pattern passes even when `-i` has
#      been lost, so it cannot witness the case-insensitivity the scan depends on.
#   3. probed through the SAME FUNCTION the export calls — not a re-typed command line.
#   4. assert the canary's PATH APPEARS IN RENDERED OUTPUT, not merely that the exit status
#      changed. `-n` and the filename are what make a hit diagnosable.
#   5. ONE CANARY PER ALTERNATION TERM. A single term witnesses one branch of five.
#
# And the property that makes the set sound: DISCRIMINATING POWER. Scenario D re-runs the
# historical bug (`rg -rniE`, where ripgrep's `-r` is --replace and eats the flags) against the
# same planted tree and asserts the canaries are NOT found. A canary the broken form also passes
# is not a control.
#
# Run standalone:  bash scripts/test-export-detectors.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/export-scan.sh
source "$REPO_ROOT/scripts/lib/export-scan.sh"

PASS=0
FAIL=0
check() { # check <description> <result(0=ok)>
  if [ "$2" = "0" ]; then PASS=$((PASS + 1)); printf "  \033[32mok\033[0m   %s\n" "$1"
  else FAIL=$((FAIL + 1)); printf "  \033[31mFAIL\033[0m %s\n" "$1"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── A synthetic shipped tree ─────────────────────────────────────────────────
# Modelled on what git archive emits: a src/ with .rs files (residual_scan requires at least
# one, so an empty export cannot read as clean), plus the allowlisted files at top level.
ROOT="$TMP/tree"
mkdir -p "$ROOT/src/core" "$ROOT/docs"
printf 'fn main() {}\n'                    > "$ROOT/src/main.rs"
printf 'pub fn helper() {}\n'              > "$ROOT/src/core/mod.rs"
printf '[package]\nname = "rtk"\n'         > "$ROOT/Cargo.toml"
printf '[[package]]\nname = "rtk"\n'       > "$ROOT/Cargo.lock"
printf '# Readme\n'                        > "$ROOT/README.md"
printf '# Features\n'                      > "$ROOT/docs/FEATURES.md"

# The term list the export will actually use, straight from the lib. Deriving the canary set
# from the same source as the pattern is what keeps constraint 5 true as the pattern grows: a
# term added to the floor or to the removal manifest gets a canary here automatically.
TERMS=()
while IFS= read -r t; do [ -n "$t" ] && TERMS+=("$t"); done < <(residual_terms "")
PATTERN="$(residual_pattern "")"

# Abort BEFORE any scenario if the term list came back empty. Without this the per-term loop
# below expands an empty array under `set -u`, the script dies mid-run, and it prints neither a
# verdict nor a "N passed" line — a fixture that reports nothing at all. Observed while
# re-breaking the lib: with the derivation changed from union to replacement, TERMS was empty
# and this file exited 0 without a Result line.
if [ "${#TERMS[@]}" -eq 0 ] || [ -z "$PATTERN" ]; then
  printf "  \033[31mFAIL\033[0m residual_terms returned nothing — there is no detector to control\n"
  echo "── Result: 0 passed, 1 failed ──"
  exit 1
fi

echo "── Scenario A: clean tree ──"
echo "  pattern under test: $PATTERN  (${#TERMS[@]} terms)"
[ "${#TERMS[@]}" -ge "${#RESIDUAL_TERMS_FLOOR[@]}" ] && r=0 || r=1
check "term list carries at least the ${#RESIDUAL_TERMS_FLOOR[@]} floor terms (got ${#TERMS[@]})" "$r"

set +e
CLEAN_OUT="$(residual_scan "$ROOT" "$PATTERN")"; CLEAN_RC=$?
set -e
[ "$CLEAN_RC" = "0" ] && r=0 || r=1
check "clean tree -> rc 0 (CLEAN), no false positive" "$r"
[ -z "$CLEAN_OUT" ] && r=0 || r=1
check "clean tree -> no output" "$r"

# ── Scenario B: one canary per alternation term ──────────────────────────────
#
# Mixed-case (constraint 2) by upper-casing the first character and appending a marker, so the
# planted token matches the pattern ONLY through case-insensitivity. Non-hidden filename inside
# the scanned root (constraint 1), reached by traversal exactly as the export reaches it.
echo "── Scenario B: one mixed-case canary per alternation term ──"
mixed_case() { # mixed_case <term> -> TeRm-shaped token, never equal to the term itself
  local t="$1" head rest
  head="$(printf '%s' "${t:0:1}" | tr '[:lower:]' '[:upper:]')"
  rest="$(printf '%s' "${t:1}" | tr '[:lower:]' '[:upper:]')"
  printf '%s%s_CaNaRy' "$head" "$rest"
}

for term in "${TERMS[@]}"; do
  canary_file="$ROOT/src/core/canary_${term}.rs"
  token="$(mixed_case "$term")"
  # The planted file must contain the mixed-case token and NOTHING that matches the pattern
  # case-sensitively. The first draft of this loop also wrote `fn zz_<term>() {}`, i.e. the
  # LOWERCASE term, and that single line silently destroyed constraint 2: re-breaking the lib
  # to `rg -rniE` (which loses -i) left every canary in this scenario still passing, because
  # the lowercase function name matched without any case-insensitivity at all. The scenario
  # looked like a control and was not one. `zz_canary` is deliberately term-free.
  printf '// planted residual: %s\nfn zz_canary() {}\n' "$token" > "$canary_file"

  # Constraint 2, asserted rather than assumed: if upper-casing produced the term verbatim the
  # canary would pass with -i dropped, and would silently stop being a control.
  if [ "$token" != "$term" ]; then r=0; else r=1; fi
  check "canary token for '$term' differs in case from the pattern term" "$r"

  # ...and the planted file must not contain the term case-sensitively anywhere. This is the
  # assertion the first draft lacked; without it, constraint 2 is a comment rather than a check.
  grep -qF -- "$term" "$canary_file" && r=1 || r=0
  check "canary file for '$term' contains no case-sensitive match of the term" "$r"

  set +e
  HIT_OUT="$(residual_scan "$ROOT" "$PATTERN")"; HIT_RC=$?
  set -e
  [ "$HIT_RC" = "1" ] && r=0 || r=1
  check "canary '$term' -> rc 1 (FOUND)" "$r"

  # Constraint 4: the path must be RENDERED, not merely counted. An exit status alone cannot
  # tell a maintainer which file to open.
  printf '%s' "$HIT_OUT" | grep -qF "canary_${term}.rs" && r=0 || r=1
  check "canary '$term' -> its path appears in the rendered output" "$r"

  rm -f "$canary_file"
done

# The tree must be clean again, or a leftover canary would make every later scenario pass for
# the wrong reason.
set +e
residual_scan "$ROOT" "$PATTERN" >/dev/null; POST_RC=$?
set -e
[ "$POST_RC" = "0" ] && r=0 || r=1
check "all canaries removed -> tree reads clean again" "$r"

# ── Scenario C: the glob allowlist really excludes, and only what it names ───
echo "── Scenario C: allowlist boundary ──"
printf 'getrandom = "0.2"\n' > "$ROOT/Cargo.toml"
set +e
residual_scan "$ROOT" "$PATTERN" >/dev/null; EXCL_RC=$?
set -e
[ "$EXCL_RC" = "0" ] && r=0 || r=1
check "allowlisted Cargo.toml hit is excluded (still CLEAN)" "$r"
printf '[package]\nname = "rtk"\n' > "$ROOT/Cargo.toml"

# ...and the same content in a file the allowlist does NOT name must be caught. Without this,
# an allowlist that had swallowed the whole tree would look identical to a working one.
printf 'getrandom = "0.2"\n' > "$ROOT/docs/NOTES.md"
set +e
INCL_OUT="$(residual_scan "$ROOT" "$PATTERN")"; INCL_RC=$?
set -e
[ "$INCL_RC" = "1" ] && r=0 || r=1
check "same content in a non-allowlisted file IS caught" "$r"
printf '%s' "$INCL_OUT" | grep -qF "NOTES.md" && r=0 || r=1
check "non-allowlisted hit renders its path" "$r"
rm -f "$ROOT/docs/NOTES.md"

# ── Scenario D: discriminating power against the historical bug ──────────────
#
# The canary set is only a control if the BROKEN detector fails it. Re-run the 2026-07-24 bug
# — `rg -rniE`, where ripgrep's `-r` is --replace and swallows `niE`, costing -n and -i — over
# the same planted tree, and require it to MISS. A drafted canary was rejected precisely
# because it passed here.
echo "── Scenario D: the historical -rniE bug must FAIL the canaries ──"
canary_file="$ROOT/src/core/canary_discriminate.rs"
printf '// planted residual: TeLeMeTrY_CaNaRy\n' > "$canary_file"

set +e
BROKEN_OUT="$(rg -rniE "$PATTERN" "$ROOT" 2>/dev/null)"; BROKEN_RC=$?
set -e
printf '%s' "$BROKEN_OUT" | grep -qF "canary_discriminate.rs" && r=1 || r=0
check "broken form (rg -rniE) does NOT report the mixed-case canary" "$r"

set +e
FIXED_OUT="$(residual_scan "$ROOT" "$PATTERN")"; FIXED_RC=$?
set -e
printf '%s' "$FIXED_OUT" | grep -qF "canary_discriminate.rs" && r=0 || r=1
check "correct form DOES report it (rc=$FIXED_RC, broken rc=$BROKEN_RC)" "$r"
rm -f "$canary_file"

# ── Scenario E: cannot-verify is its own outcome, never a pass ───────────────
echo "── Scenario E: CANNOT-VERIFY (rc 2) is distinct from CLEAN (rc 0) ──"
set +e
residual_scan "$TMP/does-not-exist" "$PATTERN" >/dev/null 2>&1; RC_MISSING=$?
residual_scan "$ROOT" "" >/dev/null 2>&1; RC_EMPTYPAT=$?
set -e
[ "$RC_MISSING" = "2" ] && r=0 || r=1
check "missing root -> rc 2, not rc 0 (got $RC_MISSING)" "$r"
[ "$RC_EMPTYPAT" = "2" ] && r=0 || r=1
check "empty pattern -> rc 2, not rc 0 (got $RC_EMPTYPAT)" "$r"

# A tree with no .rs files is an export that did not happen. This is the check that would have
# caught scanning a directory that had been deleted out from under the scan.
NOSRC="$TMP/nosrc"; mkdir -p "$NOSRC"; printf 'hello\n' > "$NOSRC/README.md"
set +e
residual_scan "$NOSRC" "$PATTERN" >/dev/null 2>&1; RC_NOSRC=$?
set -e
[ "$RC_NOSRC" = "2" ] && r=0 || r=1
check "root with no .rs files -> rc 2, not rc 0 (got $RC_NOSRC)" "$r"

# ── Scenario F: the derivation unions, and validates ────────────────────────
echo "── Scenario F: manifest derivation unions with the floor ──"
MANIFEST="$TMP/manifest.txt"
printf 'telemetry\ntelemetry_cmd\nureq\ngetrandom\n' > "$MANIFEST"
DERIVED="$(residual_terms "$MANIFEST")"

# Union, not replacement: every floor term must survive a derivation.
missing=""
for term in "${RESIDUAL_TERMS_FLOOR[@]}"; do
  printf '%s\n' "$DERIVED" | grep -qx "$term" || missing="$missing $term"
done
[ -z "$missing" ] && r=0 || r=1
check "every floor term survives the derivation (missing:${missing:-none})" "$r"

# ...and a manifest-only term is added. Planted term is deliberately NOT already in the
# alternation: `telemetry` is the first alternand and would have had zero discriminating power.
printf '%s\n' "$DERIVED" | grep -qx "telemetry_cmd" && r=0 || r=1
check "manifest-only term 'telemetry_cmd' is added by the derivation" "$r"

# Validation: the terms that would make the gate permanently red must be rejected. `run` is the
# concrete one — a derivation over removed identifiers yields it, and `pub fn run(` appears in
# 61 files under src/.
printf 'run\nrg\n.*\nTeleMetry2\n' > "$MANIFEST"
set +e
VALIDATED="$(residual_terms "$MANIFEST" 2>/dev/null)"
set -e
printf '%s\n' "$VALIDATED" | grep -qx "rg" && r=1 || r=0
check "too-short term 'rg' rejected" "$r"
printf '%s\n' "$VALIDATED" | grep -qx '\.\*' && r=1 || r=0
check "non-identifier term '.*' rejected" "$r"
printf '%s\n' "$VALIDATED" | grep -qx "TeleMetry2" && r=0 || r=1
check "valid term 'TeleMetry2' accepted" "$r"

# A missing manifest is not an error — the floor still applies, so the union only ever grows.
NOFILE_TERMS="$(residual_terms "$TMP/no-such-manifest")"
[ "$(printf '%s\n' "$NOFILE_TERMS" | grep -c .)" = "${#RESIDUAL_TERMS_FLOOR[@]}" ] && r=0 || r=1
check "absent manifest -> floor terms only, no error" "$r"

echo
echo "── Result: $PASS passed, $FAIL failed ──"
[ "$FAIL" = "0" ]
