//! Sync, threaded MCP proxy: stdio JSON-RPC <-> upstream legacy-SSE MCP server.
//!
//! ### Transport assumed
//!
//! The upstream is assumed to speak the legacy MCP SSE transport:
//!
//! 1. `GET /sse` — opens a persistent `text/event-stream`. The FIRST event is
//!    `event: endpoint\ndata: /message?sessionId=<uuid>`, giving the client
//!    the per-session POST URL.
//! 2. `POST <endpoint>` — client sends JSON-RPC; the response for that `id`
//!    arrives back on the SSE stream as `event: message\ndata: <json>`.
//!
//! This matches the shape JetBrains Rider's MCP server uses on port 64343.
//!
//! ### Threading
//!
//! - **Reader thread** (`sse_reader_loop`): blocking line-read on the SSE
//!   stream. Parses `event:` / `data:` framed blocks. Responses with an `id`
//!   are routed via `mpsc::Sender` to the stdin thread, keyed by the original
//!   request's `id`. Notifications (no `id`) are forwarded straight to stdout.
//! - **Main thread** (`run`): owns stdin, stdout, and the upstream POST
//!   endpoint. For each line of stdin JSON-RPC:
//!     - Record (id -> tool_name) for `tools/call` requests so the response
//!       rewriter knows which tool's payload it's compacting.
//!     - Forward the request body to the upstream via HTTP POST.
//!     - Await the matching response on the shared `Receiver`.
//!     - Rewrite the response (if it's a tool-call response for a tool we
//!       know how to compact), then write back to stdout.
//!
//! Notifications from upstream (`tools/list_changed`, etc.) are broadcast via
//! a separate channel so they don't collide with id-keyed routing.
//!
//! ### Why sync
//!
//! This proxy deliberately stays synchronous (std::thread + std::sync::mpsc).
//! rtk's project discipline is "No async by design" — keeping the binary
//! small and startup <10ms. Two threads and a sync HTTP client (`ureq`) are
//! enough for the ask: the throughput is dozens of tool calls per minute,
//! not thousands per second.

use anyhow::{anyhow, bail, Context, Result};
use serde_json::Value;
use std::collections::HashMap;
use std::io::{self, BufRead, BufReader, Write};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use crate::mcp::response::rewrite_envelope;

