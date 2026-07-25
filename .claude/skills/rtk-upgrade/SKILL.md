---
description: RTK fork upgrade — orchestrate the upgrade scripts and render their checklists. Trigger on "check rtk upstream", "should I upgrade rtk", "what's new upstream", "sync the fork", "merge upstream into rtk", "compile rtk changelog", or any rtk fork-sync request.
allowed-tools: Bash Read AskUserQuestion
---

# RTK Upgrade (orchestrate, don't improvise)

Drive the RTK fork upgrade with **three script subcommands (check / apply / install) and a render
step**. The scripts are deterministic and emit compact `✓`/`✗` checklists; your job is to run them,
render their output, and gate the install + push. Do NOT re-verify by hand — that manual re-checking
is the context bloat this skill exists to eliminate.

The scripts live at the **repo root** (`<repo>/scripts/`), not in this skill folder. Run them from
the rtk project root exactly as written — `bash scripts/rtk-upgrade.sh check` — never rewrite the
path relative to the skill directory.

## Versioning (what `apply` reconciles)

The fork version is **`<upstream/develop Cargo.toml base>-dev-fork.<N>`** — e.g. upstream develop
`0.42.5` → fork `0.42.5-dev-fork.1`. `apply` retracks it automatically after every merge; you never
hand-edit it.

- **N** = `max(existing git tags "<base>-dev-fork.*") + 1`, else `1` (monotonic, collision-safe).
- **Canonical sites (lockstep):** `Cargo.toml`, `.release-please-manifest.json`, and `Cargo.lock`'s
  own `rtk` entry. `post-merge-verify.sh §5` hard-fails if these three disagree.
- **Conflict resolution** is fork-preserving, NOT blanket take-upstream: on a version-bumping sync,
  `apply` takes **ours** for `Cargo.toml`/manifest (keeping fork-owned lines — `description`,
  `license`, the `insta` dev-dep, deps) and lets reconcile overwrite only the version; it **aborts**
  if upstream changed any non-version line in `Cargo.toml` (a real dependency change needs you).
  `CHANGELOG.md` is resolved by the `merge=union` driver in `.gitattributes` (keeps both histories).
- **`README.md` is fork-owned** — `az`, the removed MCP bridge, the fork install story — so `apply`
  takes **ours** on conflict and logs that upstream's side was discarded (review by hand if you
  care). Deliberately *not* `merge=union`: union suits an append-only changelog, but on a README it
  duplicates sections and contradicts itself.
- **Never auto-resolved:** `docs/guide/resources/what-rtk-covers.md` (a capability manifest that must
  keep BOTH upstream's new ecosystems and the fork's deltas), `src/main.rs` (routing table) and
  `src/hooks/hook_cmd.rs` (egress surface) — an auto-resolve there can resurrect the MCP bridge or
  telemetry. `apply` aborts and prints a targeted reminder for each.
- **Known, accepted property:** `-dev-fork.N` is a semver *pre-release*, so it sorts *below* its
  base (`0.42.2-dev-fork.1` < `0.42.2`). The scripts compare on **base**, and `install` keeps
  `cargo install --force` so this never reads as a refused "downgrade".

## Why this is scripted

rtk is a *fork* (Azure `az_cmd`, removed MCP bridge, SIGPIPE / `find` parallel-walk / args_utils
fixes), so an upgrade must preserve fork features through a real merge — more than ctx-upgrade's
pull+reinstall. All that determinism lives in the scripts, so it never has to live in your context:

- `bash scripts/rtk-upgrade.sh check` → fetch + decision report; ends with machine-stable
  `RECOMMENDATION:` and `next:` lines.
- `bash scripts/rtk-upgrade.sh apply` → merge `upstream/develop`, auto-resolving ONLY the
  mechanical version/changelog/README conflicts (fork-preserving — see § Versioning) and aborting on any
  other conflict, then retrack the fork version, then full quality gate + fork-invariant
  assertions + behavior spot-checks. Leaves the merge **committed-but-UNPUSHED**.
- `bash scripts/rtk-upgrade.sh install` → `cargo install --path . --force` the merged binary into
  `~/.cargo/bin`, then assert the installed `rtk --version` matches the merged `Cargo.toml` version.
  This is what makes the upgrade *take effect* for the user's shell — `apply` only builds
  `target/release/rtk`. Local + reversible (reinstall the prior tag).

## Flow

