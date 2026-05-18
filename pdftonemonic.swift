import Foundation
import CoreGraphics
import AppKit
import Darwin

/// Load PDF bytes for a CUPS job. Order matters: pipes first when safe; never block on a TTY stdin.
func loadJobPDF(arguments args: [String]) -> Data? {
    if isatty(STDIN_FILENO) == 0 {
        let fromStdin = FileHandle.standardInput.readDataToEndOfFile()
        if !fromStdin.isEmpty { return fromStdin }
    }
    if args.count >= 7 {
        let p = args[6]
        if !p.isEmpty && p != "-" {
            if let d = try? Data(contentsOf: URL(fileURLWithPath: p)), !d.isEmpty {
                return d
            }
        }
    }
    return nil
}

let maxRenderScale: CGFloat = 2.0
let feedPaddingDots = 4
/// Logged once per job to /private/var/log/cups/error_log (confirms install is current).
private let filterBuildTag = "pdftonemonic build 2026-05-18-dual-mode-sticky-receipt"

func debugDirectoryURL() -> URL? {
    guard let path = ProcessInfo.processInfo.environment["NEMONIC_DEBUG_DIR"],
          !path.isEmpty else {
        return nil
    }

    let url = URL(fileURLWithPath: path, isDirectory: true)
    try? FileManager.default.createDirectory(at: url,
                                             withIntermediateDirectories: true,
                                             attributes: nil)
    return url
}

func shouldPreviewOnly() -> Bool {
    let value = ProcessInfo.processInfo.environment["NEMONIC_PREVIEW_ONLY"]?.lowercased()
    return value == "1" || value == "true" || value == "yes"
}

func resolveNemonicMode(rawOptions: String) -> String {
    // Allow env override for testing (NEMONIC_MODE=Receipt or Sticky)
    if let env = ProcessInfo.processInfo.environment["NEMONIC_MODE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
       !env.isEmpty {
        let v = env.capitalized
        if v == "Receipt" || v == "Sticky" {
            return v
        }
    }
    // CUPS options string: "PageSize=... NemonicMode=Receipt ColorModel=Gray ..."
    for token in rawOptions.split(separator: " ") {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("NemonicMode=") {
            var v = String(t.dropFirst("NemonicMode=".count))
            if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
                v = String(v.dropFirst().dropLast())
            }
            if v == "Receipt" || v == "Sticky" {
                return v
            }
        }
    }
    return "Sticky"
}

func envInt(_ name: String, default defaultValue: Int) -> Int {
    guard let raw = ProcessInfo.processInfo.environment[name],
          let value = Int(raw) else {
        return defaultValue
    }
    return value
}

func envDouble(_ name: String, default defaultValue: Double) -> Double {
    guard let raw = ProcessInfo.processInfo.environment[name],
          let value = Double(raw) else {
        return defaultValue
    }
    return value
}

func envInterpolationQuality() -> CGInterpolationQuality {
    switch ProcessInfo.processInfo.environment["NEMONIC_INTERPOLATION"]?.lowercased() {
    case "none":
        return .none
    case "low":
        return .low
    case "medium":
        return .medium
    case "high":
        return .high
    default:
        return .none
    }
}

func savePNG(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let pngData = rep.representation(using: .png, properties: [:]) else { return }
    try? pngData.write(to: url)
}

func saveDebugImage(_ image: CGImage, pageNum: Int, stage: String, directory: URL?) {
    guard let directory else { return }
    let fileURL = directory.appendingPathComponent(String(format: "page-%02d-%@.png", pageNum, stage))
    savePNG(image, to: fileURL)
}

func makeImage(from rawData: [UInt8], width: Int, height: Int) -> CGImage? {
    let colorSpace = CGColorSpaceCreateDeviceGray()
    let data = Data(rawData) as CFData
    guard let provider = CGDataProvider(data: data) else { return nil }
    return CGImage(width: width,
                   height: height,
                   bitsPerComponent: 8,
                   bitsPerPixel: 8,
                   bytesPerRow: width,
                   space: colorSpace,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                   provider: provider,
                   decode: nil,
                   shouldInterpolate: false,
                   intent: .defaultIntent)
}

