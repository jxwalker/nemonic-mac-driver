#!/usr/bin/env bash
# Mandatory gates before wasting paper. Stops at first failure.
# Usage: bash run_print_gates.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
MIN_OUT="${MIN_ESC_POS_BYTES:-15000}"
MIN_INK="${MIN_INK_DOTS:-400}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SDK="$(xcrun --show-sdk-path 2>/dev/null || true)"
BIN="$TMP/pdftonemonic.bin"
# CUPS filter argv: job user title copies options file
CUPS_ARGS=("1" "testuser" "nemonic-gate" "1" "")
PDF="$TMP/canon.pdf"
OUT="$TMP/out.bin"
VIZ="$TMP/viz.txt"

pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; exit 1; }

echo "=== Gate 0: preview-only env must be unset for real print ==="
if [[ "${NEMONIC_PREVIEW_ONLY:-}" =~ ^(1|true|yes)$ ]]; then
  fail "NEMONIC_PREVIEW_ONLY is set — filter sends zero bytes to printer."
fi
pass "NEMONIC_PREVIEW_ONLY not set"

echo ""
echo "=== Gate 1: compile pdftonemonic.swift ==="
[[ -n "$SDK" && -d "$SDK" ]] || fail "No SDK (xcode-select --install)"
swiftc -sdk "$SDK" "$REPO/pdftonemonic.swift" -o "$BIN" -O
[[ $(wc -c <"$BIN" | tr -d ' ') -ge 10000 ]] || fail "binary too small"
pass "compiled"

echo ""
echo "=== Gate 2: job file path + stdin closed (terminal-safe) ==="
swift "$REPO/make_test_pdf.swift" "$PDF"
"$BIN" "${CUPS_ARGS[@]}" "$PDF" < /dev/null >"$OUT"
BYTES=$(wc -c <"$OUT" | tr -d ' ')
[[ "$BYTES" -ge "$MIN_OUT" ]] || fail "ESC/POS only $BYTES bytes (min $MIN_OUT)"
pass "$BYTES bytes (file + /dev/null stdin)"

echo ""
echo "=== Gate 3: stdin pipe (CUPS-like), argv[6] is '-' ==="
BYTES2=$(cat "$PDF" | "$BIN" "${CUPS_ARGS[@]}" "-" | wc -c | tr -d ' ')
[[ "$BYTES2" -ge "$MIN_OUT" ]] || fail "stdin path only $BYTES2 bytes"
pass "$BYTES2 bytes (stdin pipe)"

echo ""
echo "=== Gate 4: visualize → ink dots ==="
swift "$REPO/visualize.swift" "$OUT" "$TMP/p.png" >"$VIZ" 2>&1
INK=$(grep -E '[[:space:]]*Ink[[:space:]]*:' "$VIZ" | head -1 | sed -E 's/.*Ink[[:space:]]*:[[:space:]]*([0-9]+).*/\1/')
[[ -n "$INK" && "$INK" -ge "$MIN_INK" ]] || fail "ink=$INK (min $MIN_INK). Log: $VIZ"
pass "$INK black dots"

echo ""
echo "=== Gate 5 (optional): installed filter ==="
INS="/Library/Printers/Nemonic/pdftonemonic"
if [[ -x "$INS" ]]; then
  BI=$("$INS" "${CUPS_ARGS[@]}" "$PDF" < /dev/null | wc -c | tr -d ' ')
  [[ "$BI" -ge "$MIN_OUT" ]] || fail "installed binary only $BI bytes — run sudo ./install.sh"
  pass "installed $BI bytes"
else
  echo "  SKIP: no $INS"
fi

echo ""
echo "=== All gates passed. Preflight your real PDF, then install if Gate 5 skipped or failed before. ==="
echo "    bash preflight_pdf.sh --open /path/to/your.pdf"
