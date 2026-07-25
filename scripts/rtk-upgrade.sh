#!/usr/bin/env bash
# rtk-upgrade.sh — thin orchestrator for the RTK fork upgrade flow.
#
# Three subcommands, so the agent runs scripted steps and never improvises:
#   check   — fetch + upgrade-check.sh; ends with a machine-stable RECOMMENDATION + `next:` line
#             (the agent runs the printed `next:` command — it does not re-derive it).
#   apply   — re-preview at merge time, merge upstream/develop with a SCRIPTED abort path, then
#             post-merge-verify.sh. Leaves the merge COMMITTED-BUT-UNPUSHED; the push is gated by
#             the human / skill, never here. Hard-refuses if the tree has tracked changes OR the
#             branch is behind its own origin/<branch> (see assert_not_behind_origin).
#   install — `cargo install --path .` the merged binary into ~/.cargo/bin, then VERIFY the
#             installed `rtk --version` matches the merged Cargo.toml version. Closes the gap
#             where apply only builds target/release/rtk and never installs it. Confirmed step,
#             run before the push; local + reversible (reinstall the prior tag).
#
# The real work lives in the companions: scripts/upgrade-check.sh, scripts/post-merge-verify.sh.
# Orchestration contract: .claude/skills/rtk-upgrade/SKILL.md.
#
# Usage:  bash scripts/rtk-upgrade.sh {check | apply [ref] | install}
#   ref — optional explicit merge target (default: upstream/develop). Per-invocation only.

set -uo pipefail   # NOT -e: a no-match grep must not abort the orchestrator.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

bold()  { printf "\033[1m%s\033[0m\n" "$*"; }
dim()   { printf "\033[2m%s\033[0m\n" "$*"; }
fail()  { printf "\033[31m✗ %s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
warn()  { printf "\033[33m%s\033[0m\n" "$*"; }

usage() { echo "usage: bash scripts/rtk-upgrade.sh {check | apply [ref] | install}"; exit 2; }

# ── Fork versioning (spec: .claude/skills/rtk-upgrade/SKILL.md § Versioning) ──
# Fork version = "<upstream/develop base>-dev-fork.<N>", mirrored in lockstep across
# Cargo.toml, .release-please-manifest.json, and Cargo.lock's own `rtk` entry.
# DRIFT GUARD: these three files are the canonical version sites. CHANGELOG.md is resolved
# by the `merge=union` driver in .gitattributes and never reaches the conflict set. If a new
# version-carrying file appears, add it here AND to post-merge-verify.sh's consistency gate.
VERSION_FILES=(Cargo.toml .release-please-manifest.json Cargo.lock)

# ── Fork-OWNED documents: take OURS on conflict ──
# README.md documents the fork's own surface (the Azure `az` filter, the REMOVED MCP bridge,
# the fork install story). Upstream README edits are essentially never wanted verbatim, so a
# conflict there is resolved by discarding the upstream side — the same guarded
# `git checkout --ours` used for the version files, with a visible log line.
# NOT a `merge=union` driver: union is correct for CHANGELOG.md because a changelog is an
# append-only chronological list, but on a README it interleaves both sides into duplicated
# sections and contradictory prose.
# DRIFT GUARD: only add a path here if the fork owns it OUTRIGHT. In particular do NOT add
# docs/guide/resources/what-rtk-covers.md — it is a capability manifest that must reflect BOTH
# upstream's newly added ecosystems AND the fork's deltas, so take-ours goes stale and lies
# about coverage while take-theirs silently drops `az` and re-advertises the MCP bridge. It
# gets a targeted hand-resolve reminder instead (see report_manual_conflict_hints).
OURS_DOC_FILES=(README.md)

# ── NEVER auto-resolved, under any circumstances ──
# src/main.rs is the command routing table; src/hooks/hook_cmd.rs is the egress-hardening
# surface. This fork is defined partly by what it REMOVED, so any union/take-either resolve
# there can silently resurrect the MCP bridge or telemetry — a "clean" merge that reintroduces
# egress. Conflict-and-stop is the correct behavior: they are absent from every auto-resolve
# set above and must stay absent. They only get a reminder, never a resolution.

cargo_ver() { grep -m1 '^version' "$1" 2>/dev/null | sed -E 's/.*"(.*)".*/\1/'; }

# Compute the fork target version from upstream/develop's base. Fail closed (return 1) on
# build metadata or a malformed result rather than fabricate a bad version. Prints target.
compute_target() {
  local up_ver up_base n target
  up_ver=$(git show upstream/develop:Cargo.toml 2>/dev/null | grep -m1 '^version' | sed -E 's/.*"(.*)".*/\1/')
  [ -n "$up_ver" ] || { fail "cannot read upstream/develop Cargo.toml version" >&2; return 1; }
  case "$up_ver" in
    *+*) fail "upstream version '$up_ver' carries build metadata (+) — refusing to fabricate a fork version" >&2; return 1 ;;
  esac
  up_base=${up_ver%%-*}
  # N = max existing <base>-dev-fork.N tag + 1, else 1 (monotonic, collision-safe).
  n=$(git tag -l "${up_base}-dev-fork.*" | sed -E 's/.*-dev-fork\.([0-9]+)$/\1/' | grep -E '^[0-9]+$' | sort -n | tail -1)
  if [ -n "$n" ]; then n=$((n + 1)); else n=1; fi
  target="${up_base}-dev-fork.${n}"
  if ! printf '%s' "$target" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+-dev-fork\.[0-9]+$'; then
    fail "computed fork version '$target' is malformed — aborting" >&2; return 1
  fi
  printf '%s' "$target"
}

