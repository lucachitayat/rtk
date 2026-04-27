//! Response-side rewriters for MCP tool results.
//!
//! MCP tool responses have this shape:
//!
//! ```json
//! {
//!   "jsonrpc":"2.0","id":1,
//!   "result":{"content":[{"type":"text","text":"<JSON-encoded tool output>"}]}
//! }
//! ```
//!
//! This module rewrites the inner `text` payload — typically a verbose JSON
//! object with one result per entry and significant key repetition — into a
//! compact Grep-style string. Agents consume the text identically (or better,
//! since `path:line:col content` is a well-known format) at ~60% fewer bytes.
//!
//! All rewriters here are pure: `fn(tool_name, payload_text) -> Option<String>`.
//! The proxy layer owns I/O.

use serde_json::Value;

/// Rewrite a tool's response text if we have a compactor for that tool.
///
/// Returns `Some(new_text)` on a successful rewrite, `None` if the tool is
/// unknown or the payload shape didn't match our expectations (safe
/// passthrough — the proxy emits the original text).
pub fn rewrite_tool_result(tool_name: &str, payload: &str) -> Option<String> {
    let json: Value = serde_json::from_str(payload).ok()?;

    match tool_name {
        "search_file" => compact_search_file(&json),
        "find_files_by_glob" => compact_find_files_by_glob(&json),
        "search_text" | "search_regex" | "search_symbol" => compact_search_hits(&json),
        "search_in_files_by_text" | "search_in_files_by_regex" => compact_legacy_search(&json),
        _ => None,
    }
}

/// `{"items":[{"filePath":"a"},{"filePath":"b"}], "more":bool}` → `"a\nb"`
/// (appends `\n...` sentinel if truncated).
fn compact_search_file(json: &Value) -> Option<String> {
    let items = json.get("items")?.as_array()?;
    let mut out = String::with_capacity(items.len() * 64);
    for item in items {
        if let Some(p) = item.get("filePath").and_then(|v| v.as_str()) {
            if !out.is_empty() {
                out.push('\n');
            }
            out.push_str(p);
        }
    }
    if json.get("more").and_then(|v| v.as_bool()).unwrap_or(false) {
        out.push_str("\n...");
    }
    Some(out)
}

/// `{"files":["a","b"]}` → `"a\nb"`.
fn compact_find_files_by_glob(json: &Value) -> Option<String> {
    let files = json.get("files")?.as_array()?;
    let parts: Vec<&str> = files.iter().filter_map(|v| v.as_str()).collect();
    Some(parts.join("\n"))
}

/// Grep-style output for `search_text`/`search_regex`/`search_symbol`.
/// `{"items":[{filePath,startLine,startColumn,...,lineText}], "more":bool}`
/// → `"path:line:col lineText"` per hit, newline-joined.
fn compact_search_hits(json: &Value) -> Option<String> {
    let items = json.get("items")?.as_array()?;
    let mut out = String::with_capacity(items.len() * 128);
    for item in items {
        let path = item.get("filePath").and_then(|v| v.as_str()).unwrap_or("?");
        let line = item.get("startLine").and_then(|v| v.as_u64()).unwrap_or(0);
        let col = item
            .get("startColumn")
            .and_then(|v| v.as_u64())
            .unwrap_or(0);
        let text = item
            .get("lineText")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .trim_end();
        if !out.is_empty() {
            out.push('\n');
        }
        // Format: <path>:<line>:<col> <lineText>
        // The `||term||` match markers from the Rider MCP are preserved in
        // lineText. Agents parsing this get the same information density as
        // an rg output.
        use std::fmt::Write;
        let _ = write!(&mut out, "{}:{}:{} {}", path, line, col, text);
    }
    if json.get("more").and_then(|v| v.as_bool()).unwrap_or(false) {
        out.push_str("\n...");
    }
    Some(out)
}

/// `{"entries":[{filePath,lineNumber,lineText}], "probablyHasMoreMatchingEntries":bool}`
/// → `"path:line lineText"` per hit, newline-joined.
fn compact_legacy_search(json: &Value) -> Option<String> {
    let entries = json.get("entries")?.as_array()?;
    let mut out = String::with_capacity(entries.len() * 128);
    for item in entries {
        let path = item.get("filePath").and_then(|v| v.as_str()).unwrap_or("?");
        let line = item.get("lineNumber").and_then(|v| v.as_u64()).unwrap_or(0);
        let text = item
            .get("lineText")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .trim_end();
        if !out.is_empty() {
            out.push('\n');
        }
        use std::fmt::Write;
        let _ = write!(&mut out, "{}:{} {}", path, line, text);
    }
    if json
        .get("probablyHasMoreMatchingEntries")
        .and_then(|v| v.as_bool())
        .unwrap_or(false)
    {
        out.push_str("\n...");
    }
    Some(out)
}

