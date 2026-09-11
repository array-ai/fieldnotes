import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The four share payloads (spec 6.1), each independently shareable, plus the
/// composed export (spec 6.2).
public enum SharePayload: String, Sendable, CaseIterable, Identifiable {
    case summary
    case tasks
    case transcript
    case audio

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .summary: "Summary"
        case .tasks: "Tasks"
        case .transcript: "Transcript"
        case .audio: "Audio"
        }
    }

    public var formats: [ShareFormat] {
        switch self {
        case .summary: [.markdown, .richText, .plainText, .pdf]
        case .tasks: [.markdown, .plainText]
        case .transcript: [.markdown, .plainText, .pdf, .webVTT, .srt]
        case .audio: [.audio]
        }
    }

    /// Audio is the rawest form of client data. Once it is in the share sheet it is
    /// gone from your control (spec 6.1), so the UI warns before this one.
    public var warnsBeforeSharing: Bool { self == .audio }
}

public enum ShareFormat: String, Sendable, Identifiable {
    case markdown
    case plainText
    case richText
    case pdf
    case webVTT
    case srt
    case audio

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .markdown: "Markdown"
        case .plainText: "Plain text"
        case .richText: "Rich text"
        case .pdf: "PDF"
        case .webVTT: "WebVTT"
        case .srt: "SRT"
        case .audio: "m4a"
        }
    }

    var fileExtension: String {
        switch self {
        case .markdown: "md"
        case .plainText: "txt"
        case .richText: "rtf"
        case .pdf: "pdf"
        case .webVTT: "vtt"
        case .srt: "srt"
        case .audio: "m4a"
        }
    }
}

/// Builds share files on demand into a temporary directory.
///
/// Everything leaves Fieldnote through the system share sheet. There are no
/// integrations and no API clients: the share sheet already reaches Mail, Messages,
/// Teams, Slack, Notes, Files, Drive, AirDrop, and any PSA app with a share
/// extension, and it costs nothing to maintain when those apps change (spec 6).
public actor ShareBuilder {

    private let renderer: MarkdownRenderer

    public init(renderer: MarkdownRenderer = MarkdownRenderer()) {
        self.renderer = renderer
    }

    public func makeFile(
        meeting: MeetingSnapshot,
        payload: SharePayload,
        format: ShareFormat
    ) async throws -> URL {
        let directory = try exportDirectory(for: meeting.id)
        let suffix = payload == .summary ? nil : payload.displayName.lowercased()
        let url = directory.appendingPathComponent(
            ExportFilename.name(
                date: meeting.startedAt,
                folder: meeting.folderName,
                title: meeting.title,
                suffix: suffix,
                fileExtension: format.fileExtension
            )
        )

        switch (payload, format) {
        case (.audio, _):
            let chunks = ChunkedAudioWriter.existingChunks(in: meeting.audioDirectory)
            return try await AudioExporter.exportSingleFile(chunks: chunks, to: url)

        case (.transcript, .webVTT):
            try write(SubtitleRenderer.webVTT(segments: meeting.segments, speakerNames: meeting.speakerNames), to: url)

        case (.transcript, .srt):
            try write(SubtitleRenderer.srt(segments: meeting.segments, speakerNames: meeting.speakerNames), to: url)

        default:
            let markdown = markdown(for: meeting, payload: payload)
            try writeText(markdown, format: format, meeting: meeting, to: url)
        }
        return url
    }

    /// The composed export: pick sections, optionally attach audio (spec 6.2).
    public func makeComposedFiles(
        meeting: MeetingSnapshot,
        sections: MarkdownRenderer.Sections,
        format: ShareFormat,
        includeAudio: Bool
    ) async throws -> [URL] {
        let directory = try exportDirectory(for: meeting.id)
        let url = directory.appendingPathComponent(
            ExportFilename.name(
                date: meeting.startedAt,
                folder: meeting.folderName,
                title: meeting.title,
                fileExtension: format.fileExtension
            )
        )
        try writeText(renderer.render(meeting, sections: sections), format: format, meeting: meeting, to: url)

        var urls = [url]
        if includeAudio {
            urls.append(try await makeFile(meeting: meeting, payload: .audio, format: .audio))
        }
        return urls
    }

    /// Whole-folder export to one file, skipping anything still processing (spec 6.2).
    public func makeFolderExport(
        name: String,
        meetings: [MeetingSnapshot],
        sections: MarkdownRenderer.Sections,
        format: ShareFormat
    ) throws -> URL {
        let directory = try exportDirectory(for: nil)
        let filename = ExportFilename.name(
            date: Date(),
            folder: nil,
            title: name,
            fileExtension: format.fileExtension
        )
        let url = directory.appendingPathComponent(filename)
        let markdown = renderer.renderFolder(name: name, meetings: meetings, sections: sections)
        switch format {
        case .pdf:
            try PDFRenderer().render(markdown: markdown, to: url)
        case .plainText:
            try write(PlainTextRenderer.from(markdown: markdown), to: url)
        default:
            try write(markdown, to: url)
        }
        return url
    }

    // MARK: - Plumbing

    private func markdown(for meeting: MeetingSnapshot, payload: SharePayload) -> String {
        switch payload {
        case .summary: renderer.renderSummary(meeting)
        case .tasks: renderer.renderTasks(meeting)
        case .transcript: renderer.renderTranscript(meeting)
        case .audio: ""
        }
    }

    private func writeText(_ markdown: String, format: ShareFormat, meeting: MeetingSnapshot, to url: URL) throws {
        switch format {
        case .plainText:
            try write(PlainTextRenderer.from(markdown: markdown), to: url)
        case .pdf:
            let labels = Array(meeting.speakerNames.keys)
            let colours = Dictionary(uniqueKeysWithValues: meeting.speakerNames.map { label, name in
                (name, SpeakerPalette.cgColor(for: label, among: labels))
            })
            try PDFRenderer().render(markdown: markdown, speakerColours: colours, to: url)
        case .richText:
            try writeRichText(markdown, to: url)
        default:
            try write(markdown, to: url)
        }
    }

    private func writeRichText(_ markdown: String, to url: URL) throws {
        #if canImport(UIKit) || canImport(AppKit)
        let attributed = try NSAttributedString(
            markdown: Data(markdown.utf8),
            options: .init(interpretedSyntax: .full)
        )
        let data = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        #else
        try write(markdown, to: url)
        #endif
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    /// Exports live in a per-meeting temp directory that is cleared each time, so a
    /// stale file from a previous share is never the thing that gets sent.
    private func exportDirectory(for meetingID: UUID?) throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("Exports", conformingTo: .directory)
            .appendingPathComponent(meetingID?.uuidString ?? "folders", conformingTo: .directory)
        try? FileManager.default.removeItem(at: base)
        return try FieldnoteStorage.ensureDirectory(base)
    }
}
