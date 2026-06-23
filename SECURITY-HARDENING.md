# RTK Enterprise Security Hardening

Version: 0.42.4-dev-fork.2 (enterprise branch)
Review date: 2026-06-22
Reviewer contact: lucachitayat@artium.ai

---

## 1. Scope and Threat Model

**What RTK is.** RTK ("Rust Token Killer") is a CLI proxy that intercepts
developer shell commands, compresses their output to save LLM context tokens,
and optionally rewrites commands via a Claude Code `PreToolUse` hook. It writes
a local SQLite database recording command names and working directories for
token-savings analytics. It links no GUI, spawns no daemon, and — in the
enterprise build — initiates no network connections.

**What the enterprise build changes.** Four controls are added on top of the
upstream codebase to address the concerns below:

1. Auto-approval of commands is disabled (the load-bearing review control).
2. The telemetry subsystem (the sole source of egress) is physically absent
   from the enterprise source tree.
3. A compile-time guard in `build.rs` and a `deny.toml` policy enforce the
   absence of HTTP/TLS/async-runtime crates at the dependency level.
4. The dependency set is vendored, checksummed, and shipped as a signed bundle
   from a controlled staging machine so the enterprise box builds fully offline.

**Assets.** Command-line arguments and working directories stored in the local
SQLite tracking database. No credentials, secrets, or file contents are
recorded.

**Adversaries.** External network adversary (can observe/inject traffic);
supply-chain adversary (malicious transitive dependency); local policy
enforcement (no outbound connections permitted from the build host).

**Out of scope.** The developer's own shell environment, the Claude Code host
process, and any command that RTK passes through to the underlying tool (e.g.,
`git`, `cargo`). RTK compresses output; it does not sandbox the tools it wraps.

---

## 2. Control Matrix

| Concern | Control | Proof / Evidence |
|---|---|---|
| **Command auto-approval** — upstream hook emits `permissionDecision:"allow"`, bypassing the human approval prompt for any rewritten command | Enterprise build compiles with the `enterprise` cargo feature, which routes every decision through the `AskRewrite` path (`hook_cmd.rs`). The `permissionDecision` field is never emitted. | Snapshot test: `cargo test --features enterprise` asserts `permissionDecision` is absent across all four hook hosts (claude, gemini, copilot, cursor). Manual verification: the Claude Code UI re-prompts for every rewritten command in enterprise mode. |
| **Network egress — HTTP client** | The `telemetry` cargo feature is disabled; `ureq` (the sole HTTP/TLS crate) is absent from the compiled binary. `build.rs` panics at compile time if any banned client/runtime crate appears in `Cargo.lock`. `deny.toml` adds a second, independent enforcement layer via `cargo deny check bans`. | **Primary proof:** full command surface run under a deny-all network namespace (`unshare -rn` on Linux, `sandbox-exec` deny-network on macOS) — zero connection attempts observed. Captured as a re-runnable CI artifact. Secondary: `nm -C target/release/rtk \| grep -i ureq` → empty; `strings target/release/rtk \| grep -iE 'ureq\|telemetry\|rtk-ai\.app'` → empty; `cargo tree --features enterprise \| grep -iE 'ureq\|reqwest\|tokio\|hyper\|tls\|openssl\|sentry'` → empty. |
| **Telemetry** | `src/core/telemetry.rs` and `src/core/telemetry_cmd.rs` are physically absent from the enterprise source tree (clean-room export). Git history is squashed to a single orphan commit, removing historical string literals (`telemetry.rtk-ai.app/ping`, `api.rtk-ai.app/telemetry`) that appeared in upstream commits. | `grep -rn 'telemetry\|maybe_ping\|ureq\|TelemetryConfig' src/` → zero matches in the enterprise repo. `git log --all -p \| grep -i 'rtk-ai.app'` → zero matches. |
| **Supply chain** | Dependency set is vendored (`cargo vendor vendor/`) on the staging machine. Cargo verifies vendored crate checksums against `Cargo.lock` automatically during `--offline` builds (integrity control built into cargo). SBOM generated via `cargo cyclonedx -f json`. Bundle signed with a key-pair (cosign or GPG); public key provisioned to the enterprise box out-of-band. | `cargo build --release --locked --offline --features enterprise` succeeds without network. SBOM file (`sbom.cdx.json`) and advisory-db audit report (`audit-report.json`) included in the signed bundle. Signature verified by the enterprise box before build. |
| **Data at rest** | The local SQLite tracking database records command names and working directories only. It is never read by RTK except for the `rtk gain` analytics display. No transmission path exists in the enterprise build. | Confirmed by code review: `src/core/tracking.rs` only writes to `~/.local/share/rtk/rtk.db` (or `RTK_DB_PATH`). No code path reads and transmits DB contents. **TODO (additional hardening):** if the reviewer's data-at-rest policy requires it, the enterprise build can default to `--no-tracking` or redact command arguments, storing only the command name. |
| **Provenance** | `UPSTREAM.md` records the upstream `rtk-ai/rtk` base SHA and the dev-fork export commit from which the enterprise tree was produced. Upstream `LICENSE` is retained. `NOTICE` credits the `rtk-enterprise` technique (Apache-2.0). | See `UPSTREAM.md`. The PROVENANCE.txt file in the signed bundle additionally records `rustc -Vv`, `cargo -V`, `Cargo.lock` SHA-256, and binary SHA-256. |

---

## 3. Residual Risk and Caveats

**Egress claim is scoped to the `rtk` binary.** The control matrix above proves
that the `rtk` binary itself makes no network syscalls and links no HTTP client.
One RTK subcommand, `rtk gain`, may auto-spawn `npx --yes ccusage` as a
fallback for Claude Code usage analytics (`src/analytics/ccusage.rs`). The
`npx` process is not the `rtk` binary and can reach npm registries. In
environments where any child process making network calls is unacceptable, this
fallback must be gated off (compile-time or runtime). The network-namespace test
should be run against the full `rtk gain` invocation to confirm the extent.

**Staging machine trust.** The `Cargo.lock`, vendored sources, and SBOM are
generated on the staging machine. The security claim depends on the staging
machine being in the trust base. The enterprise box's independent checks
(signature verification, cargo checksum verification, pinned advisory-DB date)
reduce but do not eliminate this trust dependency.

**Tracking DB content.** The SQLite database is local-only with no transmission
path in the enterprise build. However, it records command-line strings which may
include paths, project names, or other environment-specific strings. If
data-at-rest policy prohibits recording any command context, the `--no-tracking`
flag or the redaction TODO should be addressed before deployment.

**Rustc minor-version sensitivity.** The enterprise build uses `[lints]
warnings = "deny"` in `Cargo.toml`. Building with a different rustc minor
version than the one used on staging may introduce new lints that fail the
build. The PROVENANCE.txt records the exact `rustc -Vv` output; the enterprise
box must use the same minor version or the `[lints]` policy must be relaxed for
that build.