/// Unwrap the canonical MCP tool-response envelope, returning
/// `(text_payload, rebuild_fn)`. The rebuild_fn takes a rewritten payload
/// string and returns the updated outer response JSON. `None` if the response
/// shape didn't match (error responses, structured content, etc.).
pub fn rewrite_envelope(response: &mut Value, tool_name: &str) -> Option<(usize, usize)> {
    let result = response.get_mut("result")?;
    let content = result.get_mut("content")?.as_array_mut()?;
    let first = content.first_mut()?;
    if first.get("type").and_then(|v| v.as_str()) != Some("text") {
        return None;
    }
    let original = first.get("text")?.as_str()?.to_string();
    let before = original.len();
    let rewritten = rewrite_tool_result(tool_name, &original)?;
    let after = rewritten.len();
    first["text"] = Value::String(rewritten);

    // Rider also returns `structuredContent` with the full uncompacted JSON
    // (see MCP spec: structured output). Since our compact text form carries
    // the same information, drop `structuredContent` to avoid double-billing
    // the agent when a client reads both.
    if let Some(obj) = result.as_object_mut() {
        obj.remove("structuredContent");
    }
    Some((before, after))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn search_file_compacts_to_newline_list() {
        let payload = r#"{"items":[{"filePath":"a"},{"filePath":"b"}]}"#;
        let out = rewrite_tool_result("search_file", payload).unwrap();
        assert_eq!(out, "a\nb");
    }

    #[test]
    fn search_file_appends_ellipsis_when_more() {
        let payload = r#"{"items":[{"filePath":"a"}],"more":true}"#;
        let out = rewrite_tool_result("search_file", payload).unwrap();
        assert_eq!(out, "a\n...");
    }

    #[test]
    fn find_files_by_glob_compacts_string_array() {
        let payload = r#"{"files":["a","b","c"]}"#;
        let out = rewrite_tool_result("find_files_by_glob", payload).unwrap();
        assert_eq!(out, "a\nb\nc");
    }

    #[test]
    fn search_text_becomes_grep_style() {
        let payload = r#"{"items":[{"filePath":"x.cs","startLine":10,"startColumn":5,"endLine":10,"endColumn":11,"startOffset":100,"endOffset":106,"lineText":"public ||foo||"}]}"#;
        let out = rewrite_tool_result("search_text", payload).unwrap();
        assert_eq!(out, "x.cs:10:5 public ||foo||");
    }

    #[test]
    fn search_text_preserves_more_flag_as_ellipsis() {
        let payload = r#"{"items":[{"filePath":"x","startLine":1,"startColumn":1,"lineText":"a"}],"more":true}"#;
        let out = rewrite_tool_result("search_text", payload).unwrap();
        assert_eq!(out, "x:1:1 a\n...");
    }

    #[test]
    fn legacy_search_in_files_by_text_compacts() {
        let payload = r#"{"entries":[{"filePath":"x","lineNumber":5,"lineText":"hit"}],"probablyHasMoreMatchingEntries":false}"#;
        let out = rewrite_tool_result("search_in_files_by_text", payload).unwrap();
        assert_eq!(out, "x:5 hit");
    }

    #[test]
    fn unknown_tool_returns_none() {
        assert!(rewrite_tool_result("get_services", r#"{"services":[]}"#).is_none());
    }

    #[test]
    fn malformed_payload_returns_none() {
        assert!(rewrite_tool_result("search_file", "not-json").is_none());
    }

    #[test]
    fn envelope_rewrites_in_place_and_reports_sizes() {
        let mut resp = json!({
            "jsonrpc": "2.0",
            "id": 1,
            "result": {
                "content": [{
                    "type": "text",
                    "text": "{\"items\":[{\"filePath\":\"a\"},{\"filePath\":\"b\"}]}"
                }]
            }
        });
        let (before, after) = rewrite_envelope(&mut resp, "search_file").unwrap();
        assert!(after < before);
        let new_text = resp["result"]["content"][0]["text"].as_str().unwrap();
        assert_eq!(new_text, "a\nb");
    }

    #[test]
    fn envelope_returns_none_for_non_text_content() {
        let mut resp = json!({
            "result": {"content": [{"type": "image", "data": "..."}]}
        });
        assert!(rewrite_envelope(&mut resp, "search_file").is_none());
    }

    #[test]
    fn envelope_returns_none_for_error_response() {
        let mut resp = json!({
            "jsonrpc": "2.0", "id": 1,
            "error": {"code": -32600, "message": "bad"}
        });
        assert!(rewrite_envelope(&mut resp, "search_file").is_none());
    }
}
