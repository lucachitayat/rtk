#!/usr/bin/env bash
# scripts/export-enterprise.sh
#
# Clean-room export of the RTK enterprise tree.
#
# PURPOSE
#   Produces a self-contained OUT_DIR that:
#     - Contains the source tree at SOURCE_REF (via git archive — no .git history)
#     - Has telemetry PHYSICALLY REMOVED (not just feature-gated)
#     - Has a single orphan commit with no connection to the dev-fork history
#
# USAGE
#   bash scripts/export-enterprise.sh [SOURCE_REF [OUT_DIR]]
#
#   SOURCE_REF  git ref to export (default: HEAD)
#   OUT_DIR     destination directory (default: /tmp/rtk-enterprise-export)
#
# SAFE TO RE-RUN: OUT_DIR is wiped and recreated on each run.
# DO NOT PUSH: this script never touches any git remote.

set -euo pipefail

# ── Args ─────────────────────────────────────────────────────────────────────

SOURCE_REF="${1:-HEAD}"
OUT_DIR="${2:-/tmp/rtk-enterprise-export}"

# Resolve to the actual repo root (script may be invoked from anywhere).
REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

# The residual-telemetry detector lives in a lib so scripts/test-export-detectors.sh can probe
# the EXACT command run below rather than a hand-copied approximation of it.
# shellcheck source=lib/export-scan.sh
source "${REPO_ROOT}/scripts/lib/export-scan.sh"

# Machine-readable removal manifest: one term per line, appended by step 2a (deleted-file
# stems) and 2c (removed dependency / feature identifiers), consumed by step 6a to derive the
# residual pattern. Deliberately OUTSIDE OUT_DIR — step 7 runs `git add -A` in there, so
# anything written inside would ship to customers.
MANIFEST_TERMS="$(mktemp -t rtk-export-terms.XXXXXX)"
trap 'rm -f "${MANIFEST_TERMS}"' EXIT

echo "=== RTK Enterprise Export ==="
echo "  SOURCE_REF : ${SOURCE_REF}"
echo "  OUT_DIR    : ${OUT_DIR}"
echo "  REPO_ROOT  : ${REPO_ROOT}"
echo ""

# ── Step 1: Fresh export from git archive ────────────────────────────────────
# Using git archive ensures we get exactly the committed tree at SOURCE_REF,
# with no untracked files, dirty working-tree changes, or .git history.

echo "[1/8] Exporting source tree at ${SOURCE_REF} …"
rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}"
git -C "${REPO_ROOT}" archive "${SOURCE_REF}" | tar -x -C "${OUT_DIR}"
echo "      Done — tree written to ${OUT_DIR}"

# ── Step 2: Physical telemetry removal ───────────────────────────────────────

echo ""
echo "[2/8] Removing telemetry …"

# 2a. Delete whole telemetry files.
DELETED_FILES=()
for f in \
    src/core/telemetry.rs \
    src/core/telemetry_cmd.rs
do
    target="${OUT_DIR}/${f}"
    if [[ -f "${target}" ]]; then
        rm "${target}"
        DELETED_FILES+=("${f}")
        # Removal manifest: the deleted file's stem is by construction a term that must not
        # survive anywhere in the shipped tree (telemetry, telemetry_cmd). Step 6a unions
        # these with its hardcoded floor, so adding a file to this loop automatically widens
        # the residual scan instead of requiring someone to remember to widen it.
        basename "${f}" .rs >> "${MANIFEST_TERMS}"
        echo "      Deleted: ${f}"
    else
        echo "      WARN: ${f} not found in export (already absent?)"
    fi
done

# 2b. Strip every #[cfg(feature = "telemetry")] attribute + the item it gates,
#     across all *.rs files under src/.
#
#     The stripper is implemented as an embedded Python 3 script so it can
#     perform proper brace-balanced, string/char/comment-aware parsing.
#     It ABORTS with a non-zero exit code naming file+line if it cannot
#     confidently locate the item boundary — fail-closed, never emits a
#     half-stripped file.

echo "      Running attribute stripper across src/**/*.rs …"

python3 - "${OUT_DIR}" <<'PYEOF'
import sys
import os
import re

# ── Brace-balanced, string/comment-aware character scanner ───────────────────

