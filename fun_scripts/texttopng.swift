import Cocoa

// This utility safely renders text to a PNG image outside the CUPS sandbox, 
// bypassing the macOS `cgtexttopdf` empty-PDF bug.
let args = CommandLine.arguments.dropFirst()
var text = ""
if args.isEmpty {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    text = String(data: data, encoding: .utf8) ?? ""
} else {
    text = args.joined(separator: "\n")
}

if text.isEmpty { exit(1) }

let font = NSFont.monospacedSystemFont(ofSize: 32, weight: .bold)
let attributes: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor.black
]
let attrString = NSAttributedString(string: text, attributes: attributes)
let textSize = attrString.size()

let padding: CGFloat = 20
let imageSize = NSSize(width: textSize.width + padding*2, height: textSize.height + padding*2)

let image = NSImage(size: imageSize)
image.lockFocus()
NSColor.white.set()
NSRect(origin: .zero, size: imageSize).fill()
attrString.draw(at: NSPoint(x: padding, y: padding))
image.unlockFocus()

guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { exit(1) }
let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else { exit(1) }

FileHandle.standardOutput.write(pngData)
