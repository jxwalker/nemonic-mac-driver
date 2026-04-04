#!/usr/bin/env bash
# preflight_pdf.sh — NO paper. Build raster from PDF, check size + ink, write PNG for visual OK.
#
# Usage:
#   bash preflight_pdf.sh                    # repo canonical test PDF
#   bash preflight_pdf.sh /path/to/job.pdf   # your file (what you would print)
#   bash preflight_pdf.sh --open my.pdf      # also open PNG in Preview
#
# Tuning (optional env):
#   MIN_INK_DOTS=800     default 500 — refuse if fewer black dots than this
#   MIN_BIN_BYTES=20000 default 12000 — refuse if ESC/POS stream too small
#
# Exit: 0 = looks printable, 1 = do not send to printer yet
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

MIN_INK_DOTS="${MIN_INK_DOTS:-500}"
MIN_BIN_BYTES="${MIN_BIN_BYTES:-12000}"
OPEN_PREVIEW=0
PDF_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --open) OPEN_PREVIEW=1; shift ;;
    --min-ink) MIN_INK_DOTS="$2"; shift 2 ;;
    --min-bytes) MIN_BIN_BYTES="$2"; shift 2 ;;
    -h|--help)
      head -18 "$0" | tail -17
      exit 0
      ;;
    *)
      PDF_ARG="$1"
      shift
      ;;
  esac
done

FILTER_SRC="$REPO/pdftonemonic.swift"
VIZ="$REPO/visualize.swift"
TEST_PDF="$TMP/input.pdf"
TEST_BIN="$TMP/out.bin"
PNG_OUT="${NEMONIC_PREFLIGHT_PNG:-/tmp/nemonic_preflight.png}"

if [[ -n "$PDF_ARG" ]]; then
  if [[ ! -f "$PDF_ARG" ]]; then
    echo "preflight: not a file: $PDF_ARG"
    exit 1
  fi
  TEST_PDF="$PDF_ARG"
else
  echo "preflight: no PDF arg — using canonical repo test PDF"
  swift "$REPO/make_test_pdf.swift" "$TEST_PDF"
fi

echo "preflight: PDF → $TEST_PDF ($(wc -c <"$TEST_PDF" | tr -d ' ') bytes)"

COMPILE_LOG="$TMP/compile.log"
if ! swiftc "$FILTER_SRC" -o "$TMP/pdftonemonic" 2>"$COMPILE_LOG"; then
  echo "preflight: compile failed"
  cat "$COMPILE_LOG"
  exit 1
fi

FILT_LOG="$TMP/filter.log"
if ! "$TMP/pdftonemonic" 1 preflight user 1 "" "$TEST_PDF" >"$TEST_BIN" 2>"$FILT_LOG"; then
  echo "preflight: filter exited non-zero"
  cat "$FILT_LOG"
  exit 1
fi

BIN_BYTES=$(wc -c <"$TEST_BIN" | tr -d ' ')
if [[ "$BIN_BYTES" -lt "$MIN_BIN_BYTES" ]]; then
  echo "preflight: FAIL — binary only $BIN_BYTES bytes (min $MIN_BIN_BYTES). Do not print."
  [[ -s "$FILT_LOG" ]] && cat "$FILT_LOG"
  exit 1
fi

VIZ_LOG="$TMP/viz.txt"
if ! swift "$VIZ" "$TEST_BIN" "$PNG_OUT" >"$VIZ_LOG" 2>&1; then
  echo "preflight: visualize failed"
  cat "$VIZ_LOG"
  exit 1
fi

INK_LINE=$(grep -E '[[:space:]]*Ink[[:space:]]*:' "$VIZ_LOG" | head -1 || true)
if [[ -z "$INK_LINE" ]]; then
  echo "preflight: FAIL — could not parse ink from visualizer"
  cat "$VIZ_LOG"
  exit 1
fi

INK=$(echo "$INK_LINE" | sed -E 's/.*Ink[[:space:]]*:[[:space:]]*([0-9]+).*/\1/')
if [[ -z "$INK" || ! "$INK" =~ ^[0-9]+$ ]]; then
  echo "preflight: FAIL — bad ink parse: $INK_LINE"
  exit 1
fi

echo "preflight: ESC/POS $BIN_BYTES bytes | $INK_LINE"
echo "preflight: PNG → $PNG_OUT  (⌘L in Preview to see note upright)"

if [[ "$INK" -lt "$MIN_INK_DOTS" ]]; then
  echo "preflight: FAIL — only $INK black dots (min $MIN_INK_DOTS). Likely blank on paper. Do not print."
  exit 1
fi

echo "preflight: PASS — safe to try a physical print if the PNG looks right."
if [[ "$OPEN_PREVIEW" -eq 1 ]]; then
  open "$PNG_OUT" 2>/dev/null || true
fi
exit 0
