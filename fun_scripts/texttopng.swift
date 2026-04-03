import Cocoa

let args = CommandLine.arguments.dropFirst()
var text = ""
if args.isEmpty {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    text = String(data: data, encoding: .utf8) ?? ""
} else {
    text = args.joined(separator: "\n")
}

if text.isEmpty { exit(1) }

let font = NSFont.monospacedSystemFont(ofSize: 48, weight: .bold)
let paragraphStyle = NSMutableParagraphStyle()
paragraphStyle.lineBreakMode = .byWordWrapping

let attributes: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor.black,
    .paragraphStyle: paragraphStyle
]

let attrString = NSAttributedString(string: text, attributes: attributes)
let maxWidth: CGFloat = 500.0 // Leaves generous margins on an 80mm roll

let textRect = attrString.boundingRect(with: NSSize(width: maxWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])

let padding: CGFloat = 20
let calculatedHeight = textRect.height + padding*2
let imageWidth = Int(maxWidth + padding*2)

// THE SECRET AUTO-ROTATION FIX:
// macOS `imagetopdf` (which CUPS uses behind the scenes) automatically rotates "Landscape" 
// images 90 degrees to fit them better onto "Portrait" pages. 
// Because short lines of text are wider than they are tall, macOS secretly spun them sideways 
// before our driver even received them!
// By forcing the output image to ALWAYS be at least a Square (by extending the white space down), 
// macOS thinks it's a Portrait image and refuses to auto-rotate it!
let imageHeight = max(Int(calculatedHeight), imageWidth)

let colorSpace = CGColorSpaceCreateDeviceRGB()
let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
guard let context = CGContext(data: nil, width: imageWidth, height: imageHeight, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: bitmapInfo) else { exit(1) }

context.setFillColor(NSColor.white.cgColor)
context.fill(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))

// Use a flipped context so the text naturally renders from the top down.
let graphicsContext = NSGraphicsContext(cgContext: context, flipped: true)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphicsContext

attrString.draw(with: NSRect(x: padding, y: padding, width: maxWidth, height: textRect.height), options: [.usesLineFragmentOrigin, .usesFontLeading])

NSGraphicsContext.restoreGraphicsState()

guard let cgImage = context.makeImage() else { exit(1) }
let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else { exit(1) }

FileHandle.standardOutput.write(pngData)
