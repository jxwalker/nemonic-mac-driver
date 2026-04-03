import Foundation
import CoreGraphics
import AppKit

func ditherAndPrint(rawData: [UInt8], width: Int, height: Int) -> Data {
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
                if pixel < 128 { 
                    b |= (1 << (7 - bit))
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
    
    return out
}

func main() {
    let args = CommandLine.arguments
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
        let dpiScale: CGFloat = 203.0 / 72.0 
        
        let testWidth = Int(box.width * dpiScale)
        let testHeight = Int(box.height * dpiScale)
        
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
        
        // PURE Y-UP RENDER (This guarantees CGContextDrawPDFPage draws completely upright and normal)
        let transform = page.getDrawingTransform(.mediaBox, rect: CGRect(x: 0, y: 0, width: testWidth, height: testHeight), rotate: 0, preserveAspectRatio: true)
        testContext.concatenate(transform)
        testContext.drawPDFPage(page)
        
        guard let testImage = testContext.makeImage() else { continue }
        
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
            let padding = 16
            minX = max(0, minX - padding)
            minY = max(0, minY - padding)
            maxX = min(testWidth - 1, maxX + padding)
            maxY = min(testHeight - 1, maxY + padding)
            
            // In Y-UP, maxY is the top of the text. CGImage.cropping uses Top-Left origin.
            let cropY = testHeight - 1 - maxY
            cropRect = CGRect(x: minX, y: cropY, width: maxX - minX + 1, height: maxY - minY + 1)
        }
        
        guard let croppedImage = testImage.cropping(to: cropRect) else { continue }
        
        let targetWidth = 576
        let rightMargin = 24 // 3mm margin from sticky edge
        let printableWidth = targetWidth - rightMargin
        
        let contentRollWidth = croppedImage.height
        let contentRollLength = croppedImage.width
        
        // Slightly smarter scaling: Scale up to 2x max to ensure readability without giant text
        var finalScale: CGFloat = 1.0
        if contentRollWidth > printableWidth {
            finalScale = CGFloat(printableWidth) / CGFloat(contentRollWidth)
        } else {
            // Upscale slightly if it's very small, but cap at 2.0 to avoid "giant" text
            finalScale = min(2.0, CGFloat(printableWidth) / CGFloat(contentRollWidth))
        }
        
        let feedPadding = 40
        let targetHeight = Int(CGFloat(contentRollLength) * finalScale) + feedPadding
        
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
        
        // Center the text within the printable area (pushes it safely away from the sticky edge)
        finalContext.translateBy(x: CGFloat(printableWidth) / 2.0, y: CGFloat(targetHeight) / 2.0)
        
        // Make context Y-DOWN so it feeds Top-to-Bottom
        finalContext.scaleBy(x: 1.0, y: -1.0)
        
        // Rotate +90 Clockwise so Top of text maps to Right edge (Sticky edge)
        finalContext.rotate(by: CGFloat.pi / 2.0)
        
        let drawWidth = CGFloat(croppedImage.width) * finalScale
        let drawHeight = CGFloat(croppedImage.height) * finalScale
        finalContext.draw(croppedImage, in: CGRect(x: -drawWidth/2.0, y: -drawHeight/2.0, width: drawWidth, height: drawHeight))
        
        let escposData = ditherAndPrint(rawData: finalData, width: targetWidth, height: targetHeight)
        FileHandle.standardOutput.write(escposData)
    }
}

main()
