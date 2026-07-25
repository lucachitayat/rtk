# Fork Notes

Running log of decisions, in-flight work, and open questions specific to this fork of `rtk-ai/rtk`. **Not for upstream consumption** — this file lives on fork `master` only and is not intended to be PR'd upstream.

Newest entries on top.

---

## 2026-07-24 (later) — Adversarial review of the verification surface

Reviewed the post-sync hardening plan with four adversarial subagents (counterexamples, logic traps,
alternative paradigms, downstream contract safety). The review paid for itself several times over:
it falsified three of the plan's six mechanisms and surfaced a live defect in the published distro.

### The frame

Every defect in the sync was an **absence assertion** — a check proving a negative — and every one
failed by returning "all clear." Presence checks fail loud; absence checks fail silent *and
reassuring*. Round 2 then falsified the dichotomy in both directions, and the corrected invariant is
the one worth keeping:

> Absence assertions need a **detector** control AND a **domain** control. Presence assertions fail
> loud only when they actually **execute**.

### Live defect — the distro was shipping its own contradiction

`docs/TELEMETRY.md` was published in `lucachitayat/rtk-enterprise`: 189 lines opening *"RTK collects
anonymous, aggregate usage metrics once per day"*, naming a data collector and a contact address —
in a distribution whose entire premise is no egress. The binary was clean the whole time; only the
documentation lied.

Cause: step 1 is `git archive | tar -x`, `.gitattributes` had no `export-ignore`, and the residual
scan was scoped to `${OUT_DIR}/src/`. **Nothing defined what the distro ships.** The published tree
also contained `.claude/` (agent skills, rules, debug harnesses), `AGENTS.md`, `CLAUDE.md`,
`.github/`, `scripts/`, and `FORK_NOTES.md` — this file, a running log of the fork's security posture
and unfixed defects, delivered to the customers it is meant to reassure.

Fixed by declaring the shipped surface (`ef1c4ae`) rather than scrubbing it: an allowlist in a scan
must be maintained per-pattern forever, an exclusion removes whole classes of leak and is auditable
at a glance.

### Line-scrubbing prose is unsound — measured, not theorised

Widening the scan alone made things *worse*. Line-based scrubbing deletes the lines that NAME the
thing and keeps the lines that DESCRIBE it: README's `## Privacy & Telemetry` heading and intro went,
and the ten-row table beneath survived — "Salted device hash", "Command count (24h)", "Estimated USD
value" — because not one row contains the word "telemetry". **The scan passed.** The detector's
vocabulary and the residual's vocabulary had simply stopped overlapping. Shipped result: a
data-collection catalogue with the sentence that framed it as opt-in removed, plus two empty code
fences. Now removes markdown **sections** whole and collapses emptied fences (`7a4e10f`).

Conclusion recorded for the follow-up: **subtract code, author prose.** Code subtraction is
mechanical and the compiler is the witness. Prose subtraction is judgment executed by a regex, and a
distro's docs should say *different* things ("no egress, here is how to verify"), which no
subtraction can produce. An `enterprise/docs/` overlay belongs in the fork — not in the enterprise
repo, which is regenerated as an orphan commit and would destroy hand edits. Precedent already
exists: `DISCLAIMER.md` + `REVIEWER-README.md` + `SECURITY-HARDENING.md` = 324 authored lines.

### Checks that were green and proved nothing

- **`build.rs`'s egress guard has never run.** It returns unless `CARGO_FEATURE_TELEMETRY` is *also*
  set; `enterprise = []` activates nothing and the export deletes the telemetry feature, so the
  lockfile scan is unreachable in every configuration this project builds — while
  `export-enterprise.sh` and `post-merge-verify.sh` both printed that it passed. Labels corrected;
  reachability (gate on feature *declaration*, not activation) is still open.
- **`build.rs`'s own unit tests never execute.** Build scripts compile to a standalone binary, so
  `cargo test` does not run them. The positive control for `forbidden_in_lockfile` had itself never
  run. Correct invocation is recorded in the review transcript.
- **`cargo test <filter>` exits 0 when the filter matches nothing** — verified:
  `zzz_no_such_filter` → exit 0, "0 passed, 2544 filtered out". The enterprise gate step would have
  printed a green `✓ (0 passed)` the day upstream relocated the module. Now asserts a non-zero count.
