// visualize.swift — Nemonic ESC/POS Binary Visualizer
//
// Parses a raw Nemonic ESC/POS binary and renders an annotated PNG showing
// exactly what the printer head would burn, with edge labels.
//
// Usage:  swift visualize.swift <input.bin> <output.png>
//
// HOW TO READ THE OUTPUT PNG
// ──────────────────────────
// The PNG represents the physical print-head scan:
//   • Column 0   (LEFT,  GREEN border) = non-sticky edge of the note
//   • Column 575 (RIGHT, RED border)   = sticky/adhesive edge of the note
//   • Row 0      (TOP,   BLUE border)  = leading edge — cut here, becomes BOTTOM of note
//   • Last row   (BOTTOM)              = trailing edge (feeds last)
//
// To see the note as it will look on a monitor (sticky strip at top):
//   Press ⌘L in Preview.app (Rotate Left = 90° counter-clockwise).
//   After rotation the RED edge is at the top — that's where the note sticks.

import Foundation
import CoreGraphics
import CoreText
import ImageIO

// ── Args ──────────────────────────────────────────────────────────────────────
let args = CommandLine.arguments
guard args.count >= 3 else {
    fputs("Usage: swift visualize.swift <input.bin> <output.png>\n", stderr)
    exit(1)
}
let inputPath  = args[1]
let outputPath = args[2]

guard let raw = try? Data(contentsOf: URL(fileURLWithPath: inputPath)) else {
    fputs("Cannot read '\(inputPath)'\n", stderr); exit(1)
}
let bytes = [UInt8](raw)

// ── Find GS v 0: 1D 76 30 00 ──────────────────────────────────────────────
var gsvIdx: Int? = nil
for i in 0..<(bytes.count - 8) {
    if bytes[i] == 0x1D && bytes[i+1] == 0x76 && bytes[i+2] == 0x30 && bytes[i+3] == 0x00 {
        gsvIdx = i; break
    }
}
guard let idx = gsvIdx else {
    fputs("""
    Error: GS v 0 command (1D 76 30 00) not found.
    Hex dump (first 32 bytes): \(bytes.prefix(32).map { String(format:"%02X",$0) }.joined(separator:" "))
    Is this a valid Nemonic ESC/POS binary?\n
    """, stderr)
    exit(1)
}

let wBytes  = Int(bytes[idx+4]) | (Int(bytes[idx+5]) << 8)  // bytes per row
let pHeight = Int(bytes[idx+6]) | (Int(bytes[idx+7]) << 8)  // number of rows
let pWidth  = wBytes * 8                                      // dots per row
let bmpOff  = idx + 8

guard bmpOff + wBytes * pHeight <= bytes.count else {
    fputs("Error: truncated — need \(bmpOff + wBytes * pHeight) bytes, have \(bytes.count)\n", stderr)
    exit(1)
}

// ── Decode 1-bit → 8-bit grayscale ───────────────────────────────────────────
// gray[] is indexed Y-DOWN: row 0 = leading edge (top of printed note after peeling).
// ESC/POS: bit 7 of byte 0 = column 0 (non-sticky / left edge). 1 = black dot.
var gray      = [UInt8](repeating: 255, count: pWidth * pHeight)
var blackDots = 0
for row in 0..<pHeight {
    for xb in 0..<wBytes {
        let byte = bytes[bmpOff + row * wBytes + xb]
        for bit in 0..<8 {
            if (byte >> (7 - bit)) & 1 == 1 {
                gray[row * pWidth + xb * 8 + bit] = 0
                blackDots += 1
            }
        }
    }
}

// ── Diagnostics ──────────────────────────────────────────────────────────────
let coverage  = Double(blackDots) / Double(max(pWidth * pHeight, 1)) * 100
let widthMM   = Double(pWidth)  / 203.0 * 25.4
let heightMM  = Double(pHeight) / 203.0 * 25.4

print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
print("  Bitmap : \(pWidth) × \(pHeight) dots")
print("  Size   : \(String(format:"%.1f",widthMM)) × \(String(format:"%.1f",heightMM)) mm  @ 203 DPI")
print("  Ink    : \(blackDots) dots  (\(String(format:"%.1f",coverage))% coverage)")
if blackDots == 0 {
    print("  ⚠  WARNING: BLANK — zero black dots. Will print an empty note.")
} else if coverage < 0.1 {
    print("  ⚠  WARNING: Very low coverage — may appear nearly blank.")
}
print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