func ditherThreshold() -> Int {
    let t = envInt("NEMONIC_THRESHOLD", default: 160)
    if (1...255).contains(t) { return t }
    fputs("pdftonemonic: NEMONIC_THRESHOLD=\(t) is outside 1...255 (0 = all-white blank); using 160.\n", stderr)
    return 160
}

func ditherAndPrint(rawData: [UInt8], width: Int, height: Int) -> (Data, [UInt8]) {
    var monoData = [UInt8](repeating: 255, count: width * height)
    let threshold = ditherThreshold()
    var out = Data()
    out.append(contentsOf: [0x02])
    out.append(contentsOf: [0x1B, 0x40])
    let wBytes = width / 8
    out.append(contentsOf: [0x1D, 0x76, 0x30, 0x00])
    out.append(contentsOf: [UInt8(wBytes & 0xFF), UInt8((wBytes >> 8) & 0xFF)])
    out.append(contentsOf: [UInt8(height & 0xFF), UInt8((height >> 8) & 0xFF)])

    for y in 0..<height {
        for xB in 0..<wBytes {
            var b: UInt8 = 0
            for bit in 0..<8 {
                let x = xB * 8 + bit
                let pixel = rawData[y * width + x]
                if Int(pixel) < threshold {
                    monoData[y * width + x] = 0
                    b |= (1 << (7 - bit))
                } else {
                    monoData[y * width + x] = 255
                }
            }
            out.append(b)
        }
    }

    out.append(contentsOf: [0x1B, 0x43, 0x01])
    out.append(contentsOf: [0x1B, 0x6C, 0x00])
    out.append(contentsOf: [0x1B, 0x50])
    out.append(contentsOf: [0x1B, 0x69])
    out.append(contentsOf: [0x03])

    return (out, monoData)
}