# Reconcile the fork version across the three canonical files, then commit. UNCONDITIONAL:
# always sets the spec target (never keeps a bare/suffix-stripped version). Idempotent: no
# commit if everything already matches. Returns non-zero on failure.
reconcile_version() {
  local target cur
  target=$(compute_target) || return 1
  cur=$(cargo_ver Cargo.toml)
  if [ "$cur" = "$target" ]; then
    dim "  version already $target — no reconcile needed"
    return 0
  fi
  bold "── Reconciling fork version → $target ──"
  # Cargo.toml: rewrite ONLY the first `^version = "..."` (the [package] version).
  perl -i -pe 'if (!$d && /^version\s*=/) { s/"[^"]*"/"'"$target"'"/; $d=1 }' Cargo.toml
  # manifest: rewrite the "." value.
  perl -i -pe 's/("\."\s*:\s*)"[^"]*"/${1}"'"$target"'"/' .release-please-manifest.json
  # Cargo.lock: rewrite the rtk own-package version (deterministic; no network/cargo needed).
  perl -0777 -i -pe 's/(\[\[package\]\]\nname = "rtk"\nversion = )"[^"]*"/${1}"'"$target"'"/' Cargo.lock
  git add Cargo.toml .release-please-manifest.json Cargo.lock
  if git commit -m "chore(fork): retrack version to ${target}" >/dev/null 2>&1; then
    green "  ✓ version retracked to $target (Cargo.toml, manifest, Cargo.lock)"
  else
    fail "version reconcile commit failed"; return 1
  fi
}

# Resolve a conflicted merge IFF every conflicted path is mechanically resolvable:
#   Cargo.toml / manifest → take OURS (preserve fork-owned lines), version fixed by reconcile;
#   Cargo.lock            → take OURS, rtk entry fixed by reconcile;
#   README.md             → take OURS (fork-owned doc), logged loudly (see OURS_DOC_FILES).
# Cargo.toml is taken OURS only if upstream changed nothing but the version line (else a real
# dependency/manifest change needs human review). CHANGELOG.md is handled by merge=union and
# never appears here. Any other conflict → caller aborts. Returns 0 if fully resolved, 1 else.
# $1 = merge target ref (only used to print a review command).
resolve_mechanical_conflicts() {
  local target="${1:-upstream/develop}"
  local u f kind base_toml theirs_toml
  u=$(git diff --name-only --diff-filter=U 2>/dev/null)
  [ -n "$u" ] || return 1
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    kind=""
    case " ${VERSION_FILES[*]} " in
      *" $f "*) kind="version" ;;        # handled below
    esac
    case " ${OURS_DOC_FILES[*]} " in
      *" $f "*) kind="ours-doc" ;;       # fork-owned doc → take ours, log it
    esac
    [ -n "$kind" ] || return 1           # unhandled path → not mechanical
    if [ "$f" = "Cargo.toml" ]; then
      # Guard: upstream side (:3) must differ from base (:1) ONLY in version line(s).
      base_toml=$(git show :1:Cargo.toml 2>/dev/null | grep -v '^version')
      theirs_toml=$(git show :3:Cargo.toml 2>/dev/null | grep -v '^version')
      if [ "$base_toml" != "$theirs_toml" ]; then
        fail "upstream changed non-version lines in Cargo.toml — needs human review" >&2
        return 1
      fi
    fi
    git checkout --ours -- "$f" || return 1   # --ours = fork; rc!=0 (e.g. modify/delete) → abort
    git add -- "$f" || return 1
    if [ "$kind" = "ours-doc" ]; then
      warn "  ⚠ $f: upstream changed it — the upstream side was DISCARDED, fork version kept."
      dim  "      Fork-owned doc (see OURS_DOC_FILES). Review manually if desired:"
      dim  "        git diff ORIG_HEAD..$target -- $f"
    fi
  done <<< "$u"
  # Nothing must remain unmerged before we complete the merge commit.
  [ -z "$(git diff --name-only --diff-filter=U 2>/dev/null)" ] || return 1
  return 0
}

