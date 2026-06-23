# Offline Build Runbook — RTK Enterprise

Two-machine model: STAGING (networked, in the trust base) prepares and signs
the build bundle; ENTERPRISE BOX (air-gapped) verifies the signature and builds
offline. No network access is required or permitted on the enterprise box.

---

## STAGING MACHINE

The staging machine must be explicitly documented as part of the trust base.
Every artifact it produces (Cargo.lock, vendor/, SBOM, audit report, PROVENANCE.txt)
is trusted by the enterprise box only via the signature; the staging machine
itself is the root of trust for those artifacts.

### Prerequisites

- Rust toolchain (rustc >= 1.91, same minor version that will be used on the enterprise box)
- `cargo-deny`: `cargo install cargo-deny --locked`
- `cargo-cyclonedx`: `cargo install cargo-cyclonedx --locked`
- `cargo-audit`: `cargo install cargo-audit --locked`
- `cosign` or `gpg` (for signing)
- Network access to crates.io and the RustSec advisory-db

### Step 1 — Refresh Cargo.lock

Start from a clean checkout of the enterprise source tree (the orphan-commit repo).

```bash
cd /path/to/rtk-airgapped

# Resolve dependencies and write a reproducible Cargo.lock.
cargo generate-lockfile

# Confirm the lock file is committed.
git add Cargo.lock
git diff --cached Cargo.lock   # review any changes
```

### Step 2 — Vendor Dependencies

```bash
# Vendor all crates into vendor/ and write .cargo/config.toml source-replacement.
cargo vendor vendor/

# cargo vendor creates .cargo/config.toml automatically.
# Verify the source-replacement block is present:
grep 'source.crates-io' .cargo/config.toml

# Add to the bundle (do not commit vendor/ to git — it is part of the signed tarball).
```

The resulting `.cargo/config.toml` redirects all registry lookups to `vendor/`.
On the enterprise box, `--offline` and `--locked` enforce that cargo uses only
the vendored sources and that the checksums match `Cargo.lock`.

### Step 3 — Run Supply-Chain Checks

#### 3a. cargo deny

```bash
# Check bans, licenses, advisories, and sources.
cargo deny check

# On a clean enterprise dependency set this should produce zero errors.
# Warnings about multiple-versions or unmaintained crates are expected and documented.
cargo deny check bans        # bans only (fast)
cargo deny check licenses    # license compliance
```

Save the output:

```bash
cargo deny check 2>&1 | tee deny-report.txt
```

#### 3b. cargo audit (pinned advisory-db snapshot)

Pin the advisory-db to a specific date so the enterprise box can reproduce
the check offline without fetching updates.

```bash
# Clone the advisory-db at a known commit.
ADVISORY_DB_DATE="2026-06-22"
git clone https://github.com/RustSec/advisory-db.git \
    --branch main \
    --single-branch \
    advisory-db-snapshot

ADVISORY_DB_SHA=$(git -C advisory-db-snapshot rev-parse HEAD)
echo "Advisory-DB SHA: $ADVISORY_DB_SHA"

# Run audit against the snapshot.
cargo audit --db advisory-db-snapshot 2>&1 | tee audit-report.txt

# Record the advisory-db SHA in PROVENANCE.txt (see Step 5).
```

### Step 4 — Generate SBOM

```bash
# CycloneDX JSON format, suitable for import into most SBOM analysis tools.
cargo cyclonedx -f json --output-file sbom.cdx.json

# Verify the file was created and contains the expected component list.
jq '.components | length' sbom.cdx.json
```

### Step 5 — Write PROVENANCE.txt

```bash
cat > PROVENANCE.txt <<EOF
RTK Enterprise Build Provenance
Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

Upstream base SHA:   <UPSTREAM_BASE_SHA>
Dev-fork export SHA: <DEVFORK_EXPORT_SHA>

Toolchain:
$(rustc -Vv)

Cargo version:
$(cargo -V)

Cargo.lock SHA-256:
$(sha256sum Cargo.lock | awk '{print $1}')

Advisory-DB SHA: $ADVISORY_DB_SHA
Advisory-DB date: $ADVISORY_DB_DATE

Build features: enterprise
Build command: cargo build --release --locked --offline --features enterprise
EOF
```

