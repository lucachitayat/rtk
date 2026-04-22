# Fork Notes

Running log of decisions, in-flight work, and open questions specific to this fork of `rtk-ai/rtk`. **Not for upstream consumption** — this file lives on fork `master` only and is not intended to be PR'd upstream.

Newest entries on top.

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