def scan_item_end(text: str, start_offset: int, path: str, origin_lineno: int) -> int:
    """
    Scan forward from start_offset through `text`, returning the exclusive end
    offset of the Rust item.  The item may be:
      - A use/single statement ending at ';' at brace-depth 0
      - An enum variant or struct field ending at ',' at brace-depth 0 (no '{' seen)
      - A brace-delimited block (fn/impl/struct/mod/match-arm) — ends at the
        balanced '}', plus an optional trailing ','

    Skips over any leading #[...] attribute lines and doc-comment lines that
    appear before the actual item keyword/token.

    Raises RuntimeError if the boundary cannot be found.
    """
    n = len(text)
    k = start_offset

    depth = 0
    in_string = False
    in_raw = False
    raw_hashes = 0
    in_char = False
    in_block_comment = False
    found_open_brace = False

    # Helper: skip to end of current line (exclusive of the '\n').
    def skip_line(k):
        while k < n and text[k] != '\n':
            k += 1
        return k  # points at '\n' or end-of-text

    # Skip over leading attribute lines (#[...]) and doc comments (///, //!)
    # that sit between the cfg attribute and the actual item body.
    while k < n:
        # Skip blank lines.
        if text[k] in (' ', '\t', '\n'):
            k += 1
            continue
        # Another attribute line: #[...]
        if text[k] == '#' and k + 1 < n and text[k+1] == '[':
            k = skip_line(k)
            if k < n and text[k] == '\n':
                k += 1
            continue
        # Doc comment or regular line comment: // or ///
        if text[k] == '/' and k + 1 < n and text[k+1] == '/':
            k = skip_line(k)
            if k < n and text[k] == '\n':
                k += 1
            continue
        # Found the start of the actual item.
        break

    if k >= n:
        raise RuntimeError(
            f"{path}:{origin_lineno}: #[cfg(feature=\"telemetry\")] attribute "
            f"has no following item (reached EOF after skipping attributes/comments)"
        )

    item_body_start = k

    while k < n:
        c = text[k]

        # ── Block comment exit ────────────────────────────────────────────────
        if in_block_comment:
            if c == '*' and k + 1 < n and text[k+1] == '/':
                in_block_comment = False
                k += 2
            else:
                k += 1
            continue

        # ── Raw string exit ───────────────────────────────────────────────────
        if in_raw:
            if c == '"':
                end_hashes = 0
                m = k + 1
                while m < n and text[m] == '#' and end_hashes < raw_hashes:
                    end_hashes += 1
                    m += 1
                if end_hashes == raw_hashes:
                    in_raw = False
                    k = m
                    continue
            k += 1
            continue

        # ── String exit ───────────────────────────────────────────────────────
        if in_string:
            if c == '\\':
                k += 2
            elif c == '"':
                in_string = False
                k += 1
            else:
                k += 1
            continue

        # ── Char literal exit ─────────────────────────────────────────────────
        if in_char:
            if c == '\\':
                k += 2
            elif c == '\'':
                in_char = False
                k += 1
            else:
                k += 1
            continue

        # ── Normal character ──────────────────────────────────────────────────

        # Line comment — skip to end of line.
        if c == '/' and k + 1 < n and text[k+1] == '/':
            k = skip_line(k)
            continue

        # Block comment open.
        if c == '/' and k + 1 < n and text[k+1] == '*':
            in_block_comment = True
            k += 2
            continue

        # Raw string open: r#*"
        if c == 'r':
            m = k + 1
            hcount = 0
            while m < n and text[m] == '#':
                hcount += 1
                m += 1
            if m < n and text[m] == '"':
                in_raw = True
                raw_hashes = hcount
                k = m + 1
                continue

        # String open.
        if c == '"':
            in_string = True
            k += 1
            continue

        # Char literal open.
        if c == '\'':
            # Lifetime heuristic: 'a followed by non-quote, non-backslash at [k+2].
            if (k + 1 < n and text[k+1] not in ("'", '\\')
                    and (k + 2 >= n or text[k+2] != '\'')):
                # Likely a lifetime — do not enter char-literal mode.
                k += 1
                continue
            in_char = True
            k += 1
            continue

        # Open brace.
        if c == '{':
            depth += 1
            found_open_brace = True
            k += 1
            continue

        # Close brace.
        if c == '}':
            depth -= 1
            if depth == 0 and found_open_brace:
                # Balanced close found.
                k += 1
                # Peek: if '=> {' follows (match arm body), keep scanning —
                # the closing '}' we just found was a struct pattern, not the
                # item body.  Skip whitespace and check for '=>'.
                peek = k
                while peek < n and text[peek] in (' ', '\t', '\n'):
                    peek += 1
                if peek + 1 < n and text[peek] == '=' and text[peek+1] == '>':
                    # This '}' ended a struct pattern (e.g. `Variant { field }`).
                    # Reset found_open_brace so we continue scanning through '=>'.
                    found_open_brace = False
                    depth = 0
                    continue
                # Otherwise this is the true end of the item.
                # Consume optional trailing ',' and newline.
                while k < n and text[k] in (' ', '\t'):
                    k += 1
                if k < n and text[k] == ',':
                    k += 1
                while k < n and text[k] in (' ', '\t'):
                    k += 1
                if k < n and text[k] == '\n':
                    k += 1
                return k
            if depth < 0:
                raise RuntimeError(
                    f"{path}:{origin_lineno}: brace underflow scanning item — "
                    f"cannot determine boundary (check for macro/match context)"
                )
            k += 1
            continue

        # Semicolon at depth 0, no brace seen → single-statement item.
        if c == ';' and depth == 0 and not found_open_brace:
            k += 1
            while k < n and text[k] in (' ', '\t'):
                k += 1
            if k < n and text[k] == '\n':
                k += 1
            return k

        # Comma at depth 0, no brace seen → enum variant or struct field.
        if c == ',' and depth == 0 and not found_open_brace:
            k += 1
            while k < n and text[k] in (' ', '\t'):
                k += 1
            if k < n and text[k] == '\n':
                k += 1
            return k

        k += 1

    raise RuntimeError(
        f"{path}:{origin_lineno}: reached EOF without finding item boundary after "
        f"#[cfg(feature=\"telemetry\")] — cannot strip safely"
    )


