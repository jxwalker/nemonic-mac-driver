import Foundation
import CoreGraphics
import AppKit

let maxRenderScale: CGFloat = 2.0
let feedPaddingDots = 60

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

func ditherAndPrint(rawData: [UInt8], width: Int, height: Int) -> (Data, [UInt8]) {
    var monoData = [UInt8](repeating: 255, count: width * height)
    let threshold = envInt("NEMONIC_THRESHOLD", default: 160)
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
    let cropPadding = max(0, envInt("NEMONIC_CROP_PADDING", default: 16))
    let rightMargin = max(0, envInt("NEMONIC_RIGHT_MARGIN", default: 12))
    let interpolationQuality = ProcessInfo.processInfo.environment["NEMONIC_INTERPOLATION"] == nil ? .high : envInterpolationQuality()
    let scaleAdjust = max(0.25, envDouble("NEMONIC_SCALE_ADJUST", default: 1.0))
    // Text printed via macOS (BBEdit, lpr, etc.) can end up outside the nominal mediaBox; 1.0 = old behaviour.
    let renderPad = max(1.0, min(4.0, envDouble("NEMONIC_RENDER_PAD", default: 2.0)))
    var pdfData: Data
    if args.count >= 7 {
        let path = args[6]
        if path.isEmpty || path == "-" {
            pdfData = FileHandle.standardInput.readDataToEndOfFile()
        } else {
            pdfData = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
        }
    } else {
        pdfData = FileHandle.standardInput.readDataToEndOfFile()
    }

    if pdfData.isEmpty {
        fputs("pdftonemonic: no PDF bytes (empty argv path or stdin).\n", stderr)
        exit(1)
    }

    guard let provider = CGDataProvider(data: pdfData as CFData),
          let pdfDoc = CGPDFDocument(provider) else {
        fputs("pdftonemonic: could not open PDF from job data.\n", stderr)
        exit(1)
    }

    var pagesEmitted = 0
    for pageNum in 1...pdfDoc.numberOfPages {
        guard let page = pdfDoc.page(at: pageNum) else { continue }

        let box = page.getBoxRect(.mediaBox)
        let padW = box.width * (renderPad - 1) / 2
        let padH = box.height * (renderPad - 1) / 2
        let bigBox = box.insetBy(dx: -padW, dy: -padH)
        let rotation = page.rotationAngle
        let isRotated = (rotation % 180 != 0)

        let pdfWidth = isRotated ? bigBox.height : bigBox.width
        let pdfHeight = isRotated ? bigBox.width : bigBox.height

        let dpiScale: CGFloat = 203.0 / 72.0
        let testWidth = Int(pdfWidth * dpiScale)
        let testHeight = Int(pdfHeight * dpiScale)

        // Render into DeviceRGB first: some PDFs (transparency / blend) rasterize empty in DeviceGray.
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

        var testData = [UInt8](repeating: 255, count: testWidth * testHeight)
        let colorSpace = CGColorSpaceCreateDeviceGray()
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
        saveDebugImage(testImage, pageNum: pageNum, stage: "rendered-gray", directory: debugDir)

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

            let invertedMinY = testHeight - 1 - maxY
            let invertedMaxY = testHeight - 1 - minY
            cropRect = CGRect(x: minX,
                              y: invertedMinY,
                              width: maxX - minX + 1,
                              height: invertedMaxY - invertedMinY + 1)
        }

        guard let croppedImage = testImage.cropping(to: cropRect) else { continue }
        saveDebugImage(croppedImage, pageNum: pageNum, stage: "cropped", directory: debugDir)

        let targetWidth = 576
        let printableWidth = targetWidth - rightMargin

        let contentWidth = croppedImage.height

        var finalScale = (CGFloat(printableWidth) / CGFloat(contentWidth)) * CGFloat(scaleAdjust)
        if finalScale > maxRenderScale {
            finalScale = maxRenderScale
        }

        // Scaled size in PDF pixel space (before +90° rotation into the head bitmap).
        var drawWidth = CGFloat(croppedImage.width) * finalScale
        var drawHeight = CGFloat(croppedImage.height) * finalScale
        // After rotation, the span along the 576-dot scan axis must not exceed printable width.
        if drawHeight > CGFloat(printableWidth) {
            finalScale *= CGFloat(printableWidth) / drawHeight
            drawWidth = CGFloat(croppedImage.width) * finalScale
            drawHeight = CGFloat(croppedImage.height) * finalScale
        }
        // Buffer height must cover the rotated AABB; using only width×scale clips tall spans → all-white output.
        let targetHeight = Int(ceil(max(drawWidth, drawHeight))) + feedPaddingDots + 64

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

        finalContext.translateBy(x: CGFloat(printableWidth) / 2.0, y: CGFloat(targetHeight) / 2.0)
        finalContext.scaleBy(x: 1.0, y: -1.0)
        finalContext.rotate(by: CGFloat.pi / 2.0)

        finalContext.draw(croppedImage,
                          in: CGRect(x: -drawWidth / 2.0,
                                     y: -drawHeight / 2.0,
                                     width: drawWidth,
                                     height: drawHeight))

        guard let finalImage = finalContext.makeImage() else { continue }
        saveDebugImage(finalImage, pageNum: pageNum, stage: "final-raster", directory: debugDir)

        let (escposData, monoData) = ditherAndPrint(rawData: finalData, width: targetWidth, height: targetHeight)
        if let monoImage = makeImage(from: monoData, width: targetWidth, height: targetHeight) {
            saveDebugImage(monoImage, pageNum: pageNum, stage: "dithered", directory: debugDir)
        }

        if !previewOnly {
            FileHandle.standardOutput.write(escposData)
            pagesEmitted += 1
        }
    }

    if !previewOnly && pagesEmitted == 0 {
        let msg = "pdftonemonic: wrote 0 pages (empty PDF, render failure, or all pages skipped). Set NEMONIC_DEBUG_DIR to capture PNGs.\n"
        if let data = msg.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}

main()
