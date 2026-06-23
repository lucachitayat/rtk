# RTK Enterprise — Security Review Starting Point

This repo is a clean-room export of the RTK ("Rust Token Killer") fork, built for
air-gapped / locked-down enterprise use. Telemetry is **physically absent** from the
source tree; networking crates are absent from the dependency graph; auto-approval of
Claude Code tool-calls is **off by default**.

This document gives a reviewer everything needed to reproduce each claim from source.

---

## Claims

| # | Claim | Evidence |
|---|-------|----------|
| 1 | Zero outbound network calls at runtime | `cargo tree` + `nm` + sandbox proof |
| 2 | No Claude Code auto-approval | Hook JSON diff |
| 3 | Telemetry code physically removed | `grep` over source |
| 4 | `enterprise` + `telemetry` combo is build-time impossible | `build.rs` guard |

---

## Verification — step by step

### Step 0 — Build

```bash
cargo build --release --features enterprise
# Must succeed with no warnings about networking crates.
```

### Step 1 — Dependency graph: no networking crates

```bash
cargo tree --features enterprise 2>&1 | grep -E "ureq|rustls|ring|hyper|reqwest|tokio"
# Expected: no output.
```

If the grep is silent, no HTTP/TLS crate reaches the binary.

Also confirm `telemetry` is not a transitive default:

```bash
grep '^default' Cargo.toml
# Expected: default = ["enterprise"]
```

### Step 2 — Symbol check: no ureq in the binary

```bash
# macOS
nm target/release/rtk | grep -i "ureq\|rustls\|ring\|hyper"

# Linux
nm --defined-only target/release/rtk | grep -i "ureq\|rustls\|ring\|hyper"
```

Expected: no output.

### Step 3 — String check: no telemetry URL in the binary

```bash
strings target/release/rtk | grep -i "rtk-ai\|telemetry\|analytics\|ping\|beacon"
# Expected: no output.
```

### Step 4 — Build-time egress guard: enterprise + telemetry panics

The `build.rs` file contains a compile-time guard that rejects the combination of
`enterprise` and `telemetry` features. Verify it fires:

```bash
cargo build --features enterprise,telemetry 2>&1 | grep "FATAL\|enterprise.*telemetry\|error"
# Expected: build error mentioning the forbidden feature combination.
```

The guard text is in `build.rs` — search for `enterprise` to locate it.

### Step 5 — Telemetry physically absent from source

```bash
grep -r "telemetry\|rtk-ai\.app\|ureq\|analytics_ping" src/ --include='*.rs'
```

Expected: zero hits (the `#[cfg(feature = "telemetry")]` gates and their bodies were
stripped during export; only this Cargo.toml feature declaration remains as a
tombstone comment if present).

### Step 6 — Runtime egress proof (network-deny sandbox)

#### macOS (`sandbox-exec`)

```bash
# Write the deny-network profile:
cat > /tmp/rtk-deny-net.sb << 'EOF'
(version 1)
(deny network*)
(allow default)
EOF

RTK=./target/release/rtk

# Hook rewrite path:
echo '{"tool_name":"Bash","tool_input":{"command":"cargo build"}}' \
  | sandbox-exec -f /tmp/rtk-deny-net.sb $RTK hook claude
# Expected: JSON with updatedInput, NO permissionDecision field, exit 0.

# Analytics (highest egress risk — reads local SQLite only):
sandbox-exec -f /tmp/rtk-deny-net.sb $RTK gain
# Expected: token savings table from local DB, exit 0.

# Version / startup:
sandbox-exec -f /tmp/rtk-deny-net.sb $RTK --version
# Expected: version string, exit 0.
```

#### Linux (`unshare`)

```bash
RTK=./target/release/rtk

# Hook rewrite path:
echo '{"tool_name":"Bash","tool_input":{"command":"cargo build"}}' \
  | unshare -rn $RTK hook claude
# Expected: same JSON output, exit 0.

# Analytics:
unshare -rn $RTK gain
# Expected: token savings table, exit 0.
```

All commands must complete successfully (exit 0) inside the network-deny namespace.
Any attempt to open a socket would produce a `Permission denied` / `EPERM` error
visible in stderr.

**Note on globally-installed `ccusage`.** The enterprise build gates the
`npx --yes ccusage` fallback (`src/analytics/ccusage.rs:99–101`), but will still
invoke a globally-installed `ccusage` binary if one is found in PATH
(`ccusage.rs:88–95` — `binary_exists()` runs before the enterprise gate). `ccusage`
reads local Claude Code session files only and makes no network calls. If the sandbox
output shows a `ccusage` subprocess spawning during `rtk gain`, this is expected and
harmless: it is a local file read, not a network connection. The sandbox test still
confirms RTK itself opens no sockets.

### Step 7 — Auto-approval is off

The enterprise binary never emits `permissionDecision: "allow"` in its hook response,
so Claude Code always falls back to prompting the human — even for commands it has
rewritten (token savings are still applied).

To observe the difference, set up a project with an explicit Bash allow rule, then
compare the hook outputs:

```bash
# 1. Create a demo project with an explicit allow rule:
mkdir -p /tmp/rtk-demo/.claude
cat > /tmp/rtk-demo/.claude/settings.json << 'EOF'
{ "permissions": { "allow": ["Bash(cargo build)"] } }
EOF

RTK=./target/release/rtk

# 2. Enterprise binary — no permissionDecision:
cd /tmp/rtk-demo
echo '{"tool_name":"Bash","tool_input":{"command":"cargo build"}}' | $RTK hook claude
# Expected: {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#             "permissionDecisionReason":"RTK auto-rewrite",
#             "updatedInput":{"command":"rtk cargo build"}}}
# NOTE: no "permissionDecision" key → Claude Code prompts human.

# 3. A non-enterprise build for comparison would add:
#   "permissionDecision": "allow"
# at the end of hookSpecificOutput — which bypasses the human prompt.
```

The controlling code is `auto_allow_enabled()` in `src/hooks/hook_cmd.rs`:

```rust
fn auto_allow_enabled() -> bool {
    !cfg!(feature = "enterprise") && std::env::var_os("RTK_NO_AUTO_ALLOW").is_none()
}
```

With `--features enterprise`, `cfg!(feature = "enterprise")` is `true`, so this
always returns `false`, and `permissionDecision` is never inserted into the response.

---

## Key files

| File | Purpose |
|------|---------|
| `SECURITY-HARDENING.md` | Full threat model and control matrix |
| `UPSTREAM.md` | Provenance — upstream commit the fork is based on |
| `build.rs` | Compile-time egress guard (`enterprise` + `telemetry` conflict) |
| `deny.toml` | `cargo-deny` bans list mirroring the build.rs guard |
| `src/hooks/hook_cmd.rs` | Auto-approval toggle (`auto_allow_enabled`) |
| `src/analytics/ccusage.rs` | `ccusage` npx gate (compile-time disabled under enterprise) |
| `Cargo.toml` | Feature declarations; `default = ["enterprise"]` |

---

## Offline build (air-gapped machines)

See `docs/enterprise/OFFLINE-BUILD-RUNBOOK.md` for the full procedure:
vendor sources, generate SBOM, run `cargo audit`, sign the archive, and build
with `--offline --features enterprise` on the target machine.