def strip_telemetry_items(path: str) -> tuple[str, int]:
    """
    Return (new_content, count_of_items_removed).
    Raises RuntimeError with file+line info if any boundary is unresolvable.
    """
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read()

    # Pattern: #[cfg(feature = "telemetry")] alone on a line (leading whitespace ok).
    ATTR_RE = re.compile(r'(?m)^[ \t]*#\[cfg\(\s*feature\s*=\s*"telemetry"\s*\)\][ \t]*\n')

    removed = 0
    result_parts = []
    pos = 0

    for m in ATTR_RE.finditer(text):
        attr_start = m.start()
        attr_end = m.end()   # offset just after the '\n' of the #[cfg] line

        # Walk BACKWARDS from attr_start to collect any preceding comment lines
        # (///, //!, or regular //) that logically belong to this item and must
        # be removed alongside it.  Stop at a blank line or any other content.
        prefix_start = attr_start
        # Collect the text before the attr as a list of line boundaries.
        before = text[:attr_start]
        before_lines = before.splitlines(keepends=True)
        # Walk backwards through lines.
        cutback = len(before_lines)
        while cutback > 0:
            prev_line = before_lines[cutback - 1]
            stripped = prev_line.strip()
            if stripped.startswith('//'):
                cutback -= 1
            else:
                break
        # prefix_start is the start of the first comment line to remove.
        prefix_start = sum(len(l) for l in before_lines[:cutback])

        # Emit everything from `pos` up to `prefix_start`.
        result_parts.append(text[pos:prefix_start])

        # Find end of the item body that follows the #[cfg] attribute.
        origin_lineno = text[:attr_start].count('\n') + 1
        item_end = scan_item_end(text, attr_end, path, origin_lineno)

        pos = item_end
        removed += 1

    result_parts.append(text[pos:])
    return "".join(result_parts), removed


# ── Walk src/ and apply stripper ─────────────────────────────────────────────

out_dir = sys.argv[1]
src_dir = os.path.join(out_dir, "src")

total_removed = 0
modified_files = []
errors = []

for dirpath, dirnames, filenames in os.walk(src_dir):
    for fname in sorted(filenames):
        if not fname.endswith(".rs"):
            continue
        fpath = os.path.join(dirpath, fname)
        with open(fpath, "r", encoding="utf-8") as fh:
            original = fh.read()

        if '#[cfg(feature = "telemetry")]' not in original:
            continue

        try:
            new_content, count = strip_telemetry_items(fpath)
        except RuntimeError as e:
            errors.append(str(e))
            continue

        if count > 0:
            rel = os.path.relpath(fpath, out_dir)
            modified_files.append((rel, count))
            with open(fpath, "w", encoding="utf-8") as fh:
                fh.write(new_content)
            total_removed += count

if errors:
    print("FATAL: attribute stripper encountered unresolvable boundaries:", file=sys.stderr)
    for e in errors:
        print(f"  {e}", file=sys.stderr)
    sys.exit(1)

print(f"      Stripped {total_removed} telemetry item(s) across {len(modified_files)} file(s):")
for (rel, count) in modified_files:
    print(f"        {rel}  ({count} item{'s' if count != 1 else ''})")
