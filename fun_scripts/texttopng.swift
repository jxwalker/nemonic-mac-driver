import AppKit
import CoreGraphics

let args = CommandLine.arguments.dropFirst()
let text: String
if args.isEmpty {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    text = String(data: data, encoding: .utf8) ?? ""
} else {
    text = args.joined(separator: "\n")
}

if text.isEmpty { exit(1) }

let lines = text
    .replacingOccurrences(of: "\r\n", with: "\n")
    .replacingOccurrences(of: "\r", with: "\n")
    .split(separator: "\n", omittingEmptySubsequences: false)
    .map(String.init)

let padding: CGFloat = 18
let maxPageWidth: CGFloat = 540
let preferredTextWidth: CGFloat = 320
let maxFontSize: CGFloat = 48
let minFontSize: CGFloat = 20
let lineSpacing: CGFloat = 6

func makeAttributes(fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
    [
        .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold),
        .foregroundColor: NSColor.black
    ]
}

func lineWidth(_ line: String, attributes: [NSAttributedString.Key: Any]) -> CGFloat {
    ceil((line as NSString).size(withAttributes: attributes).width)
}

func isPreformatted(_ line: String) -> Bool {
    if line.isEmpty { return true }
    if line.first?.isWhitespace == true { return true }

    let letters = line.filter { $0.isLetter }.count
    let spaces = line.filter { $0.isWhitespace }.count
    let symbols = line.count - letters - spaces

    if letters == 0 { return true }
    return symbols > letters
}

func wrapLine(_ line: String, maxWidth: CGFloat, attributes: [NSAttributedString.Key: Any]) -> [String] {
    if line.isEmpty || isPreformatted(line) || lineWidth(line, attributes: attributes) <= maxWidth {
        return [line]
    }

    let words = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    var wrapped: [String] = []
    var current = ""

    for word in words {
        let candidate = current.isEmpty ? word : "\(current) \(word)"
        if lineWidth(candidate, attributes: attributes) <= maxWidth {
            current = candidate
        } else {
            if !current.isEmpty {
                wrapped.append(current)
                current = word
            } else {
                wrapped.append(word)
            }
        }
    }

    if !current.isEmpty {
        wrapped.append(current)
    }

    return wrapped
}

func wrappedLines(attributes: [NSAttributedString.Key: Any]) -> [String] {
    let contentMaxWidth = min(maxPageWidth - padding * 2, preferredTextWidth)
    return lines.flatMap { wrapLine($0, maxWidth: contentMaxWidth, attributes: attributes) }
}

func longestLineWidth(lines: [String], attributes: [NSAttributedString.Key: Any]) -> CGFloat {
    lines.reduce(0) { currentMax, line in
        max(currentMax, ceil((line as NSString).size(withAttributes: attributes).width))
    }
}

var fontSize = maxFontSize
var attributes = makeAttributes(fontSize: fontSize)
var layoutLines = wrappedLines(attributes: attributes)
var contentWidth = longestLineWidth(lines: layoutLines, attributes: attributes)

while contentWidth > (maxPageWidth - padding * 2) && fontSize > minFontSize {
    fontSize -= 1
    attributes = makeAttributes(fontSize: fontSize)
    layoutLines = wrappedLines(attributes: attributes)
    contentWidth = longestLineWidth(lines: layoutLines, attributes: attributes)
}

guard let font = attributes[.font] as? NSFont else { exit(1) }
let lineHeight = ceil(font.ascender - font.descender + font.leading + lineSpacing)
let contentHeight = max(lineHeight, CGFloat(layoutLines.count) * lineHeight)

let pageWidth = ceil(min(maxPageWidth, max(contentWidth + padding * 2, 72)))
let pageHeight = ceil(max(contentHeight + padding * 2, 72))

let pdfData = NSMutableData()
guard let consumer = CGDataConsumer(data: pdfData as CFMutableData) else { exit(1) }
var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { exit(1) }

context.beginPDFPage(nil)
context.setFillColor(NSColor.white.cgColor)
context.fill(mediaBox)

let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphicsContext

for (index, line) in layoutLines.enumerated() {
    let baselineY = pageHeight - padding - font.ascender - (CGFloat(index) * lineHeight)
    (line as NSString).draw(at: NSPoint(x: padding, y: baselineY), withAttributes: attributes)
}

NSGraphicsContext.restoreGraphicsState()
context.endPDFPage()
context.closePDF()

FileHandle.standardOutput.write(pdfData as Data)
