import CoreGraphics
import CoreText
import FieldnoteKit
import Foundation

/// PDF generated from the Markdown export, via CoreText so one implementation covers
/// iOS and macOS.
///
/// Speaker colours survive into the PDF (spec 6.2): each speaker gets a stable colour
/// from the same palette the transcript view uses, so a printed transcript reads the
/// same way as the screen.
public struct PDFRenderer: Sendable {

    public struct Style: Sendable {
        public var pageSize: CGSize = CGSize(width: 595, height: 842) // A4 at 72 dpi
        public var margin: CGFloat = 48
        public var bodyFontSize: CGFloat = 11
        public var titleFontSize: CGFloat = 20
        public var headingFontSize: CGFloat = 14

        public init() {}
    }

    public var style: Style

    public init(style: Style = Style()) {
        self.style = style
    }

    public func render(markdown: String, speakerColours: [String: CGColor] = [:], to url: URL) throws {
        let attributed = attributedString(from: markdown, speakerColours: speakerColours)
        var mediaBox = CGRect(origin: .zero, size: style.pageSize)

        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw PDFError.cannotCreateContext
        }

        let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
        let textBounds = mediaBox.insetBy(dx: style.margin, dy: style.margin)
        let path = CGPath(rect: textBounds, transform: nil)

        var start = 0
        let length = attributed.length
        while start < length {
            context.beginPDFPage(nil)
            context.textMatrix = .identity
            // CoreText draws bottom-up; the PDF context is already in that space.
            let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(start, 0), path, nil)
            CTFrameDraw(frame, context)
            let visible = CTFrameGetVisibleStringRange(frame)
            context.endPDFPage()

            guard visible.length > 0 else { break }
            start += visible.length
        }
        context.closePDF()
        try? FieldnoteStorage.protect(url)
    }

    // MARK: - Markdown to attributed text

    func attributedString(from markdown: String, speakerColours: [String: CGColor]) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for line in markdown.components(separatedBy: .newlines) {
            output.append(attributed(line: line, speakerColours: speakerColours))
            output.append(NSAttributedString(string: "\n"))
        }
        return output
    }

    private func attributed(line: String, speakerColours: [String: CGColor]) -> NSAttributedString {
        if line.hasPrefix("# ") {
            return NSAttributedString(string: String(line.dropFirst(2)), attributes: attributes(size: style.titleFontSize, bold: true))
        }
        if line.hasPrefix("## ") {
            return NSAttributedString(string: String(line.dropFirst(3)), attributes: attributes(size: style.headingFontSize, bold: true))
        }

        let plain = PlainTextRenderer.from(markdown: line)
        var attributes = attributes(size: style.bodyFontSize, bold: false)

        // Transcript lines start "**[0:12] Dave:**". Colour by speaker name.
        if let speaker = Self.speakerName(inTranscriptLine: line), let colour = speakerColours[speaker] {
            attributes[kCTForegroundColorAttributeName as NSAttributedString.Key] = colour
        }
        return NSAttributedString(string: plain, attributes: attributes)
    }

    static func speakerName(inTranscriptLine line: String) -> String? {
        guard line.hasPrefix("**") else { return nil }
        let body = line.dropFirst(2)
        guard let colon = body.firstIndex(of: ":") else { return nil }
        var name = String(body[body.startIndex..<colon])
        if let close = name.firstIndex(of: "]") {
            name = String(name[name.index(after: close)...])
        }
        return name.trimmingCharacters(in: .whitespaces).nilIfEmpty
    }

    /// CoreText attribute keys, not UIKit ones. `NSAttributedString.Key.font` and
    /// `.foregroundColor` expect UIFont and UIColor on iOS; CoreText's equivalents
    /// take CTFont and CGColor, which is what this renderer has and what keeps it
    /// free of UIKit and AppKit.
    private func attributes(size: CGFloat, bold: Bool) -> [NSAttributedString.Key: Any] {
        let font = CTFontCreateWithName(
            (bold ? "Helvetica-Bold" : "Helvetica") as CFString,
            size,
            nil
        )
        return [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTParagraphStyleAttributeName as NSAttributedString.Key: paragraphStyle(size: size)
        ]
    }

    private func paragraphStyle(size: CGFloat) -> CTParagraphStyle {
        var paragraphSpacing = size * 0.6
        var lineSpacing = size * 0.25
        return withUnsafePointer(to: &paragraphSpacing) { spacing in
            withUnsafePointer(to: &lineSpacing) { line in
                let settings = [
                    CTParagraphStyleSetting(
                        spec: .paragraphSpacing,
                        valueSize: MemoryLayout<CGFloat>.size,
                        value: spacing
                    ),
                    CTParagraphStyleSetting(
                        spec: .lineSpacingAdjustment,
                        valueSize: MemoryLayout<CGFloat>.size,
                        value: line
                    )
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
    }

    public enum PDFError: Error, LocalizedError {
        case cannotCreateContext
        public var errorDescription: String? { "The PDF could not be created." }
    }
}

extension SpeakerPalette {
    /// The CoreGraphics form, for the PDF path. The palette itself lives in
    /// FieldnoteKit so the UI and the exports agree without importing CoreGraphics.
    public static func cgColor(for label: String, among labels: [String]) -> CGColor {
        let colour = colours[index(for: label, among: labels)]
        return CGColor(
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            components: [colour.red, colour.green, colour.blue, 1]
        ) ?? CGColor(gray: 0, alpha: 1)
    }
}