PYEOF

# 2c. Cargo.toml: remove ureq / getrandom dep lines, telemetry feature line,
#     and update default feature to enterprise.
echo "      Patching Cargo.toml …"
python3 - "${OUT_DIR}/Cargo.toml" "${MANIFEST_TERMS}" <<'PYEOF'
import sys
import re

path = sys.argv[1]
# Removal manifest (append-only). Every dependency or feature this step strips is, by
# construction, a term step 6a must not find anywhere in the shipped tree — so record the bare
# identifier here rather than relying on someone remembering to add it to 6a's pattern. Only
# the identifier: 6a validates each derived term and rejects anything that is not one.
terms_path = sys.argv[2]
with open(path, "r") as fh:
    lines = fh.readlines()

out = []
removed = []
terms = []
for line in lines:
    stripped = line.strip()
    # Remove ureq and getrandom dependency lines (optional dep declarations).
    dep = re.match(r'^(ureq|getrandom)\s*=', stripped)
    if dep:
        removed.append(("dep", stripped))
        terms.append(dep.group(1))
        continue
    # Remove the telemetry = [...] feature line and any immediately-preceding
    # comment lines that reference telemetry/ureq/getrandom (stale dev notes).
    if re.match(r'^telemetry\s*=', stripped):
        removed.append(("feature", stripped))
        terms.append("telemetry")
        # Walk back in `out` and remove trailing comment lines that mention
        # these removed deps (they are stale internal notes, not API docs).
        while out and re.match(r'^\s*#.*(?:telemetry|ureq|getrandom)', out[-1]):
            removed.append(("stale-comment", out.pop().strip()))
        continue
    # Change default = [] to default = ["enterprise"].
    if re.match(r'^default\s*=\s*\[\s*\]', stripped):
        line = re.sub(r'default\s*=\s*\[\s*\]', 'default = ["enterprise"]', line)
        removed.append(("default-rewrite", stripped))
    out.append(line)

with open(path, "w") as fh:
    fh.writelines(out)

with open(terms_path, "a") as fh:
    for t in terms:
        fh.write(t + "\n")

for (kind, val) in removed:
    print(f"        Cargo.toml [{kind}] removed/updated: {val}")
print(f"        Removal manifest: recorded {len(terms)} residual term(s): {', '.join(sorted(set(terms))) or '(none)'}")
PYEOF

# ── Step 3: Write UPSTREAM.md ─────────────────────────────────────────────────

echo ""
echo "[3/8] Prepending enterprise header to CHANGELOG.md …"

CHANGELOG="${OUT_DIR}/CHANGELOG.md"
if [[ -f "${CHANGELOG}" ]]; then
    if grep -qF 'Enterprise hardened build' "${CHANGELOG}"; then
        echo "      CHANGELOG.md already contains enterprise header — skipping (idempotent)."
    else
        python3 - "${CHANGELOG}" <<'PYEOF'
import sys

path = sys.argv[1]
HEADER = (
    "\n"
    "> **Enterprise hardened build** — the telemetry subsystem has been removed"
    " from this distribution. Entries below are upstream history (rtk-ai/rtk)"
    " and may reference telemetry features that are not present in this build.\n"
    "\n"
)

with open(path, "r", encoding="utf-8") as fh:
    content = fh.read()

lines = content.splitlines(keepends=True)

# Find the first top-level heading line (`# ...`).
insert_after = 0
for i, line in enumerate(lines):
    if line.startswith("# "):
        insert_after = i + 1
        break

lines.insert(insert_after, HEADER)

with open(path, "w", encoding="utf-8") as fh:
    fh.writelines(lines)

print(f"      Enterprise header inserted after line {insert_after} of CHANGELOG.md.")
PYEOF
    fi
else
    echo "      WARN: CHANGELOG.md not found in export — skipping header insertion."
fi

echo ""
echo "[4/8] Scrubbing telemetry references from non-.rs files across the export …"

