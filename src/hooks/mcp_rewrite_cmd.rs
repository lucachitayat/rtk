//! Thin CLI glue: parses `rtk mcp-rewrite <tool_name> <input_json>`, dispatches
//! to the per-server rewriter in `crate::mcp`, prints rewritten JSON on stdout.
//!
//! Exit code protocol (mirrors `rewrite_cmd.rs` to keep hook authoring symmetric):
//!
//! | Exit | Stdout            | Meaning                                           |
//! |------|-------------------|---------------------------------------------------|
//! | 0    | rewritten JSON    | Rewrite applied — hook should emit updatedInput.  |
//! | 1    | (none)            | No rewrite — hook passes through unchanged.       |
//!
//! Unlike the shell `rewrite` command there are no deny/ask verdicts here —
//! MCP input rewriting is purely additive (inject safer defaults). If stronger
//! policies are needed later, bolt on the same PermissionVerdict machinery as
//! the shell-side hook.

use anyhow::Context;
use std::io::Write;

pub fn run(tool_name: &str, input_json: &str) -> anyhow::Result<()> {
    let input: serde_json::Value =
        serde_json::from_str(input_json).context("parsing MCP tool_input JSON")?;

    let rewritten = if tool_name.starts_with("mcp__rider__") {
        crate::mcp::rider::rewrite(tool_name, input)
    } else {
        None
    };

    match rewritten {
        Some(new_input) => {
            let serialized = serde_json::to_string(&new_input)
                .context("serializing rewritten MCP tool_input")?;
            print!("{}", serialized);
            let _ = std::io::stdout().flush();
            Ok(())
        }
        None => std::process::exit(1),
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn non_mcp_tool_name_is_passthrough() {
        // run() calls process::exit(1) on passthrough, so we can't invoke it
        // directly from a test. Instead verify the dispatch branch by calling
        // into the rewriter and asserting it returns None.
        let input: serde_json::Value = serde_json::from_str(r#"{"command":"ls"}"#).unwrap();
        assert!(crate::mcp::rider::rewrite("Bash", input).is_none());
    }

    #[test]
    fn rider_tool_gets_rewritten() {
        let input: serde_json::Value = serde_json::from_str(r#"{"q":"ILogger"}"#).unwrap();
        let out = crate::mcp::rider::rewrite("mcp__rider__search_text", input);
        assert!(out.is_some());
    }
}