# Targeted hand-resolve guidance for conflicts we deliberately REFUSE to auto-resolve.
# Printed on the abort path so the human knows what must survive the manual resolution.
# $1 = space-delimited conflicted-path list (with a leading/trailing space).
# DRIFT GUARD: keep in sync with OURS_DOC_FILES and the never-auto note above.
report_manual_conflict_hints() {
  case " $1 " in
    *" docs/guide/resources/what-rtk-covers.md "*)
      warn "  ⚠ docs/guide/resources/what-rtk-covers.md is a capability MANIFEST — resolve by hand, keeping BOTH sides:"
      echo "      • upstream's newly added ecosystems/filters (take-ours leaves the manifest stale and under-claiming)"
      echo "      • the fork's deltas: Azure \`az\` IS present; the MCP bridge is REMOVED"
      echo "        (take-theirs silently drops \`az\` and re-advertises the MCP bridge)"
      ;;
  esac
  case " $1 " in
    *" src/main.rs "*|*" src/hooks/hook_cmd.rs "*)
      warn "  ⚠ src/main.rs / src/hooks/hook_cmd.rs are NEVER auto-resolved — routing table + egress-hardening surface."
      echo "      This fork is defined partly by what it REMOVED. Resolve by hand and confirm the"
      echo "      resolution does not resurrect the MCP bridge or telemetry."
      ;;
  esac
}

# ── Stale-base guard: refuse to merge onto a branch that is behind its OWN remote ──
# Three refs are in play at every sync, and the tooling historically modelled only two of them:
#   upstream/develop  — the sync SOURCE (what gets merged IN)
#   origin/<branch>   — the fork's OWN remote (where the merge eventually gets PUSHED)
#   <branch>          — the local branch (what gets merged INTO)
# Ignoring the middle one cost a full merge on 2026-07-24: local `develop` sat 1 commit behind
# `origin/develop` (pushed from another machine on 2026-07-12). `check` reported no problem
# because it never looked at origin, so `apply` merged 231 upstream commits onto that stale
# base. The work duplicated a bug fix that already existed in the missed commit, and nothing
# surfaced until the final `git push` was rejected as non-fast-forward — after every gate had
# passed and the merge was long since committed.
# Fail-closed, in the same spirit as the not-clean-working-tree guard: print what is missing,
# exit non-zero with the tree UNTOUCHED, and let the human choose how to integrate. Deliberately
# does NOT auto-pull — integrating someone else's commits is a decision, not a side effect.
# Three cases where it stays silent and returns 0, by design:
#   • no `origin` remote, or origin/<branch> does not exist (brand-new branch never pushed) —
#     there is no remote base to be stale against, and a missing ref must never read as "0";
#   • detached HEAD — no branch name to resolve a remote-tracking ref from;
#   • merely AHEAD of origin — unpushed local work is the NORMAL state here, since `apply`
#     itself deliberately leaves the merge committed-but-unpushed.
# DRIFT GUARD: this reads only remote-tracking refs, so it is only as fresh as the last fetch —
# it MUST be called after the origin fetch in cmd_apply, never before. If a second merge entry
# point is ever added to this script, call it there too; its counterpart report line lives in
# upgrade-check.sh's `── Divergence ──` section and the two must keep telling the same story.
assert_not_behind_origin() {
  local branch behind ahead
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
  [ -n "$branch" ] && [ "$branch" != "HEAD" ] || return 0
  git rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null || return 0
  behind=$(git rev-list --count "HEAD..origin/$branch" 2>/dev/null || echo 0)
  ahead=$(git rev-list --count "origin/$branch..HEAD" 2>/dev/null || echo 0)
  [ "$behind" != "0" ] || return 0
  fail "branch '$branch' is $behind commit(s) BEHIND origin/$branch — refusing to merge onto a stale base. Tree untouched."
  git log --oneline --no-decorate "HEAD..origin/$branch" | head -10 | sed 's/^/      /'
  dim  "      (local is also $ahead commit(s) ahead of origin/$branch)"
  warn "  Merging now would sync upstream onto a base the fork's own remote has already moved past:"
  echo "      • work already landed in those commits gets duplicated or reverted by the merge"
  echo "      • the eventual 'git push' is rejected as non-fast-forward — after every gate has passed"
  dim  "  Integrate first, then re-run apply:"
  echo "      git pull --ff-only origin $branch     # no local commits to keep"
  echo "      git pull --rebase  origin $branch     # local commits to keep"
  return 1
}