# Strip telemetry-mentioning lines from markdown/text files ACROSS THE WHOLE EXPORT.
#
# Was scoped to src/ until 2026-07-24, on the theory that top-level docs were
# "intentional".  That was wrong and it shipped: README.md carried a live
# "## Privacy & Telemetry" section stating RTK "can collect anonymous, aggregate
# usage metrics once per day", and docs/usage/FEATURES.md documented a
# [telemetry] config block and RTK_TELEMETRY_DISABLED — describing a capability
# the distro does not contain.  Scoping a residual scrub narrower than the
# shipped surface means the largest residual is the one nobody looks at.
#
# ALLOWLIST — files that mention the vocabulary LEGITIMATELY and must not be
# scrubbed.  Each entry is a positive signal, not a leak:
#   Cargo.lock       getrandom arrives transitively (verified present, unrelated
#                    to telemetry, whose deps 2c removes); scrubbing corrupts it.
#   Cargo.toml       2c already patched it; re-scrubbing would mangle TOML.
#   build.rs         drives the egress guard.
#   build_support/egress_guard.rs
#                    FORBIDDEN_CRATES literally names ureq/reqwest by design — it IS the
#                    egress denylist. Split out of build.rs so its unit tests actually run;
#                    a build script's own #[cfg(test)] tests never do.
#   tests/egress_guard_test.rs
#                    those tests. They assert the declared-vs-active predicate against real
#                    manifest shapes, so `telemetry = ["ureq"]` appears in string literals
#                    BY DESIGN. Scrubbing it would delete the assertions.
#   deny.toml        cargo-deny BANS ureq; the mention is the enforcement.
#   DISCLAIMER.md REVIEWER-README.md SECURITY-HARDENING.md CHANGELOG.md UPSTREAM.md
#                    enterprise-authored; they explain that telemetry was REMOVED.
# DRIFT GUARD: keep this list in sync with the step-6a scan allowlist below.
# Anything added here is a file the residual scan will also stop protecting.
python3 - "${OUT_DIR}" <<'PYEOF'
import sys
import os
import re

src_dir = sys.argv[1]

ALLOWLIST = {
    'Cargo.lock', 'Cargo.toml', 'build.rs', 'deny.toml',
    'build_support/egress_guard.rs', 'tests/egress_guard_test.rs',
    'DISCLAIMER.md', 'REVIEWER-README.md', 'SECURITY-HARDENING.md',
    'CHANGELOG.md', 'UPSTREAM.md',
}

# Lines matching any of these patterns are removed from non-.rs files.
TELEMETRY_LINE_RE = re.compile(
    r'telemetry\.rs|telemetry_cmd\.rs|telemetry|TelemetryConfig|maybe_ping|ureq',
    re.IGNORECASE,
)

HEADING_RE = re.compile(r'^(#{1,6})\s')

# Markdown sections are removed WHOLE, before any line-level scrubbing.
#
# Line-level scrubbing alone is unsound on prose: it deletes the lines that NAME the
# thing and keeps the lines that DESCRIBE it. Measured on 2026-07-24 — scrubbing
# README.md by line removed the "## Privacy & Telemetry" heading and its intro
# paragraph, then left the ten-row table beneath it fully intact ("Salted device
# hash", "Command count (24h)", "Estimated USD value", …) because not one of those
# rows contains the word "telemetry". The residual scan passed, because the
# detector's vocabulary and the residual's vocabulary had stopped overlapping.
# The result shipped a detailed data-collection catalogue with the heading that
# framed it as opt-in removed — strictly worse than leaving the section alone.
#
# So: if a HEADING matches, drop from that heading to the next heading of the same
# or higher level. Body-only mentions still fall through to the line scrubber.
def strip_md_sections(lines):
    out, i, dropped = [], 0, 0
    while i < len(lines):
        m = HEADING_RE.match(lines[i])
        if m and TELEMETRY_LINE_RE.search(lines[i]):
            level = len(m.group(1))
            i += 1
            while i < len(lines):
                m2 = HEADING_RE.match(lines[i])
                if m2 and len(m2.group(1)) <= level:
                    break
                i += 1
                dropped += 1
            dropped += 1  # the heading itself
            continue
        out.append(lines[i])
        i += 1
    return out, dropped

# Stripping lines out of a fenced block can leave ```lang / ``` with nothing between.
def drop_empty_fences(lines):
    out, i, dropped = [], 0, 0
    while i < len(lines):
        if lines[i].lstrip().startswith('```') and i + 1 < len(lines) \
                and lines[i + 1].strip() == '```':
            i += 2
            dropped += 2
            continue
        out.append(lines[i])
        i += 1
    return out, dropped

