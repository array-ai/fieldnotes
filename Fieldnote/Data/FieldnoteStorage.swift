import Foundation

/// Where things live on disk, and with what protection.
///
/// Everything Fieldnote writes is client meeting material, so it all gets
/// `.completeUnlessOpen`: readable while a recording or a processing task holds it
/// open, sealed once the device locks and the file is closed.
public enum FieldnoteStorage {

    public static var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Fieldnote", conformingTo: .directory)
    }

    /// User-visible via the Files app (`LSSupportsOpeningDocumentsInPlace`), so the
    /// user can always get their own audio out by hand (spec 6.4).
    public static var meetingsDirectory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Meetings", conformingTo: .directory)
    }

    public static func meetingDirectory(for meetingID: UUID) -> URL {
        meetingsDirectory.appendingPathComponent(meetingID.uuidString, conformingTo: .directory)
    }

    /// Chunked audio lands here during recording, one file per chunk.
    public static func audioChunkDirectory(for meetingID: UUID) -> URL {
        meetingDirectory(for: meetingID).appendingPathComponent("audio", conformingTo: .directory)
    }

    /// Stage checkpoints, so a killed background task resumes rather than restarts.
    public static func checkpointDirectory(for meetingID: UUID) -> URL {
        meetingDirectory(for: meetingID).appendingPathComponent("checkpoints", conformingTo: .directory)
    }

    @discardableResult
    public static func ensureDirectory(_ url: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) {
            if isDirectory.boolValue { return url }
            throw CocoaError(.fileWriteFileExists)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [
            .protectionKey: FileProtectionType.completeUnlessOpen
        ])
        return url
    }

    /// Applies the file-protection class to something already written.
    public static func protect(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUnlessOpen],
            ofItemAtPath: url.path(percentEncoded: false)
        )
    }

    public static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }
}
