//! Positive controls for the compile-time egress guard (`build.rs`).
//!
//! WHY THIS FILE IS NOT IN build.rs
//! -------------------------------
//! These three tests used to live in a `#[cfg(test)] mod tests` inside build.rs, where they
//! never ran. `cargo metadata` reports the `build-script-build` target as `test = false`, and
//! their names appeared 0 times in a full `cargo test --all` (verified 2026-07-24). They were
//! the guard's only positive control and the control had never once executed — the same shape
//! as the enterprise auto-allow predicate test, in the guard rather than in the hook.
//!
//! That mattered less while the guard's lockfile scan was unreachable in every configuration
//! this project builds. It matters now: the scan is reachable in the exported distribution,
//! where it can refuse a customer's build.
//!
//! `include!` of the shared source, rather than a copy, so these tests exercise the same code
//! build.rs runs. A copy would drift, and a drifted control is worse than none — it reports on
//! something nobody ships.

#![allow(dead_code)]

include!("../build_support/egress_guard.rs");

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

/// Every forbidden crate must actually be detectable. Asserting one name (reqwest) leaves 23
/// entries whose spelling nothing checks — a typo in the list is invisible, and the list is
/// the whole detector.
#[test]
fn every_forbidden_crate_is_detected() {
    for name in FORBIDDEN_CRATES {
        let lock = format!(
            "[[package]]\nname = \"serde\"\nversion = \"1.0.0\"\n\n\
             [[package]]\nname = \"{name}\"\nversion = \"0.1.0\"\n"
        );
        assert_eq!(
            forbidden_in_lockfile(&lock).as_deref(),
            Some(*name),
            "FORBIDDEN_CRATES lists '{name}' but the scan does not detect it"
        );
    }
}

// ── The declared-vs-active gate ──────────────────────────────────────────────

#[test]
fn manifest_with_telemetry_feature_is_declared() {
    // The dev fork's shape: the feature exists, so the lockfile legitimately carries the
    // telemetry dependency graph and the guard must skip.
    let manifest = "[package]\nname = \"rtk\"\n\n[features]\ndefault = []\nenterprise = []\ntelemetry = [\"ureq\"]\n";
    assert!(
        manifest_declares_telemetry_feature(manifest),
        "a [features] table containing `telemetry` must read as declared"
    );
}

#[test]
fn exported_manifest_shape_is_not_declared() {
    // What the export actually produces: [features] survives with default/enterprise, and the
    // telemetry line is gone. This is the case that makes the guard run for customers, so it
    // is asserted against the real post-export shape rather than an empty manifest.
    let manifest =
        "[package]\nname = \"rtk\"\n\n[features]\ndefault = [\"enterprise\"]\nenterprise = []\n";
    assert!(
        !manifest_declares_telemetry_feature(manifest),
        "an exported manifest with the telemetry feature removed must read as NOT declared"
    );
}

#[test]
fn manifest_without_features_table_is_not_declared() {
    // `develop`'s shape: no [features] block at all.
    let manifest = "[package]\nname = \"rtk\"\n\n[dependencies]\nserde = \"1\"\n";
    assert!(
        !manifest_declares_telemetry_feature(manifest),
        "a manifest with no [features] table must read as NOT declared"
    );
}

#[test]
fn telemetry_elsewhere_in_the_manifest_is_not_a_declaration() {
    // A `telemetry` key under [dependencies], or the word in a comment, must not be mistaken
    // for a feature declaration — that would switch the guard OFF in a tree that should be
    // scanned, which is the fail-open direction.
    let manifest =
        "[package]\nname = \"rtk\"\n# telemetry was removed\n\n[dependencies]\ntelemetry = \"1\"\n";
    assert!(
        !manifest_declares_telemetry_feature(manifest),
        "only a [features] entry counts as a declaration"
    );
}

// ── Fail-closed behaviour ────────────────────────────────────────────────────
//
// Both parsers must abort rather than answer on unreadable input. Without these, the
// "fails closed" claim in the doc comments is an assertion nobody checks.

#[test]
#[should_panic(expected = "cannot parse Cargo.lock")]
fn malformed_lockfile_panics_rather_than_reporting_clean() {
    forbidden_in_lockfile("this is not = valid toml [[[");
}

#[test]
#[should_panic(expected = "no [[package]] table")]
fn lockfile_without_packages_panics() {
    forbidden_in_lockfile("version = 3\n");
}

#[test]
#[should_panic(expected = "'package' key is not an array")]
fn lockfile_with_non_array_package_panics() {
    forbidden_in_lockfile("package = \"not-an-array\"\n");
}

#[test]
#[should_panic(expected = "cannot parse Cargo.toml")]
fn malformed_manifest_panics_rather_than_switching_the_guard_off() {
    manifest_declares_telemetry_feature("[features\nbroken");
}
