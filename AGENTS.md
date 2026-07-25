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

## Disconfirming an ALL-CLEAR (the mirror of the above)

The procedure above is one-sided. It was written after a false *positive*, so it
teaches doubting the alarm. On 2026-07-24 the failures ran the other way: **seven
false negatives in one session, every one an empty result accepted as "clean".**
An alarm at least announces itself. An all-clear is silent, arrives sooner, and
reads as progress.

So before believing any negative result — no matches, nothing found, exit 1, an
empty diff, a green ✓ — establish two controls. Neither is optional and neither
substitutes for the other:

1. **DOMAIN control — is there anything there to examine?** Assert the target
   exists, is non-empty, and is the thing you meant. `grep` exits **2** for "no
   such path" and **1** for "no match", and `|| true` erases the difference;
   `rg` on a missing path exits 2 the same way. State the count you scanned
   (files, lines, packages), not just the count you found.
2. **DETECTOR control — can this exact command find anything at all?** Plant a
   positive instance and confirm the *byte-identical* invocation reports it.
   Retyped or "equivalent" commands do not count: the flags are usually what
   broke.

Both controls, or you have not verified anything. A canary alone certifies a
scan of the wrong place; a domain check alone certifies a broken detector
pointed at real data.

The seven, as a checklist of shapes rather than anecdotes:

- **scanned a target that had been deleted** — `/tmp` export dir was gone; zero
  matches nearly refuted a real, live defect.
- **wrong regex dialect** — `grep` with `|` alternation under BRE matched the
  literal string `a|b`, not either branch. Use `-E`.
- **flags silently eaten** — `rg -rniE` : ripgrep's `-r` is `--replace`, so this
  replaced every match with the literal `niE` and dropped `-n` and `-i`.
- **substring collision** — a match on `mcp-proxy` hit the npm package
  `@jetbrains/mcp-proxy` and nearly caused deletion of working config.
- **a test that compiles to nothing** — a body entirely inside
  `#[cfg(feature = "…")]` runs as an empty function and reports *passed*.
- **a test target that is never built** — a `#[cfg(test)] mod tests` inside
  `build.rs` never runs; `cargo metadata` reports `build-script-build` as
  `test = false`.
- **a sandbox that is not the tree** — the same grep returned 0 hits in an MCP
  sandbox and 2 hits on the host, for the same file. Prefer the published
  artifact (`gh api`) or a host `Read`; a sandbox copy is a different target.

Corollaries worth stating separately, because each cost real time here:

- **A filter matching zero tests still exits 0.** `cargo test <filter>` prints
  `0 passed` and succeeds. Assert the count is non-zero, not just the exit code.
- **A canary `✗` indicts the detector, not the tree.** Fix the scan — its flags,
  its pattern, its scanned root — and do not trust that run's other greens.
- **A control that has never been seen to fail is not a control.** Re-break the
  detector on purpose and confirm the control reds. Two canaries were falsified
  this way after they had been written and looked convincing.
- **Wire the check to the decision.** Printing "MARKERS REMAIN" next to an
  unconditional `git commit` is not a gate; a conflict-marker pair landed in a
  commit here for exactly that reason.

## RTK fork facts (version-specific — rot-prone, kept out of the always-on layer)

- Fork version is **`<upstream/develop base>-dev-fork.N`**. Do NOT hardcode the numbers here —
  they rot at every sync. `bash scripts/rtk-upgrade.sh check` prints all three live (fork,
  upstream/develop, upstream/master) in its `── Divergence ──` block. Version scheme + sync
  mechanics: `scripts/rtk-upgrade.sh` reconcile (spec in rtk-upgrade/SKILL.md).
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
