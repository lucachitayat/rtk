#!/usr/bin/env bash
# scripts/lib/export-scan.sh — the enterprise export's residual-telemetry detector.
#
# WHY THIS IS A LIB
# -----------------
# Extracted from export-enterprise.sh so scripts/test-export-detectors.sh can probe the EXACT
# command the export runs instead of a hand-copied approximation of it. A canary that probes a
# reconstruction proves nothing about the real detector. Two drafted canaries were falsified
# empirically on 2026-07-24 for exactly that reason:
#
#   - one PASSED under the very bug it advertised catching. It planted a lowercase token and
#     the pattern is lowercase, so the accidentally-dropped `-i` was a no-op for it — while a
#     real residual spelled "TELEMETRY" went unmatched.
#   - one probed an explicit hidden file outside the scanned root, while the real scan is a
#     DIRECTORY TRAVERSAL. Measured on ripgrep 15.2.0: explicit hidden file → rc=0, the same
#     file reached by traversal → rc=1, because traversal applies the hidden-file filter.
#
# Sourced, never executed. No side effects at source time.
#
# shellcheck shell=bash

# ── Residual terms ────────────────────────────────────────────────────────────
#
# The hardcoded floor. NEVER REPLACE THIS with a derivation — union with it (see
# residual_terms below). Two independent reasons, both measured in this tree:
#   - a derivation over the identifiers in the removed code resolves to include `run`,
#     `command` and `core`. `pub fn run(` alone appears in 61 files under src/, so every clean
#     export would FATAL. A permanently-red gate is worse than no gate: it gets switched off.
#   - no removed item names `getrandom` — it arrives transitively — so a replacing derivation
#     would silently drop a term that is currently load-bearing.
RESIDUAL_TERMS_FLOOR=(telemetry maybe_ping ureq TelemetryConfig getrandom)

# Minimum length for a DERIVED term. Anything shorter matches most of the tree and converts a
# fail-closed detector into a permanently-red one. `ureq` (4) is the shortest real term.
RESIDUAL_TERM_MIN_LEN=4

# Files whose mention of a residual term is legitimate, so they are excluded from the scan.
#
# DRIFT GUARD: this must mirror export-enterprise.sh's step-4 ALLOWLIST. Each entry is a file
# that names a removed thing on purpose — build.rs's FORBIDDEN_CRATES denylist, deny.toml's ban
# entry, getrandom arriving transitively in Cargo.lock, and the enterprise-authored docs that
# exist to explain that telemetry was removed. Adding an entry here stops protecting that file,
# so an entry is a decision, not a convenience.
RESIDUAL_SCAN_EXCLUDES=(
    Cargo.lock Cargo.toml build.rs deny.toml
    DISCLAIMER.md REVIEWER-README.md SECURITY-HARDENING.md CHANGELOG.md UPSTREAM.md
)

# residual_terms <manifest_file>
#
# Print the union of the hardcoded floor and the terms derived from the removal manifest, one
# per line, sorted and deduplicated. The manifest is written by export-enterprise.sh steps 2a
# (deleted-file stems) and 2c (removed dependency / feature identifiers); a missing or empty
# manifest is NOT an error — the floor still applies — because the union can only ever grow.
#
# Derived terms are validated, and a rejected term is announced on stderr rather than dropped
# quietly: a derivation that silently discards its input is another absence assertion.
residual_terms() {
    local manifest="${1:-}"
    local derived=()
    if [[ -n "${manifest}" && -s "${manifest}" ]]; then
        local t
        while IFS= read -r t; do
            [[ -n "${t}" ]] || continue
            if [[ ! "${t}" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]]; then
                echo "residual_terms: rejected non-identifier term '${t}'" >&2
                continue
            fi
            if [[ ${#t} -lt ${RESIDUAL_TERM_MIN_LEN} ]]; then
                echo "residual_terms: rejected term '${t}' (shorter than ${RESIDUAL_TERM_MIN_LEN} chars)" >&2
                continue
            fi
            derived+=("${t}")
        done < "${manifest}"
    fi
    printf '%s\n' "${RESIDUAL_TERMS_FLOOR[@]}" ${derived[@]+"${derived[@]}"} | sort -u
}

# residual_pattern <manifest_file>
#
# The alternation residual_scan takes, e.g. "TelemetryConfig|getrandom|maybe_ping|telemetry|ureq".
residual_pattern() {
    residual_terms "${1:-}" | paste -sd '|' -
}

# residual_scan <root> <pattern>
#
# Scan <root> for <pattern>. THREE outcomes, not two — an unverifiable claim is not a passing
# one:
#     0  CLEAN          — the scan ran and found nothing
#     1  FOUND          — hits printed on stdout; the caller must treat this as fatal
#     2  CANNOT VERIFY  — reason printed on stderr; the caller must treat this as fatal too
#
# DOMAIN CONTROL. Everything above the scan asserts that there is something to scan, because
# `rg` exits 2 on a missing path and the historical `|| true` swallowed it, leaving an empty
# result that read as "clean" — a verification that never ran, reported as a pass. On
# 2026-07-24 that is how docs/TELEMETRY.md reached customers: 189 lines opening "RTK collects
# anonymous, aggregate usage metrics once per day", while the scan looked only at src/.
residual_scan() {
    local root="${1:-}" pattern="${2:-}"
    if [[ -z "${pattern}" ]]; then
        echo "residual_scan: refusing to scan with an empty pattern" >&2
        return 2
    fi
    if ! command -v rg >/dev/null 2>&1; then
        echo "residual_scan: 'rg' (ripgrep) is not on PATH — install with: brew install ripgrep" >&2
        return 2
    fi
    if [[ ! -d "${root}" ]]; then
        echo "residual_scan: root '${root}' is not a directory" >&2
        return 2
    fi
    if [[ -z "$(find "${root}" -type f -name '*.rs' -print -quit)" ]]; then
        echo "residual_scan: root '${root}' contains no .rs files — an export this empty did not happen" >&2
        return 2
    fi

    local globs=() e
    for e in "${RESIDUAL_SCAN_EXCLUDES[@]}"; do globs+=(--glob "!${e}"); done

    # NOT `-rniE`: those are grep's flags. In ripgrep `-r` is --replace and swallows the next
    # token, so `-rniE` meant "replace every match with the literal niE" — losing -n (line
    # numbers) and -i (case-insensitivity) and printing `niE` in place of the offending text.
    # On 2026-07-24 that reported `constants.rs: "niE",` for a residual `"telemetry",`, hiding
    # the cause. Recursion is implicit when the argument is a directory.
    #
    # `x="$(cmd)" && rc=0 || rc=$?` keeps both the output and the exit status while staying
    # safe under the caller's `set -e`: a bare assignment from a failing substitution aborts.
    # `${globs[@]+"${globs[@]}"}`: bash 3.2 (the system bash on macOS) treats "${arr[@]}" on an
    # EMPTY array as an unbound variable under `set -u`, so emptying RESIDUAL_SCAN_EXCLUDES would
    # abort rg with an obscure message instead of scanning with no exclusions.
    local hits rc
    hits="$(rg -n -i "${pattern}" "${root}" ${globs[@]+"${globs[@]}"})" && rc=0 || rc=$?
    case "${rc}" in
        0) printf '%s\n' "${hits}"; return 1 ;;
        1) return 0 ;;
        *) echo "residual_scan: rg exited ${rc} (not a no-match) — scan did not complete" >&2; return 2 ;;
    esac
}