cmd_check() {
  # upgrade-check.sh fetches upstream and prints the full decision report, ending with a
  # machine-stable `RECOMMENDATION: CURRENT|DEFER|INVESTIGATE` line we map to a next command.
  local out rec master_alert
  out=$(bash scripts/upgrade-check.sh)
  printf '%s\n' "$out"
  rec=$(printf '%s\n' "$out" | grep -E '^RECOMMENDATION:' | tail -1 | awk '{print $2}')
  # Additive signal: master-only fixes the develop sync can't bring in (rare, often security).
  master_alert=$(printf '%s\n' "$out" | grep -E '^MASTER_ALERT:' | tail -1 | sed 's/^MASTER_ALERT: //')
  echo
  bold "── Next ──"
  case "$rec" in
    INVESTIGATE)  echo "next: bash scripts/rtk-upgrade.sh apply" ;;
    DEFER|CURRENT) echo "next: (none — fork needs no merge)" ;;
    *)            echo "next: (no recommendation parsed — read the report above)" ;;
  esac
  if [ -n "$master_alert" ]; then
    fail "⚠ MASTER-ONLY: $master_alert — port directly (develop sync will NOT bring these in; see report)."
  fi
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

  # Refresh the fork's OWN remote too — assert_not_behind_origin below reads only
  # remote-tracking refs, so a stale origin/<branch> makes the guard silently useless (which is
  # exactly the 2026-07-24 failure mode: nobody had fetched origin since another machine pushed).
  # Runs for ANY target, including an explicit override: the push destination does not change
  # with the merge source. Tolerates failure — offline degrades to a warning + last-known refs,
  # never a hard block, since everything else `apply` does is local.
  if git remote get-url origin >/dev/null 2>&1; then
    git fetch --no-tags origin 2>&1 | tail -3 \
      || warn "  ⚠ could not fetch origin — stale-base check falls back to the last known origin refs."
  else
    dim "  (no 'origin' remote — stale-base check skipped)"
  fi

  # Refuse to entangle a merge with uncommitted TRACKED work (modified or staged).
  # Untracked files are deliberately NOT a blocker: git will not merge into them, and the
  # abort path's reset cannot clobber them, so gating on them is strictly too tight — a stray
  # agent worktree under .claude/worktrees/ once refused an otherwise-clean apply. Warn only.
  if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    fail "tracked changes present (modified or staged) — commit or stash first. Tree untouched."
    git status --short --untracked-files=no | head -20 | sed 's/^/      /'
    exit 1
  fi
  local untracked
  untracked=$(git ls-files --others --exclude-standard 2>/dev/null | head -5)
  if [ -n "$untracked" ]; then
    warn "  ⚠ untracked files present — not a blocker (they cannot conflict with the merge):"
    printf '%s\n' "$untracked" | sed 's/^/      /'
  fi

  # Fail-closed stale-base guard — must run AFTER the origin fetch above and BEFORE any merge.
  assert_not_behind_origin || exit 1

  # Read-only preview at merge time — ADVISORY only. merge-tree --name-only does not cleanly
  # enumerate conflicted paths, so we never decide on it: the guarded real merge below is the
  # sole authority (its --diff-filter=U set drives mechanical-resolve-or-abort).
  if git merge-tree --write-tree HEAD "$target" >/dev/null 2>&1; then
    green "✓ Merge preview clean."
  else
    dim "(merge preview shows conflicts — the guarded merge will mechanically resolve version/changelog conflicts or abort.)"
  fi

  local n sha
  n=$(git rev-list --count "HEAD..$target" 2>/dev/null || echo "?")
  sha=$(git rev-parse --short "$target" 2>/dev/null || echo "?")

  bold "── Merging $target ($n commits @ $sha) ──"
  if git merge --no-ff "$target" -m "merge: sync $target @ $sha ($n commits)"; then
    green "✓ Merge committed (NOT pushed)."
  else
    # Conflict. Resolve ONLY the mechanical version/lock conflicts (fork-preserving); abort
    # on anything else, restoring the pre-merge tree exactly as the old behavior did.
    if resolve_mechanical_conflicts "$target"; then
      if git commit --no-edit >/dev/null 2>&1; then
        green "✓ Merge committed (mechanical conflicts auto-resolved, fork lines preserved, NOT pushed)."
      else
        git merge --abort 2>/dev/null || true
        fail "could not complete merge commit after resolution. Tree restored to pre-merge HEAD."
        exit 1
      fi
    else
      local conflicts
      conflicts=$(git diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ' ')
      fail "merge aborted — non-mechanical conflicts in: ${conflicts:-<unknown>}. Tree restored to pre-merge HEAD."
      report_manual_conflict_hints "$conflicts"
      git merge --abort 2>/dev/null || true
      exit 1
    fi
  fi
  echo

  # Retrack the fork version to <upstream-base>-dev-fork.N (idempotent; no-op if already correct).
  if ! reconcile_version; then
    fail "version reconcile failed — merge is committed but version may be wrong."
    dim "  To undo the merge: git reset --hard ORIG_HEAD"
    exit 1
  fi
  echo

  bash scripts/post-merge-verify.sh
  local rc=$?
  echo
  if [ "$rc" = "0" ]; then
    green "✓ All gates passed. Merge is committed but UNPUSHED."
    dim   "  next: bash scripts/rtk-upgrade.sh install   (then confirm the push)"
  else
    fail "Gates failed (rc=$rc). The merge is already committed."
    dim "  To undo the merge: git reset --hard ORIG_HEAD   (returns to pre-merge HEAD)"
  fi
  exit "$rc"
}