/// Run the proxy main loop. Blocks until stdin closes or upstream fails.
pub fn run(upstream: &str) -> Result<()> {
    let upstream = upstream.trim_end_matches('/').to_string();

    // Open the SSE stream. The first `event: endpoint` gives us the POST URL.
    let sse_url = format!("{}/sse", upstream);
    let sse_resp = ureq::get(&sse_url)
        .set("Accept", "text/event-stream")
        .call()
        .with_context(|| format!("opening SSE stream at {}", sse_url))?;

    let reader = BufReader::new(sse_resp.into_reader());

    // Channel for responses keyed by JSON-RPC id. The reader thread routes;
    // the main thread awaits. `Arc<Mutex<HashMap<id, Sender>>>` tracks
    // outstanding requests.
    let pending: Arc<Mutex<HashMap<String, Sender<Value>>>> = Arc::new(Mutex::new(HashMap::new()));

    // Channel for upstream notifications (pass-through to stdout).
    let (notif_tx, notif_rx) = mpsc::channel::<Value>();

    // Channel: reader thread hands back the endpoint URL once it reads the
    // first SSE `endpoint` event.
    let (endpoint_tx, endpoint_rx) = mpsc::channel::<String>();

    let pending_reader = Arc::clone(&pending);
    let reader_handle = thread::spawn(move || {
        if let Err(e) = sse_reader_loop(reader, endpoint_tx, notif_tx, pending_reader) {
            eprintln!("[rtk mcp-proxy] SSE reader terminated: {:#}", e);
        }
    });

    // Wait (briefly) for the endpoint event.
    let endpoint_path = endpoint_rx
        .recv_timeout(Duration::from_secs(5))
        .context("timed out waiting for SSE `endpoint` event from upstream")?;
    let post_url = format!("{}{}", upstream, endpoint_path);

    // Notification forwarder thread: drain `notif_rx` onto stdout.
    thread::spawn(move || {
        let stdout = io::stdout();
        while let Ok(n) = notif_rx.recv() {
            let mut lock = stdout.lock();
            if let Ok(line) = serde_json::to_string(&n) {
                let _ = writeln!(lock, "{}", line);
            }
        }
    });

    // Track which JSON-RPC id corresponds to which tool name, so the
    // response rewriter can look up the compactor.
    let mut id_to_tool: HashMap<String, String> = HashMap::new();

    let stdin = io::stdin();
    let stdout = io::stdout();
    for line in stdin.lock().lines() {
        let line = line.context("reading stdin")?;
        if line.trim().is_empty() {
            continue;
        }

        let req: Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(e) => {
                eprintln!("[rtk mcp-proxy] malformed JSON-RPC line from stdin: {}", e);
                continue;
            }
        };

        // If this is a tools/call with an id, remember the tool name and set
        // up a rendezvous.
        let id_value = req.get("id").cloned();
        let method = req.get("method").and_then(|v| v.as_str()).unwrap_or("");
        let is_call = method == "tools/call";

        let (id_str, rx_opt) = if let Some(id) = id_value.as_ref() {
            let id_str = id_key(id);
            let (tx, rx) = mpsc::channel();
            pending
                .lock()
                .map_err(|_| anyhow!("pending map poisoned"))?
                .insert(id_str.clone(), tx);
            if is_call {
                if let Some(tn) = req
                    .get("params")
                    .and_then(|p| p.get("name"))
                    .and_then(|n| n.as_str())
                {
                    id_to_tool.insert(id_str.clone(), strip_mcp_prefix(tn).to_string());
                }
            }
            (Some(id_str), Some(rx))
        } else {
            (None, None)
        };

        // Forward to upstream.
        let body = serde_json::to_string(&req)?;
        let post = ureq::post(&post_url)
            .set("Content-Type", "application/json")
            .send_string(&body);
        if let Err(e) = post {
            eprintln!("[rtk mcp-proxy] upstream POST failed: {:#}", e);
            if let Some(id) = id_str.as_ref() {
                pending
                    .lock()
                    .map_err(|_| anyhow!("pending map poisoned"))?
                    .remove(id);
            }
            continue;
        }

        // Notifications (no id) don't get a response; we're done.
        let Some(rx) = rx_opt else { continue };
        let id_str = id_str.expect("id_str set when rx_opt is Some");

        // Await the SSE-delivered response. 60s is generous; Rider tool
        // calls normally return in <3s.
        let mut resp = match rx.recv_timeout(Duration::from_secs(60)) {
            Ok(v) => v,
            Err(_) => {
                eprintln!(
                    "[rtk mcp-proxy] timed out awaiting response for id {}",
                    id_str
                );
                pending
                    .lock()
                    .map_err(|_| anyhow!("pending map poisoned"))?
                    .remove(&id_str);
                id_to_tool.remove(&id_str);
                continue;
            }
        };

        // Rewrite if we have a compactor for this tool.
        if let Some(tool) = id_to_tool.remove(&id_str) {
            let _ = rewrite_envelope(&mut resp, &tool);
            // If rewrite_envelope returned None, the original response is
            // already in `resp` unchanged — nothing to do.
        }

        // Write response on its own line.
        let line = serde_json::to_string(&resp)?;
        {
            let mut lock = stdout.lock();
            writeln!(lock, "{}", line)?;
            lock.flush()?;
        }
    }

    // Stdin closed — signal reader to stop by dropping the upstream read.
    // (ureq reader terminates when the body stream ends. We can't force it
    // cleanly from here; rely on process exit.)
    drop(reader_handle);

    Ok(())
}