- **`test_auto_allow_enabled_false_when_enterprise_feature` asserts nothing anywhere.** Its body is
  entirely `#[cfg(feature = "enterprise")]`, so the default build runs an empty function and reports
  passed; and the only enterprise run filters on `fork_tests`, which its path does not match. The
  fork's headline property — `enterprise ⇒ !auto_allow_enabled()` — has no executing witness. Move
  pending; note it contradicts `fork_tests.rs:53-54`, which must be amended in the same commit.
- **`grep` exit 2 read as clean.** The conflict-marker scan's `else` branch treated a missing path
  argument as "no markers found". Four `inv_exists` guards added.
- **`cargo tree` fail-open.** `2>/dev/null | grep -i ureq || true` printed PASS when cargo tree
  failed *and* when `OUT_DIR` was absent. Three outcomes now: CLEAN / FOUND / CANNOT-VERIFY. Also
  `--target all`, since it defaulted to the host triple while `Cargo.toml` has a `cfg(unix)` section.
- **`ci.yml`'s egress scan omits `ureq`** — the fork's actual HTTP client — on a branch named
  `harden/no-egress`. Open.
- **~30 `rg`-dependent tests pass vacuously in CI**, which never installs ripgrep. Open; note the
  `test` job is a 3-OS matrix with no install steps (the `tree` install is in the `benchmark` job).

### Method note, recorded deliberately

Verifying the telemetry-doc finding, I scanned `/tmp/rtk-enterprise-export`, got zero matches, and
nearly reported the finding refuted. **The directory had been deleted.** I read an empty result from
a non-existent target as "clean" — the exact failure this entry is about, committed while
investigating it. Ground truth came from `gh api` against the published repo. Four further false
negatives came from my own malformed patterns (BRE `|`, `rg -r`, unescaped backticks). The rule:
**assert the target exists before believing an empty result**, and prefer the published artifact over
any local copy.

---

## 2026-07-24 — Sync upstream/develop @ bee2178 (231 commits); tooling hardening

Merged 231 commits from `upstream/develop` into `develop` (merge `7659d3a`, `--no-ff`), then brought
`harden/no-egress` forward (merge `6fe29c6`). Fork version retracked to `0.42.4-dev-fork.2`. Both
branches pushed; `cargo install --path . --force` verified the installed binary matches.

### Merge into `develop` — 2 conflicts, both docs
- `README.md` → took **ours**. Upstream's side hardcoded a stale `rtk 0.28.2` in the verify snippet;
  the fork's is version-agnostic. This case is now mechanised (see `OURS_DOC_FILES`).
- `docs/guide/resources/what-rtk-covers.md` → genuine merge, took upstream's header (matches the rest
  of the doc) plus its `jest` row the fork had dropped. Verified the `az` section (12 rows) survived
  and no MCP re-advertisement crept back.

### Merge into `harden/no-egress` — 5 conflicts
Sequencing mattered: the same upstream delta conflicts in **2** files on `develop` but **4** on
`harden/no-egress`, the extra two being `src/main.rs` and `src/hooks/hook_cmd.rs` — the egress-sensitive
pair. Syncing `develop` first isolated the doc conflicts from the security-relevant ones.
- Three were pure adjacency: fork enterprise tests vs upstream's new Factory Droid tests (×2), and
  `RTK_META_COMMANDS` next to upstream's new `SbtCommands` enum. All additive, both sides kept.
- `cursor_ask` was real divergence. The fork omitted `"permission"` entirely; upstream now sets
  `"permission": "ask"`. **Adopted upstream's.** Both prompt the human, so approval is unchanged, and
  the fork's test was overspecified — it asserted field *absence* when the actual invariant is "never
  `allow`". Retitled `test_hardening_cursor_ask_never_allows_carries_rewrite` and it now asserts the
  value. Removes a divergence that conflicted on every sync.
- Upstream moved `RTK_META_COMMANDS` into a new shared `src/core/constants.rs`; the fork's local copy
  became a dead duplicate (`dead_code` error). Deleted it after diffing both lists — identical apart
  from upstream leaving `"telemetry"` ungated.