// ── Build annotated PNG ───────────────────────────────────────────────────────
// Canvas layout (CGContext is Y-UP; all Y values measured from bottom).
//
//  canvasH  ┬──────────────────────────────────────────────┐
//           │  topPad  (leading edge label)                 │
//  topEdge  ├──[BLUE BAR]─────────────────────[BLUE BAR]──┤  ← leading edge (row 0)
//           │  [GRN]        print area         [RED]        │
//  botEdge  ├──[GRAY BAR]─────────────────────[GRAY BAR]──┤  ← trailing edge
//           │  botPad  (trailing label + info)              │
//  0        └──────────────────────────────────────────────┘

let sideMargin = 75
let topPad     = 48
let botPad     = 52

let canvasW = pWidth  + sideMargin * 2
let canvasH = pHeight + topPad     + botPad

let pOriginX = sideMargin
let pOriginY = botPad        // bottom-left of print area in Y-UP space
let topEdge  = pOriginY + pHeight  // Y-UP coord of visual top of print area

let rgb = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil, width: canvasW, height: canvasH,
    bitsPerComponent: 8, bytesPerRow: canvasW * 4, space: rgb,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fputs("Cannot create canvas\n", stderr); exit(1) }

// Background: dark charcoal
ctx.setFillColor(CGColor(red: 0.18, green: 0.18, blue: 0.18, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))

// White print area
ctx.setFillColor(.white)
ctx.fill(CGRect(x: pOriginX, y: pOriginY, width: pWidth, height: pHeight))

// ── Blit decoded bitmap into print area ──────────────────────────────────────
// gray[] is Y-DOWN; CGContext is Y-UP → flip by translating to topEdge and scaling y=-1.
gray.withUnsafeMutableBytes { ptr in
    let gs = CGColorSpaceCreateDeviceGray()
    if let bCtx = CGContext(
        data: ptr.baseAddress, width: pWidth, height: pHeight,
        bitsPerComponent: 8, bytesPerRow: pWidth,
        space: gs, bitmapInfo: CGImageAlphaInfo.none.rawValue
    ), let img = bCtx.makeImage() {
        ctx.saveGState()
        ctx.translateBy(x: CGFloat(pOriginX), y: CGFloat(topEdge))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: pWidth, height: pHeight))
        ctx.restoreGState()
    }
}

// ── Edge indicator bars (4 px) ────────────────────────────────────────────────
let bw: CGFloat = 4
// TOP  (leading edge)  — blue
ctx.setFillColor(CGColor(red: 0.25, green: 0.50, blue: 1.00, alpha: 1))
ctx.fill(CGRect(x: CGFloat(pOriginX), y: CGFloat(topEdge) - bw, width: CGFloat(pWidth), height: bw))
// BOTTOM (trailing)   — mid-gray
ctx.setFillColor(CGColor(red: 0.55, green: 0.55, blue: 0.55, alpha: 1))
ctx.fill(CGRect(x: CGFloat(pOriginX), y: CGFloat(pOriginY), width: CGFloat(pWidth), height: bw))
// LEFT  (non-sticky)  — green
ctx.setFillColor(CGColor(red: 0.15, green: 0.75, blue: 0.25, alpha: 1))
ctx.fill(CGRect(x: CGFloat(pOriginX), y: CGFloat(pOriginY), width: bw, height: CGFloat(pHeight)))
// RIGHT (sticky edge) — red
ctx.setFillColor(CGColor(red: 0.90, green: 0.15, blue: 0.15, alpha: 1))
ctx.fill(CGRect(x: CGFloat(pOriginX + pWidth) - bw, y: CGFloat(pOriginY), width: bw, height: CGFloat(pHeight)))