After building on staging (optional — if producing a reference binary):

```bash
cargo build --release --locked --features enterprise

BINARY_SHA=$(sha256sum target/release/rtk | awk '{print $1}')
echo "" >> PROVENANCE.txt
echo "Reference binary SHA-256 (staging): $BINARY_SHA" >> PROVENANCE.txt
```

### Step 6 — Sign the Bundle

Assemble the bundle:

```bash
mkdir -p rtk-enterprise-bundle/
cp -r vendor/ rtk-enterprise-bundle/
cp .cargo/config.toml rtk-enterprise-bundle/cargo-config.toml
cp Cargo.lock rtk-enterprise-bundle/
cp sbom.cdx.json rtk-enterprise-bundle/
cp audit-report.txt rtk-enterprise-bundle/
cp deny-report.txt rtk-enterprise-bundle/
cp PROVENANCE.txt rtk-enterprise-bundle/
cp -r src/ rtk-enterprise-bundle/
cp Cargo.toml rtk-enterprise-bundle/
cp build.rs rtk-enterprise-bundle/ 2>/dev/null || true
# Include all top-level files (deny.toml, UPSTREAM.md, SECURITY-HARDENING.md, etc.)
cp deny.toml UPSTREAM.md SECURITY-HARDENING.md LICENSE rtk-enterprise-bundle/ 2>/dev/null || true

tar czf rtk-enterprise-bundle.tar.gz rtk-enterprise-bundle/
```

Sign with GPG (key-pair — NOT keyless; keyless cosign requires network):

```bash
# GPG (recommended for air-gapped environments):
gpg --armor --detach-sign rtk-enterprise-bundle.tar.gz
# Produces rtk-enterprise-bundle.tar.gz.asc

# Alternative: cosign with a local key pair:
# cosign generate-key-pair   # run once; keep cosign.key private
# cosign sign-blob --key cosign.key rtk-enterprise-bundle.tar.gz \
#     --output-signature rtk-enterprise-bundle.tar.gz.sig
```

Transfer `rtk-enterprise-bundle.tar.gz` and the signature file (`.asc` or `.sig`)
to the enterprise box via an approved out-of-band channel. Provision the public
key to the enterprise box via the same channel.

---

## ENTERPRISE BOX

### Prerequisites

All prerequisites must be pre-provisioned before the bundle arrives. No
network access is assumed or permitted.

- **rustc >= 1.91** (same minor version used on staging — see PROVENANCE.txt).
  Do NOT rely on `rust-toolchain.toml` to fetch the toolchain; it must already
  be present. Confirm: `rustc -Vv`.
- **C compiler and assembler** on PATH (required by `ring` for cryptographic
  primitives and by `rusqlite` with the `bundled` feature for SQLite compilation).
  Confirm: `cc --version` and `as --version`.
- GPG or cosign public key (provisioned out-of-band from staging).

### Step 1 — Verify Bundle Signature

```bash
# GPG:
gpg --verify rtk-enterprise-bundle.tar.gz.asc rtk-enterprise-bundle.tar.gz
# Expected: "Good signature from ..."

# cosign:
# cosign verify-blob --key cosign.pub \
#     --signature rtk-enterprise-bundle.tar.gz.sig \
#     rtk-enterprise-bundle.tar.gz
# Expected: "Verified OK"
```

Do not proceed if signature verification fails.

### Step 2 — Extract and Configure

```bash
tar xzf rtk-enterprise-bundle.tar.gz
cd rtk-enterprise-bundle/

# Restore the vendor source-replacement config.
mkdir -p .cargo/
cp cargo-config.toml .cargo/config.toml
```

### Step 3 — Build

```bash
cargo build --release --locked --offline --features enterprise
```

What each flag does:
- `--release`: optimized build (<10ms startup, <5MB binary).
- `--locked`: cargo refuses to update `Cargo.lock`; every dependency must match exactly.
- `--offline`: cargo never attempts a network connection; all sources must be vendored.
- `--features enterprise`: activates the auto-approval toggle and egress guard.

