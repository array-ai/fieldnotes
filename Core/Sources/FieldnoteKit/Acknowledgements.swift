import Foundation

/// The models, data and libraries Fieldnote is built from, with who made them and
/// under what licence, shown in Settings → Acknowledgements.
///
/// Several licences require the licence text itself to travel with the app
/// (Apache 2.0, OpenMDW, MIT, BSD), so each entry names a file in
/// `Resources/Licenses`, copied into the app bundle. `AcknowledgementsTests` checks
/// that every downloadable model and every Swift package is listed here, and that
/// every file named exists.
public struct Acknowledgement: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable, CaseIterable {
        case bundledModel = "Built-in models"
        case downloadableModel = "Downloadable models"
        case data = "Data"
        case library = "Libraries"
    }

    public var id: String { name }
    public let kind: Kind
    public let name: String
    /// Who made it, and who converted it, as their licences ask to be credited.
    public let credit: String
    public let licence: String
    /// The licence text, in `Resources/Licenses`.
    public let licenceFile: String
    /// A NOTICE file the licence asks to be passed on, in `Resources/Licenses`.
    public let noticeFile: String?
    /// Where it comes from.
    public let source: URL
    /// Hugging Face repos a downloadable model is fetched from (`ModelPack.repo`).
    public let repos: [String]
    /// The Swift package identity (`Package.resolved`) for a library.
    public let package: String?

    init(
        _ kind: Kind,
        _ name: String,
        credit: String,
        licence: String,
        file: String,
        notice: String? = nil,
        source: String,
        repos: [String] = [],
        package: String? = nil
    ) {
        self.kind = kind
        self.name = name
        self.credit = credit
        self.licence = licence
        self.licenceFile = file
        self.noticeFile = notice
        self.source = URL(string: source)!
        self.repos = repos
        self.package = package
    }

    /// The folder in the app bundle, and in `Resources/`, holding the licence texts.
    public static let folder = "Licenses"

    public static let all: [Acknowledgement] = [
        // Built in
        Acknowledgement(
            .bundledModel, "Nemotron 3 Diarization",
            credit: "NVIDIA. Core ML conversion by Fluid Inference.",
            licence: "OpenMDW 1.1", file: "OpenMDW-1.1.txt",
            source: "https://huggingface.co/nvidia/Nemotron-3-Diarization"
        ),

        // Downloaded when the user asks
        Acknowledgement(
            .downloadableModel, "Parakeet TDT and CTC",
            credit: "NVIDIA. Core ML conversions by Fluid Inference.",
            licence: "CC BY 4.0", file: "CC-BY-4.0.txt",
            source: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3",
            repos: [
                "FluidInference/parakeet-tdt-0.6b-v3-coreml", "FluidInference/parakeet-tdt-0.6b-v2-coreml",
                "FluidInference/parakeet-tdt-ctc-110m-coreml", "FluidInference/parakeet-ctc-110m-coreml"
            ]
        ),
        Acknowledgement(
            .downloadableModel, "Nemotron 3.5 ASR Streaming",
            credit: "NVIDIA. Core ML conversion by Fluid Inference.",
            licence: "OpenMDW 1.1", file: "OpenMDW-1.1.txt",
            source: "https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b",
            repos: ["FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML"]
        ),
        Acknowledgement(
            .downloadableModel, "MiniCPM5 1B and 2B",
            credit: "OpenBMB. Core AI export by mlboydaisuke; chip-specific builds compiled by publicarray.",
            licence: "Apache 2.0", file: "Apache-2.0.txt",
            source: "https://huggingface.co/openbmb/MiniCPM5-2B",
            repos: ["mlboydaisuke/MiniCPM5-1B-CoreAI", "mlboydaisuke/MiniCPM5-2B-CoreAI", "publicarray/fieldnote-models"]
        ),
        Acknowledgement(
            .downloadableModel, "Qwen3.5 2B",
            credit: "Qwen team, Alibaba Cloud. Core AI export by mlboydaisuke; chip-specific builds compiled by publicarray.",
            licence: "Apache 2.0", file: "Apache-2.0.txt",
            source: "https://huggingface.co/Qwen/Qwen3.5-2B",
            repos: ["mlboydaisuke/qwen3.5-2B-CoreAI", "publicarray/fieldnote-models"]
        ),
        Acknowledgement(
            .downloadableModel, "pyannote community-1",
            credit: "pyannote, WeSpeaker and BUT Speech@FIT. Modified: converted to Core ML by Fluid Inference.",
            licence: "CC BY 4.0", file: "CC-BY-4.0.txt",
            source: "https://huggingface.co/pyannote/speaker-diarization-community-1",
            repos: ["FluidInference/speaker-diarization-coreml"]
        ),

        // Data
        Acknowledgement(
            .data, "GeoNames place names",
            credit: "GeoNames. Modified: reduced to populated places and packed into the app's offline place table.",
            licence: "CC BY 4.0", file: "CC-BY-4.0.txt",
            source: "https://www.geonames.org"
        ),

        // Swift packages
        Acknowledgement(
            .library, "FluidAudio", credit: "Fluid Inference.",
            licence: "Apache 2.0", file: "Apache-2.0.txt",
            source: "https://github.com/FluidInference/FluidAudio", package: "fluidaudio"
        ),
        Acknowledgement(
            .library, "Core AI Models", credit: "Apple Inc.",
            licence: "BSD 3-Clause", file: "coreai-models.txt",
            source: "https://github.com/apple/coreai-models", package: "coreai-models"
        ),
        Acknowledgement(
            .library, "swift-transformers", credit: "Hugging Face.",
            licence: "Apache 2.0", file: "Apache-2.0.txt",
            source: "https://github.com/huggingface/swift-transformers", package: "swift-transformers"
        ),
        Acknowledgement(
            .library, "swift-huggingface", credit: "Hugging Face.",
            licence: "Apache 2.0", file: "Apache-2.0.txt",
            source: "https://github.com/huggingface/swift-huggingface", package: "swift-huggingface"
        ),
        Acknowledgement(
            .library, "swift-jinja", credit: "Hugging Face.",
            licence: "Apache 2.0", file: "Apache-2.0.txt",
            source: "https://github.com/huggingface/swift-jinja", package: "swift-jinja"
        ),
        Acknowledgement(
            .library, "XGrammar", credit: "XGrammar contributors.",
            licence: "Apache 2.0", file: "Apache-2.0.txt", notice: "xgrammar-NOTICE.txt",
            source: "https://github.com/mlc-ai/xgrammar", package: "xgrammar"
        ),
        Acknowledgement(
            .library, "yyjson", credit: "YaoYuan.",
            licence: "MIT", file: "yyjson.txt",
            source: "https://github.com/ibireme/yyjson", package: "yyjson"
        ),
        Acknowledgement(
            .library, "EventSource", credit: "Mattt.",
            licence: "MIT", file: "EventSource.txt",
            source: "https://github.com/mattt/EventSource", package: "eventsource"
        ),
        Acknowledgement(
            .library, "Swift Collections", credit: "Apple Inc. and the Swift project authors.",
            licence: "Apache 2.0", file: "Apache-2.0.txt",
            source: "https://github.com/apple/swift-collections", package: "swift-collections"
        ),
        Acknowledgement(
            .library, "Swift Crypto", credit: "Apple Inc. and the Swift project authors.",
            licence: "Apache 2.0", file: "Apache-2.0.txt", notice: "swift-crypto-NOTICE.txt",
            source: "https://github.com/apple/swift-crypto", package: "swift-crypto"
        ),
        Acknowledgement(
            .library, "Swift ASN.1", credit: "Apple Inc. and the Swift project authors.",
            licence: "Apache 2.0", file: "Apache-2.0.txt", notice: "swift-asn1-NOTICE.txt",
            source: "https://github.com/apple/swift-asn1", package: "swift-asn1"
        ),
    ]
}