// ── Text label helper ─────────────────────────────────────────────────────────
func drawLabel(_ text: String, at pt: CGPoint, size: CGFloat, color: CGColor, bold: Bool = false) {
    let name = (bold ? "Menlo-Bold" : "Menlo") as CFString
    let font = CTFontCreateWithName(name, size, nil)
    let cfStr = text as CFString
    let len   = CFStringGetLength(cfStr)
    let attr  = CFAttributedStringCreateMutable(kCFAllocatorDefault, 0)!
    CFAttributedStringReplaceString(attr, CFRangeMake(0, 0), cfStr)
    CFAttributedStringSetAttribute(attr, CFRangeMake(0, len), kCTFontAttributeName, font)
    CFAttributedStringSetAttribute(attr, CFRangeMake(0, len), kCTForegroundColorAttributeName, color)
    let line = CTLineCreateWithAttributedString(attr)
    ctx.saveGState()
    ctx.textMatrix = .identity
    ctx.textPosition = pt
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

func textWidth(_ text: String, size: CGFloat, bold: Bool = false) -> CGFloat {
    let name = (bold ? "Menlo-Bold" : "Menlo") as CFString
    let font = CTFontCreateWithName(name, size, nil)
    let attr  = CFAttributedStringCreateMutable(kCFAllocatorDefault, 0)!
    let cfStr = text as CFString
    CFAttributedStringReplaceString(attr, CFRangeMake(0, 0), cfStr)
    CFAttributedStringSetAttribute(attr, CFRangeMake(0, CFStringGetLength(cfStr)), kCTFontAttributeName, font)
    let line = CTLineCreateWithAttributedString(attr)
    return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
}

let white   = CGColor(red: 1,    green: 1,    blue: 1,    alpha: 1)
let lblBlue = CGColor(red: 0.40, green: 0.65, blue: 1.00, alpha: 1)
let lblRed  = CGColor(red: 1.00, green: 0.40, blue: 0.40, alpha: 1)
let lblGrn  = CGColor(red: 0.30, green: 0.90, blue: 0.40, alpha: 1)
let lblGray = CGColor(red: 0.60, green: 0.60, blue: 0.60, alpha: 1)
let lblYel  = CGColor(red: 1.00, green: 0.90, blue: 0.20, alpha: 1)
let lblOrng = CGColor(red: 1.00, green: 0.55, blue: 0.10, alpha: 1)

// ── Rotated side labels ───────────────────────────────────────────────────────
// Left side: "NON-STICKY EDGE" reads bottom-to-top (rotate +π/2 in CGContext = CCW)
let leftLabel  = "◀ NON-STICKY EDGE"
let rightLabel = "STICKY EDGE ▶"
let sideFontSz: CGFloat = 10
let leftW  = textWidth(leftLabel,  size: sideFontSz)
let rightW = textWidth(rightLabel, size: sideFontSz)

ctx.saveGState()
ctx.translateBy(x: CGFloat(pOriginX) - 6, y: CGFloat(pOriginY + pHeight / 2) - leftW / 2)
ctx.rotate(by: .pi / 2)
drawLabel(leftLabel, at: CGPoint(x: 0, y: -sideFontSz + 2), size: sideFontSz, color: lblGrn)
ctx.restoreGState()

ctx.saveGState()
ctx.translateBy(x: CGFloat(pOriginX + pWidth) + 6, y: CGFloat(pOriginY + pHeight / 2) + rightW / 2)
ctx.rotate(by: -.pi / 2)
drawLabel(rightLabel, at: CGPoint(x: 0, y: -sideFontSz + 2), size: sideFontSz, color: lblRed)
ctx.restoreGState()

// ── Top label: leading edge ───────────────────────────────────────────────────
let leadingLabel = "▲ LEADING EDGE — cut & peel here — this becomes the BOTTOM of the peeled note"
drawLabel(leadingLabel,
          at: CGPoint(x: CGFloat(pOriginX), y: CGFloat(topEdge) + 8),
          size: 10, color: lblBlue)

// ── Bottom labels ─────────────────────────────────────────────────────────────
drawLabel("▼ TRAILING EDGE (feeds last)",
          at: CGPoint(x: CGFloat(pOriginX), y: CGFloat(pOriginY) - 16),
          size: 10, color: lblGray)

// ── Info bar at very bottom ───────────────────────────────────────────────────
let infoLine = "\(pWidth) × \(pHeight) dots   \(String(format:"%.1f",widthMM)) × \(String(format:"%.1f",heightMM)) mm   \(blackDots) black dots  (\(String(format:"%.1f",coverage))%)"
drawLabel(infoLine,
          at: CGPoint(x: CGFloat(pOriginX), y: 18),
          size: 10, color: lblGray)

let guideText: String
let guideColor: CGColor
if blackDots == 0 {
    guideText  = "⚠  BLANK — filter produced no ink. Check rendering pipeline."
    guideColor = lblOrng
} else {
    guideText  = "✓ To read: press ⌘L in Preview.app (Rotate Left 90° CCW) — sticky/red edge should face UP"
    guideColor = lblYel
}
drawLabel(guideText,
          at: CGPoint(x: CGFloat(pOriginX), y: 5),
          size: 10, color: guideColor, bold: true)

// ── Save PNG ──────────────────────────────────────────────────────────────────
guard let finalImg = ctx.makeImage() else {
    fputs("Cannot create final image\n", stderr); exit(1)
}
let destURL = URL(fileURLWithPath: outputPath) as CFURL
guard let dest = CGImageDestinationCreateWithURL(destURL, "public.png" as CFString, 1, nil as CFDictionary?) else {
    fputs("Cannot create PNG destination at '\(outputPath)'\n", stderr); exit(1)
}
CGImageDestinationAddImage(dest, finalImg, nil as CFDictionary?)
guard CGImageDestinationFinalize(dest) else {
    fputs("PNG write failed\n", stderr); exit(1)
}
print("Saved: \(outputPath)")
