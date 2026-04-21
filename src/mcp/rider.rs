//! JetBrains Rider MCP input rewriter.
//!
//! Empirical findings from 50+ probe calls against the Rider MCP (port 64343)
//! motivate three default rewrites:
//!
//! 1. `search_text` / `search_regex` / `search_file` / `search_symbol` — the
//!    "quick query" family accepts a `paths:` glob array with `!` excludes.
//!    Without excludes, results are flooded with `.claude/worktrees/*` mirror
//!    duplicates and `obj/` / `bin/` build artifacts. We inject sensible
//!    excludes when `paths:` is absent.
//!
//! 2. `search_in_files_by_text` / `search_in_files_by_regex` — documented
//!    older family. Without `fileMask`, results include binary (`.lance`) and
//!    cache (`.oh/.cache/*`) blobs whose `lineText` is garbage bytes. We
//!    leave `fileMask` alone (too repo-specific to auto-set) but warn via the
//!    `rtk doctor` output — TODO.
//!
//! 3. `search_symbol` empirically indexes JavaScript/TypeScript only in this
//!    Rider build; C# classes, interfaces, enums, and methods all return
//!    empty. A hint rewrite is not applicable (we can't know repo language
//!    from the tool_input alone), so we leave it to documentation.

use serde_json::{json, Value};

/// Default exclude patterns prepended to `paths:` on the quick-query family.
///
/// Ordering convention: worktree mirrors first (most common pollution), then
/// build artifacts. Keep synchronized with the recipe in
/// `~/.claude/includes/tool-preferences.md`.
const DEFAULT_EXCLUDES: &[&str] = &["!.claude/worktrees/**", "!**/obj/**", "!**/bin/**"];

/// Tools in the "quick query" family share a schema (`q` + `paths` + `limit`
/// + `projectPath`). All four honor `paths:["!...glob..."]` excludes.
const QUICK_QUERY_TOOLS: &[&str] = &[
    "search_text",
    "search_regex",
    "search_file",
    "search_symbol",
];

/// Returns `Some(modified_input)` if a rewrite was applied, `None` if the
/// input should be passed through unchanged.
pub fn rewrite(tool_name: &str, mut input: Value) -> Option<Value> {
    let short = tool_name.strip_prefix("mcp__rider__")?;
    let obj = input.as_object_mut()?;

    if QUICK_QUERY_TOOLS.contains(&short) && inject_default_excludes(obj) {
        return Some(input);
    }

    None
}

/// Mutates `obj["paths"]` to contain DEFAULT_EXCLUDES. Returns true if any
/// change was made.
///
/// Cases:
/// - `paths` absent — insert a new array with only the defaults.
/// - `paths` present — append any defaults not already present (preserves
///   caller-supplied includes/excludes).
/// - `paths` present but not an array — leave alone (malformed input; let the
///   MCP server error so the agent sees the real problem).
fn inject_default_excludes(obj: &mut serde_json::Map<String, Value>) -> bool {
    match obj.get_mut("paths") {
        None => {
            obj.insert("paths".to_string(), json!(DEFAULT_EXCLUDES));
            true
        }
        Some(Value::Array(arr)) => {
            let mut modified = false;
            for pat in DEFAULT_EXCLUDES {
                let already = arr.iter().any(|v| v.as_str() == Some(*pat));
                if !already {
                    arr.push(json!(*pat));
                    modified = true;
                }
            }
            modified
        }
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn injects_excludes_when_paths_absent() {
        let input = json!({
            "q": "ILogger",
            "limit": 10,
            "projectPath": "/repo"
        });
        let out = rewrite("mcp__rider__search_text", input).expect("should rewrite");
        let paths = out.get("paths").and_then(|v| v.as_array()).unwrap();
        assert!(paths
            .iter()
            .any(|p| p.as_str() == Some("!.claude/worktrees/**")));
        assert!(paths.iter().any(|p| p.as_str() == Some("!**/obj/**")));
        assert!(paths.iter().any(|p| p.as_str() == Some("!**/bin/**")));
    }

    #[test]
    fn appends_missing_excludes_to_existing_paths() {
        let input = json!({
            "q": "ILogger",
            "paths": ["**/*.cs"],
        });
        let out = rewrite("mcp__rider__search_text", input).expect("should rewrite");
        let paths = out.get("paths").and_then(|v| v.as_array()).unwrap();
        // Caller's include preserved
        assert!(paths.iter().any(|p| p.as_str() == Some("**/*.cs")));
        // Defaults appended
        assert!(paths
            .iter()
            .any(|p| p.as_str() == Some("!.claude/worktrees/**")));
    }

    #[test]
    fn leaves_alone_when_all_excludes_already_present() {
        let input = json!({
            "q": "ILogger",
            "paths": [
                "!.claude/worktrees/**",
                "!**/obj/**",
                "!**/bin/**",
            ],
        });
        let out = rewrite("mcp__rider__search_text", input);
        assert!(out.is_none(), "no-op when defaults already present");
    }

    #[test]
    fn partial_overlap_only_adds_missing() {
        let input = json!({
            "q": "foo",
            "paths": ["!.claude/worktrees/**"],
        });
        let out = rewrite("mcp__rider__search_file", input).expect("should add remaining");
        let paths = out.get("paths").and_then(|v| v.as_array()).unwrap();
        assert_eq!(paths.len(), 3);
    }

    #[test]
    fn ignores_non_rider_tools() {
        let input = json!({ "q": "foo" });
        assert!(rewrite("mcp__other__search_text", input).is_none());
    }

    #[test]
    fn ignores_rider_tools_outside_quick_query_family() {
        // get_file_text_by_path, get_symbol_info, etc.
        let input = json!({ "filePath": "x.cs" });
        assert!(rewrite("mcp__rider__get_symbol_info", input).is_none());
    }

    #[test]
    fn leaves_malformed_paths_alone() {
        let input = json!({
            "q": "foo",
            "paths": "not-an-array",
        });
        let out = rewrite("mcp__rider__search_text", input);
        assert!(out.is_none(), "malformed paths should pass through");
    }

    #[test]
    fn applies_to_all_quick_query_tools() {
        for tool in QUICK_QUERY_TOOLS {
            let full = format!("mcp__rider__{}", tool);
            let input = json!({ "q": "x" });
            assert!(
                rewrite(&full, input).is_some(),
                "{} should be rewritten",
                full
            );
        }
    }
}
