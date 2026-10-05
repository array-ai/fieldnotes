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
        case parakeetV2
        case parakeetTdtCtc110m
        case nemotronStreaming
        case minicpm5
        // MiniCPM5 compiled ahead of time for one Core AI chip family each (our
        // compile-models workflow): the phone downloads a ready model. h17g/h17p are
        // the iPhone 16 family, h18p the iPhone 17 Pro.
        case minicpm5H17g
        case minicpm5H17p
        case minicpm5H18p
        // MiniCPM5 2B: the portable model, and the build compiled for h17p.
        case minicpm5_2b
        case minicpm5_2bH17p
        case pyannoteCommunity1

        /// The build of this model compiled for a Core AI chip family
        /// (`AIModel.deviceArchitectureName`, e.g. "h17g"), if one is offered.
        public func compiled(for architecture: String?) -> ID? {
            guard let architecture, let first = architecture.first else { return nil }
            return ID(rawValue: rawValue + first.uppercased() + String(architecture.dropFirst()))
        }
    }

    public let id: ID
    public let name: String
    public let repo: String
    public let revision: String
    public let license: String
    public let files: [ModelFile]

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    /// The folder holding the model bundle's own `metadata.json` inside the download
    /// ("ios-static", "minicpm5-2b/ios-h17p"): the pack keeps the repo's layout. Nil
    /// when it's at the top, or the pack isn't a language-model bundle.
    public var bundleFolder: String? {
        let metadata = files.map(\.path)
            .filter { $0 == "metadata.json" || $0.hasSuffix("/metadata.json") }
            .min { $0.split(separator: "/").count < $1.split(separator: "/").count }
        guard let metadata, metadata.contains("/") else { return nil }
        return String(metadata.dropLast("/metadata.json".count))
    }

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
