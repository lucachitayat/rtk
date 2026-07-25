pub const RTK_DATA_DIR: &str = "rtk";
pub const HISTORY_DB: &str = "history.db";
pub const CONFIG_TOML: &str = "config.toml";
pub const FILTERS_TOML: &str = "filters.toml";
pub const TRUSTED_FILTERS_JSON: &str = "trusted_filters.json";
pub const DEFAULT_HISTORY_DAYS: i64 = 90;

/// RTK-only subcommands that should never fall back to raw execution.
/// When adding a new RTK-only subcommand to `Commands`, add its clap name here.
pub const RTK_META_COMMANDS: &[&str] = &[
    "gain",
    "discover",
    "learn",
    "init",
    "config",
    "proxy",
    "run",
    "hook",
    "hook-audit",
    "pipe",
    "cc-economics",
    "verify",
    "trust",
    "untrust",
    "session",
    "rewrite",
    // Gated so `scripts/export-enterprise.sh` step 2b strips it with the rest of the
    // telemetry surface. The fork's previous copy of this list (in main.rs, before upstream
    // moved it here) carried the same attribute; without it the bare string survives the
    // export and trips the step 6a residual scan.
    #[cfg(feature = "telemetry")]
    "telemetry",
    "smart",
    "deps",
    "json",
];
