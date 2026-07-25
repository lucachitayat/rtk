use std::collections::HashSet;
use std::fs;
use std::path::Path;

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

/// Run the egress guard — but only when both `enterprise` AND `telemetry`
/// are active. A plain `--features enterprise` build (the only kind this
/// project actually produces; see the design note below) returns at the
/// telemetry gate and never reaches the lockfile scan.
///
/// Panics if the `telemetry` feature is active alongside `enterprise`,
/// confirming this by scanning Cargo.lock for the forbidden crates that
/// telemetry pulls in (ureq, rustls, etc.).
///
/// Design note: Cargo.lock records all resolvable packages across ALL feature
/// combinations — it is not filtered by the current active feature set.
/// Therefore we scope the scan to builds where both `enterprise` AND
/// `telemetry` env vars are set; otherwise the lockfile would always contain
/// rustls (from the telemetry resolution) even when telemetry is disabled.
fn check_enterprise_egress() {
    // Cargo sets CARGO_FEATURE_<NAME> (uppercased, hyphens → underscores) for
    // every active feature.  Skip entirely unless enterprise is active.
    if std::env::var_os("CARGO_FEATURE_ENTERPRISE").is_none() {
        return;
    }

    let manifest_dir =
        std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR must be set by Cargo");
    let lock_path = Path::new(&manifest_dir).join("Cargo.lock");

    // Re-run the guard whenever Cargo.lock changes.
    println!("cargo:rerun-if-changed=Cargo.lock");

    // Only scan when telemetry is also active — that is the feature that
    // brings forbidden networking crates into the compiled binary.
    // An enterprise-only build (no telemetry) is intentionally allowed.
    if std::env::var_os("CARGO_FEATURE_TELEMETRY").is_none() {
        return;
    }

    let lock_text = fs::read_to_string(&lock_path)
        .unwrap_or_else(|e| panic!("EGRESS GUARD: cannot read Cargo.lock: {}", e));

    if let Some(name) = forbidden_in_lockfile(&lock_text) {
        panic!(
            "EGRESS GUARD: forbidden networking crate '{}' present in Cargo.lock — \
             enterprise build refused. Build without --features telemetry.",
            name
        );
    }
}
// ── End egress guard ──────────────────────────────────────────────────────────

fn main() {
    check_enterprise_egress();
    #[cfg(windows)]
    {
        // Clap + the full command graph can exceed the default 1 MiB Windows
        // main-thread stack during process startup. Reserve a larger stack for
        // the CLI binary so `rtk.exe --version`, `--help`, and hook entry
        // points start reliably without requiring ad-hoc RUSTFLAGS.
        println!("cargo:rustc-link-arg=/STACK:8388608");
    }

    let filters_dir = Path::new("src/filters");
    let out_dir = std::env::var("OUT_DIR").expect("OUT_DIR must be set by Cargo");
    let dest = Path::new(&out_dir).join("builtin_filters.toml");

    // Rebuild when any file in src/filters/ changes
    println!("cargo:rerun-if-changed=src/filters");

    let mut files: Vec<_> = fs::read_dir(filters_dir)
        .expect("src/filters/ directory must exist")
        .filter_map(|e| e.ok())
        .filter(|e| e.path().extension().is_some_and(|ext| ext == "toml"))
        .collect();

    // Sort alphabetically for deterministic filter ordering
    files.sort_by_key(|e| e.file_name());

    let mut combined = String::from("schema_version = 1\n\n");

    for entry in &files {
        let content = fs::read_to_string(entry.path())
            .unwrap_or_else(|e| panic!("Failed to read {:?}: {}", entry.path(), e));
        combined.push_str(&format!(
            "# --- {} ---\n",
            entry.file_name().to_string_lossy()
        ));
        combined.push_str(&content);
        combined.push_str("\n\n");
    }

    // Validate: parse the combined TOML to catch errors at build time
    let parsed: toml::Value = combined.parse().unwrap_or_else(|e| {
        panic!(
            "TOML validation failed for combined filters:\n{}\n\nCheck src/filters/*.toml files",
            e
        )
    });

    // Detect duplicate filter names across files
    if let Some(filters) = parsed.get("filters").and_then(|f| f.as_table()) {
        let mut seen: HashSet<String> = HashSet::new();
        for key in filters.keys() {
            if !seen.insert(key.clone()) {
                panic!(
                    "Duplicate filter name '{}' found across src/filters/*.toml files",
                    key
                );
            }
        }
    }

    fs::write(&dest, combined).expect("Failed to write combined builtin_filters.toml");
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Synthetic Cargo.lock fragment containing a forbidden crate.
    const LOCK_WITH_REQWEST: &str = r#"
[[package]]
name = "serde"
version = "1.0.0"
source = "registry+https://github.com/rust-lang/crates.io-index"

[[package]]
name = "reqwest"
version = "0.11.0"
source = "registry+https://github.com/rust-lang/crates.io-index"
"#;

    /// Synthetic Cargo.lock fragment with no forbidden crates.
    const LOCK_CLEAN: &str = r#"
[[package]]
name = "serde"
version = "1.0.0"
source = "registry+https://github.com/rust-lang/crates.io-index"

[[package]]
name = "rusqlite"
version = "0.31.0"
source = "registry+https://github.com/rust-lang/crates.io-index"
"#;

    #[test]
    fn forbidden_in_lockfile_detects_reqwest() {
        let hit = forbidden_in_lockfile(LOCK_WITH_REQWEST);
        assert_eq!(hit.as_deref(), Some("reqwest"), "should detect reqwest");
    }

    #[test]
    fn forbidden_in_lockfile_passes_clean_graph() {
        let hit = forbidden_in_lockfile(LOCK_CLEAN);
        assert!(
            hit.is_none(),
            "clean graph should return None, got {:?}",
            hit
        );
    }

    #[test]
    fn benign_crates_not_flagged() {
        // rusqlite, libsqlite3-sys, socket2, mio must NOT be in the list
        for name in &["rusqlite", "libsqlite3-sys", "socket2", "mio"] {
            assert!(
                !FORBIDDEN_CRATES.contains(name),
                "{} must not be in FORBIDDEN_CRATES",
                name
            );
        }
    }
}
