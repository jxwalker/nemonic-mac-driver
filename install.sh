#!/bin/bash
set -e

echo "Nemonic MIP-201W Native macOS Driver Installer"
echo "=============================================="

if [ "$EUID" -ne 0 ]; then
  echo "Please run this script with sudo:"
  echo "sudo ./install.sh"
  exit 1
fi

echo "1. Compiling Swift driver (Apple Silicon Native)..."
swiftc pdftonemonic.swift -o pdftonemonic -O

echo "2. Installing CUPS filter to /Library/Printers/Nemonic..."
mkdir -p /Library/Printers/Nemonic
cp pdftonemonic /Library/Printers/Nemonic/
chmod 755 /Library/Printers/Nemonic/pdftonemonic

echo "3. Installing PPD to /Library/Printers/PPDs/Contents/Resources..."
gzip -c Nemonic_MIP_201.ppd > /Library/Printers/PPDs/Contents/Resources/Nemonic_MIP_201.ppd.gz
chmod 644 /Library/Printers/PPDs/Contents/Resources/Nemonic_MIP_201.ppd.gz

echo "4. Restarting CUPS daemon..."
killall -HUP cupsd || true
sleep 2

echo "5. Looking for connected Nemonic printer via USB..."
URI=$(lpinfo -v 2>/dev/null | grep -i "nemonic" | grep "usb://" | awk '{print $2}' | head -n 1)

if [ -n "$URI" ]; then
    echo "Found printer at $URI"
    echo "Adding printer queue 'Nemonic_MIP_201'..."
    lpadmin -p "Nemonic_MIP_201" -v "$URI" -P "/Library/Printers/PPDs/Contents/Resources/Nemonic_MIP_201.ppd.gz" -E
    echo "Printer added successfully! You can now print to 'Nemonic_MIP_201'."
else
    echo "Printer not found via USB. Please ensure it is plugged in and turned on."
    echo "You can add it manually in System Settings -> Printers & Scanners."
    echo "Select 'nemonic MIP-201' and macOS will automatically use the installed native driver."
fi

echo ""
echo "Installation complete! Enjoy your Rosetta-free printer."
