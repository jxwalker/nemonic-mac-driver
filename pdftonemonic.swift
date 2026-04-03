import Foundation
import CoreGraphics
import AppKit

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
    let renderWidth = max(576, envInt("NEMONIC_RENDER_WIDTH", default: 1152))
    let cropPadding = max(0, envInt("NEMONIC_CROP_PADDING", default: 16))
    let rightMargin = max(0, envInt("NEMONIC_RIGHT_MARGIN", default: 12))
    let interpolationQuality = ProcessInfo.processInfo.environment["NEMONIC_INTERPOLATION"] == nil ? .high : envInterpolationQuality()
    let scaleAdjust = max(0.25, envDouble("NEMONIC_SCALE_ADJUST", default: 1.0))
    var pdfData: Data
    if args.count >= 7 {
        pdfData = try! Data(contentsOf: URL(fileURLWithPath: args[6]))
    } else {
        pdfData = FileHandle.standardInput.readDataToEndOfFile()
    }
    
    guard let provider = CGDataProvider(data: pdfData as CFData),
          let pdfDoc = CGPDFDocument(provider) else { exit(1) }

    for pageNum in 1...pdfDoc.numberOfPages {
        guard let page = pdfDoc.page(at: pageNum) else { continue }

        let box = page.getBoxRect(.mediaBox)
        let rotation = page.rotationAngle
        let isRotated = (rotation % 180 != 0)

        let pdfWidth = isRotated ? box.height : box.width
        let pdfHeight = isRotated ? box.width : box.height

        // Pass 1: Render the page into a raw grayscale bitmap using a Y-up context.
        let testWidth = renderWidth
        let testScale = CGFloat(testWidth) / max(pdfWidth, 1)
        let testHeight = max(1, Int(ceil(pdfHeight * testScale)))

        let colorSpace = CGColorSpaceCreateDeviceGray()
        var testData = [UInt8](repeating: 255, count: testWidth * testHeight)
        guard let testContext = CGContext(data: &testData,
                                          width: testWidth,
                                          height: testHeight,
                                          bitsPerComponent: 8,
                                          bytesPerRow: testWidth,
                                          space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { continue }

        testContext.setFillColor(.white)
        testContext.fill(CGRect(x: 0, y: 0, width: testWidth, height: testHeight))

        let renderRect = CGRect(x: 0, y: 0, width: testWidth, height: testHeight)
        let drawingTransform = page.getDrawingTransform(.mediaBox,
                                                        rect: renderRect,
                                                        rotate: 0,
                                                        preserveAspectRatio: true)
        testContext.concatenate(drawingTransform)
        testContext.drawPDFPage(page)
        guard let testImage = testContext.makeImage() else { continue }
        saveDebugImage(testImage, pageNum: pageNum, stage: "rendered", directory: debugDir)

        // Find non-white pixel bounds (Auto-Crop)
        var minX = testWidth, maxX = 0, minY = testHeight, maxY = 0
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

            cropRect = CGRect(x: minX,
                              y: minY,
                              width: maxX - minX + 1,
                              height: maxY - minY + 1)
        }

        guard let croppedImage = testImage.cropping(to: cropRect) else { continue }
        saveDebugImage(croppedImage, pageNum: pageNum, stage: "cropped", directory: debugDir)

        // Pass 2: Layout cropped image for printer
        let targetWidth = 576

        // Keep a white band on the sticky edge so printed content does not climb onto the adhesive.
        let printableWidth = targetWidth - rightMargin

        let contentWidth = croppedImage.width
        let contentHeight = croppedImage.height
        let finalScale = (CGFloat(printableWidth) / CGFloat(max(contentWidth, contentHeight))) * CGFloat(scaleAdjust)
        let drawWidth = CGFloat(contentWidth) * finalScale
        let drawHeight = CGFloat(contentHeight) * finalScale
        let targetHeight = max(1, Int(ceil(drawWidth)))

        var finalData = [UInt8](repeating: 255, count: targetWidth * targetHeight)
        guard let finalContext = CGContext(data: &finalData,
                                           width: targetWidth,
                                           height: targetHeight,
                                           bitsPerComponent: 8,
                                           bytesPerRow: targetWidth,
                                           space: colorSpace,
                                           bitmapInfo: CGImageAlphaInfo.none.rawValue) else { continue }

        finalContext.setFillColor(.white)
        finalContext.fill(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        finalContext.interpolationQuality = interpolationQuality

        // Rotate 90° clockwise in a Y-up context. The raster's right edge is the physical top.
        let stickyGap = CGFloat(rightMargin)
        let xPos = CGFloat(targetWidth) - (drawHeight / 2.0) - stickyGap
        let yPos = CGFloat(targetHeight) / 2.0
        finalContext.translateBy(x: xPos, y: yPos)
        finalContext.rotate(by: -.pi / 2.0)
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
        }
    }
}

main()
