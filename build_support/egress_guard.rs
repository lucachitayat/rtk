// build_support/egress_guard.rs — the pure logic of the compile-time egress guard.
//
// WHY THIS IS A SEPARATE FILE
// ---------------------------
// It is `include!`d by BOTH `build.rs` and `tests/egress_guard_test.rs`. That is the only
// reason it exists: a `#[cfg(test)] mod tests` inside build.rs never executes. `cargo
// metadata` reports the `build-script-build` target as `test = false`, and the three unit
// tests that lived in build.rs appeared 0 times in a full `cargo test --all` run — verified
// 2026-07-24. They were the guard's only positive control, and they had never once run.
//
// This matters more now than it did: the guard's lockfile scan used to be unreachable in
// every configuration this project builds, and it is now reachable in the exported
// distribution, where it refuses the build. A detector that can fail a customer's build
// needs a control that actually executes.
//
// Contains no side effects and no `main` — only the two pure decisions the guard makes.

// ── Egress guard ─────────────────────────────────────────────────────────────
// HTTP/TLS clients and async runtimes that must never appear in an enterprise
// build. Does NOT include rusqlite, libsqlite3-sys, socket2, or mio — those
// are benign / required.
const FORBIDDEN_CRATES: &[&str] = &[
    "ureq",
    "reqwest",
    "hyper",
    "isahc",
    "curl",
    "surf",
    "attohttpc",
    "minreq",
    "awc",
    "tokio",
    "async-std",
    "smol",
    "native-tls",
    "openssl",
    "rustls",
    "hyper-tls",
    "hyper-rustls",
    "sentry",
    "tungstenite",
    "quinn",
    "h2",
    "h3",
    "trust-dns",
    "hickory-resolver",
];

/// Scan `lock_text` (contents of Cargo.lock) for any forbidden networking
/// crate.  Returns `Some(name)` for the first hit, `None` if the graph is
/// clean.  Pure function — easy to unit-test.
///
/// Fails closed: a Cargo.lock that cannot be parsed as TOML, or that lacks
/// the `[[package]]` array a real lockfile always has, panics instead of
/// reporting "clean". An egress guard that cannot read its input must
/// refuse, not silently approve.
fn forbidden_in_lockfile(lock_text: &str) -> Option<String> {
    let parsed: toml::Value = lock_text
        .parse()
        .unwrap_or_else(|e| panic!("EGRESS GUARD: cannot parse Cargo.lock as TOML: {}", e));
    let packages = parsed
        .get("package")
        .unwrap_or_else(|| {
            panic!("EGRESS GUARD: Cargo.lock has no [[package]] table — malformed lockfile")
        })
        .as_array()
        .unwrap_or_else(|| {
            panic!("EGRESS GUARD: Cargo.lock 'package' key is not an array — malformed lockfile")
        });
    for pkg in packages {
        if let Some(name) = pkg.get("name").and_then(|v| v.as_str()) {
            if FORBIDDEN_CRATES.contains(&name) {
                return Some(name.to_string());
            }
        }
    }
    None
}

/// `true` when `manifest_text` (contents of Cargo.toml) DECLARES a `telemetry`
/// feature under `[features]` — regardless of whether it is active.
///
/// This is what decides whether scanning Cargo.lock is meaningful at all, and the
/// distinction is declared-vs-active, not on-vs-off. Cargo.lock records every
/// resolvable package across ALL feature combinations, so in a tree that merely
/// *declares* an optional `telemetry` feature the lockfile still names ureq and
/// rustls even with the feature off — scanning there would be permanently red. In a
/// tree where the feature does not exist at all (the exported distribution, where
/// the export deletes it) no such resolution is possible, so a hit is a real hit.
///
/// Fails closed, for the same reason `forbidden_in_lockfile` does: this function
/// decides whether the guard runs, so a manifest it cannot read must abort the build
/// rather than answer with a guess. Answering `true` on a parse error would silently
/// switch the guard off in exactly the tree whose manifest is broken.
fn manifest_declares_telemetry_feature(manifest_text: &str) -> bool {
    let parsed: toml::Value = manifest_text
        .parse()
        .unwrap_or_else(|e| panic!("EGRESS GUARD: cannot parse Cargo.toml as TOML: {}", e));
    parsed
        .get("features")
        .and_then(|f| f.as_table())
        .is_some_and(|features| features.contains_key("telemetry"))
}
// ── End egress guard ──────────────────────────────────────────────────────────
