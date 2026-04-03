// make_test_pdf.swift — Canonical test PDF for the Nemonic driver
//
// Generates an A4 PDF with corner markers, direction arrows, and bold central
// text. Chosen so that every failure mode is immediately visible in the preview:
//
//   • Wrong rotation direction  → "▲ READING TOP" appears on the wrong side
//   • Mirror                    → "NEMONIC TEST" appears backwards
//   • Upside-down               → corner labels swap
//   • Crop failure              → corner labels disappear or note is tiny
//   • Scale failure             → text too small / overflows width
//
// Usage:  swift make_test_pdf.swift [output.pdf]
//         (defaults to /tmp/nemonic_test_input.pdf)

import Foundation
import CoreGraphics
import CoreText

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "/tmp/nemonic_test_input.pdf"

// A4 dimensions in points (1 pt = 1/72 inch)
let pw: CGFloat = 595
let ph: CGFloat = 842

// NOTE: CGContext for PDF uses Y-UP (y=0 = page bottom, y=842 = page top).
var box = CGRect(x: 0, y: 0, width: pw, height: ph)
guard let pdf = CGContext(URL(fileURLWithPath: outputPath) as CFURL, mediaBox: &box, nil) else {
    fputs("Cannot create PDF at '\(outputPath)'\n", stderr); exit(1)
}

pdf.beginPDFPage(nil)

// White background
pdf.setFillColor(.white)
pdf.fill(box)

// ── CoreText drawing helper ────────────────────────────────────────────────────
// x, y = baseline position in Y-UP PDF coordinates.
// Returns the drawn line's typographic width so callers can center text.
@discardableResult
func drawText(_ s: String, x: CGFloat, y: CGFloat, size: CGFloat, bold: Bool = false) -> CGFloat {
    let fontName = (bold ? "Helvetica-Bold" : "Helvetica") as CFString
    let font  = CTFontCreateWithName(fontName, size, nil)
    let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
    let cfStr = s as CFString
    let len   = CFStringGetLength(cfStr)
    let attr  = CFAttributedStringCreateMutable(kCFAllocatorDefault, 0)!
    CFAttributedStringReplaceString(attr, CFRangeMake(0, 0), cfStr)
    CFAttributedStringSetAttribute(attr, CFRangeMake(0, len), kCTFontAttributeName, font)
    CFAttributedStringSetAttribute(attr, CFRangeMake(0, len), kCTForegroundColorAttributeName, black)
    let line  = CTLineCreateWithAttributedString(attr)
    let tw    = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    pdf.saveGState()
    pdf.textMatrix = .identity
    pdf.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, pdf)
    pdf.restoreGState()
    return tw
}

func centeredX(_ s: String, size: CGFloat, bold: Bool = false) -> CGFloat {
    let fontName = (bold ? "Helvetica-Bold" : "Helvetica") as CFString
    let font  = CTFontCreateWithName(fontName, size, nil)
    let cfStr = s as CFString
    let attr  = CFAttributedStringCreateMutable(kCFAllocatorDefault, 0)!
    CFAttributedStringReplaceString(attr, CFRangeMake(0, 0), cfStr)
    CFAttributedStringSetAttribute(attr, CFRangeMake(0, CFStringGetLength(cfStr)), kCTFontAttributeName, font)
    let line = CTLineCreateWithAttributedString(attr)
    let tw   = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    return (pw - tw) / 2
}

func textWidth(_ s: String, size: CGFloat, bold: Bool = false) -> CGFloat {
    let fontName = (bold ? "Helvetica-Bold" : "Helvetica") as CFString
    let font = CTFontCreateWithName(fontName, size, nil)
    let cfStr = s as CFString
    let attr = CFAttributedStringCreateMutable(kCFAllocatorDefault, 0)!
    CFAttributedStringReplaceString(attr, CFRangeMake(0, 0), cfStr)
    CFAttributedStringSetAttribute(attr, CFRangeMake(0, CFStringGetLength(cfStr)), kCTFontAttributeName, font)
    let line = CTLineCreateWithAttributedString(attr)
    return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
}

// ── Layout constants ──────────────────────────────────────────────────────────
// Using 1-inch (72pt) margins — typical app default.
let m: CGFloat = 72

// In Y-UP coordinates:
//   top of printable area baseline ≈ ph - m - fontSize
//   bottom baseline                ≈ m
//   page centre baseline           ≈ ph / 2

// ── Corner markers ────────────────────────────────────────────────────────────
// These must survive auto-crop: if any corner disappears, cropping is wrong.
let cornerSz: CGFloat = 14
drawText("╔ TOP-LEFT",
         x: m,
         y: ph - m - cornerSz,
         size: cornerSz, bold: true)

let trText = "TOP-RIGHT ╗"
let trW = textWidth(trText, size: cornerSz, bold: true)
drawText(trText, x: pw - m - trW, y: ph - m - cornerSz, size: cornerSz, bold: true)

drawText("╚ BOT-LEFT",
         x: m,
         y: m,
         size: cornerSz, bold: true)

let brText = "BOT-RIGHT ╝"
let brW = textWidth(brText, size: cornerSz, bold: true)
drawText(brText, x: pw - m - brW, y: m, size: cornerSz, bold: true)

// ── Direction arrows ──────────────────────────────────────────────────────────
// Placed just inside the margin so they show up after auto-crop.
// In the correct print preview PNG these map to:
//   "▲ READING TOP"    → appears near RIGHT (sticky) edge of PNG
//   "▼ READING BOTTOM" → appears near LEFT (non-sticky) edge of PNG
let arrowSz: CGFloat = 13
let topArrow = "▲  READING TOP"
drawText(topArrow,
         x: centeredX(topArrow, size: arrowSz),
         y: ph - m - cornerSz - 26,
         size: arrowSz)

let botArrow = "▼  READING BOTTOM"
drawText(botArrow,
         x: centeredX(botArrow, size: arrowSz),
         y: m + cornerSz + 8,
         size: arrowSz)

// ── Central content ───────────────────────────────────────────────────────────
// Large, bold, asymmetric. After correct rotation + crop:
//   • "NEMONIC TEST" reads left-to-right (top area of note)
//   • "Abc  Xyz  123" is below it
let bigSz: CGFloat = 42
let mainText = "NEMONIC TEST"
drawText(mainText,
         x: centeredX(mainText, size: bigSz, bold: true),
         y: ph / 2 + 25,
         size: bigSz, bold: true)

let subText = "Abc  Xyz  123"
let subSz: CGFloat = 26
drawText(subText,
         x: centeredX(subText, size: subSz),
         y: ph / 2 - 20,
         size: subSz)

// ── Mid-page separator line ───────────────────────────────────────────────────
// A horizontal line across the full printable width to test for X-axis mirroring.
// After correct rotation it becomes a vertical rule in the PNG.
pdf.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.3))
pdf.setLineWidth(1)
pdf.move(to: CGPoint(x: m, y: ph / 2 - 40))
pdf.addLine(to: CGPoint(x: pw - m, y: ph / 2 - 40))
pdf.strokePath()

pdf.endPDFPage()
pdf.closePDF()
print("Test PDF written to: \(outputPath)")
