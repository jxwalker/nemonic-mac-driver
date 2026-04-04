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

/// Black dots in 1-bit buffer (value 0 = burn on thermal).
func blackDotCount(_ mono: [UInt8]) -> Int {
    var n = 0
    for v in mono where v == 0 {
        n += 1
    }
    return n
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
    let minInkDots = max(0, envInt("NEMONIC_MIN_INK_DOTS", default: 400))
    let interpolationQuality = ProcessInfo.processInfo.environment["NEMONIC_INTERPOLATION"] == nil ? .high : envInterpolationQuality()
    let scaleAdjust = max(0.25, envDouble("NEMONIC_SCALE_ADJUST", default: 1.0))
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
        fputs("pdftonemonic: no PDF data.\n", stderr)
        exit(1)
    }

    guard let provider = CGDataProvider(data: pdfData as CFData),
          let pdfDoc = CGPDFDocument(provider) else {
        fputs("pdftonemonic: invalid PDF.\n", stderr)
        exit(1)
    }

    var pagesEmitted = 0
    for pageNum in 1...pdfDoc.numberOfPages {
        guard let page = pdfDoc.page(at: pageNum) else { continue }

        let box = page.getBoxRect(.mediaBox)
        let rotation = page.rotationAngle
        let isRotated = (rotation % 180 != 0)

        let pdfWidth = isRotated ? box.height : box.width
        let pdfHeight = isRotated ? box.width : box.height

        let dpiScale: CGFloat = 203.0 / 72.0
        let testWidth = Int(pdfWidth * dpiScale)
        let testHeight = Int(pdfHeight * dpiScale)

        let colorSpace = CGColorSpaceCreateDeviceGray()
        var testData = [UInt8](repeating: 255, count: testWidth * testHeight)
        guard let testContext = CGContext(data: &testData,
                                          width: testWidth,
                                          height: testHeight,
                                          bitsPerComponent: 8,
                                          bytesPerRow: testWidth,
                                          space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { continue }

        testContext.setFillColor(CGColor.white)
        testContext.fill(CGRect(x: 0, y: 0, width: testWidth, height: testHeight))

        testContext.translateBy(x: 0, y: CGFloat(testHeight))
        testContext.scaleBy(x: dpiScale, y: -dpiScale)

        testContext.translateBy(x: pdfWidth / 2.0, y: pdfHeight / 2.0)
        testContext.rotate(by: -CGFloat(rotation) * .pi / 180.0)
        testContext.translateBy(x: -box.midX, y: -box.midY)

        testContext.drawPDFPage(page)
        guard let testImage = testContext.makeImage() else { continue }
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

        var drawWidth = CGFloat(croppedImage.width) * finalScale
        var drawHeight = CGFloat(croppedImage.height) * finalScale
        if drawHeight > CGFloat(printableWidth) {
            finalScale *= CGFloat(printableWidth) / drawHeight
            drawWidth = CGFloat(croppedImage.width) * finalScale
            drawHeight = CGFloat(croppedImage.height) * finalScale
        }
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

        let ink = blackDotCount(monoData)
        if !previewOnly && minInkDots > 0 && ink < minInkDots {
            let msg = "pdftonemonic: page \(pageNum) skipped — only \(ink) black dots (min \(minInkDots)); refusing blank raster. Set NEMONIC_DEBUG_DIR for PNGs.\n"
            if let data = msg.data(using: .utf8) { FileHandle.standardError.write(data) }
            continue
        }

        if !previewOnly {
            FileHandle.standardOutput.write(escposData)
            pagesEmitted += 1
        }
    }

    if !previewOnly && pagesEmitted == 0 {
        fputs("pdftonemonic: no pages sent to printer (all blank or errors). Job fails.\n", stderr)
        exit(1)
    }
}

main()