modified = []
for dirpath, _dirs, filenames in os.walk(src_dir):
    for fname in sorted(filenames):
        if fname.endswith('.rs'):
            continue  # .rs files already handled by the attribute stripper
        fpath = os.path.join(dirpath, fname)
        if os.path.relpath(fpath, src_dir) in ALLOWLIST:
            continue  # legitimate mention — see ALLOWLIST rationale above
        try:
            with open(fpath, 'r', encoding='utf-8') as fh:
                lines = fh.readlines()
        except (UnicodeDecodeError, PermissionError):
            continue  # skip binary files

        sec_dropped = 0
        if fname.endswith('.md'):
            lines_after, sec_dropped = strip_md_sections(lines)
        else:
            lines_after = lines

        kept = [l for l in lines_after if not TELEMETRY_LINE_RE.search(l)]
        if fname.endswith('.md'):
            kept, fence_dropped = drop_empty_fences(kept)
        else:
            fence_dropped = 0

        removed_count = len(lines) - len(kept)
        if removed_count == 0:
            continue  # nothing changed

        rel = os.path.relpath(fpath, src_dir)
        with open(fpath, 'w', encoding='utf-8') as fh:
            fh.writelines(kept)
        modified.append((rel, removed_count))
        detail = f" ({sec_dropped} in whole sections)" if sec_dropped else ""
        print(f"        {rel}  ({removed_count} line{'s' if removed_count != 1 else ''} removed{detail})")

if not modified:
    print("        No non-.rs files required changes.")
else:
    print(f"      Scrubbed {sum(c for _, c in modified)} line(s) across {len(modified)} file(s).")
PYEOF

echo ""
echo "[5/8] Writing UPSTREAM.md …"

EXPORT_SHA="$(git -C "${REPO_ROOT}" rev-parse "${SOURCE_REF}")"

UPSTREAM_BASE_SHA="<UPSTREAM_BASE_SHA>"
if git -C "${REPO_ROOT}" remote | grep -q '^upstream$'; then
    if git -C "${REPO_ROOT}" merge-base "${SOURCE_REF}" upstream/develop &>/dev/null; then
        UPSTREAM_BASE_SHA="$(git -C "${REPO_ROOT}" merge-base "${SOURCE_REF}" upstream/develop)"
        echo "      UPSTREAM_BASE_SHA resolved: ${UPSTREAM_BASE_SHA}"
    else
        echo "      NOTE: 'upstream' remote exists but merge-base failed — leaving placeholder."
    fi
else
    echo "      NOTE: no 'upstream' remote found — leaving UPSTREAM_BASE_SHA placeholder."
fi

# Populate UPSTREAM.md from the template that was just exported (already in OUT_DIR).
UPSTREAM_MD="${OUT_DIR}/UPSTREAM.md"
if [[ -f "${UPSTREAM_MD}" ]]; then
    python3 - "${UPSTREAM_MD}" "${EXPORT_SHA}" "${UPSTREAM_BASE_SHA}" <<'PYEOF'
import sys
path, export_sha, upstream_base_sha = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "r") as fh:
    content = fh.read()
content = content.replace("<DEVFORK_EXPORT_SHA>", export_sha)
content = content.replace("<UPSTREAM_BASE_SHA>", upstream_base_sha)
with open(path, "w") as fh:
    fh.write(content)
print(f"      UPSTREAM.md updated with export SHA {export_sha[:12]}…")
PYEOF
else
    # Template not present in archive — generate a minimal one.
    cat > "${UPSTREAM_MD}" <<MDEOF
# Upstream Provenance