### Semantic conflict — a clean merge that did not compile
`src/discover/rules.rs` merged textually clean, then failed `E0063`: upstream refactored `RtkRule` to a
`..RtkRule::DEFAULT` spread and added `pipeline_final_safe`, and the fork's `az` rule predates that,
enumerating fields explicitly. Adopted the spread like every neighbouring rule (`7673a53`). Yields
`pipeline_final_safe: false`, inert for `az` — it is always a shell pipeline's *first* segment.

### Tooling defects found and fixed
- **`check`'s CURRENT early-exit keyed on `develop`, not `HEAD`** (`954b4a5`). The merge preview had been
  moved to follow `HEAD`, but the early-exit deciding whether the preview is *reached* had not — so on a
  feature branch behind upstream while `develop` was current, `check` printed CURRENT and exited before
  previewing. Caught only by running `check` in a detached worktree at the pre-merge commit, where it
  claimed CURRENT while 228 commits behind with 19 conflicting files. Six decision sites moved to
  `HEAD..upstream/develop`; the `develop` lines remain sync-source bookkeeping that must not gate.
- **The conflict-marker probe false-positived on `={7}`** — upstream's new `src/cmds/python/uv_cmd.rs`
  carries a pytest banner fixture. Independently already fixed on `origin/develop` by `533bda5`
  (2026-07-12); this sync duplicated that work because local `develop` was one commit stale and
  nothing in `check` looks at `origin`. Resolved in favour of `533bda5`, which also carries CRLF and
  Windows path fixes. **Root cause is now tracked: the tooling models `upstream` and the local branch
  but never the fork's own remote.**
- **`apply` refused to run on untracked files** — an unrelated agent worktree directory blocked it.
  Untracked files cannot conflict with a merge nor be clobbered by the abort path's hard reset.

### Enterprise / MCP notes
- `develop` carries **no** enterprise code at all — no `[features]` block, no `auto_allow_enabled`, no
  export script. The whole apparatus lives on `harden/no-egress`. That separation is sound; keep it.
- `post-merge-verify.sh` never builds or tests `--features enterprise`, so a merge can break the distro
  and it is only caught at export time by `export-enterprise.sh` step 6d. Verified manually this sync
  (clean), but that was luck, not verification.
- 8 fork-only tests (`test_hardening_*`, `test_enterprise_*`) sit inside `src/hooks/hook_cmd.rs`, an
  upstream-owned high-churn file, and caused 2 of the 5 conflicts above. Same permanent-conflict-surface
  pattern that motivated dropping the MCP bridge on 2026-05-21.
- `~/.claude.json` still registers a `rider` MCP server invoking `rtk mcp-proxy`, a subcommand deleted
  in `8011f9a` (2026-05-21). The entry cannot work and will hang. Recovery anchor if ever wanted:
  tag `fork/mcp-bridge-archive-20260521`.

### Notable upstream content
Full changelog compiled to `/tmp/rtk-upstream-changelog.md` (149 itemized + 32 noise = 181 non-merge).
Dominant theme is correctness hardening: a cross-cutting `never_worse` output guard (`861a46d`) so RTK
can never emit more tokens than the raw command; a grep/rg overhaul (`eafadce`, `37ee6cf`, `66b95cb`,
`0adfae6`) making `grep` run the engine actually invoked instead of silently substituting ripgrep with
translated flags — which had been causing silent false-negative greps in this very repo; a 26-commit
series fixing `cargo --message-format=json` reporting failing builds as compiled; `dotnet test` no
longer double-reporting failures; and TOML-filter trust-gating (`1130a7c`) requiring explicit
`rtk trust` before any custom filter runs.

### Build gate
`env -u RTK_NO_AUTO_ALLOW bash scripts/post-merge-verify.sh` — all green on both branches: fmt, clippy,
2539/2550 tests, 8 shell tests, release build, 11 fork invariants, 3 behaviour spot-checks, version
consistency. With `RTK_NO_AUTO_ALLOW=1` set (the ambient shell value), 7 upstream hook tests fail on
`harden/no-egress`; proved pre-existing by running the identical target in a detached worktree at
`4fa5c40`, which failed the same 7.

---

## 2026-06-03 — Sync upstream/develop @ 4f4a6a0 (7 commits)

