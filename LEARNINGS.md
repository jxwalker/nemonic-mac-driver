# Nemonic MIP-201W macOS Driver: Developer Notes & Learnings

This document serves as a "brain dump" for future development on the native macOS Apple Silicon driver for the Mangoslab Nemonic MIP-201W printer. We went through extensive trial and error to decode the hardware behavior, macOS CUPS quirks, and CoreGraphics matrix math. 

Read this before attempting to fix rotation, mirroring, or auto-crop bugs!

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

## 2. The Bash Script "Blank Page" Bug (`cgtexttopdf`)
* **The Symptom**: Printing a plain text file (or piping text) from the terminal via `lpr` prints a massive, blank sheet of paper. However, printing a PDF from BBEdit works perfectly.
* **The Cause**: macOS CUPS uses a hidden filter called `cgtexttopdf` to handle raw text. When `cgtexttopdf` formats text for the `80x80mm.Fullbleed` page size defined in our PPD, it places the text entirely outside the visible `mediaBox` (or at the absolute bottom margin). 
* **The Result**: The driver's `Auto-Crop` scanner looks for black pixels, finds none (because they were clipped out of bounds by Apple's filter), falls back to scanning the entire 80x80mm white page, scales it up, and prints a foot-long blank sticky note.
* **The Fix**: We bypassed `cgtexttopdf` entirely by creating a native Swift CLI tool (`texttopng.swift`) that converts terminal text into a high-res PNG *before* sending it to `lpr`.

---

## 3. CoreGraphics Matrix Hell (The "Upside Down & Mirrored" Bug)
The most difficult part of writing this driver was extracting the bounding box of the text and drawing it rotated without accidentally mirroring it.

* **Y-UP vs Y-DOWN**: A raw memory-backed `CGContext` is naturally Y-UP (origin at Bottom-Left). If you render a PDF into it, the image is physically stored Top-Down visually, meaning `y=0` in the array is the bottom of the page.
* **The Crop Bug**: `CGImage.cropping(to:)` natively expects a Y-DOWN (`Top-Left` origin) rectangle. If you calculate `minY` and `maxY` by scanning a Y-UP array, passing those coordinates to the crop function will literally flip the crop box upside-down. If your text is at the top of the page, the crop box will extract empty white space at the bottom!
* **The Draw Bug**: If you flip a `CGContext` to be Y-DOWN (`scaleBy(x: 1.0, y: -1.0)`) and then call `CGContext.draw(cgImage)`, CoreGraphics will draw the image **upside down**. An upside-down image rotated 90 degrees geometrically behaves like a **180-degree rotation + a mirror flip**. This is why the user kept seeing "upside down and mirrored" output when we tried to rotate it.

---

## 4. The Blueprint for the Perfect Driver
To successfully finish the driver, the pipeline **must** strictly adhere to this flow without mixing Apple's coordinate flips:

1. **Pass 1 (Render)**: Use `page.getDrawingTransform` to render the PDF perfectly upright into a standard Y-UP `CGContext`. 
2. **Pass 2 (Crop)**: Scan the memory array for the text bounds. Since the array is Y-UP, `maxY` is the visual top of the text. Calculate the crop rect for `CGImage.cropping` by inverting the Y-axis mathematically (`cropY = testHeight - 1 - maxY`).
3. **Pass 3 (Layout)**: Create a `finalContext` (Y-UP). Translate to the center. **Do not use `scale(y: -1)`**. Rotate exactly `-CGFloat.pi / 2.0` (which is 90 degrees Clockwise in a Y-UP system). Draw the cropped image.
4. **Pass 4 (Byte Packing)**: Because the `finalContext` is Y-UP, Row 0 in the memory array is the *bottom* of the visual image. To ensure the printer prints the top of the text first (so it doesn't get chopped off by the cutting blade), **read the `finalData` array backwards** (`visualY = height - 1 - y`). Do NOT flip the X-axis in software.

---

## 5. Sticky Edge Margins
The print head is exactly 576 dots (80mm) wide. If you scale text to exactly 576 dots, the top of the letters will print directly onto the sticky adhesive and get clipped by the mechanical edge of the printer. 
* Always restrict `printableWidth` to **~540 dots**, leaving 36 dots (~4.5mm) of pure white space on the right-hand (sticky) edge.
