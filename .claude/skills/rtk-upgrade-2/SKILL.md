---
description: RTK fork upgrade — orchestrate the upgrade scripts and render their checklists. Trigger on "check rtk upstream", "should I upgrade rtk", "what's new upstream", "sync the fork", "merge upstream into rtk", "compile rtk changelog", or any rtk fork-sync request.
allowed-tools: Bash Read AskUserQuestion
---

# RTK Upgrade (orchestrate, don't improvise)

Drive the RTK fork upgrade with **three script subcommands (check / apply / install) and a render
step**. The scripts are deterministic and emit compact `✓`/`✗` checklists; your job is to run them,
render their output, and gate the install + push. Do NOT re-verify by hand — that manual re-checking
is the context bloat this skill exists to eliminate.

## Why this is scripted

rtk is a *fork* (Azure `az_cmd`, removed MCP bridge, SIGPIPE / `find` parallel-walk / args_utils
fixes), so an upgrade must preserve fork features through a real merge — more than ctx-upgrade's
pull+reinstall. All that determinism lives in the scripts, so it never has to live in your context:

- `bash scripts/rtk-upgrade.sh check` → fetch + decision report; ends with machine-stable
  `RECOMMENDATION:` and `next:` lines.
- `bash scripts/rtk-upgrade.sh apply` → re-preview, merge `upstream/develop` (scripted abort on
  conflict), full quality gate + fork-invariant assertions + behavior spot-checks. Leaves the
  merge **committed-but-UNPUSHED**.
- `bash scripts/rtk-upgrade.sh install` → `cargo install --path . --force` the merged binary into
  `~/.cargo/bin`, then assert the installed `rtk --version` matches the merged `Cargo.toml` version.
  This is what makes the upgrade *take effect* for the user's shell — `apply` only builds
  `target/release/rtk`. Local + reversible (reinstall the prior tag).

## Flow

1. Run `bash scripts/rtk-upgrade.sh check` **once**. Render its output. Read the final
   `RECOMMENDATION:` and `next:` lines.
2. **CURRENT** or **DEFER** → report the one-line rationale and STOP. (The usual outcome.)
3. **Check-only phrasing** — the user asked a *question* ("should I…?", "anything worth pulling?",
   "what's new?") → STOP after the check report regardless of recommendation. Never auto-merge
   on a question.
4. **INVESTIGATE + an upgrade *imperative*** ("upgrade", "sync the fork", "merge upstream") → run
   the printed `next:` command (`apply`) **once**. Render its `✓`/`✗` checklist.
   - If `check` showed the merge preview as unavailable (`?` / git < 2.38), ask one confirm
     question before running `apply` (the conflict signal is degraded).
5. **If `apply` reports an aborted merge** → STOP and report the conflict list verbatim. Do NOT
   inspect files or resolve by hand — `apply` already restored the tree.
6. **If any gate shows `✗`** → read the inline failure digest first. Open `/tmp/pmv_*.txt` only if
   the digest is insufficient, and **at most the first ~60 lines**. Fix the cause, then re-run
   `bash scripts/post-merge-verify.sh` to reverify — never hand-roll `cargo`.
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

## Maintenance

The decision pivots — `HOT_PATHS` (in `scripts/upgrade-check.sh`) and the fork-invariant checks
(in `scripts/post-merge-verify.sh`) — are hand-maintained and each carries a `DRIFT GUARD`
comment. When you add or remove a fork feature or a high-traffic filter, update those lists in
the same change so this skill can't silently bless a merge that dropped a fork feature.
