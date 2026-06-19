# AGENTS.md — RTK (Rust Token Killer) fork

Agent-facing notes for working in / with this RTK fork. The always-on global rule
(`~/.claude/RTK.md` + `includes/tool-preferences.md`) carries only the RTK reflex
trigger + a one-line verdict; the rot-prone mechanics and the full disconfirmation
procedure live here, loaded only when an agent is actually in this tree.

## RTK compression-drop disconfirmation (full procedure)

Classify before claiming a drop — 3 outcomes (CCA-F D5.3 access-failure-vs-valid-result):

1. **State first (D5.6 temporal annotation):** is the command state-dependent
   (`git status`, `ls`, `gh`, `ps`, log tails)? If yes, pin the temporal dimension
   BEFORE comparing — note `git rev-parse HEAD` + `git reflog -5`. A change here is a
   state change, not a drop.
2. **Re-fetch unfiltered:** RTK/Bash → `rtk run <cmd>` (raw `sh -c`, untracked — NOT
   `rtk proxy`, which still tracks usage); context-mode/MCP → `Read` the cited source
   path (no rtk oracle exists for MCP output).
3. **Classify the discrepancy:**
   - *reformat / compaction* (same data, different shape) → NOT a drop (RTK working as designed).
   - *state changed between runs* (confirmed via reflog/HEAD) → NOT a drop.
   - *a datum present in raw but absent from compressed* (a file, line, or record) → REAL drop → use the ground-truth read.

Origin: a 2026-06-07 false positive where an "RTK silent-drop" on `git status --short`
(16→1 files) was actually an interceding commit; hooked output and `rtk proxy` agreed,
so there was no drop. The lesson: a verify-trigger needs a bounded, cheap disconfirmation
procedure, not vague suspicion.

## RTK fork facts (version-specific — rot-prone, kept out of the always-on layer)

- Fork: **v0.42.2-dev-fork.1** (upstream/develop at 0.42.2; upstream/master at 0.42.4).
  Version scheme + sync mechanics: `scripts/rtk-upgrade.sh` reconcile (spec in rtk-upgrade-2/SKILL.md).
- The PreToolUse hook is `rtk hook claude`, keying on the **bare leading command name**:
  - pipes rewrite the **first segment only** (`cat f | grep x` → `rtk read f | grep x`);
  - `&&` rewrites **each segment** (`git status && ls` → `rtk git status && rtk ls`);
  - **absolute-path invocations are NOT rewritten** (`/usr/bin/git status` → no rewrite);
  - being in the help list ≠ every subform rewrites (`npm install` no, `npm run` yes).
- Wrapped set (~40+): `git`, `ls`, `tree`, `read` (`cat`→`rtk read`), `grep`, `find`,
  `diff`, `wc`, `gh`, `cargo`, `docker`, `kubectl`, `npm run`, `curl`, `psql`, … —
  run `rtk discover` for the live picture rather than trusting this list.
- `60-90% savings` / `<10ms "Zero Overhead"` are documented design targets (README,
  TECHNICAL.md), and underwrite the `<10KB→RTK / >10KB→context-mode` routing rule.