1. Run `bash scripts/rtk-upgrade.sh check` **once**. Render its output. Read the final
   `RECOMMENDATION:` and `next:` lines.
2. **CURRENT** or **DEFER** → report the one-line rationale and STOP. (The usual outcome.)
   - **EXCEPTION — master-only alert.** `check` independently scans `upstream/master` for fixes
     the develop sync can NOT bring in (rare security backports / hotfixes). If it emits a
     `MASTER_ALERT:` line (the dispatcher reprints it as a `⚠ MASTER-ONLY:` warning under `next:`),
     do NOT silently stop — surface it even on CURRENT/DEFER. These are ported **directly**, not via
     the develop merge: `git show <sha>` to inspect, then `git cherry-pick -x <sha>` (auto-cites the
     SHA) or a hand-port that names the SHA in the commit body. The body citation is what makes the
     next `check` recognise it as `✓ ported` and stop re-alerting.
3. **Check-only phrasing** — the user asked a *question* ("should I…?", "anything worth pulling?",
   "what's new?") → STOP after the check report regardless of recommendation. Never auto-merge
   on a question.
4. **INVESTIGATE + an upgrade *imperative*** ("upgrade", "sync the fork", "merge upstream") → run
   the printed `next:` command (`apply`) **once**. Render its `✓`/`✗` checklist.
   - If `check` showed the merge preview as unavailable (`?` / git < 2.38), ask one confirm
     question before running `apply` (the conflict signal is degraded).
5. **If `apply` reports an aborted merge** → STOP and report the conflict list verbatim. Do NOT
   inspect files or resolve by hand — `apply` already restored the tree. Wait for the user.
   - **If the user then says to resolve them**, the sanctioned route back onto the golden path is:
     `git merge --no-ff <target> -m "merge: sync <target> @ <sha> (<n> commits)"` (the exact command
     `apply` runs), resolve ONLY the conflicted files, `git add` + `git commit`, then **re-run
     `bash scripts/rtk-upgrade.sh apply`**. The merge is already committed, so `apply`'s own merge
     step reports `Already up to date` and it proceeds straight to `reconcile_version` + the full
     gate. Do NOT hand-roll the version retrack: it is `reconcile_version` in `rtk-upgrade.sh` and
     sourcing that file to call it directly fails (`BASH_SOURCE` is unbound under `eval`).
   - Prefer merging into `develop` over a feature branch. On 2026-07-24 the same sync produced 2
     conflicts on `develop` but 4 on `harden/no-egress`, the two extra being `src/main.rs` and
     `src/hooks/hook_cmd.rs` — the security-sensitive pair. Sync `develop` first, then bring the
     feature branch forward, so doc conflicts and egress-surface conflicts are reviewed separately.
6. **If any gate shows `✗`** → read the inline failure digest first. Open `/tmp/pmv_*.txt` only if
   the digest is insufficient, and **at most the first ~60 lines**. Fix the cause, then re-run
   `bash scripts/post-merge-verify.sh` to reverify — never hand-roll `cargo`.
   - **A textually clean merge can still be semantically broken.** Expect `E0063`-class failures
     where upstream adds a struct field and a fork-only initializer does not set it — git merges
     both sides without complaint and the gate is what catches it. Fix by adopting upstream's
     idiom (e.g. `..Struct::DEFAULT`), not by special-casing the fork.
   - **Disconfirm before claiming a regression.** A `✗` may be environmental, not merge damage:
     `RTK_NO_AUTO_ALLOW=1` in the shell flips `auto_allow_enabled()` and reds 7 upstream hook
     tests on `harden/no-egress`. Re-run with `env -u RTK_NO_AUTO_ALLOW`, and to prove a failure
     pre-dates the merge, run the same target in a throwaway `git worktree add --detach <pre-merge-sha>`.
     Full procedure: `AGENTS.md` § RTK compression-drop disconfirmation.
7. **All gates `✓`** → ask the user to confirm the local install (AskUserQuestion). On confirm,
   run `bash scripts/rtk-upgrade.sh install` **once** and render its `✓`/`✗`. This recompiles and
   installs the merged binary to `~/.cargo/bin` and verifies the installed `rtk --version` matches
   the merged `Cargo.toml` — it's what makes the upgrade take effect for the user's shell. On an
   install `✗` (build failure or version mismatch), read the inline digest, fix, and re-run the
   `install` subcommand — never hand-roll `cargo install`. **Install before push** (prove the local
   binary works, then publish).
