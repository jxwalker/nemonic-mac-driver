#!/bin/bash
# test.sh — Nemonic Driver Test Harness
#
# Compiles pdftonemonic.swift WITHOUT installing it, runs it on the canonical
# test PDF, and produces a visual PNG preview so you can verify correctness
# before touching the printer.
#
# Run from the repo root:
#   bash test.sh
#
# Or point at an existing PDF to test a real document:
#   bash test.sh /path/to/document.pdf

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="/tmp/nemonic_test_$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT   # clean up on exit (remove this line to inspect binaries)

FILTER="$REPO/pdftonemonic.swift"
VIZ="$REPO/visualize.swift"
MKTPDF="$REPO/make_test_pdf.swift"

INPUT_PDF="${1:-}"          # optional: pass your own PDF as $1
TEST_PDF="$TMP/test_input.pdf"
TEST_BIN="$TMP/test_output.bin"
TEST_PNG="${TMPDIR:-/tmp}/nemonic_preview.png"  # keep PNG after EXIT trap

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║   Nemonic Driver Test Harness            ║"
echo "╚══════════════════════════════════════════╝"

# ── Step 1: Test PDF ──────────────────────────────────────────────────────────
if [ -n "$INPUT_PDF" ]; then
    TEST_PDF="$INPUT_PDF"
    echo ""
    echo "[1/4] Using provided PDF: $INPUT_PDF"
else
    echo ""
    echo "[1/4] Generating canonical test PDF..."
    if ! swift "$MKTPDF" "$TEST_PDF" 2>&1; then
        echo "✗ FAIL: Could not generate test PDF"; exit 1
    fi
fi

# ── Step 2: Compile ──────────────────────────────────────────────────────────
echo ""
echo "[2/4] Compiling filter (no install)..."
COMPILE_LOG="$TMP/compile.log"
if ! swiftc "$FILTER" -o "$TMP/pdftonemonic" 2>"$COMPILE_LOG"; then
    echo "✗ FAIL: Compilation failed"
    echo "────────────────────────────────────────"
    cat "$COMPILE_LOG"
    echo "────────────────────────────────────────"
    exit 1
fi
BINARY_KB=$(( $(stat -f%z "$TMP/pdftonemonic" 2>/dev/null || stat -c%s "$TMP/pdftonemonic") / 1024 ))
echo "      ✓ Compiled  (${BINARY_KB}KB)"

# ── Step 3: Run filter ────────────────────────────────────────────────────────
# The CUPS filter signature is:  filter job user title copies options [file]
# We pass a real filename as arg 6 (index 6 in Swift's args[]).
echo ""
echo "[3/4] Running filter..."
FILTER_LOG="$TMP/filter.log"
if ! "$TMP/pdftonemonic" "1" "testuser" "nemonic-test" "1" "" "$TEST_PDF" \
        < /dev/null > "$TEST_BIN" 2>"$FILTER_LOG"; then
    echo "✗ FAIL: Filter crashed"
    echo "────────────────────────────────────────"
    cat "$FILTER_LOG"
    echo "────────────────────────────────────────"
    exit 1
fi

BIN_BYTES=$(stat -f%z "$TEST_BIN" 2>/dev/null || stat -c%s "$TEST_BIN")
if [ "$BIN_BYTES" -eq 0 ]; then
    echo "✗ FAIL: Filter produced empty output (0 bytes)"
    exit 1
fi
echo "      ✓ Output: ${BIN_BYTES} bytes"

if [ -s "$FILTER_LOG" ]; then
    echo "      [filter stderr]:"
    sed 's/^/        /' "$FILTER_LOG"
fi

# ── Step 4: Visualize ─────────────────────────────────────────────────────────
echo ""
echo "[4/4] Rendering preview PNG..."
if ! swift "$VIZ" "$TEST_BIN" "$TEST_PNG" 2>&1; then
    echo "✗ FAIL: Visualizer failed"; exit 1
fi

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║   PREVIEW: $TEST_PNG"
echo "╠══════════════════════════════════════════╣"
echo "║                                           ║"
echo "║   SUCCESS CRITERIA                        ║"
echo "║   ─────────────────────────────────────   ║"
echo "║                                           ║"
echo "║   1. Open the PNG (opening now...)        ║"
echo "║   2. Press ⌘L  (Rotate Left / 90° CCW)   ║"
echo "║   3. After rotation, verify ALL of:       ║"
echo "║                                           ║"
echo "║   ✓ 'NEMONIC TEST' reads left-to-right    ║"
echo "║     and is NOT mirrored                   ║"
echo "║   ✓ '▲ READING TOP' is near the TOP       ║"
echo "║   ✓ '▼ READING BOTTOM' is near the BOTTOM ║"
echo "║   ✓ '╔ TOP-LEFT' is in the top-left       ║"
echo "║   ✓ 'BOT-RIGHT ╝' is in the bottom-right  ║"
echo "║   ✓ RED (sticky) edge is now at the TOP   ║"
echo "║   ✓ Text fills most of the width          ║"
echo "║     (not tiny, not overflowing)           ║"
echo "║                                           ║"
echo "║   FAILURE MODES (look for these):         ║"
echo "║   ✗ Text upside-down after rotation       ║"
echo "║     → rotation direction is wrong         ║"
echo "║       (change rotate +π/2 to -π/2)        ║"
echo "║   ✗ Text mirrored after rotation          ║"
echo "║     → unwanted Y-flip (scaleBy y=-1)      ║"
echo "║   ✗ TOP-LEFT appears at bottom-right      ║"
echo "║     → 180° rotation (two errors cancel)   ║"
echo "║   ✗ Green edge at top after rotation      ║"
echo "║     → rotated wrong direction (CW vs CCW) ║"
echo "║   ✗ Blank PNG (zero ink)                  ║"
echo "║     → rendering/crop failure              ║"
echo "║   ✗ Tiny text (< 40% width)               ║"
echo "║     → scale cap too low or wrong axis     ║"
echo "╚══════════════════════════════════════════╝"
echo ""

(open "$TEST_PNG" 2>/dev/null || true) &
echo "(Preview: $TEST_PNG — open manually if needed)"
