---
description: RTK fork upgrade-check — fetch upstream, diff vs fork, score impact on high-traffic filters, recommend defer vs merge. Trigger when user asks about RTK upstream updates, "should I upgrade my fork", "check rtk upstream", or wants a changelog of new upstream commits.
allowed-tools: Bash Read Grep
---

# RTK Upgrade Check

Run before recommending any merge of `upstream/develop` (or `upstream/master`) into this fork. Defer-by-default; merge only when high-traffic filter behavior is actually changing.

## When to Use

- "check rtk upstream", "should I upgrade rtk", "what's new upstream", "compile rtk changelog"
- Periodic check (user asks "anything worth pulling?")
- Before any planned fork-sync work

## How to Run

```bash
bash scripts/upgrade-check.sh        # decide: defer or merge
# ...if you merge:
bash scripts/post-merge-verify.sh    # gate + behavior checks on the merged branch
```

`upgrade-check.sh` does:
1. `git fetch upstream develop master` (branches only — tags skipped to avoid local-tag conflicts like `latest`)
2. Counts divergence (develop vs upstream/develop and upstream/master)
3. Lists new upstream commits and the files they touch
4. **Cross-references against high-traffic filter paths** (see below) — the only thing that matters
5. Pulls `rtk gain --history` so the impact ranking reflects current usage, not stale assumptions
6. Prints DEFER or INVESTIGATE recommendation
7. **Merge preview** — `git merge-tree` read-only dry run proves whether the merge is conflict-free *before* you commit to it (no agent fan-out needed to guess at conflicts)
8. On INVESTIGATE, emits a copy-paste **post-merge verification block** tailored to the commits found

`post-merge-verify.sh` (run after merging) does: quality gate (fmt/clippy/test) → release build → behavior spot-checks (SIGPIPE no-crash, gh no-id forwarding) → divergence + fork-version sanity. Exit 0 = all gates pass.

## High-Traffic Filter Paths (the decision pivot)

Defined in `scripts/upgrade-check.sh` as `HOT_PATHS`. These are the only paths where an upstream change actually changes the user's day-to-day output:

- `src/cmds/system/grep*` — `rtk grep` (#1 by volume, ~78M tokens saved historically)
- `src/cmds/system/read*` — `rtk read` (#2 by call count)
- `src/cmds/git/` — `rtk git branch`, `rtk gh pr diff`
- `src/cmds/dotnet/` — `rtk dotnet build` (verify clippy-only vs behavior change)
- `src/cmds/cloud/` — `rtk curl`, container (`ps -ef`/`ps aux` via toml filter)
- `src/core/toml_filter.rs` + `filters/` — TOML filter engine + configs
- `src/core/utils.rs` — cross-cutting helpers (strip_ansi, truncate)

If you update this list, also update `memory/rtk_upgrade_check.md` and `HOT_PATHS` in the script.

## Decision Rule

- **DEFER** when: zero high-traffic paths touched AND no specific user pain. Cost-of-merge (conflicts vs MCP/az fork code) outweighs zero behavioral value.
- **INVESTIGATE** when: any high-traffic path is touched. For each commit, `git show <sha> -- <path>` and judge:
  - Clippy/whitespace/match-sugar → still defer (no output change)
  - Regex / format string / truncation / new field → real impact, merge
- **MERGE NOW** when: high-traffic regex/format change confirmed, OR user has a specific upstream bug-fix they need, OR rolling-cadence checkpoint reached.

## Fork Features to Preserve on Merge

Don't maintain a manual conflict list — the merge preview (script step 7) is authoritative. The one fork-only value-add to eyeball post-merge is `src/cmds/cloud/az_cmd.rs` (Azure CLI filter); `FORK_NOTES.md` and `.claude/skills/rtk-upgrade/` are fork-only and never conflict.

> **Note:** the MCP rewrite/proxy bridge (`src/mcp/**`, `src/hooks/mcp_rewrite_cmd.rs`) was **removed** on 2026-05-21 (archived at tag `fork/mcp-bridge-archive-20260521`) — not a preserve-target.

For ad-hoc questions: `git merge-tree --write-tree develop upstream/develop` (exit 0 = zero conflicts) and `git log upstream/develop..develop -- <path>` (which fork commits touch a path).

## Output Format

When invoked, briefly state:
1. Divergence summary (N commits behind/ahead)
2. Hot-path hit count
3. Recommendation (DEFER / INVESTIGATE / MERGE) with a one-line rationale

Don't paginate the full diff stat unless the user asks for it.
