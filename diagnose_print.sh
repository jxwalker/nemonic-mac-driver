#!/usr/bin/env bash
# Controlled diagnosis: proves whether the INSTALLED filter matches a FRESH BUILD and emits non-trivial raster.
# Run: bash diagnose_print.sh   (no sudo)
# Paste the whole output if printing is still blank.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
INSTALLED="/Library/Printers/Nemonic/pdftonemonic"
# CUPS filter argv: job user title copies options file (matches test.sh / run_print_gates.sh)
CUPS_ARGS=("1" "testuser" "nemonic-diagnose" "1" "")
TMPD="$(mktemp -d)"
cleanup() { rm -rf "$TMPD"; }
trap cleanup EXIT

SDK="$(xcrun --show-sdk-path 2>/dev/null || true)"
echo "======== Nemonic print diagnosis $(date) ========"
echo "Git:    $(cd "$REPO" && git rev-parse --short HEAD) $(cd "$REPO" && git log -1 --format=%ci)"
echo "SDK:    ${SDK:-MISSING}"
echo "NEMONIC_PREVIEW_ONLY=${NEMONIC_PREVIEW_ONLY:-<unset>}"

echo ""
echo "--- Installed filter (what CUPS uses) ---"
if [[ ! -e "$INSTALLED" ]]; then
  echo "MISSING: $INSTALLED"
else
  ls -la "$INSTALLED"
  shasum -a 256 "$INSTALLED"
fi

echo ""
echo "--- Fresh build from repo (swiftc) ---"
if [[ -z "$SDK" || ! -d "$SDK" ]]; then
  echo "SKIP compile: no SDK"
  FRESH_B=""
else
  FRESH_B="$TMPD/pdftonemonic.build"
  swiftc -sdk "$SDK" "$REPO/pdftonemonic.swift" -o "$FRESH_B" -O
  ls -la "$FRESH_B"
  shasum -a 256 "$FRESH_B"
fi

echo ""
echo "--- Raster byte count (canonical test PDF) ---"
PDF="$TMPD/t.pdf"
swift "$REPO/make_test_pdf.swift" "$PDF"
if [[ -n "${FRESH_B:-}" ]]; then
  BYTES_F=$("$FRESH_B" "${CUPS_ARGS[@]}" "$PDF" < /dev/null | wc -c | tr -d ' ')
  echo "Fresh build stdout: $BYTES_F bytes"
fi
if [[ -x "$INSTALLED" ]]; then
  BYTES_I=$("$INSTALLED" "${CUPS_ARGS[@]}" "$PDF" < /dev/null | wc -c | tr -d ' ')
  echo "Installed stdout:   $BYTES_I bytes"
fi

echo ""
echo "--- CUPS queue ---"
lpstat -p 2>/dev/null | grep -i nemonic || echo "(no queue name matched 'nemonic')"
lpstat -v 2>/dev/null | grep -i nemonic || true

echo ""
if [[ -n "${FRESH_B:-}" && -x "$INSTALLED" ]]; then
  if cmp -s "$FRESH_B" "$INSTALLED"; then
    echo "RESULT: Installed binary is byte-identical to fresh build."
  else
    echo "RESULT: Binaries differ on disk (timestamps/paths); compare test output above."
    if [[ -n "${BYTES_F:-}" && -n "${BYTES_I:-}" && "$BYTES_F" == "$BYTES_I" ]]; then
      echo "RESULT: Same raster byte count from fresh + installed for test PDF — filter behaviour likely matches."
    else
      echo "RESULT: *** Run: sudo ./install.sh from latest main ***"
    fi
  fi
fi
if [[ -n "${BYTES_I:-}" && "${BYTES_I:-0}" -lt 15000 ]]; then
  echo "RESULT: *** Installed filter output too small ($BYTES_I) — expect ~30k+ for test PDF."
fi
echo "======== end ========"
