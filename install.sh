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

echo "3. Patching PPD margins and installing to /Library/Printers/PPDs/Contents/Resources..."
gzip -dc Nemonic_MIP_201.ppd > /tmp/Nemonic_MIP_201.ppd

sed -i '' -e 's/^\*ImageableArea 80x28mm.*/\*ImageableArea 80x28mm.Transverse\/80 x 28 mm: "0 0 226.8 79.4"/' /tmp/Nemonic_MIP_201.ppd
sed -i '' -e 's/^\*ImageableArea 80x56mm.*/\*ImageableArea 80x56mm.Transverse\/80 x 56 mm: "0 0 226.8 158.7"/' /tmp/Nemonic_MIP_201.ppd
sed -i '' -e 's/^\*ImageableArea 80x80mm.*/\*ImageableArea 80x80mm.Fullbleed\/80 x 80 mm: "0 0 226.8 226.8"/' /tmp/Nemonic_MIP_201.ppd
sed -i '' -e 's/^\*ImageableArea 80x104mm.*/\*ImageableArea 80x104mm.Fullbleed\/80 x 104 mm: "0 0 226.8 294.8"/' /tmp/Nemonic_MIP_201.ppd
sed -i '' -e 's/^\*ImageableArea 80x136mm.*/\*ImageableArea 80x136mm.Fullbleed\/80 x 136 mm: "0 0 226.8 385.5"/' /tmp/Nemonic_MIP_201.ppd
sed -i '' -e 's/\*ParamCustomPageSize WidthOffset:  3 points 11.3 11.3/\*ParamCustomPageSize WidthOffset:  3 points 0 0/' /tmp/Nemonic_MIP_201.ppd
sed -i '' -e 's/\*ParamCustomPageSize HeightOffset: 4 points 11.3 11.3/\*ParamCustomPageSize HeightOffset: 4 points 0 0/' /tmp/Nemonic_MIP_201.ppd

gzip -c /tmp/Nemonic_MIP_201.ppd > /Library/Printers/PPDs/Contents/Resources/Nemonic_MIP_201.ppd.gz
chmod 644 /Library/Printers/PPDs/Contents/Resources/Nemonic_MIP_201.ppd.gz
rm -f /tmp/Nemonic_MIP_201.ppd

echo "4. Restarting CUPS daemon..."
killall -HUP cupsd || true
sleep 2

echo "5. Looking for connected Nemonic printer via USB..."
URI=$(lpinfo -v 2>/dev/null | grep -i "nemonic" | grep "usb://" | awk '{print $2}' | head -n 1)

if [ -n "$URI" ]; then
    echo "Found printer at $URI"
    echo "Adding printer queue 'Nemonic_MIP_201'..."
    lpadmin -p "Nemonic_MIP_201" -v "$URI" -P "/Library/Printers/PPDs/Contents/Resources/Nemonic_MIP_201.ppd.gz" -E
    lpadmin -p "Nemonic_MIP_201" -o PageSize=80x80mm.Fullbleed
    echo "Printer added successfully! You can now print to 'Nemonic_MIP_201'."
else
    echo "Printer not found via USB. Please ensure it is plugged in and turned on."
    echo "You can add it manually in System Settings -> Printers & Scanners."
    echo "Select 'nemonic MIP-201' and macOS will automatically use the installed native driver."
fi

echo ""
echo "Installation complete!"