Merged 7 commits from `upstream/develop` into `develop` (merge commit `9f062ab`, `--no-ff`). **Clean 3-way merge — zero conflicts** (confirmed pre-merge by `git merge-tree`). Only 3 files changed (`Cargo.toml`, `src/cmds/git/git.rs`, `src/core/args_utils.rs`); all 41 prior fork commits preserved, `az_cmd.rs` and the `rtk-upgrade` skill intact.

### Why merge (not defer)
`/rtk-upgrade` flagged INVESTIGATE — two genuine correctness fixes on the top-2 token-volume commands:
- `89ae19b` fix(grep): rewrites `--` restoration in `args_utils.rs` from value-based matching (`parsed.contains(...)`, which **duplicated tokens** when a positional/filename equalled a command token, e.g. `rtk grep diff -- diff`, `rtk git diff -- diff`) to deterministic **position-based** math (`user_region_len = parsed.len() + missing_dashes`). Affects **`rtk grep` (#1, 78.8M tokens saved historically)** and `rtk git diff`. Brought in via merge `57e9350` (KuSh double-dash fix).
- `c5ec92f` + `ab4fa7b` fix(git): prevent a **UTF-8 byte-slice panic** (`&hash[..7]`) on multibyte branch names in `git commit` output, and correct hash extraction (old code grabbed the branch name, not the hash — now finds the `]` and takes the last whitespace token). Uses `chars().take(7)`. Touches the git/ hot path.

### Also landed
- `6f4519a` / `4c278d1` chore: declare MSRV `rust-version = "1.91"` in `Cargo.toml`. Merged in cleanly (added line; fork version/description/license preserved). Local toolchain is 1.94.1 — satisfied.

### Not impacting
- The 265-line `find_cmd.rs` delta seen in the symmetric diffstat is **the fork's own** parallel-walk work, not new upstream — `rtk find` (#2) untouched by this sync.

### Behavior note
The `args_utils.rs` rewrite drops special handling of multi-segment compound commands with `--` (`cmd1 -- a && cmd2 -- file`); those aren't a single `rtk` invocation in practice, so it's a non-issue. The removed `test_compound_command_with_dashes` reflected that.

### Version
`0.41.0-dev-fork.1` → `0.41.0-dev-fork.2`. Also fixed pre-existing drift: `.release-please-manifest.json` was lagging at `0.41.0-dev-fork.0`, now synced to `0.41.0-dev-fork.2`.

### Build gate (`scripts/post-merge-verify.sh` — all green)
- `cargo fmt --all --check` ✅ · `cargo clippy --all-targets` ✅ · `cargo test --all` ✅ **2064 passed** (+9 vs pre-merge 2055 — the new upstream multibyte/arg regression tests).
- `cargo build --release` ✅ · SIGPIPE `rtk grep | head` exits 141 (no SIGABRT) ✅ · `gh pr view` no-id forwarding ✅.
- Installed locally: `cargo install --path . --force` → live `~/.cargo/bin/rtk` now `0.41.0-dev-fork.2`.

### Rollback anchors
- Tag: **`fork/develop-pre-merge-20260603`** → `da4339d` (pre-merge `develop` tip). Revert develop: `git reset --hard fork/develop-pre-merge-20260603`.
- Binary backup: `~/.cargo/bin/rtk.bak-da4339d` (the live `0.41.0-dev-fork.1` build). Instant restore: `cp ~/.cargo/bin/rtk.bak-da4339d ~/.cargo/bin/rtk`.

---

## 2026-06-02 — perf(find): parallel walk (fork-local feature)

`rtk find` walked the filesystem on a single thread (`ignore::WalkBuilder::build()`) while the engine it uses (`ignore` crate) is the same one `fd`/`ripgrep` parallelize. Switched `collect_matches` to `build_parallel()` with a per-thread `mpsc` sender; matches are merged then sorted, so output is **byte-identical** to the serial walk.

### Why
On a 16k-file tree `rtk find . -name '*.cs'` measured **270 ms** serial; native `find` ~1.1 s. The serial walk left ~2× on the table vs `fd`. Every `find` an agent issues is hook-rewritten to `rtk find`, so this is on the hot path of daily use.

### Result (measured, warm, `hyperfine -N`)
- `rtk find`: **270 ms → 135 ms** (≈2×); now ~1.15× faster than `fd` (156 ms) **and** keeps the compact dir-grouped output.
- Output parity: `diff` of old-serial vs new-parallel `rtk find` on the real tree = **byte-identical**.

### TDD (red-green, behavior-preserving)
1. `f5ec92a` refactor — extract pure `collect_matches` (serial), suite stays green.
2. `18c7f06` test — 10 characterization tests pinning the exact result set (sort/dedup, gitignore, hidden-vs-dotfile, type filter, `-iname`, `-maxdepth`, empty).
3. `54fb9e3` perf — `build_parallel()`; the same tests pass unchanged.
4. `031a27e` chore — version bump.

### Gate
- `cargo fmt --all --check` ✅ · `cargo clippy --all-targets` ✅ (exit 0) · `cargo test` ✅ **2055 passed, 0 failed, 7 ignored**.
- `scripts/test-all.sh`: 94 passed, 12 failed, 10 skipped — the **12 failures are identical on the pre-change binary** (pre-existing: untrusted `.rtk/filters.toml`, pnpm/ccusage/curl env, rewrite-config tests). `── Find ──` assertions PASS on both. Zero new failures.

### Version
`0.41.0-dev-fork.0` → `0.41.0-dev-fork.1`. No new dependency (`ignore` already vendored).

### Rollback anchors
- Tag: **`fork/develop-pre-parallel-find-20260602`** → `ad393ed` (pre-change `develop` tip). Revert develop: `git reset --hard fork/develop-pre-parallel-find-20260602`.
- Binary backup: `~/.cargo/bin/rtk.bak-ad393ed` (the live serial build). Instant restore: `cp ~/.cargo/bin/rtk.bak-ad393ed ~/.cargo/bin/rtk` (takes effect next Bash call).

### Upstream
Clean, general improvement (not fork-specific) — candidate for an upstream PR to `rtk-ai/rtk` later. Not filed yet.

---

## 2026-06-01 — Sync upstream/develop @ 6873764 (35 commits)

Merged 35 commits from `upstream/develop` (`5a149a7..6873764`) into `develop` via `sync/upstream-develop-6873764`. **Clean merge — zero conflicts** (confirmed pre-merge by a read-only `git merge-tree` dry run; the MCP-bridge removal of 2026-05-21 eliminated the historical conflict surface). All 33 fork commits preserved; `az_cmd.rs` and the `rtk-upgrade` skill intact.

### Why merge (not defer)
`/rtk-upgrade` flagged INVESTIGATE — 3 commits touch high-traffic git paths. Two are genuine fixes worth taking:
- `e1bb17f` fix(gh,glab): stop pre-rejecting `gh pr view` / `pr checks` / `run view` / `glab mr view` when the id is omitted (RTK was blocking valid commands with "number required"). Verified live: `rtk gh pr view` now forwards to `gh`.
- `49a094a` fix: reset SIGPIPE to `SIG_DFL` — fixes SIGABRT crash on piped output. Verified live: `rtk grep … | head` exits 0, not 134. Relevant to the #1 command `rtk grep`.

### Also landed
- `83cd93e` chore(args): double-dash restoration extracted to `src/core/args_utils.rs` (−200 lines `git.rs`, −45 `cargo_cmd.rs`) — behavior-preserving refactor, +15 tests.
- `4128572` fix(gh): fallback note when a PR/issue body filters to empty (+4 tests).
- Copilot CLI hook support (`init.rs`, `hook_cmd.rs`, `constants.rs`), go build-failure exit status, init symlink fixes, README_pt.

### Cleanup
- Removed orphaned `hooks/claude/rtk-mcp-rewrite.sh` — its backing `Commands::McpRewrite` was deleted in `8011f9a` (2026-05-21); the script called a nonexistent subcommand. Recovery still available at tag `fork/mcp-bridge-archive-20260521`.

### Version
Stays `0.41.0-dev-fork.0` (already ahead of upstream `0.40.0`).

### Build gate
- `cargo fmt --all` ✅
- `cargo clippy --all-targets` ✅ (0 warnings)
- `cargo test --all` ✅ (2045 passed, 0 failed, 7 ignored)

---

## 2026-05-21 — Drop fork-owned MCP bridge (Path A); sync upstream/develop @ a04aa7e

Merged 56 commits from `upstream/develop` (`15a0d2e..a04aa7e`) into `develop` via `merge/upstream-develop-20260521`. Took **Path A** from the upgrade plan: drop the fork-owned MCP code rather than re-wire it across upstream's lint-tightening and `AgentTarget::Hermes` additions.

### Why drop
- Rider IDE usage has fallen off; the bridge (`rtk mcp-proxy`) and Rider tool-input rewriter (`rtk mcp-rewrite`) were bespoke for that workflow.
- Future upstream syncs become routine without fork-only enum variants in `src/main.rs` and a fork-only module tree.
- Recovery is cheap (see anchor below) — the code is one `git show` away.

### Recovery anchor
- Tag: **`fork/mcp-bridge-archive-20260521`** → `e104843` (pre-merge `develop` tip), pushed to `origin`.
- Resurrect with: `git show fork/mcp-bridge-archive-20260521 -- src/mcp/ src/hooks/mcp_rewrite_cmd.rs tests/integration_mcp_rewrite.rs tests/fixtures/mcp/`
- Origin commits if cherry-picking: `463886b` (feat), `3d9eb8a` (test).

### What landed from upstream
Notable, in priority of day-to-day relevance:
- `rtk pipe <filter>` — generic stdin→named-filter (extends `rtk grep` coverage to piped contexts).
- `kubectl get pods/services` compaction (#1720); `docker compose --tail` forward (#1885); `docker ps` / `ps -a` split (#1895 batch).
- `git push` streaming via new `src/core/stream.rs` framework (#1531).
- Tee truncation caps + tail hints (#1928).
- `rtk init --dry-run` + parallel-safe test coverage; `AgentTarget::Hermes` variant.
- `cargo clippy --deny warnings` mandatory in CI — drove the az_cmd lint cleanup below.

### Fork-side cleanup forced by lint tightening (rust 1.94.0 + `-D warnings`)
- `src/cmds/cloud/az_cmd.rs`: removed unused `use crate::json_cmd;` import.
- `src/cmds/cloud/az_cmd.rs`: removed dead `const GENERIC_COMPRESS_DEPTH`.
- `src/cmds/cloud/az_cmd.rs:52`: collapsed manual char comparison to slice (`line.find(['{', '['])`).
- `src/cmds/cloud/az_cmd.rs:1857`: replaced `iter::repeat().take().collect()` with `"a".repeat(N)`.

### Version
`0.40.0-dev-fork.1` → `0.41.0-dev-fork.0` (upstream cadence at rc.229 of 0.41.x).

### Build gate
- `cargo fmt --all` ✅
- `cargo clippy --all-targets` ✅ (0 warnings)
- `cargo test --all` ✅ (1958 passed, 0 failed, 6 ignored)

### Files removed
`src/mcp/{mod,proxy,response,rider}.rs`, `src/mcp/snapshots/`, `src/hooks/mcp_rewrite_cmd.rs`, `tests/integration_mcp_rewrite.rs`, `tests/fixtures/mcp/rider_search_text_response.json`. The `mod mcp;` declaration, `Commands::McpRewrite` / `Commands::McpProxy` variants + dispatch arms, and `pub mod mcp_rewrite_cmd;` export were removed from `src/main.rs` and `src/hooks/mod.rs`.

---

## 2026-04-26 — Fork branching model: introduce `develop` branch

Adopted upstream's two-track flow on the fork:
- `develop` = active integration; tracks `upstream/develop` + carries fork-only work. New feature branches base here.
- `master` = release pin at `0.38.0-fork.1`; advances only via deliberate promotion merges from `develop`.

### Why now
`CONTRIBUTING.md` (lines 182–232), `.github/workflows/ci.yml` (line 5: `branches: [develop, master]`), and `release-please-config.json` all already assume this layout — inherited from upstream and never wired up. The fork was running single-branch in defiance of its own docs. With `develop` in place, `cargo install` from `master` now means "last known-good fork version" — a real fallback if a `develop` merge regresses.

### Initial develop content
- Base: fork master (`3c9b8f9` = `0.38.0-fork.1`)
- Merged: `upstream/develop` (`323cc3d`) — net +3299/-330 across 31 files. New filter: `glab` (1535 LOC). Auto-merged cleanly via `ort` strategy, no manual conflicts.
- Merged: `chore/fork-notes-log` (transitively pulls in `test/mcp-integration-coverage`) — `FORK_NOTES.md` + 5 MCP integration test gaps + `rtk init` migrator note.
- Style: `cargo fmt` applied to fork-only `src/mcp/proxy.rs`, `src/mcp/response.rs` (had never been formatted).

### Develop version
`0.39.0-dev-fork.0`. Master pinned at `0.38.0-fork.1` until a stable cut. Per fork rule, develop > upstream/develop (`0.34.3`) and > upstream/master (`0.37.2`) ✓.

### Rollback anchor
Tag: `fork/master-pre-develop-20260426 → 3c9b8f9`. If anything goes sideways:
```
git switch master
git branch -D develop
git push origin --delete develop
git tag -d fork/master-pre-develop-20260426
```

### Build gate (verified before push)
- `cargo fmt --all -- --check` ✅ (after applying fmt to `mcp/*.rs`)
- `cargo clippy --all-targets` — 22 warnings, 0 errors. **Identical warning location set vs. master**; net 0 new warnings introduced. All pre-existing tech debt from fork az/mcp + upstream develop. Out of scope to fix here.
- `cargo test --all` — 1763 passed, 9 ignored, 0 failed.

### Out of scope (follow-up tasks)
- [ ] `install.sh` and `scripts/check-installation.sh` still hardcode `rtk-ai/rtk` master URL — needs fork-pointing fix with optional `BRANCH=develop|master` env var so "build master" actually pulls fork master.
- [ ] In-flight branches (`feat/az-cli-support`, `fix/disambiguate-rtk-name`) stay where they are; new branches base off `develop` going forward. Both are PRs to upstream and should rebase onto the corresponding `upstream/develop` head, not fork develop.
- [ ] `chore/fork-notes-log` and `test/mcp-integration-coverage` are now merged into develop and can be deleted (local + origin) at convenience.
- [ ] Memory `reference_no_ci_sole_maintainer.md` flagged for review: `ci.yml` triggers on `[develop, master]` PRs but only fires if Actions enabled on `lucachitayat/rtk`. Verify on GitHub Settings → Actions before relying on CI.
- [ ] `release-please` config exists but isn't driving releases on the fork. Revisit if/when wanted.
- [ ] Backlog clippy warnings (22 inherited) — separate cleanup task.

---

## 2026-04-22 — `rtk init` auto-migrator silent no-op on clean-install

### Symptom
After merging `upstream/master` into fork (`420e519`, 0.37.0-fork → 0.38.0-fork.1), every Bash tool call in Claude Code failed with:

```
PreToolUse:Bash hook error: /bin/sh: /Users/…/.claude/hooks/rtk-rewrite.sh: No such file or directory
```

Upstream `22892f0 feat(hooks): native hook handlers, remove bash scripts` deleted `hooks/claude/rtk-rewrite.sh` and registers `rtk hook claude` in `settings.json` instead. The merge pulled the deletion; the installed `~/.claude/settings.json` still pointed at the dead `.sh`.

### Why `rtk init --global` didn't fix it
`migrate_old_hook_script()` (`src/hooks/init.rs:879-901`) guards the cleanup with `if old_hook.exists()`. On a clean-install or post-merge environment the `.sh` is already absent, the guard is false, `remove_legacy_settings_entries()` is never called, and `hook_already_present()` — which treats any `cmd.contains("rtk-rewrite.sh")` as "already present" (`init.rs:~855-870`) — then refuses to insert the new entry. Net result: `rtk init --global -v` prints "hook already present" twice and changes nothing. Silent no-op.

This affects any user who: (a) installs 0.38+ fresh, or (b) merges post-`22892f0` upstream without ever having the `.sh` file on disk. The auto-migration path only works when upgrading in-place from a previous install that still has the script.

### Fix applied (this fork)
One-line surgical edit to `~/.claude/settings.json`: replaced the `command` value in the Bash PreToolUse entry from the dead `.sh` path to `"rtk hook claude"`. Matches exactly what `insert_hook_entry()` at `src/hooks/init.rs:821` would have produced. `rtk verify` → `PASS  native binary hook registered`.

### Decision: not patching locally
Upstream convention wins — hook name stays `rtk hook claude` (no fork-alias). Renaming would diverge the idempotency substring match and cost us on every future merge. The migrator bug is a real upstream defect but low-priority: anyone who hits it lands here, reads this, does the one-line edit, moves on.

### Upstream-facing fix (not filed)
The right patch would be: call `remove_legacy_settings_entries()` unconditionally at the top of `run_default_mode()`, outside the `old_hook.exists()` guard. That way the settings.json cleanup happens whether or not the physical `.sh` ever existed. Parked — not filing until after #1209 / #1242 land (absorption rate is the binding constraint, same logic as the MCP probe below).

---

## 2026-04-21 — Stale upstream PR refresh + MCP upstream-interest probe

### Refreshed against `upstream/develop`
- **PR #1209** (`feat/az-cli-support`): `dd38130 → 9069708`. Clean merge (gh's `CONFLICTING/DIRTY` was stale; git auto-followed the docs `→ resources/` rename). All 1720 tests pass.
- **PR #1242** (`fix/disambiguate-rtk-name`): `39224f8 → 5e5a1f8`. Clean merge, all 1671 tests pass.

Backup branches kept (fork-only, indefinite retention):
- `backup/feat/az-cli-support-pre-refresh-20260421-173703`
- `backup/fix/disambiguate-rtk-name-pre-refresh-20260421-173422`

### Build-gate lesson
- Initial plan called for `cargo clippy --all-targets -- -D warnings`. **Rejected mid-run** — `upstream/develop` itself ships warnings (e.g. `function_casts_as_integer` in `src/main.rs:2234-2235`, `manual_map` in `src/discover/registry.rs:663`) that would block any refresh. Reverted to project standard: exit-code-only check. Documented in `~/.claude/plans/ill-trust-you-i-cheeky-forest.md`.

### MCP — upstream interest probe filed
- **Issue:** [rtk-ai/rtk#1442](https://github.com/rtk-ai/rtk/issues/1442) — "MCP tool-input rewriters: gauging interest before opening a PR"
- **Pitch:** rewriter-only (`mcp-rewrite` subcommand, `src/mcp/rider.rs` pattern). The proxy half (`src/mcp/proxy.rs`) is architecturally off-brand for rtk (long-lived daemon, threaded, IDE-specific) — **staying fork-only indefinitely** regardless of issue outcome.
- **Decision gate:**
  - Maintainer interest signaled → open focused PR for rewriter alone (~150 LOC + snapshot tests)
  - Silent or "no" → fork keeps both, no rework needed
- **Why probe first:** absorption rate is the binding constraint. PRs #1209 and #1242 sat 61 commits behind for weeks. Adding a third large open PR while the existing two are still `BLOCKED` on review is counterproductive.

### State discrepancy noted
- Plan claimed fork `master` was at `3d9eb8a` (test commit) and pushed to origin. Reality: `origin/master = 3c9b8f9`, the test commit `3d9eb8a` is **local-only**. Either never pushed or someone rewound origin (unlikely). Pending decision: push or not.

### Open / TODO
- [ ] Decide whether to push `3d9eb8a` (test commit) to fork `origin/master`
- [ ] Fix `src/cmds/cloud/az_cmd.rs:1859` `manual_repeat_n` clippy warning on `feat/az-cli-support` (1-line: `repeat('a').take(2048)` → `repeat_n('a', 2048)`)
- [ ] Watch [#1442](https://github.com/rtk-ai/rtk/issues/1442) for traction signal — re-evaluate MCP PR plan after #1209 / #1242 land or close
- [ ] Stale Cargo.lock drift in worktree `/Users/lucachitayat/code/rtk-master-merged` (`0.35.0 → 0.34.3` rtk version stamp) — benign cargo build artifact, can be discarded any time

---

## Conventions for this file

- **Newest on top.** Append new sections above the previous one.
- **Date headers** in `YYYY-MM-DD` format, with a one-line topic.
- **Decisions stay in the log even when superseded** — strike through and add the new decision, don't delete.
- **Issue / PR numbers always linked.**
- **No mentions of AI / Claude / agents** anywhere in this file (per fork-wide convention).
