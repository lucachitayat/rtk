# `az` Generic Fallback Replaces Data With JSON Schema

**Status:** fixed in PR #1209
**Severity:** high — the LLM receives fabricated-looking structural placeholders instead of actual Azure data
**Discovered:** 2026-04-15 while debugging CI pipelines via an Azure DevOps agent session
**Area:** `src/cmds/cloud/az_cmd.rs` → `run_generic` → `json_cmd::filter_json_string`

## Resolution

The `run_generic` path no longer calls `json_cmd::filter_json_string` (the schema extractor). It now parses JSON, prunes known Azure noise keys (`_links`, `url`, `collectionUri`, `projectUri`, nested `project.*` boilerplate, `revision`), caps top-level arrays at 20 items with a `... +K more items` marker, and emits compact JSON via `serde_json::to_string` (single-line, no indentation). Values are preserved; schema-only output was a bug, not a design choice.

## Symptom

Any `az` subcommand **not** in the specialized allow-list comes back with its real values replaced by type tokens like `int`, `string`, `url`, `date?`, `bool`, or summaries like `string[123]`. Nested objects and arrays are collapsed past depth 4 into `...`.

### Example 1 — `az pipelines runs list`

Command as the user typed it (common for CI triage):

```bash
az pipelines runs list \
  --organization https://dev.azure.com/myorg \
  --project MyProject \
  --branch refs/pull/123/merge \
  --top 5 \
  --output json
```

RTK hook rewrites this to `rtk az pipelines runs list ...`. Because `runs` is not `build`, it falls through to `run_generic` in `az_cmd.rs:404`. That function passes the raw JSON through `json_cmd::filter_json_string(raw, 4)` at `az_cmd.rs:442`, which calls `extract_schema` (`cmds/system/json_cmd.rs:186`). The result looks like this:

```
[{
  _links: {
    self: {
      href: url
    },
    ...
  },
  buildNumber: string,
  definition: {
    id: int,
    name: string,
    path: string,
    project: {
      ...
    }
  },
  finishTime: date?,
  id: int,
  reason: string,
  result: string,
  sourceBranch: string,
  status: string,
  ...
}] (5)
```

There are zero actual build numbers, ids, branches, results, or commit SHAs in that output. To the LLM this looks like a **valid response with data** — it isn't. It's the shape of the response with type-names where every value should be.

### Example 2 — `az pipelines show`, `az repos pr list`, `az boards work-item show`

Same mechanism. None of these subcommands match the allow-list in `run` (`az_cmd.rs:56-68`), so they all go through `run_generic` and come back schema-only.

### Example 3 — `az pipelines runs show --id <N>`

Returns the shape of a single build, with every useful field (`id`, `buildNumber`, `result`, `status`, `sourceBranch`, `sourceVersion`, `startTime`, `finishTime`, `requestedBy.displayName`) replaced by its type name. Indistinguishable from a successful fetch to a naive caller.

## Expected

The specialized filters in `az_cmd.rs` preserve values (see `filter_build_list`, `filter_build_show`, `filter_timeline`) — they extract the useful fields and render them in a compact human-readable form. That is the correct design. The bug is that the generic fallback silently **destroys** the data it is supposed to compress.

## Root cause

`az_cmd.rs:442-451`:

```rust
let filtered = match json_cmd::filter_json_string(&raw, JSON_COMPRESS_DEPTH) {
    Ok(schema) => {
        println!("{}", schema);
        schema
    }
    Err(_) => {
        print!("{}", raw);
        raw.clone()
    }
};
```

`filter_json_string` (`cmds/system/json_cmd.rs:181`) is a **schema extractor**, not a compressor. Its return value is only useful when the caller wants to know the *shape* of an unknown API response (e.g. during initial filter development). Using it as a live output path means every value is thrown away.

This was almost certainly a placeholder that was meant to be replaced with a real generic compressor (e.g. field-prune + size-bound truncate that keeps actual values), but was left in production.

## Workaround

Bypass RTK entirely for the affected commands:

```bash
rtk proxy az pipelines runs list --organization https://dev.azure.com/myorg --project MyProject --top 5 --output json
```

Or route through `--output tsv` / `--query` so the output is plain text (which `run_generic` still runs through `filter_json_string`, but the serde parse fails and it prints raw — see the `Err(_)` branch). **TSV is currently the most reliable bypass through RTK** for non-specialized subcommands:

```bash
az pipelines runs list --organization ... --project ... --query "[].{id:id,result:result,status:status,branch:sourceBranch,num:buildNumber}" --output tsv
```

That query escapes the JSON path by emitting tab-separated values, which `filter_json_string` can't parse, so the raw bytes reach stdout.

## Suggested fix directions

Pick one:

1. **Replace `filter_json_string` in `run_generic` with a real value-preserving compressor.** Candidate rules:
   - Drop `_links`, `url`, `id` fields with GUIDs, `revision`, `priority`, inner `project` blocks — things the specialized filters already strip.
   - Flatten top-level arrays of objects into one-line-per-object summaries with the 4-6 most useful fields by convention (`id`, `name`/`displayName`, `status`/`result`, one timestamp).
   - Cap output at N items with an `... +X more` marker, same as `filter_build_list`.

2. **Add more specialized handlers.** At minimum:
   - `az pipelines runs list` / `runs show` (these are the common CI-triage entry points — the `build` variant handled today is increasingly deprecated in `az` CLI).
   - `az repos pr list` / `pr show`.
   - `az boards work-item show`.

3. **Default to raw passthrough for unrecognized subcommands** and let the user opt into schema extraction with an explicit flag. The current behavior violates least-surprise — an LLM reading the schema output has no signal that the values are fake.

4. **At minimum, tag the schema output with a loud marker** (e.g. prepend `# rtk: az subcommand not specialized, showing schema only — rerun with 'rtk proxy az ...' for raw output`) so callers know the data is not real.

Option 4 is the cheapest stopgap; option 1 or 2 is the real fix.

## How to verify a fix

1. Pick an un-specialized `az` subcommand (`az pipelines runs list` is ideal — it's what triggered this report).
2. Run via `rtk az ...`. Output must include at least one real primitive value (an id, a buildNumber, a sourceBranch). If every value is a type-name, the bug is still live.
3. Add a test in `az_cmd.rs` that asserts `run_generic` output for a known JSON fixture contains the actual values, not just type names.

## Related

- `test_all_filters_invalid_json` (`az_cmd.rs:1491`) already covers the specialized filters returning `None` on invalid input. There is no equivalent test for `run_generic`; if there were, this bug would have been caught.
- The docs table in `docs/guide/what-rtk-covers.md` lists `aws` under Cloud but **does not list `az`** — the generic fallback was probably never promoted to "covered" for this reason, but the hook still intercepts `az` commands.

## Regression test

To detect a future regression, grep the generic output for type-name values. If `rtk az repos list` (or any un-specialized az subcommand) returns output containing `: string` or `: int` as a standalone value, the regression is back.
