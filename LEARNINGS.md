# Nemonic MIP-201W macOS Driver: Developer Notes & Learnings

Read **[docs/technical/developer-guide.md](./docs/technical/developer-guide.md)** first for the current CUPS/PDF pipeline, correct crop math, and debugging checklist. This file keeps **hardware/protocol** facts and **historical** notes that are easy to misremember.

---

## 1. Hardware & Protocol Realities
* **Resolution**: 203 DPI (8 dots per mm).
* **Print Head Width**: 576 dots (exactly 80mm).
* **Protocol**: It uses standard ESC/POS (`GS v 0` raster bit image) but requires specific wrapper bytes:
  * **Header**: `0x02` (STX), `0x1B 0x40` (Init), `0x1D 0x76 0x30 0x00` (Print Raster) + `WidthL WidthH HeightL HeightH`.
  * **Footer**: `0x1B 0x43 0x01`, `0x1B 0x6C 0x00`, `0x1B 0x50`, `0x1B 0x69` (Cut), `0x03` (ETX).
* **NO HARDWARE MIRRORING**: A raw byte test proved that the printer does **not** mirror the X-axis natively. Byte 0, Bit 7 (the MSB) prints on the absolute left-hand side of the paper (non-sticky edge). Byte 71, Bit 0 prints on the absolute right-hand side of the paper.
* **The "Sideways" Concept**: The physical roll feeds out with the sticky adhesive running continuously along the **RIGHT edge**. Because users hold the note with the sticky edge on the right/top, they want to read the text running *along the length of the roll*. Therefore, **ALL text must be rotated 90 degrees Clockwise** relative to the print head so that it prints Top-to-Bottom.

---

## 2. Plain text, `cgtexttopdf`, and app PDFs (historical + current)

* **Terminal / `lpr` on raw text:** macOS often routes through **`cgtexttopdf`**. For sticky media that filter can place glyphs in awkward relation to the page box; the driver’s auto-crop then sees little or no ink. The **fun_scripts** path builds PDF/PNG another way to avoid that sandbox/font pipeline.
* **BBEdit and most GUI apps:** Do **not** send raw text to the filter — they spool **`application/pdf`**. Jobs often include **`ColorModel=Gray`** in the options. Two separate issues caused “blank” output in production:
  1. **Raster:** Drawing some Quartz PDFs **only** into **DeviceGray** can yield an empty first pass; the fix is **DeviceRGB → flatten to gray** (see developer guide).
  2. **Crop:** **`CGImage.cropping(to:)`** uses Quartz **bottom-left** coordinates; buffer **row 0 is the bottom** of the bitmap. Applying an extra Y “flip” for crop moved the rectangle into **white margins** on **US Letter–sized** pages while body copy sat lower on the sheet — physically blank output. Correct crop uses **`y: minY`** in buffer row space (after padding/clamp), not an inverted formula.

---

## 3. CoreGraphics: one coordinate system at a time

Y-flips, `scaleBy(y: -1)`, and “invert crop Y” snippets are **context-specific**. A recipe that fixes one stage can break another. When changing rotation or crop:

1. Re-run **`bash run_print_gates.sh`** and **`bash preflight_pdf.sh`** on a **Letter-sized** PDF exported from BBEdit (or `cupsfilter` with `-o ColorModel=Gray`), not only the small built-in test PDF.
2. Use **`NEMONIC_DEBUG_DIR`** and inspect **`rendered`**, **`cropped`**, and **`final-raster`** PNGs when ink disappears.

---

## 4. Sticky Edge Margins

The print head is exactly 576 dots (80mm) wide. If you scale text to exactly 576 dots, the top of the letters will print directly onto the sticky adhesive and get clipped by the mechanical edge of the printer. 
* Always restrict `printableWidth` to **~540 dots**, leaving ~36 dots (~4.5mm) of pure white space on the right-hand (sticky) edge.
