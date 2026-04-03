import Foundation
import CoreGraphics
import AppKit

func ditherAndPrint(cgImage: CGImage, width: Int, height: Int) -> Data {
    let colorSpace = CGColorSpaceCreateDeviceGray()
    let bytesPerRow = width
    var rawData = [UInt8](repeating: 0, count: height * bytesPerRow)
    
    guard let context = CGContext(data: &rawData,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
        return Data()
    }
    
    context.setFillColor(.white)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    
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
                let pixel = rawData[y * bytesPerRow + x]
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
        
        let mediaBox = page.getBoxRect(.mediaBox)
        let isLandscape = mediaBox.width > mediaBox.height
        
        let targetWidth = 576 // 80mm fixed print head width
        let baseDimension = isLandscape ? mediaBox.height : mediaBox.width
        let longDimension = isLandscape ? mediaBox.width : mediaBox.height
        
        let scale = CGFloat(targetWidth) / baseDimension
        let targetHeight = Int(longDimension * scale)
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil,
                                      width: targetWidth,
                                      height: targetHeight,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
        
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        
        context.translateBy(x: CGFloat(targetWidth) / 2.0, y: CGFloat(targetHeight) / 2.0)
        
        if isLandscape {
            // Rotate 90 degrees to align the wide document along the length of the roll
            context.rotate(by: -CGFloat.pi / 2.0)
        }
        
        // Scale X by -1 (mirror correction), Scale Y by -1 (fix upside-down)
        context.scaleBy(x: -scale, y: -scale)
        
        context.translateBy(x: -mediaBox.width / 2.0, y: -mediaBox.height / 2.0)
        
        context.drawPDFPage(page)
        
        guard let cgImage = context.makeImage() else { continue }
        let escposData = ditherAndPrint(cgImage: cgImage, width: targetWidth, height: targetHeight)
        FileHandle.standardOutput.write(escposData)
    }
}

main()
