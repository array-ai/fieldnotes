import FieldnoteKit
import Foundation
import Testing

// @testable: BackupArchive's payload types are app-internal, and giving them public
// memberwise initialisers just to satisfy a test would be the tail wagging the dog.
@testable import Fieldnote

@Suite("Backup archive")
struct BackupArchiveTests {

    private func payload() -> BackupArchive.Payload {
        let segment = TranscriptSegment(start: 0, end: 3, text: "Hello", speakerID: "S1")
        return BackupArchive.Payload(
            manifest: .init(createdAt: Date(), meetingCount: 1, includesAudio: false),
            meetings: [
                BackupArchive.MeetingBackup(
                    id: UUID(),
                    title: "Test meeting",
                    type: .siteVisit,
                    startedAt: Date(),
                    duration: 60,
                    localeIdentifier: "en_AU",
                    folderName: "Client",
                    segments: [segment],
                    speakerNames: ["S1": "Dave"],
                    speakerEmbeddings: ["S1": [0.1, 0.2, 0.3]],
                    summary: MeetingSummary(overview: "Short meeting.")
                )
            ]
        )
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).fieldnote")
    }

    @Test("An archive round-trips with the right passphrase")
    func roundTrip() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try BackupArchive.write(payload(), passphrase: "correct horse battery", to: url)
        let restored = try BackupArchive.read(from: url, passphrase: "correct horse battery")

        #expect(restored.meetings.count == 1)
        #expect(restored.meetings[0].title == "Test meeting")
        #expect(restored.meetings[0].speakerEmbeddings["S1"] == [0.1, 0.2, 0.3])
    }

    @Test("A wrong passphrase fails cleanly rather than returning junk")
    func wrongPassphrase() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try BackupArchive.write(payload(), passphrase: "correct horse battery", to: url)
        #expect(throws: BackupArchive.ArchiveError.self) {
            _ = try BackupArchive.read(from: url, passphrase: "wrong")
        }
    }

    @Test("The archive on disk does not contain the meeting text in the clear")
    func contentIsEncrypted() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try BackupArchive.write(payload(), passphrase: "correct horse battery", to: url)
        let raw = try Data(contentsOf: url)
        #expect(raw.range(of: Data("Test meeting".utf8)) == nil)
    }

    @Test("A file that is not an archive is rejected by its header")
    func notAnArchive() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("just some text".utf8).write(to: url)

        #expect(throws: BackupArchive.ArchiveError.self) {
            _ = try BackupArchive.read(from: url, passphrase: "anything")
        }
    }
}
