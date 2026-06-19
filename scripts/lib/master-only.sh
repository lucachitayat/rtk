#!/usr/bin/env bash
# master-only.sh — detect upstream/master-only fixes the develop sync can't bring in.
#
# The fork syncs from upstream/develop. Anything that lands ONLY on
# upstream/master (security backports, hotfixes cut straight onto the release
# branch) never arrives via the normal sync and is rare-but-critical to catch.
# `check_master_only` surfaces such commits and suppresses two kinds of noise:
#   - release-please / CI / build chores (never substantive)
#   - commits already handled on the fork — detected by ancestry (a real merge)
#     OR by the upstream short-SHA appearing in a fork commit body. The body
#     check is what makes hand-ported AND `git cherry-pick -x` ports both
#     register, regardless of the conflicts/adaptation that would break
#     patch-id (git's --cherry-pick) on a long-diverged fork.
#
# PORTING CONVENTION: cite the upstream SHA in the port's commit body — either
# `git cherry-pick -x <sha>` (auto-cites) or a hand-port that names the SHA.
#
# Sourced by upgrade-check.sh (uses its color helpers) and by
# scripts/test-master-only.sh (uses the fallback helpers below).

declare -F dim   >/dev/null 2>&1 || dim()   { printf "\033[2m%s\033[0m\n" "$*"; }
declare -F hot   >/dev/null 2>&1 || hot()   { printf "\033[33m%s\033[0m\n" "$*"; }
declare -F green >/dev/null 2>&1 || green() { printf "\033[32m%s\033[0m\n" "$*"; }

# Populated by check_master_only on each call.
MASTER_UNPORTED=0
MASTER_SECURITY=0

# check_master_only [fork_ref] [develop_ref] [master_ref]
# Defaults target the live fork; tests pass fixture refs.
# Sets MASTER_UNPORTED / MASTER_SECURITY; prints a per-commit breakdown.
check_master_only() {
  local fork_ref="${1:-develop}" dev_ref="${2:-upstream/develop}" master_ref="${3:-upstream/master}"
  local raw sha subj shown=0
  MASTER_UNPORTED=0
  MASTER_SECURITY=0
  raw=$(git log --no-merges --pretty=format:'%h%x09%s' "${dev_ref}..${master_ref}" 2>/dev/null || true)
  if [ -z "$raw" ]; then green "  ✓ No master-only commits."; return 0; fi
  while IFS=$'\t' read -r sha subj; do
    [ -z "$sha" ] && continue
    # Drop release-please / CI / build chore noise.
    printf '%s' "$subj" | grep -qiE '^(chore|ci|build)(\(|:)|release-please|^release ' && continue
    # Already handled? ancestry (merged) or SHA cited in a fork commit body.
    if git merge-base --is-ancestor "$sha" "$fork_ref" 2>/dev/null \
       || git log "$fork_ref" --grep="$sha" --oneline -1 2>/dev/null | grep -q .; then
      dim "  ✓ ported    $sha  $subj"
      continue
    fi
    shown=$((shown + 1))
    MASTER_UNPORTED=$((MASTER_UNPORTED + 1))
    if printf '%s' "$subj" | grep -qiE 'security|CVE|vuln'; then
      MASTER_SECURITY=$((MASTER_SECURITY + 1))
      hot "  🔴 SECURITY  $sha  $subj"
    else
      hot "  ⚠ unported  $sha  $subj"
    fi
  done <<< "$raw"
  [ "$shown" = "0" ] && green "  ✓ No unported master-only fixes (release chores filtered)."
  return 0
}
