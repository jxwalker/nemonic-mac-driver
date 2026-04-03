#!/usr/bin/swift
import Foundation
import CoreGraphics
import AppKit

/*
 * Nemonic MIP-201W Native macOS CUPS Filter
 * 
 * Replaces the proprietary Intel (x86_64) rastertonemonic filter with a 100% native
 * Swift implementation. Bypasses the need for Rosetta 2 on Apple Silicon Macs.
 *
 * It reads PDF data from CUPS, rasterizes it using CoreGraphics, applies dithering
 * (thresholding), and outputs the custom ESC/POS binary format required by the printer.
 * Handles the 90-degree rotation for the sticky edge and fixes mirror imaging natively.
 */

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
    
    // Draw white background
    context.setFillColor(.white)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    
    // Draw the PDF page image into the context
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    
    var out = Data()
    
    // Nemonic Hardware Initialization Header
    out.append(contentsOf: [0x02])                 // STX
    out.append(contentsOf: [0x1B, 0x40])           // ESC @ (Initialize printer)
    
    // ESC/POS GS v 0 (Print raster bit image)
    let wBytes = width / 8
    out.append(contentsOf: [0x1D, 0x76, 0x30, 0x00])
    out.append(contentsOf: [UInt8(wBytes & 0xFF), UInt8((wBytes >> 8) & 0xFF)])
    out.append(contentsOf: [UInt8(height & 0xFF), UInt8((height >> 8) & 0xFF)])
    
    // Dithering (Threshold 50%) and Bit-packing
    for y in 0..<height {
        for xB in 0..<wBytes {
            var b: UInt8 = 0
            for bit in 0..<8 {
                let x = xB * 8 + bit
                let pixel = rawData[y * bytesPerRow + x]
                // 0 is black in CoreGraphics grayscale; Nemonic expects 1 for black (heat on)
                if pixel < 128 { 
                    b |= (1 << (7 - bit))
                }
            }
            out.append(b)
        }
    }
    
    // Nemonic Hardware Footer
    out.append(contentsOf: [0x1B, 0x43, 0x01])     // ESC C 1 (Page length)
    out.append(contentsOf: [0x1B, 0x6C, 0x00])     // ESC l 0 (Left margin)
    out.append(contentsOf: [0x1B, 0x50])           // ESC P
    out.append(contentsOf: [0x1B, 0x69])           // ESC i (Partial cut)
    out.append(contentsOf: [0x03])                 // ETX
    
    return out
}

func main() {
    let args = CommandLine.arguments
    
    var pdfData: Data
    if args.count >= 7 {
        // Filename provided as argument 6
        do {
            pdfData = try Data(contentsOf: URL(fileURLWithPath: args[6]))
        } catch {
            fputs("Error reading file: \(error)\n", stderr)
            exit(1)
        }
    } else {
        // Read from standard input (CUPS pipeline)
        pdfData = FileHandle.standardInput.readDataToEndOfFile()
    }
    
    if pdfData.isEmpty {
        fputs("Empty PDF data\n", stderr)
        exit(1)
    }
    
    guard let provider = CGDataProvider(data: pdfData as CFData),
          let pdfDoc = CGPDFDocument(provider) else {
        fputs("Failed to parse PDF\n", stderr)
        exit(1)
    }
    
    // Process all pages in the PDF document
    for pageNum in 1...pdfDoc.numberOfPages {
        guard let page = pdfDoc.page(at: pageNum) else { continue }
        
        let mediaBox = page.getBoxRect(.mediaBox)
        
        // The Nemonic MIP-201W thermal head is 576 dots wide (203 DPI)
        let targetWidth = 576 
        
        // Scale the PDF height accordingly
        let scale = CGFloat(targetWidth) / mediaBox.height
        let targetHeight = Int(mediaBox.width * scale)
        
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
        
        // Matrix Transformations to match the physical printer orientation
        context.translateBy(x: CGFloat(targetWidth) / 2.0, y: CGFloat(targetHeight) / 2.0)
        
        // Rotate +90 degrees (Text runs top-to-bottom, sticky edge on the right)
        context.rotate(by: CGFloat.pi / 2.0)
        
        // Flip X and Y (Fixes mirror image from printer, and fixes native PDF upside-down rendering)
        context.scaleBy(x: -scale, y: -scale)
        
        context.translateBy(x: -mediaBox.width / 2.0, y: -mediaBox.height / 2.0)
        
        context.drawPDFPage(page)
        
        guard let cgImage = context.makeImage() else { continue }
        
        // Generate ESC/POS data and send to standard output for the CUPS USB backend
        let escposData = ditherAndPrint(cgImage: cgImage, width: targetWidth, height: targetHeight)
        FileHandle.standardOutput.write(escposData)
    }
}

main()
