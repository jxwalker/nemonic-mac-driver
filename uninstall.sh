#!/bin/bash
set -e

echo "Nemonic MIP-201W Driver Uninstaller"
echo "==================================="

if [ "$EUID" -ne 0 ]; then
  echo "Please run this script with sudo:"
  echo "sudo ./uninstall.sh"
  exit 1
fi

echo "1. Removing printer queue..."
lpadmin -x "Nemonic_MIP_201" 2>/dev/null || true

echo "2. Removing CUPS filter..."
rm -f /Library/Printers/Nemonic/pdftonemonic

echo "3. Removing PPD file..."
rm -f /Library/Printers/PPDs/Contents/Resources/Nemonic_MIP_201.ppd.gz

echo "4. Restarting CUPS daemon..."
killall -HUP cupsd || true

echo "Uninstallation complete."