func main() {
    let args = CommandLine.arguments
    let debugDir = debugDirectoryURL()
    let previewOnly = shouldPreviewOnly()
    fputs("\(filterBuildTag)\n", stderr)
    if previewOnly {
        fputs("pdftonemonic: NEMONIC_PREVIEW_ONLY is set — stdout will carry no ESC/POS (blank sheet if backend still feeds paper).\n", stderr)
    }
    var pagesSentToPrinter = 0
    let cropPadding = max(0, envInt("NEMONIC_CROP_PADDING", default: 16))
    let rightMargin = max(0, envInt("NEMONIC_RIGHT_MARGIN", default: 12))
    let interpolationQuality = ProcessInfo.processInfo.environment["NEMONIC_INTERPOLATION"] == nil ? .high : envInterpolationQuality()
    let scaleAdjust = max(0.25, envDouble("NEMONIC_SCALE_ADJUST", default: 1.0))

    let rawOptions = (args.count >= 6) ? args[5] : ""
    let nemonicMode = resolveNemonicMode(rawOptions: rawOptions)
    let isStickyMode = (nemonicMode != "Receipt")
    fputs("pdftonemonic: NemonicMode=\(nemonicMode) (isSticky=\(isStickyMode))\n", stderr)

    guard let pdfData = loadJobPDF(arguments: args), !pdfData.isEmpty else {
        fputs("pdftonemonic: no PDF bytes (if running by hand with a file path, use: ... < /dev/null or pass a valid argv[6]).\n", stderr)
        exit(1)
    }

    guard let provider = CGDataProvider(data: pdfData as CFData),
          let pdfDoc = CGPDFDocument(provider) else {
        fputs("pdftonemonic: invalid PDF.\n", stderr)
        exit(1)
    }

    let pageCount = pdfDoc.numberOfPages
    guard pageCount > 0 else {
        fputs("pdftonemonic: PDF has no pages.\n", stderr)
        exit(1)
    }

    for pageNum in 1...pageCount {
        guard let page = pdfDoc.page(at: pageNum) else { continue }

        let box = page.getBoxRect(.mediaBox)
        let rotation = page.rotationAngle
        let isRotated = (rotation % 180 != 0)

        let pdfWidth = isRotated ? box.height : box.width
        let pdfHeight = isRotated ? box.width : box.height

        let dpiScale: CGFloat = 203.0 / 72.0
        let testWidth = Int(pdfWidth * dpiScale)
        let testHeight = Int(pdfHeight * dpiScale)

        // Render PDF into DeviceRGB first: some jobs (BBEdit / Quartz, transparency blends)
        // rasterize as empty white in a direct DeviceGray+drawPDFPage pass.
        let colorSpaceRGB = CGColorSpaceCreateDeviceRGB()
        let bmpRGB = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        var testDataRGB = [UInt8](repeating: 0, count: max(1, testWidth * testHeight * 4))
        guard let rgbContext = CGContext(data: &testDataRGB,
                                         width: testWidth,
                                         height: testHeight,
                                         bitsPerComponent: 8,
                                         bytesPerRow: testWidth * 4,
                                         space: colorSpaceRGB,
                                         bitmapInfo: bmpRGB) else { continue }

        rgbContext.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        rgbContext.fill(CGRect(x: 0, y: 0, width: testWidth, height: testHeight))

        rgbContext.translateBy(x: 0, y: CGFloat(testHeight))
        rgbContext.scaleBy(x: dpiScale, y: -dpiScale)

        rgbContext.translateBy(x: pdfWidth / 2.0, y: pdfHeight / 2.0)
        rgbContext.rotate(by: -CGFloat(rotation) * .pi / 180.0)
        rgbContext.translateBy(x: -box.midX, y: -box.midY)

        rgbContext.drawPDFPage(page)
        guard let rgbImage = rgbContext.makeImage() else { continue }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        var testData = [UInt8](repeating: 255, count: testWidth * testHeight)
        guard let grayRaster = CGContext(data: &testData,
                                         width: testWidth,
                                         height: testHeight,
                                         bitsPerComponent: 8,
                                         bytesPerRow: testWidth,
                                         space: colorSpace,
                                         bitmapInfo: CGImageAlphaInfo.none.rawValue) else { continue }
        grayRaster.interpolationQuality = interpolationQuality
        grayRaster.draw(rgbImage, in: CGRect(x: 0, y: 0, width: testWidth, height: testHeight))
        guard let testImage = grayRaster.makeImage() else { continue }
        saveDebugImage(rgbImage, pageNum: pageNum, stage: "rendered-rgb", directory: debugDir)
        saveDebugImage(testImage, pageNum: pageNum, stage: "rendered", directory: debugDir)

        var minX = testWidth
        var maxX = 0
        var minY = testHeight
        var maxY = 0
        for y in 0..<testHeight {
            for x in 0..<testWidth {
                if testData[y * testWidth + x] < 250 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }

        var cropRect = CGRect(x: 0, y: 0, width: testWidth, height: testHeight)
        if minX <= maxX && minY <= maxY {
            let padding = cropPadding
            minX = max(0, minX - padding)
            minY = max(0, minY - padding)
            maxX = min(testWidth - 1, maxX + padding)
            maxY = min(testHeight - 1, maxY + padding)

            // CGImage.cropping uses Quartz coords: origin bottom-left; buffer row 0 is y=0.
            cropRect = CGRect(x: minX,
                              y: minY,
                              width: maxX - minX + 1,
                              height: maxY - minY + 1)
        }

        guard let croppedImage = testImage.cropping(to: cropRect) else { continue }
        saveDebugImage(croppedImage, pageNum: pageNum, stage: "cropped", directory: debugDir)

        let targetWidth = 576
        let sideMarginDots = isStickyMode ? rightMargin : 8
        let printableWidth = targetWidth - sideMarginDots

        // Sticky: after +90° rotation we fit the *height* of the cropped content across the printable width.
        // Receipt: we fit the *width* of the cropped content across the printable width (normal orientation).
        let contentDimForFit = isStickyMode ? croppedImage.height : croppedImage.width

        var finalScale = (CGFloat(printableWidth) / CGFloat(contentDimForFit)) * CGFloat(scaleAdjust)
        if finalScale > maxRenderScale {
            finalScale = maxRenderScale
        }

        var drawWidth = CGFloat(croppedImage.width) * finalScale
        var drawHeight = CGFloat(croppedImage.height) * finalScale
        if isStickyMode && drawHeight > CGFloat(printableWidth) {
            // Only needed in sticky mode: after rotation both dimensions must fit the tall output bitmap.
            finalScale *= CGFloat(printableWidth) / drawHeight
            drawWidth = CGFloat(croppedImage.width) * finalScale
            drawHeight = CGFloat(croppedImage.height) * finalScale
        }

        let extra = isStickyMode ? feedPaddingDots : (feedPaddingDots + 64)
        let targetHeight = isStickyMode
            ? Int(ceil(max(drawWidth, drawHeight))) + extra
            : Int(ceil(drawHeight)) + extra

        var finalData = [UInt8](repeating: 255, count: targetWidth * targetHeight)
        guard let finalContext = CGContext(data: &finalData,
                                           width: targetWidth,
                                           height: targetHeight,
                                           bitsPerComponent: 8,
                                           bytesPerRow: targetWidth,
                                           space: colorSpace,
                                           bitmapInfo: CGImageAlphaInfo.none.rawValue) else { continue }

        finalContext.setFillColor(CGColor.white)
        finalContext.fill(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        finalContext.interpolationQuality = interpolationQuality

        if isStickyMode {
            // Original sticky-note path: +90° rotation so text reads correctly with adhesive on the side.
            // Biased toward north (leading edge) — small padding on north, extra white on south.
            let northPadding: CGFloat = 4
            finalContext.translateBy(x: CGFloat(printableWidth) / 2.0, y: northPadding + drawHeight / 2.0)
            finalContext.scaleBy(x: 1.0, y: -1.0)
            finalContext.rotate(by: CGFloat.pi / 2.0)

            finalContext.draw(croppedImage,
                              in: CGRect(x: -drawWidth / 2.0,
                                         y: -drawHeight / 2.0,
                                         width: drawWidth,
                                         height: drawHeight))
        } else {
            // Receipt path: normal upright orientation, content flows down the paper length.
            // Set up context so y=0 is the leading edge and Y increases toward the trailing edge.
            finalContext.translateBy(x: 0, y: CGFloat(targetHeight))
            finalContext.scaleBy(x: 1.0, y: -1.0)

            let leftMargin = CGFloat(sideMarginDots) / 2.0
            let topPadding = CGFloat(feedPaddingDots)

            // 180° in the paper-down system — this version gives correct left-to-right.
            finalContext.saveGState()
            finalContext.translateBy(x: leftMargin + drawWidth, y: topPadding + drawHeight)
            finalContext.scaleBy(x: -1.0, y: -1.0)
            finalContext.draw(croppedImage,
                              in: CGRect(x: 0, y: 0, width: drawWidth, height: drawHeight))
            finalContext.restoreGState()
        }

        guard let finalImage = finalContext.makeImage() else { continue }
        saveDebugImage(finalImage, pageNum: pageNum, stage: "final-raster", directory: debugDir)

        // Receipt correction: force correct orientation on paper (top of content
        // at leading edge, left-to-right reading) regardless of drawing math.
        if !isStickyMode {
            // Vertical flip (reverse row order)
            for i in 0..<(targetHeight / 2) {
                let j = targetHeight - 1 - i
                for x in 0..<targetWidth {
                    let a = i * targetWidth + x
                    let b = j * targetWidth + x
                    let tmp = finalData[a]
                    finalData[a] = finalData[b]
                    finalData[b] = tmp
                }
            }
            // Horizontal flip (reverse each row left-to-right)
            for y in 0..<targetHeight {
                var left = y * targetWidth
                var right = left + targetWidth - 1
                while left < right {
                    let tmp = finalData[left]
                    finalData[left] = finalData[right]
                    finalData[right] = tmp
                    left += 1
                    right -= 1
                }
            }
        }


        let (escposData, monoData) = ditherAndPrint(rawData: finalData, width: targetWidth, height: targetHeight)
        if let monoImage = makeImage(from: monoData, width: targetWidth, height: targetHeight) {
            saveDebugImage(monoImage, pageNum: pageNum, stage: "dithered", directory: debugDir)
        }

        if !previewOnly {
            FileHandle.standardOutput.write(escposData)
            pagesSentToPrinter += 1
        }
    }

    if !previewOnly && pagesSentToPrinter == 0 {
        fputs("pdftonemonic: no ESC/POS emitted — every page failed render/crop (would look blank).\n", stderr)
        exit(1)
    }
}

main()