**Upstream project:** rtk-ai/rtk ("Rust Token Killer")
**Dev-fork export SHA:** \`${EXPORT_SHA}\`
**Upstream base SHA:** \`${UPSTREAM_BASE_SHA}\`

Generated by scripts/export-enterprise.sh at export time.
MDEOF
    echo "      UPSTREAM.md created (template absent from archive)."
fi

# ── Step 4: Verification ─────────────────────────────────────────────────────

echo ""
echo "[6/8] Verifying …"

# 6a. No telemetry / ureq / getrandom / maybe_ping / TelemetryConfig refs remain
#     anywhere in the SHIPPED TREE — not just src/.
#
# Scope was `${OUT_DIR}/src/` until 2026-07-24 and that is how docs/TELEMETRY.md
# reached customers: 189 lines opening "RTK collects anonymous, aggregate usage
# metrics once per day", naming a data collector and a contact address. The code
# was clean the whole time; the scan simply never looked at the largest residual.
# A detector is only as good as its domain — scanning a subset of what ships and
# reporting PASS is an absence assertion about a place you did not examine.
# The detector, its term list, its glob allowlist and its three-outcome contract all live in
# scripts/lib/export-scan.sh, sourced at the top. Nothing about the scan is written twice:
# scripts/test-export-detectors.sh plants canaries and probes the SAME functions, so its
# positive controls are controls on the command that actually ships this tree.
#
# The pattern is the UNION of a hardcoded floor and the terms derived from what steps 2a/2c
# actually removed — never a replacement for the floor. Residual limit, stated honestly: the
# derivation is bounded by what 2a/2b/2c removed, so a leak whose vocabulary is disjoint from
# the removed code stays invisible to it. Union-with-hardcoded keeps the pattern monotonically
# additive, so widening it can never narrow it.
RESIDUAL_PATTERN="$(residual_pattern "${MANIFEST_TERMS}")"
echo "      [6a] Checking for residual refs across the shipped tree …"
echo "           pattern: ${RESIDUAL_PATTERN}"
echo "           derived from the removal manifest: $(sort -u "${MANIFEST_TERMS}" | paste -sd ',' - || true)"
# Three outcomes, not two: CLEAN (0) / FOUND (1) / CANNOT-VERIFY (2). `set +e` around the call
# because a bare assignment from a non-zero substitution would abort before the case runs, and
# CANNOT-VERIFY must be reported as itself rather than as a shell abort.
set +e
GREP_HIT="$(residual_scan "${OUT_DIR}" "${RESIDUAL_PATTERN}")"
SCAN_RC=$?
set -e
case "${SCAN_RC}" in
    0) echo "      PASS — no residual ${RESIDUAL_PATTERN} anywhere in the shipped tree" ;;
    1)
        echo "FATAL: residual references found in the shipped tree:" >&2
        echo "${GREP_HIT}" >&2
        exit 1
        ;;
    *)
        echo "FATAL: cannot verify the shipped tree — see the reason above. An unverifiable" >&2
        echo "       egress claim is not a passing one." >&2
        exit 1
        ;;
esac

# 6b. cargo build --release succeeds — AND the build-time egress guard is observed to run.
#
# The output is captured rather than streamed because 6e reads it. build.rs announces which
# branch check_enterprise_egress() took via `cargo:warning=`, and 6e asserts the announcement
# is present. That assertion is the reachability control: whether the guard's lockfile scan is
# reachable depends on the exported manifest and on Cargo's feature environment, neither of
# which this script can infer — it has to be told by the code that decides.
echo "      [6b] Running cargo build --release …"
BUILD_LOG="$(mktemp -t rtk-export-build.XXXXXX)"
trap 'rm -f "${MANIFEST_TERMS}" "${BUILD_LOG}"' EXIT
(cd "${OUT_DIR}" && cargo build --release 2>&1) | tee "${BUILD_LOG}"
echo "      PASS — cargo build --release succeeded"

# 6c. cargo tree must show no ureq.
#
# Was `cargo tree 2>/dev/null | grep -i ureq || true`. That is fail-OPEN in three ways, all
# of which printed PASS: cargo tree exiting non-zero (bad lockfile, toolchain, registry),
# OUT_DIR missing so `cd` fails, and stderr discarded so nobody sees why. An infrastructure
# failure was indistinguishable from a clean dependency graph, in the check that certifies
# the distro's central property.
#
# Three outcomes now, not two: CLEAN / FOUND / CANNOT-VERIFY. The third is fatal — an
# unverifiable egress claim is not a passing one.
#
# --target all: cargo tree defaults to the HOST triple only, and Cargo.toml already carries
# a [target.'cfg(unix)'.dependencies] section — so a target-conditional HTTP client would be
# invisible when exporting from macOS while still compiling into a Windows build.
echo "      [6c] Checking cargo tree for ureq …"
TREE_OUT="$(cd "${OUT_DIR}" && cargo tree --target all 2>&1)"; TREE_RC=$?
if [[ ${TREE_RC} -ne 0 ]]; then
    echo "FATAL: cannot verify — 'cargo tree --target all' failed (rc=${TREE_RC}):" >&2
    echo "${TREE_OUT}" | tail -20 >&2
    exit 1
fi
TREE_UREQ="$(printf '%s\n' "${TREE_OUT}" | grep -i ureq || true)"
if [[ -n "${TREE_UREQ}" ]]; then
    echo "FATAL: ureq found in cargo tree:" >&2
    echo "${TREE_UREQ}" >&2
    exit 1
fi
echo "      PASS — ureq not present in dependency tree (all targets)"

# 6d. cargo build --features enterprise succeeds.
# This step proves the enterprise feature set COMPILES. It is 6b that a customer actually runs
# (the export rewrites `default = ["enterprise"]`), and 6e below is what proves the egress
# guard ran during it. 6c covers the dependency graph independently.
echo "      [6d] Running cargo build --release --features enterprise …"
(cd "${OUT_DIR}" && cargo build --release --features enterprise 2>&1)
echo "      PASS — enterprise feature set compiles"

# 6e. The build-time egress guard must be OBSERVED to have run during 6b.
#
# Until 2026-07-24 the guard was unreachable in every configuration this project builds — it
# returned early unless the `telemetry` feature was ACTIVE, which the export deletes — and
# three artifacts nonetheless reported that it had passed. The fix gates the scan on whether
# telemetry is DECLARED, so it now runs here. This step exists so that claim is checked rather
# than asserted: build.rs prints its decision, and the export reads it back.
#
# Note on what this step is NOT. The obvious check — append a `[[package]] name = "ureq"` entry
# to the exported Cargo.lock and expect the build to refuse — cannot work, and was measured not
# to: Cargo PRUNES an extraneous lock entry during resolution, before any build script runs
# (verified 2026-07-24, ureq present before `cargo metadata`, gone after). The guard only ever
# sees the resolved graph, which is the only case that matters, but it also means an injected
# entry proves nothing either way. Hence an announcement, not an injection.
echo "      [6e] Confirming build.rs's egress guard actually ran …"
if [[ ! -s "${BUILD_LOG}" ]]; then
    echo "FATAL: cannot verify — the 6b build log is missing or empty." >&2
    exit 1
fi
if grep -q 'EGRESS GUARD: SKIPPED' "${BUILD_LOG}"; then
    echo "FATAL: the egress guard SKIPPED its scan during the release build." >&2
    grep 'EGRESS GUARD' "${BUILD_LOG}" >&2
    echo "       The exported Cargo.toml still declares a 'telemetry' feature — step 2c did" >&2
    echo "       not remove it, so the guard treats this tree as the dev fork." >&2
    exit 1
fi
if ! grep -q 'EGRESS GUARD: PASSED' "${BUILD_LOG}"; then
    echo "FATAL: cannot verify — the release build produced no 'EGRESS GUARD' verdict." >&2
    echo "       Either build.rs no longer announces its decision, or" >&2
    echo "       check_enterprise_egress() returned before reaching the scan (is 'enterprise'" >&2
    echo "       still in the manifest's default feature set?)." >&2
    exit 1
fi
echo "      PASS — egress guard ran and passed during the release build:"
grep 'EGRESS GUARD' "${BUILD_LOG}" | sed 's/^warning: /        /' | head -3

# ── Step 5: Orphan git commit ────────────────────────────────────────────────

echo ""
echo "[7/8] Initializing orphan git repository …"

SHORT_SHA="$(git -C "${REPO_ROOT}" rev-parse --short "${SOURCE_REF}")"

git -C "${OUT_DIR}" init -q
git -C "${OUT_DIR}" add -A
git -C "${OUT_DIR}" commit -q -m "RTK enterprise hardened build — exported from ${SHORT_SHA}"

COMMIT_SHA="$(git -C "${OUT_DIR}" rev-parse HEAD)"
echo "      Orphan commit created: ${COMMIT_SHA}"
echo "      (no remote configured — this repo is local-only)"

# ── Step 6: Summary ───────────────────────────────────────────────────────────

echo ""
echo "[8/8] Export complete."
echo ""
echo "┌─────────────────────────────────────────────────────────────────────┐"
echo "│  RTK Enterprise Export Summary                                      │"
echo "├─────────────────────────────────────────────────────────────────────┤"
printf "│  Source ref        : %-48s │\n" "${SOURCE_REF} (${SHORT_SHA})"
printf "│  Output directory  : %-48s │\n" "${OUT_DIR}"
printf "│  Orphan commit     : %-48s │\n" "${COMMIT_SHA}"
echo "├─────────────────────────────────────────────────────────────────────┤"
printf "│  Whole files deleted     : %-41s │\n" "${#DELETED_FILES[@]}"
echo "│  Attribute-gated items   : (see stripper output above)              │"
echo "├─────────────────────────────────────────────────────────────────────┤"
echo "│  Verification                                                        │"
# These labels describe what the steps above actually did. "all files under src/" survived here
# for months after 6a's scope was still src/-only — and then stayed wrong in the other
# direction after 6a was widened. A summary is the last thing anyone reads and the first thing
# that goes stale, so it names the real domain and does not claim the egress guard ran.
echo "│    residual scan (whole shipped tree)     : PASS (empty)            │"
echo "│    cargo build --release                  : PASS                    │"
echo "│    cargo tree --target all | grep ureq    : PASS (empty)            │"
echo "│    cargo build --features enterprise      : PASS (compiles only)    │"
echo "│    build.rs egress guard observed to run  : PASS                    │"
echo "└─────────────────────────────────────────────────────────────────────┘"
