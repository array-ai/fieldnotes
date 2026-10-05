import Foundation

/// A model the user can download on request, pinned to one Hugging Face revision.
///
/// Fieldnote bundles only what it needs by default (Nemotron 3 for speakers, Apple's
/// built-in speech model for transcripts). These are optional: a bigger, more
/// accurate transcription model, and the older speaker models for comparison. They
/// are fetched only when the user taps Download, only from the revision below, and
/// each file is checked against its SHA-256 before it is used.
public struct ModelPack: Sendable, Identifiable, Equatable {

    public enum ID: String, Sendable, CaseIterable {
        case parakeetV3
        case pyannoteCommunity1
        case pyannoteLegacy
    }

    public let id: ID
    public let name: String
    public let repo: String
    public let revision: String
    public let license: String
    public let files: [ModelFile]

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    /// Where a file comes from: this exact revision, never `main`.
    public func url(for file: ModelFile) -> URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(file.path)")!
    }

    public static func pack(_ id: ID) -> ModelPack {
        // The catalog is generated with every ID present; a missing one is a build bug.
        guard let pack = catalog.first(where: { $0.id == id }) else {
            preconditionFailure("No model pack \(id.rawValue) in ModelCatalogData.swift")
        }
        return pack
    }
}

public struct ModelFile: Sendable, Equatable {
    /// Path inside the pack, e.g. "Encoder.mlmodelc/weights/weight.bin".
    public let path: String
    public let size: Int64
    /// Lowercase hex.
    public let sha256: String
}

extension Int64 {
    /// "483 MB", "1.2 GB".
    public var byteCountDescription: String {
        let mb = Double(self) / 1_000_000
        return mb >= 1_000 ? String(format: "%.1f GB", mb / 1_000) : String(format: "%.0f MB", mb)
    }
}
