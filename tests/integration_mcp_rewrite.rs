//! Integration tests for MCP rewrite + proxy CLI commands.
//!
//! All tests are marked `#[ignore]` — they require the `rtk` binary to be
//! built. Run with:
//!   `cargo test --test integration_mcp_rewrite -- --ignored`
//!
//! `env!("CARGO_BIN_EXE_rtk")` is provided automatically by Cargo for
//! integration test crates when the package builds a binary named `rtk`.

use std::io::Write;

// ─── Mock upstream helpers ────────────────────────────────────────────────────

/// Bind to a random localhost port; return the bound listener.
fn bind_random_port() -> std::net::TcpListener {
    std::net::TcpListener::bind("127.0.0.1:0").expect("bind random port")
}

fn listener_port(l: &std::net::TcpListener) -> u16 {
    l.local_addr().expect("local_addr").port()
}

/// Spin a minimal HTTP/SSE mock upstream in a background thread.
///
/// Protocol:
/// 1. Accepts `GET /sse` → responds with SSE headers + `endpoint` event, then
///    waits for the POST to arrive before emitting the `message` event.
/// 2. Accepts `POST /message` → drains request body, responds 200 OK, signals
///    the SSE goroutine to emit `message_json`.
fn serve_mock_upstream(
    listener: std::net::TcpListener,
    message_json: String,
) -> std::thread::JoinHandle<()> {
    std::thread::spawn(move || {
        use std::io::{BufRead, BufReader};

        // 1. Accept GET /sse
        let (sse_stream, _) = listener.accept().expect("accept SSE conn");
        let mut sse_write = sse_stream.try_clone().expect("clone sse write end");

        let (post_ready_tx, post_ready_rx) = std::sync::mpsc::channel::<()>();
        let (sse_emit_tx, sse_emit_rx) = std::sync::mpsc::channel::<()>();

        // SSE handler thread: reads GET /sse headers, sends SSE response.
        let msg = message_json.clone();
        std::thread::spawn(move || {
            let mut reader = BufReader::new(sse_stream);
            let mut line = String::new();
            reader.read_line(&mut line).expect("sse request line");
            loop {
                let mut h = String::new();
                reader.read_line(&mut h).expect("drain hdr");
                if h.trim().is_empty() {
                    break;
                }
            }
            let _ = write!(
                &mut sse_write,
                "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: keep-alive\r\n\r\n"
            );
            let _ = write!(
                &mut sse_write,
                "event: endpoint\ndata: /message?sessionId=test-abc\n\n"
            );
            let _ = sse_write.flush();
            let _ = post_ready_tx.send(());
            // Wait for POST handler to have accepted + responded.
            let _ = sse_emit_rx.recv();
            let _ = write!(&mut sse_write, "event: message\ndata: {}\n\n", msg);
            let _ = sse_write.flush();
        });

        // Wait until endpoint event was sent, then accept POST.
        let _ = post_ready_rx.recv();

        if let Ok((mut post_stream, _)) = listener.accept() {
            let mut reader = BufReader::new(post_stream.try_clone().expect("clone post"));
            let mut line = String::new();
            reader.read_line(&mut line).expect("post request line");
            let mut content_length = 0usize;
            loop {
                let mut h = String::new();
                reader.read_line(&mut h).expect("drain hdr");
                if h.trim().is_empty() {
                    break;
                }
                let hl = h.to_lowercase();
                if hl.starts_with("content-length:") {
                    content_length = hl
                        .split(':')
                        .nth(1)
                        .unwrap_or("0")
                        .trim()
                        .parse()
                        .unwrap_or(0);
                }
            }
            if content_length > 0 {
                let mut body = vec![0u8; content_length];
                std::io::Read::read_exact(&mut reader, &mut body).expect("read body");
            }
            let _ = write!(post_stream, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n");
            let _ = post_stream.flush();
            // Signal SSE thread to emit the message event.
            let _ = sse_emit_tx.send(());
        }
    })
}

// ─── A1: Proxy roundtrip ──────────────────────────────────────────────────────

/// A1: Full JSON-RPC roundtrip through the proxy with a mock upstream.
///
/// Sends an `initialize` request; expects the upstream's response back on
/// stdout with matching `id`.
#[test]
#[ignore]
fn test_proxy_roundtrip_with_mock_upstream() {
    let listener = bind_random_port();
    let port = listener_port(&listener);

    let upstream_response = r#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"mock","version":"0.0.1"}}}"#;
    let _server = serve_mock_upstream(listener, upstream_response.to_string());

    let upstream = format!("http://127.0.0.1:{}", port);
    let stdin_payload = r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}}}"#;

    let mut child = std::process::Command::new(env!("CARGO_BIN_EXE_rtk"))
        .args(["mcp-proxy", "--upstream", &upstream])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .expect("spawn rtk mcp-proxy");

    {
        if let Some(ref mut stdin) = child.stdin {
            let _ = stdin.write_all(stdin_payload.as_bytes());
            let _ = stdin.write_all(b"\n");
        }
        child.stdin.take(); // close to signal EOF
    }

    let out = child.wait_with_output().expect("wait for child");
    let stdout_str = String::from_utf8_lossy(&out.stdout);
    let stderr_str = String::from_utf8_lossy(&out.stderr);
    let parsed: serde_json::Value =
        serde_json::from_str(stdout_str.trim()).unwrap_or(serde_json::Value::Null);

    assert!(
        parsed.get("id").is_some(),
        "expected JSON-RPC response with `id` field;\nstdout: {}\nstderr: {}",
        stdout_str,
        stderr_str
    );
    assert_eq!(
        parsed.get("id").and_then(|v| v.as_i64()),
        Some(1),
        "expected id=1 echoed back;\nstdout: {}\nstderr: {}",
        stdout_str,
        stderr_str
    );
}

