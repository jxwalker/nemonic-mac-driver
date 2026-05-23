#!/bin/bash
set -e

echo "Nemonic Dual-Queue Setup (Receipt + Sticky)"
echo "============================================"

if [ "$EUID" -ne 0 ]; then
  echo "Please run with sudo:"
  echo "sudo ./setup_custom_queues.sh"
  exit 1
fi

PPD="/Library/Printers/PPDs/Contents/Resources/Nemonic_MIP_201.ppd.gz"
DEVICE="usb://nemonic/MIP-201?serial=NAWKISG43000373"

echo "1. Removing any existing custom queues..."
lpadmin -x Nemonic_Receipt 2>/dev/null || true
lpadmin -x Nemonic_Sticky 2>/dev/null || true

echo "2. Creating Nemonic_Receipt (upright portrait)..."
lpadmin -p Nemonic_Receipt -v "$DEVICE" -P "$PPD" -E \
        -o printer-is-shared=false \
        -o printer-location="Receipt mode - upright, non-rotated printing" \
        -o printer-info="Nemonic Receipt (Portrait)"

lpadmin -p Nemonic_Receipt -o NemonicMode=Receipt
lpadmin -p Nemonic_Receipt -o PageSize=80x136mm.Fullbleed

echo "3. Creating Nemonic_Sticky (sideways for notes)..."
lpadmin -p Nemonic_Sticky -v "$DEVICE" -P "$PPD" -E \
        -o printer-is-shared=false \
        -o printer-location="Sticky notes - rotated for adhesive edge" \
        -o printer-info="Nemonic Sticky (Landscape)"

lpadmin -p Nemonic_Sticky -o NemonicMode=Sticky
lpadmin -p Nemonic_Sticky -o PageSize=80x80mm.Fullbleed

echo ""
echo "4. Current settings:"
lpoptions -p Nemonic_Receipt
lpoptions -p Nemonic_Sticky

echo ""
echo "Done."
echo "Print to 'Nemonic_Receipt' for normal upright receipts."
echo "Print to 'Nemonic_Sticky' for sideways sticky notes."
echo ""
echo "The driver now defaults to Receipt and uses the queue name as a strong hint,"
echo "so Word should work reliably with the Receipt queue even if the PPD option is quirky."
