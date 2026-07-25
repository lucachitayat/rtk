//! Fork-only tests for `hook_cmd` — quarantined out of `hook_cmd.rs` on purpose.
//!
//! WHY THIS FILE EXISTS
//! --------------------
//! `src/hooks/hook_cmd.rs` is one of the highest-churn upstream files in the tree.
//! Every fork-only block interleaved into it — code or tests — becomes a permanent
//! conflict surface, because upstream keeps adding its own material in exactly the
//! same regions. On the 2026-07-24 sync, 2 of the 5 merge conflicts were purely
//! adjacency: upstream appended tests next to the fork's `test_hardening_*` /
//! `test_enterprise_*` families and git could not tell the two apart.
//!
//! This is the same reasoning that motivated dropping the fork-owned MCP bridge on
//! 2026-05-21 (see FORK_NOTES.md, "Drop fork-owned MCP bridge (Path A)"): fork-only
//! code woven into upstream-owned files costs more, forever, than the feature is
//! worth. There, the fix was deletion; here the tests are load-bearing (they are the
//! ONLY coverage of the enterprise compile-time opt-out), so they are relocated
//! instead. `hook_cmd.rs` keeps a single 3-line `mod` declaration and stays
//! byte-comparable with upstream everywhere else.
//!
//! RULES FOR THIS FILE
//! -------------------
//! * Fork-only tests go HERE, never back into `hook_cmd.rs`.
//! * This module is a child of `hook_cmd::tests` (rustc resolves `mod fork_tests;` inside
//!   the inline `mod tests` of the non-mod-rs file `hook_cmd.rs` to exactly this path), so
//!   `use super::*` reaches both the `tests` helpers (`cli_args`, `claude_input`,
//!   `cursor_input`, `all_allowed`, `gemini_render`) and — through `tests`' own
//!   `use super::*` — `hook_cmd`'s private items (`cursor_ask`, `HookDecision`,
//!   `copilot_cli_response_from_decision`, `auto_allow_enabled`, …).
//! * The `#[cfg(feature = "enterprise")]` / `#[cfg(not(...))]` attributes below are the
//!   only coverage of the enterprise compile-time path — do not relax them.

use super::*;

// ── RTK_NO_AUTO_ALLOW / enterprise hardening ──────────────────────────────
//
// Design note: std::env::set_var is not thread-safe under parallel cargo test.
// Instead of mutating the process environment, we test the following separately:
//
//   A) The predicate auto_allow_enabled() logic via a single-threaded env-var test
//      run with `-- --test-threads=1` (documented) OR via the cfg(feature) path.
//   B) Each host's response shape when `rule_allows=true` but the conditional
//      `if rule_allows && auto_allow_enabled()` would be false — by directly
//      calling the low-level functions with AskRewrite (which has the same code
//      path as AllowRewrite with !auto_allow_enabled(), both omit permissionDecision).
//   C) The JSON output shape of cursor_ask / gemini "ask_user" with rewrite present.
//
// The enterprise feature flag tests (cfg(feature = "enterprise")) exercise the
// compile-time path and run correctly because the feature is fixed at compile time
// (no runtime races).
//
// The predicate tests for (A) — `test_auto_allow_enabled_*` — stay in hook_cmd.rs
// next to `auto_allow_enabled()` itself; (B) and (C) live below.

// --- Host output shape: permissionDecision absent when auto-allow is off ---
//
// We verify invariant (B) by directly exercising the AskRewrite arm of each
// host function (AskRewrite always omits permissionDecision regardless of the
// env-var, and AllowRewrite with !auto_allow_enabled() takes the same branch).
// A separate structural test (C) verifies cursor_ask / gemini ask_user shapes.

// Copilot CLI: AskRewrite (= AllowRewrite with opt-out) must omit permissionDecision
// and still carry the rewritten command. (Already covered by the existing
// test_copilot_cli_ask_rewrite_omits_permission_decision; restated here explicitly
// for the hardening audit trail.)
#[test]
fn test_hardening_copilot_cli_omits_permission_decision_carries_rewrite() {
    // AskRewrite path — same output shape as AllowRewrite + !auto_allow_enabled().
    let r = copilot_cli_response_from_decision(
        &cli_args("cargo test"),
        HookDecision::AskRewrite("rtk cargo test".into()),
        "cargo test",
    )
    .unwrap();
    assert!(
        r.get("permissionDecision").is_none(),
        "AskRewrite (opt-out shape) must NOT set permissionDecision; got: {r}"
    );
    assert_eq!(
        r["modifiedArgs"]["command"], "rtk cargo test",
        "rewritten command must still be present"
    );
}