// ─── A5: Error passthrough ────────────────────────────────────────────────────

/// A5: When the upstream returns a JSON-RPC error, the proxy must pass it
/// through byte-identical — no compaction attempted on error envelopes.
#[test]
#[ignore]
fn test_proxy_error_response_unchanged() {
    let listener = bind_random_port();
    let port = listener_port(&listener);

    let error_response =
        r#"{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}"#;
    let _server = serve_mock_upstream(listener, error_response.to_string());

    let upstream = format!("http://127.0.0.1:{}", port);
    // Send a tools/call so the proxy would normally attempt compaction.
    let stdin_payload = r#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"mcp__rider__search_text","arguments":{"q":"foo"}}}"#;

    let mut child = std::process::Command::new(env!("CARGO_BIN_EXE_rtk"))
        .args(["mcp-proxy", "--upstream", &upstream])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .expect("spawn rtk mcp-proxy");

    {
        if let Some(ref mut stdin) = child.stdin {
            let _ = stdin.write_all(stdin_payload.as_bytes());
            let _ = stdin.write_all(b"\n");
        }
        child.stdin.take();
    }

    let out = child.wait_with_output().expect("wait for child");
    let stdout_str = String::from_utf8_lossy(&out.stdout);
    let parsed: serde_json::Value =
        serde_json::from_str(stdout_str.trim()).unwrap_or(serde_json::Value::Null);

    assert!(
        parsed.get("error").is_some(),
        "expected `error` key preserved in passthrough; stdout: {}",
        stdout_str
    );
    assert_eq!(
        parsed["error"]["code"].as_i64(),
        Some(-32601),
        "error code must be unchanged; stdout: {}",
        stdout_str
    );
    assert!(
        parsed.get("result").is_none(),
        "error response must not grow a `result` key; stdout: {}",
        stdout_str
    );
}

// ─── A4: mcp-rewrite CLI exclusions ──────────────────────────────────────────

/// A4: `rtk mcp-rewrite mcp__rider__search_text '{"q":"foo","paths":["src/"]}'`
/// must exit 0 and inject all three default exclude patterns into `paths`.
#[test]
#[ignore]
fn test_mcp_rewrite_cli_injects_exclusions() {
    let input_json = r#"{"q":"foo","paths":["src/"]}"#;

    let output = std::process::Command::new(env!("CARGO_BIN_EXE_rtk"))
        .args(["mcp-rewrite", "mcp__rider__search_text", input_json])
        .output()
        .expect("failed to spawn rtk mcp-rewrite");

    assert!(
        output.status.success(),
        "expected exit 0, got {:?}\nstdout: {}\nstderr: {}",
        output.status.code(),
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr),
    );

    let stdout = String::from_utf8_lossy(&output.stdout);
    let parsed: serde_json::Value =
        serde_json::from_str(stdout.trim()).expect("stdout should be valid JSON");

    let paths = parsed
        .get("paths")
        .and_then(|v| v.as_array())
        .expect("`paths` array must be present in rewritten output");

    let path_strs: Vec<&str> = paths.iter().filter_map(|v| v.as_str()).collect();

    assert!(
        path_strs.contains(&"!.claude/worktrees/**"),
        "expected `!.claude/worktrees/**` in paths; got: {:?}",
        path_strs
    );
    assert!(
        path_strs.contains(&"!**/obj/**"),
        "expected `!**/obj/**` in paths; got: {:?}",
        path_strs
    );
    assert!(
        path_strs.contains(&"!**/bin/**"),
        "expected `!**/bin/**` in paths; got: {:?}",
        path_strs
    );
    assert!(
        path_strs.contains(&"src/"),
        "original `src/` path must be preserved; got: {:?}",
        path_strs
    );
}