/// Canonicalize a JSON-RPC id into a string map key. Id can be number or string.
fn id_key(v: &Value) -> String {
    match v {
        Value::String(s) => format!("s:{}", s),
        Value::Number(n) => format!("n:{}", n),
        _ => format!("o:{}", v),
    }
}

/// Strip the `mcp__<server>__` prefix that Claude Code uses, leaving bare
/// `search_text` / `search_file` / etc. for compactor lookup.
fn strip_mcp_prefix(tool: &str) -> &str {
    if let Some(rest) = tool.strip_prefix("mcp__") {
        if let Some(idx) = rest.find("__") {
            return &rest[idx + 2..];
        }
    }
    tool
}

/// Parse an SSE stream: each event is a block of `key: value\n` lines
/// terminated by a blank line. We care about `event:` and `data:` lines.
///
/// Dispatches:
/// - first `event: endpoint` → `endpoint_tx`, then drops.
/// - `event: message` with `id` → `pending.remove(id)?.send(value)`
/// - `event: message` without `id` → `notif_tx`
fn sse_reader_loop<R: BufRead>(
    mut reader: R,
    endpoint_tx: Sender<String>,
    notif_tx: Sender<Value>,
    pending: Arc<Mutex<HashMap<String, Sender<Value>>>>,
) -> Result<()> {
    let mut endpoint_sent = false;
    let mut cur_event = String::new();
    let mut cur_data = String::new();
    let mut line = String::new();

    loop {
        line.clear();
        let n = reader.read_line(&mut line)?;
        if n == 0 {
            // EOF
            break;
        }
        let trimmed = line.trim_end_matches(['\n', '\r']);

        if trimmed.is_empty() {
            // Dispatch the assembled event.
            if !cur_event.is_empty() || !cur_data.is_empty() {
                if !endpoint_sent && cur_event == "endpoint" {
                    endpoint_tx
                        .send(cur_data.clone())
                        .context("sending endpoint to main")?;
                    endpoint_sent = true;
                } else {
                    // `event: message` (default) or anything else — try to
                    // parse data as JSON.
                    if let Ok(v) = serde_json::from_str::<Value>(&cur_data) {
                        let has_id = v.get("id").is_some();
                        if has_id {
                            let k = id_key(v.get("id").unwrap());
                            let tx_opt = pending
                                .lock()
                                .map_err(|_| anyhow!("pending map poisoned"))?
                                .remove(&k);
                            if let Some(tx) = tx_opt {
                                let _ = tx.send(v);
                            } else {
                                // Unknown id — log and drop.
                                eprintln!("[rtk mcp-proxy] orphan response id={}", k);
                            }
                        } else {
                            // Notification.
                            let _ = notif_tx.send(v);
                        }
                    }
                }
            }
            cur_event.clear();
            cur_data.clear();
            continue;
        }

        if let Some(rest) = trimmed.strip_prefix("event: ") {
            cur_event = rest.to_string();
        } else if let Some(rest) = trimmed.strip_prefix("data: ") {
            if !cur_data.is_empty() {
                cur_data.push('\n');
            }
            cur_data.push_str(rest);
        } else if trimmed.starts_with(':') {
            // SSE comment; ignore.
        } else {
            // Field name without known handling — ignore.
        }
    }

    if !endpoint_sent {
        bail!("SSE stream ended before sending endpoint event");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strip_mcp_prefix_removes_server_segment() {
        assert_eq!(strip_mcp_prefix("mcp__rider__search_text"), "search_text");
        assert_eq!(strip_mcp_prefix("mcp__foo__bar_baz"), "bar_baz");
    }

    #[test]
    fn strip_mcp_prefix_passes_through_bare_names() {
        assert_eq!(strip_mcp_prefix("search_text"), "search_text");
        assert_eq!(strip_mcp_prefix("Bash"), "Bash");
    }

    #[test]
    fn id_key_distinguishes_number_and_string() {
        let n = serde_json::json!(1);
        let s = serde_json::json!("1");
        assert_ne!(id_key(&n), id_key(&s));
    }
}
