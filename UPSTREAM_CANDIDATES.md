# Fork → Upstream Candidates

Suggested fork-only changes worth contributing back to `rtk-ai/rtk`, ranked by
**priority** (value if accepted) × **readiness** (how close to a clean PR).

This fork tracks `upstream/develop`. The goal of upstreaming is to **shrink the
fork's permanent delta** — every accepted PR is one less thing to carry through
future syncs. See `FORK_NOTES.md` for the full fork divergence and
`.claude/skills/rtk-upgrade/SKILL.md` for the sync workflow.

> **Snapshot:** assessed 2026-06-18 against `upstream/develop` @ `39cbb96`
> (fork `develop` @ `c8c2ac6`). Re-verify duplication before acting — upstream
> moves, and several fork fixes have already been adopted there (below).

## Prerequisites (apply to every PR)

1. **CLA.** `rtk-ai/rtk` requires a signed Contributor License Agreement.
   Nothing merges until it's signed — confirm this *first*, before writing PRs.
2. **Per-PR isolation.** Cherry-pick each change onto a clean branch off
   `upstream/develop`, stripped of fork divergence (no MCP removal, no fork
   versioning/tooling, no `FORK_NOTES.md`). One focused PR per item — the fork
   branch cannot be pushed wholesale.
3. **Duplication check.** Before writing each PR, diff the candidate against
   current `upstream/develop`. Upstream may already have it (see "Already
   upstream" below) or have fixed it differently.

## Candidates (ranked)

| # | Candidate | Path | Priority | Readiness | Notes |
|---|-----------|------|----------|-----------|-------|
| 1 | `find` parallel-walk | `src/cmds/system/find_cmd.rs` | **High** | **High** | Upstream is still serial (`build()`); fork uses `build_parallel()`. `find` is the #2 command by usage. Isolated to one file. Needs a benchmark in the PR. |
| 2 | Azure CLI filter (`az`) | `src/cmds/cloud/az_cmd.rs` (+ `main.rs` routing) | Medium | Low | Genuine new feature, but ~2,560 lines → large review. Gate on whether upstream *wants* Azure support (open an issue first). Also wire routing + the `az` PASSTHROUGH classification. |

## Already upstream — verify parity, likely no PR needed

These were "easy win" candidates until the duplication check showed upstream
already has them (the fork pulled them from upstream over time, or upstream
added equivalents independently). Action is *verify parity*, not *contribute*:

| Change | Path | Upstream status |
|--------|------|-----------------|
| `args_utils` (`--` restoration) | `src/core/args_utils.rs` | **Present on `upstream/develop`** |
| SIGPIPE reset handler | `src/main.rs` (~L1434) | **Present** (upstream `main.rs` has SIGPIPE handling) |
| SIGINT/SIGTERM child-kill (#897) | `src/main.rs` (~L2383) | **Appears present** — diff to confirm the fork's version isn't more complete |

## Keep local — never upstream

Fork-defining divergence, not general-purpose:

- MCP bridge/rewrite removal
- Fork versioning + upgrade tooling (`scripts/rtk-upgrade.sh`,
  `scripts/upgrade-check.sh`, `scripts/lib/master-only.sh`, the `rtk-upgrade`
  skill)
- `FORK_NOTES.md`, this file

## Suggested sequencing

1. Confirm the **CLA** is signed (blocks everything).
2. Land **#1 (`find` parallel-walk)** first — high value, isolated, proves the
   contribution flow with a small surface.
3. Re-verify the "Already upstream" trio is genuinely redundant; drop from the
   fork if so (further shrinks the delta).
4. Only then weigh **#2 (`az`)** — open an upstream issue to gauge interest
   before investing in a 2.5k-line PR.