8. **Install `✓`** → ask the user to confirm the push (AskUserQuestion). On confirm,
   `git push origin <branch>`. Otherwise leave it committed-unpushed.

## Rules (the whole point — follow exactly)

- **Trust the `✓`/`✗`.** Do NOT re-verify a script's result with manual `git show` / `cat-file` /
  `git diff` / `cargo`. The scripts already assert every fork invariant and run the full gate.
- **Run the `next:` command** the `check` report prints — don't re-derive what to run next.
- **Don't re-run a passing script.** Re-run one only when its inputs changed (e.g.
  `post-merge-verify.sh` after a human fix). Reverify with the script, never by hand.
- **Verbose output stays in `/tmp`.** Read the inline digest; open `/tmp/pmv_*.txt` only on `✗`,
  capped at ~60 lines. Never paginate diffs or build logs.
- **Install is confirmed but not the hard gate.** `cargo install` is local + reversible (reinstall
  the previous tag), so confirm it like the push but don't treat it as outward-facing. It always
  goes through the `install` subcommand — never hand-roll `cargo install`.
- **Push is the only hard gate.** The local merge is reversible (`git reset --hard ORIG_HEAD`);
  the push is outward-facing — always confirm it.

## Output Format

Render the script checklists; add a one-line headline (the `RECOMMENDATION`, or the apply
pass/fail summary). Don't restate the full diff stat unless asked.

- **"Files touched by new upstream/develop commits" is a three-dot diff** (`develop...upstream/develop`):
  it lists ONLY the upstream-side delta since the merge-base — i.e. exactly what the merge brings in.
  Fork-only files (FORK_NOTES.md, `scripts/`, `az_cmd.rs`, this SKILL, …) will **never** appear there,
  and the deletion counts are upstream's, not yours. If you (or the user) see this section, do NOT
  read it as "the merge will delete fork files" — by construction it cannot. No investigation warranted.
- **The merge-tree preview is authoritative for the branch it names, not for `develop`.** It is
  computed against `HEAD`, because `apply` merges into whatever branch is checked out. When `HEAD`
  is not `develop`, the preview prints `preview computed for branch <name> (not develop) — apply
  will merge into this branch`; surface that line and read the conflict list as belonging to that
  branch. The develop-based sections above it can list fewer files.
- **"Master-only commits (NOT reachable via develop sync)"** lists `upstream/master`-only commits,
  each tagged `🔴 SECURITY` / `⚠ unported` / `✓ ported`. Release/chore/ci noise is filtered; a commit
  is `✓ ported` if it's an ancestor of the fork OR its SHA is cited in a fork commit body. This is
  the fork's blind spot (it syncs from develop only), so anything `🔴`/`⚠` here is real, unported,
  and needs a direct port — see Flow step 2's exception. Detector lives in
  `scripts/lib/master-only.sh`, tested by `scripts/test-master-only.sh` (run inside
  `post-merge-verify.sh`, since shell tests are NOT covered by `cargo test`/`clippy`).

## Maintenance

**Before changing a guard, reproduce it firing.** Most of both scripts only runs when something
is wrong, so in the repo's steady state a broken guard is indistinguishable from a working one —
two shipped defective on 2026-07-24 and neither showed up in a normal run. `debug/` holds
scenario builders (`simulate-stale-origin.sh`, `simulate-behind-upstream.sh`, both
`setup`/`teardown`, both local-only) that construct the triggering state. Run the harness before
and after your change; see `debug/README.md`.

The decision pivots — `HOT_PATHS` (in `scripts/upgrade-check.sh`), the fork-invariant checks
(in `scripts/post-merge-verify.sh`), and the `VERSION_FILES` set (in `scripts/rtk-upgrade.sh`) —
are hand-maintained and each carries a `DRIFT GUARD` comment. When you add or remove a fork
feature, a high-traffic filter, or a version-carrying file, update the matching list in the same
change so this skill can't silently bless a merge that dropped a fork feature or skipped a version
site. The version scheme + conflict contract live in § Versioning above; `Cargo.toml`,
`.release-please-manifest.json`, and `Cargo.lock` are the only files `apply` reconciles — if a new
version-carrying file appears (e.g. a real `Formula/rtk.rb` version), add it to `VERSION_FILES` and
the §5 consistency gate, or it will drift.
