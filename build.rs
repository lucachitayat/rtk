use std::collections::HashSet;
use std::fs;
use std::path::Path;

// FORBIDDEN_CRATES, forbidden_in_lockfile and manifest_declares_telemetry_feature. Kept in a
// shared file because a `#[cfg(test)] mod tests` inside build.rs NEVER RUNS — the
// build-script-build target is `test = false`, so the guard's three unit tests appeared 0
// times in `cargo test --all` (verified 2026-07-24). The same file is `include!`d by
// tests/egress_guard_test.rs, which is where those tests now live and actually execute.
include!("build_support/egress_guard.rs");

/// Run the egress guard: scan Cargo.lock for the forbidden networking crates, and refuse the
/// build if any is present.
///
/// SCOPE — this is the part that was wrong until 2026-07-24. The scan used to be gated on the
/// `telemetry` feature being ACTIVE, which made it unreachable in every configuration this
/// project builds: `enterprise = []` activates nothing on its own, and the export deletes the
/// telemetry feature outright. Three artifacts nevertheless reported that it had passed.
///
/// The gate is now DECLARED-vs-ACTIVE, not on-vs-off:
///
/// - the manifest does NOT declare a `telemetry` feature → SCAN. This is the exported
///   distribution, where the export removed the feature and its dependencies. No telemetry
///   resolution is possible, so any forbidden crate in the lockfile is a real finding. Every
///   customer build now enforces the invariant, including the plain `cargo build --release`
///   they will actually run, since the export rewrites `default = ["enterprise"]`.
/// - the manifest declares it and it is ACTIVE → SCAN, and refuse. Unchanged.
/// - the manifest declares it and it is INACTIVE → SKIP. This is the dev fork. Cargo.lock
///   records all resolvable packages across ALL feature combinations, so the lockfile names
///   ureq and rustls here even with telemetry off. Scanning would be permanently red, and a
///   permanently-red guard gets switched off. This branch is deliberately exempt; making the
///   scan unconditional in the dev fork is the mistake this note exists to prevent.
fn check_enterprise_egress() {
    // Cargo sets CARGO_FEATURE_<NAME> (uppercased, hyphens → underscores) for
    // every active feature.  Skip entirely unless enterprise is active.
    if std::env::var_os("CARGO_FEATURE_ENTERPRISE").is_none() {
        return;
    }

    let manifest_dir =
        std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR must be set by Cargo");
    let lock_path = Path::new(&manifest_dir).join("Cargo.lock");
    let manifest_path = Path::new(&manifest_dir).join("Cargo.toml");

    // Re-run the guard whenever either input changes. Cargo.toml matters now: whether it
    // declares the telemetry feature is what decides if the scan runs at all.
    println!("cargo:rerun-if-changed=Cargo.lock");
    println!("cargo:rerun-if-changed=Cargo.toml");

    let manifest_text = fs::read_to_string(&manifest_path)
        .unwrap_or_else(|e| panic!("EGRESS GUARD: cannot read Cargo.toml: {}", e));
    let telemetry_declared = manifest_declares_telemetry_feature(&manifest_text);
    let telemetry_active = std::env::var_os("CARGO_FEATURE_TELEMETRY").is_some();

    // The guard ANNOUNCES its decision, both ways. Until 2026-07-24 this code path was
    // invisible: three separate artifacts claimed the egress guard had passed while it was
    // returning early in every configuration the project builds, and nothing in any build's
    // output could have contradicted them. A silent guard is indistinguishable from an absent
    // one, so it now says which branch it took.
    //
    // The scanning line is also the reachability control the export asserts (step 6e): a
    // decision this code makes for itself is not something an outside script can infer.
    // And in the distribution it is evidence for the auditor — the build itself states that
    // the lockfile was checked.
    if telemetry_declared && !telemetry_active {
        // Dev fork. See the scope note above — the lockfile legitimately carries the
        // telemetry dependency graph here, so a hit would not mean what it means elsewhere.
        println!(
            "cargo:warning=EGRESS GUARD: SKIPPED — this manifest declares an inactive \
             'telemetry' feature, so Cargo.lock carries its dependency graph regardless. \
             Scanning here would be permanently red. No egress claim is made about this build."
        );
        return;
    }

    let lock_text = fs::read_to_string(&lock_path)
        .unwrap_or_else(|e| panic!("EGRESS GUARD: cannot read Cargo.lock: {}", e));

    println!(
        "cargo:warning=EGRESS GUARD: scanning Cargo.lock for {} forbidden networking crates \
         (telemetry feature declared: {}, active: {})",
        FORBIDDEN_CRATES.len(),
        telemetry_declared,
        telemetry_active
    );

    if let Some(name) = forbidden_in_lockfile(&lock_text) {
        panic!(
            "EGRESS GUARD: forbidden networking crate '{}' present in Cargo.lock — \
             enterprise build refused.{}",
            name,
            if telemetry_active {
                " Build without --features telemetry."
            } else {
                " This tree declares no telemetry feature, so nothing should be pulling \
                  this crate in. Do not silence the guard — find what added the dependency."
            }
        );
    }

    println!("cargo:warning=EGRESS GUARD: PASSED — no forbidden networking crate in Cargo.lock");
}

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

// NO `#[cfg(test)] mod tests` HERE — it would never run. The build-script target is
// `test = false`, so tests written in this file compile in no test binary and report nothing.
// The egress guard's unit tests live in tests/egress_guard_test.rs, which `include!`s
// build_support/egress_guard.rs and therefore exercises the same code this file does.