Cargo verifies the SHA-256 checksum of every vendored crate against the hashes
recorded in `Cargo.lock`. This is the primary supply-chain integrity control for
the enterprise box.

**Rustc minor-version note.** The enterprise source uses `[lints] workspace = true`
with `warnings = "deny"`. If the enterprise box's rustc minor version differs from
staging's, new lints introduced in the newer compiler may fail the build. To resolve:
either match the rustc version exactly (preferred) or override for the enterprise
build only:

```bash
RUSTFLAGS="-W warnings" cargo build --release --locked --offline --features enterprise
```

### Step 4 — Verify the Binary

```bash
# Confirm no HTTP client symbols are linked.
nm -C target/release/rtk | grep -i ureq
# Expected: no output

# Confirm no telemetry or endpoint strings are embedded.
strings target/release/rtk | grep -iE 'ureq|telemetry|rtk-ai\.app|api\.rtk'
# Expected: no output

# Confirm no async runtime is linked.
nm -C target/release/rtk | grep -iE 'tokio|async_std|smol'
# Expected: no output

# Record the binary SHA-256 and compare to PROVENANCE.txt (if staging produced one).
sha256sum target/release/rtk
```

### Step 5 — Egress Test (Primary Proof)

Run the full RTK command surface under a deny-all network namespace to confirm
zero network syscalls.

**Linux (unshare):**

```bash
# Build a minimal test script.
cat > /tmp/rtk-egress-test.sh <<'EOF'
#!/bin/bash
set -e
RTK=./target/release/rtk

echo "--- rtk gain ---"
$RTK gain 2>&1 || true

echo "--- rtk git status ---"
$RTK git status 2>&1 || true

echo "--- rtk --version ---"
$RTK --version 2>&1

echo "All commands completed."
EOF
chmod +x /tmp/rtk-egress-test.sh

# Run under deny-all network namespace.
unshare -rn /tmp/rtk-egress-test.sh
# Expected: all commands complete without "Connection refused" / ENETUNREACH errors.
```

**Linux (firejail):**

```bash
firejail --net=none /tmp/rtk-egress-test.sh
```

**macOS (sandbox-exec):**

```bash
sandbox-exec -p '(version 1)(deny network*)' /tmp/rtk-egress-test.sh
```

Capture the output as a CI artifact:

```bash
unshare -rn /tmp/rtk-egress-test.sh 2>&1 | tee egress-test-result.txt
echo "Exit code: $?" >> egress-test-result.txt
```

**Note on `rtk gain` and npx.** The `rtk gain` command may attempt to spawn
`npx --yes ccusage` as a fallback. If `npx` is not present or the network is
blocked, RTK falls back gracefully. In the deny-all network namespace test,
confirm that any npx attempt fails with a network error (not a hang), and that
RTK itself continues to function. If strict policy requires no child process
to attempt network access, gate the npx fallback off in the enterprise build
(see `src/analytics/ccusage.rs`).

### Step 6 — Functional Test

```bash
cargo test --release --locked --offline --features enterprise --all
```

All tests must pass. Snapshot tests asserting `permissionDecision` is absent
are included in the enterprise test suite and serve as the auto-approval proof.

---

## Quick-Reference Checklist

### Staging
- [ ] `cargo generate-lockfile` — fresh Cargo.lock
- [ ] `cargo vendor vendor/` — vendored deps + `.cargo/config.toml`
- [ ] `cargo deny check` — supply-chain policy passes
- [ ] `cargo audit --db advisory-db-snapshot` — no vulnerabilities
- [ ] `cargo cyclonedx -f json` — SBOM generated
- [ ] `PROVENANCE.txt` written (rustc -Vv, cargo -V, Cargo.lock sha256)
- [ ] Bundle assembled and signed (GPG key-pair, not keyless)

### Enterprise Box
- [ ] Bundle signature verified before extraction
- [ ] `cargo build --release --locked --offline --features enterprise` succeeds
- [ ] `nm` / `strings` checks — no ureq, tokio, telemetry symbols
- [ ] Egress test under deny-all network namespace — zero connection attempts
- [ ] `cargo test --features enterprise --all` — all tests pass
- [ ] Binary SHA-256 recorded and compared to PROVENANCE.txt