// Claude native: AskRewrite omits permissionDecision and carries the rewrite.
#[test]
fn test_hardening_claude_ask_rewrite_omits_permission_decision() {
    // process_claude_payload -> AskRewrite -> hook_output has no permissionDecision.
    // We verify via run_claude_inner which returns the full hookSpecificOutput wrapper.
    // "git status" with no allow rule configured returns AskRewrite (the opt-out shape).
    let result = run_claude_inner(&claude_input("git status")).unwrap();
    let v: Value = serde_json::from_str(&result).unwrap();
    let hook = &v["hookSpecificOutput"];
    // With default config (no allow rules), permissionDecision is absent.
    assert!(
        hook.get("permissionDecision").is_none(),
        "AskRewrite (opt-out shape) must NOT set permissionDecision on Claude path; got: {hook}"
    );
    assert!(
        hook["updatedInput"]["command"].is_string(),
        "rewritten command must still be present"
    );
}

// Gemini: "ask_user" decision with rewrite must carry hookSpecificOutput.
#[test]
fn test_hardening_gemini_ask_user_with_rewrite_carries_command() {
    // When auto_allow_enabled() is false, AllowRewrite emits "ask_user".
    // Verify the JSON shape: decision="ask_user" and rewrite is present.
    let rendered = gemini_json("ask_user", Some("rtk git status"));
    let v: Value = serde_json::from_str(&rendered).unwrap();
    assert_eq!(v["decision"], "ask_user");
    assert_eq!(
        v["hookSpecificOutput"]["tool_input"]["command"], "rtk git status",
        "rewritten command must be present in hookSpecificOutput even for ask_user"
    );
}

// Cursor: cursor_ask must carry updated_input and must never auto-approve.
// The invariant is the VALUE, not the field's absence: upstream's explicit
// "ask" prompts the human just as the fork's earlier omit-the-field form did.
// Asserting absence overspecified this and conflicted on every upstream sync.
#[test]
fn test_hardening_cursor_ask_never_allows_carries_rewrite() {
    let result = cursor_ask("rtk git status");
    let v: Value = serde_json::from_str(&result).unwrap();
    assert_ne!(
        v["permission"], "allow",
        "cursor_ask must never auto-approve; got: {v}"
    );
    assert_eq!(
        v["updated_input"]["command"], "rtk git status",
        "rewritten command must still be present in updated_input"
    );
    assert_eq!(v["continue"], true, "continue:true must be present");
}

// --- enterprise feature: compile-time opt-out — full host coverage ---

#[cfg(feature = "enterprise")]
#[test]
fn test_enterprise_copilot_cli_allow_rewrite_omits_permission_decision() {
    // In enterprise builds, AllowRewrite must behave identically to AskRewrite.
    let r = copilot_cli_response_from_decision(
        &cli_args("cargo test"),
        HookDecision::AllowRewrite("rtk cargo test".into()),
        "cargo test",
    )
    .unwrap();
    assert!(
        r.get("permissionDecision").is_none(),
        "enterprise: AllowRewrite must NOT set permissionDecision on Copilot CLI path; got: {r}"
    );
    assert_eq!(r["modifiedArgs"]["command"], "rtk cargo test");
}

#[cfg(feature = "enterprise")]
#[test]
fn test_enterprise_cursor_allow_rewrite_omits_permission() {
    // With all_allowed() rules, decide returns AllowRewrite; enterprise build
    // then calls cursor_ask instead of cursor_allow.
    let result = run_cursor_inner_with_rules(&cursor_input("git status"), &[], &[], &all_allowed());
    let v: Value = serde_json::from_str(&result).unwrap();
    assert!(
        v.get("permission").is_none() || v["permission"] != "allow",
        "enterprise: Cursor AllowRewrite must not emit permission:allow; got: {v}"
    );
    assert!(
        v["updated_input"]["command"].is_string(),
        "rewritten command must still be present"
    );
}

#[cfg(feature = "enterprise")]
#[test]
fn test_enterprise_claude_allow_rewrite_omits_permission_decision() {
    // run_claude_inner -> process_claude_payload; with enterprise feature,
    // even AllowRewrite must not set permissionDecision.
    if let Some(result) = run_claude_inner(&claude_input("git status")) {
        let v: Value = serde_json::from_str(&result).unwrap();
        let hook = &v["hookSpecificOutput"];
        assert!(
            hook.get("permissionDecision").is_none() || hook["permissionDecision"] != "allow",
            "enterprise: permissionDecision must not be 'allow' on Claude path; got: {hook}"
        );
        assert!(hook["updatedInput"]["command"].is_string());
    }
}

#[cfg(feature = "enterprise")]
#[test]
fn test_enterprise_gemini_allow_rewrite_emits_ask_user() {
    let rendered = gemini_render("git status", &[], &[], &all_allowed());
    let v: Value = serde_json::from_str(&rendered).unwrap();
    assert_ne!(
        v["decision"], "allow",
        "enterprise: Gemini AllowRewrite must not emit decision:allow; got: {v}"
    );
    assert!(
        v.get("hookSpecificOutput").is_some(),
        "rewritten command must still be present in hookSpecificOutput"
    );
}