cmd_install() {
  # Build + install the merged binary into ~/.cargo/bin, then VERIFY the install took:
  # the binary the user's shell actually invokes must report the merged Cargo.toml version.
  # This closes the gap where post-merge-verify only builds target/release/rtk (never installed).
  # `--force` so an unchanged version string (e.g. after a human fix that didn't bump) still
  # reinstalls the new code rather than cargo refusing as "already installed".
  bold "=== RTK install ==="
  echo "branch: $(git rev-parse --abbrev-ref HEAD)   head: $(git log -1 --oneline HEAD)"
  echo

  local repo_ver
  repo_ver=$(grep -m1 '^version' Cargo.toml | sed -E 's/.*"(.*)".*/\1/')

  bold "── Installing (cargo install --path . --force) ──"
  if cargo install --path . --force >/tmp/rtk_install.txt 2>&1; then
    green "✓ cargo install --path . (built rtk $repo_ver)"
  else
    fail "cargo install failed (digest below; full: /tmp/rtk_install.txt)"
    grep -nE 'error\[|error:|^error|warning:' /tmp/rtk_install.txt 2>/dev/null | head -15 | sed 's/^/      /' || true
    exit 1
  fi
  echo

  # ── Install verification ──
  # The installed binary on PATH must report the merged version. A mismatch also catches the
  # documented name-collision (Rust Token Killer vs the unrelated "Rust Type Kit" rtk).
  bold "── Install verification ──"
  local bin_path installed_ver
  bin_path=$(command -v rtk || true)
  if [ -z "$bin_path" ]; then
    fail "rtk not found on PATH after install — is ~/.cargo/bin on PATH?"
    exit 1
  fi
  dim "  binary: $bin_path"
  installed_ver=$(rtk --version 2>/dev/null | grep -oE '[0-9][0-9A-Za-z.+_-]*' | head -1)
  if [ "$installed_ver" = "$repo_ver" ]; then
    green "✓ installed rtk $installed_ver matches merged Cargo.toml"
    echo
    green "✓ Install complete and verified."
  else
    fail "installed rtk version (${installed_ver:-<none>}) != merged Cargo.toml ($repo_ver)"
    dim "  wrong binary on PATH? (name-collision: Rust Token Killer vs 'Rust Type Kit' rtk)"
    exit 1
  fi
}

case "${1:-}" in
  check)   cmd_check ;;
  apply)   cmd_apply "${2:-}" ;;
  install) cmd_install ;;
  *)       usage ;;
esac
