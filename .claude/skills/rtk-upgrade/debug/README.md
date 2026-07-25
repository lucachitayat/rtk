# Upgrade-tooling debug harnesses

Scenario builders for `scripts/upgrade-check.sh` and `scripts/rtk-upgrade.sh`.

## Why these exist

Both scripts are mostly **guards** — code that only runs when something is wrong. In the repo's
normal steady state (fork current with upstream, branch pushed, tree clean) every guard is
unreachable, so a broken guard looks exactly like a working one. On 2026-07-24 two shipped
defective and neither was caught by running the tool normally:

- The merge preview was changed to follow `HEAD`, but the `CURRENT` early-exit above it still
  keyed on `develop`. On a feature branch behind upstream while `develop` was current, `check`
  printed `RECOMMENDATION: CURRENT` and exited **before** the preview. The fix was unreachable
  dead code in exactly the case it was written for.
- Nothing in the tooling looked at `origin` at all, so a sync ran onto a base one commit stale,
  duplicated an already-landed fix, and only failed at `git push` after every gate had passed.

Running `check` after a successful sync reports `CURRENT` and tells you nothing. **A guard you
cannot trigger is a guard you have not tested.** These scripts build the triggering state.

## Usage

Both take `setup` / `teardown` and are safe to re-run. Everything they create is local — a
scratch worktree under `/tmp`, a throwaway branch, and (for the stale-origin case) a
remote-tracking ref. No network, no push, nothing touching a real branch.

```bash
bash .claude/skills/rtk-upgrade/debug/simulate-stale-origin.sh setup
bash .claude/skills/rtk-upgrade/debug/simulate-stale-origin.sh teardown
```

### `simulate-stale-origin.sh` — branch behind its own remote

Exercises the `⚠ STALE BASE` block in `check`'s Divergence section and `assert_not_behind_origin`
in `apply`. Builds the diverged case (behind *and* ahead), which is the harder one.

Expected: `check` prints `STALE BASE … N commit(s) BEHIND`, and `apply` exits non-zero with
`refusing to merge onto a stale base. Tree untouched.` before fetching or merging anything.

### `simulate-behind-upstream.sh` — HEAD genuinely behind upstream

Exercises the HEAD-relative divergence line, the merge preview, and the `INVESTIGATE` path.
Takes an optional commit-ish (default: the merge-base with `upstream/develop`).

Expected: `check` reports `<branch> behind upstream/develop: N commits (apply merges into THIS
branch)`, runs the preview, names the branch it was computed for, and recommends `INVESTIGATE` —
**not** `CURRENT`.

## Gotcha that will cost you a cycle

Both harnesses copy the **working-tree** versions of the scripts into the scratch worktree, so
you test your uncommitted edits rather than what is committed. That makes the scratch tree dirty,
and `apply`'s clean-tree guard fires before the guard you are trying to reach. Both scripts
therefore commit the copied scripts during `setup`. If you copy anything in by hand afterwards,
commit it there too or you will keep hitting the wrong guard.

## Verifying a fix properly

Run the harness **before** the fix and capture the wrong behaviour, then after. A fix to a guard
that was never observed failing is a guess. See `AGENTS.md` § Disconfirming an ALL-CLEAR for the
generalisation, and § RTK compression-drop disconfirmation for the same principle applied to
output diffs.

## Writing a positive control for a SCAN

These harnesses trigger guards by building state. The other family of untestable-by-normal-use
check is the **scan** that reports PASS on finding nothing, where a wrong pattern, wrong root or
eaten flag is indistinguishable from a clean tree. `scripts/test-export-detectors.sh` is the
worked example (it controls the enterprise export's residual scan); `scripts/test-master-only.sh`
is the template both follow. A canary must satisfy all five, and each one is there because a
canary lacking it was written, looked convincing, and was then falsified:

1. planted **inside the scanned root**, under a **non-hidden** filename — ripgrep applies its
   hidden-file filter to directory traversals but not to explicitly-named paths (rg 15.2.0:
   explicit hidden file `rc=0`, same file via traversal `rc=1`), so a canary outside the root or
   hidden inside it probes a path the real scan cannot reach;
2. a **mixed-case** token, and nothing case-matching the pattern anywhere else in the planted
   file — a lowercase canary passes even when `-i` has been lost;
3. probed through the **same function the real check calls**, not a retyped command line — which
   is why the detector lives in `scripts/lib/`;
4. assert the canary's **path appears in rendered output**, not merely that the exit status moved;
5. **one canary per alternation term** — one term witnesses one branch.

Then the part that makes the set a control rather than a decoration: **re-break the detector on
purpose and confirm the canaries fail.** A canary that has never been seen to fail is one more
uncontrolled absence assertion.
