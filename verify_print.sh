#!/usr/bin/env bash
# Quick check: installed filter exists, is non-trivial, and repo test PDF yields raster bytes.
set -euo pipefail
REPO="$(cd "$(dirname "$0")" && pwd)"
BIN="/Library/Printers/Nemonic/pdftonemonic"
echo "== Installed filter =="
if [[ ! -x "$BIN" ]]; then
  echo "MISSING: $BIN — run sudo ./install.sh"
  exit 1
fi
ls -la "$BIN"
echo ""
echo "== Repo self-test (no printer needed) =="
exec bash "$REPO/test.sh"
