# Nemonic MIP-201W Native macOS Driver

A 100% native Apple Silicon (arm64) macOS driver for the Mangoslab Nemonic MIP-201W sticky note printer.

## Why this exists
The official driver provided by Mangoslab relies on an older Intel (`x86_64`) binary filter (`rastertonemonic`). On modern Apple Silicon Macs (M1/M2/M3/M4), this forces users to install Apple's Rosetta 2 translation layer. Additionally, the official driver has hardcoded paths that conflict with the strict CUPS sandbox introduced in recent versions of macOS, causing printing to fail silently.

This project completely reverse-engineers the printer's proprietary USB protocol and provides a native, Rosetta-free CUPS driver written entirely in Swift.

## Features
* **100% Native Apple Silicon support**: No Rosetta required.
* **Bypasses `cgpdftoraster`**: Directly reads PDF print jobs and natively rasterizes them using Apple's highly-optimized CoreGraphics engine.
* **Orientation Auto-Fix**: Automatically rotates the print feed 90 degrees and corrects the mirror-image hardware bug so that text runs top-to-bottom natively, aligned perfectly with the paper's right-hand sticky edge.
* **Prints Anything**: Accurately reproduces system fonts, vector graphics, shapes, barcodes, and logos.

## Installation

1. Clone or download this repository.
2. Open Terminal and navigate to the directory.
3. Run the installer script with `sudo`:

```bash
sudo ./install.sh
```

The script will:
* Compile the Swift driver into a native binary.
* Install the binary to the correct CUPS `/Library/Printers/Nemonic/` path.
* Install the patched PostScript Printer Description (PPD) file.
* Automatically detect your printer via USB and add it to your system.

## Uninstallation

To completely remove the driver and printer queue from your system:

```bash
sudo ./uninstall.sh
```

## How it works (Protocol Technicals)
The printer accepts a slight variation of the standard ESC/POS protocol (`GS v 0`) wrapped in specific start/end bytes:
1. **Header**: `STX (0x02)`, `ESC @` (Initialize)
2. **Image Header**: `GS v 0 0` + `WidthBytes(72)` + `HeightDots`
3. **Data**: Raw 1-bit monochrome pixel array (1 = black/burn, 0 = white)
4. **Footer**: `ESC C 1`, `ESC l 0`, `ESC P`, `ESC i` (Partial Cut), `ETX (0x03)`

## License
MIT License. Feel free to fork, modify, and improve.
