//! MCP (Model Context Protocol) tool-input rewriters.
//!
//! Where `src/hooks/rewrite_cmd.rs` rewrites raw shell command strings, this
//! module rewrites the structured JSON inputs that Claude Code sends to MCP
//! tool calls (e.g. `mcp__rider__search_file`).
//!
//! Each submodule targets one MCP server. Filters are additive — they inject
//! sensible defaults (worktree / build-artifact excludes, language file
//! masks) that the agent would otherwise have to set every call.

pub mod proxy;
pub mod response;
pub mod rider;
