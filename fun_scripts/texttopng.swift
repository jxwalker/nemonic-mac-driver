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

// Use a large 48pt font, which at 1:1 pixel mapping (203 DPI) prints beautifully bold 6mm text
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
let imageWidth = Int(maxWidth + padding*2)
let imageHeight = Int(textRect.height + padding*2)

let colorSpace = CGColorSpaceCreateDeviceRGB()
let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
guard let context = CGContext(data: nil, width: imageWidth, height: imageHeight, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: bitmapInfo) else { exit(1) }

context.setFillColor(.white)
context.fill(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))

let graphicsContext = NSGraphicsContext(cgContext: context, flipped: true)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphicsContext

attrString.draw(with: NSRect(x: padding, y: padding, width: maxWidth, height: textRect.height), options: [.usesLineFragmentOrigin, .usesFontLeading])

NSGraphicsContext.restoreGraphicsState()

guard let cgImage = context.makeImage() else { exit(1) }
let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else { exit(1) }

FileHandle.standardOutput.write(pngData)
