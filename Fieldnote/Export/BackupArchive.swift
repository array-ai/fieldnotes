import CommonCrypto
import CryptoKit
import Foundation

/// One encrypted archive the user holds and stores wherever they choose (spec 6.5).
/// No cloud, no sync service, nothing to sign in to.
///
/// AES-GCM under a key derived from the user's passphrase with PBKDF2-HMAC-SHA256.
/// The passphrase is never stored: a lost passphrase means a lost archive, which is
/// the correct trade for a file full of client meetings.
public enum BackupArchive {

    public struct Manifest: Codable, Sendable {
        public var version: Int = 1
        public var createdAt: Date
        public var meetingCount: Int
        public var includesAudio: Bool
    }

    public struct Payload: Codable, Sendable {
        public var manifest: Manifest
        public var meetings: [MeetingBackup]
    }

    public struct MeetingBackup: Codable, Sendable {
        public var id: UUID
        public var title: String
        public var type: MeetingType
        public var startedAt: Date
        public var duration: TimeInterval
        public var localeIdentifier: String
        public var folderName: String?
        public var segments: [TranscriptSegment]
        public var speakerNames: [String: String]
        /// Raw cluster embeddings, carried so a restored device can still build the
        /// v2 speaker registry (spec 11.3) from historical meetings.
        public var speakerEmbeddings: [String: [Float]]
        public var summary: MeetingSummary?
    }

    // MARK: - Write

    public static func write(_ payload: Payload, passphrase: String, to url: URL) throws {
        let plaintext = try JSONEncoder.backup.encode(payload)
        let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        let key = try deriveKey(passphrase: passphrase, salt: salt)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else { throw ArchiveError.encryptionFailed }

        // salt ‖ nonce ‖ ciphertext ‖ tag, with a short magic header so a wrong file
        // fails with a clear message rather than a decryption error.
        var output = Data("FIELDNOTE1".utf8)
        output.append(salt)
        output.append(combined)
        try output.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    // MARK: - Read

    public static func read(from url: URL, passphrase: String) throws -> Payload {
        let data = try Data(contentsOf: url)
        let magic = Data("FIELDNOTE1".utf8)
        guard data.count > magic.count + 16, data.prefix(magic.count) == magic else {
            throw ArchiveError.notAFieldnoteArchive
        }
        let body = data.dropFirst(magic.count)
        let salt = body.prefix(16)
        let sealedData = body.dropFirst(16)

        let key = try deriveKey(passphrase: passphrase, salt: Data(salt))
        do {
            let box = try AES.GCM.SealedBox(combined: Data(sealedData))
            let plaintext = try AES.GCM.open(box, using: key)
            return try JSONDecoder.backup.decode(Payload.self, from: plaintext)
        } catch is CryptoKitError {
            throw ArchiveError.wrongPassphrase
        }
    }

    // MARK: - Key derivation

    static func deriveKey(passphrase: String, salt: Data, rounds: UInt32 = 310_000) throws -> SymmetricKey {
        var derived = Data(count: 32)
        let passphraseData = Data(passphrase.utf8)

        let status = derived.withUnsafeMutableBytes { derivedBytes -> Int32 in
            salt.withUnsafeBytes { saltBytes -> Int32 in
                passphraseData.withUnsafeBytes { passphraseBytes -> Int32 in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passphraseBytes.baseAddress?.assumingMemoryBound(to: CChar.self),
                        passphraseData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        rounds,
                        derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        32
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw ArchiveError.keyDerivationFailed }
        return SymmetricKey(data: derived)
    }

    public enum ArchiveError: Error, LocalizedError {
        case encryptionFailed
        case keyDerivationFailed
        case notAFieldnoteArchive
        case wrongPassphrase

        public var errorDescription: String? {
            switch self {
            case .encryptionFailed: "The archive could not be encrypted."
            case .keyDerivationFailed: "The passphrase could not be processed."
            case .notAFieldnoteArchive: "That file is not a Fieldnote archive."
            case .wrongPassphrase: "Wrong passphrase, or the archive is damaged."
            }
        }
    }
}

extension JSONEncoder {
    static var backup: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var backup: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
