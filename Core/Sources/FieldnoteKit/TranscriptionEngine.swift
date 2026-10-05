import Foundation

/// Which speech model writes the transcript.
///
/// Apple's model writes the live transcript while recording. With a Parakeet model
/// selected (optional downloads), the transcript is redone after stop with that
/// model; the live text is what you see until then. Nemotron 3.5 Streaming replaces
/// Apple's model while recording, so its live transcript is the final one.
public enum TranscriptionEngine: String, Codable, CaseIterable, Sendable {
    case apple
    /// Parakeet TDT v3, multilingual. Raw value kept from when it was the only one.
    case parakeet
    case parakeetV2
    case parakeetCtc110m
    /// NVIDIA Nemotron 3.5 ASR Streaming, the Latin-script build at 2,240 ms chunks.
    case nemotronStreaming

    public static let defaultsKey = "transcriptionEngine"

    public init(storedValue: String?) {
        self = storedValue.flatMap(TranscriptionEngine.init(rawValue:)) ?? .apple
    }

    public var displayName: String { card.title }

    /// The download that provides this engine; nil for Apple's built-in model.
    public var modelPack: ModelPack.ID? {
        switch self {
        case .apple: nil
        case .parakeet: .parakeetV3
        case .parakeetV2: .parakeetV2
        case .parakeetCtc110m: .parakeetTdtCtc110m
        case .nemotronStreaming: .nemotronStreaming
        }
    }

    /// The 25 languages Parakeet TDT v3 was trained on (BCP-47 primary tags).
    public static let parakeetLanguages: Set<String> = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
        "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
    ]

    /// The languages of Nemotron 3.5's Latin-script build.
    public static let nemotronLatinLanguages: Set<String> = ["en", "es", "fr", "it", "pt", "de"]

    /// Transcribes while recording, rather than redoing the transcript after stop.
    public var runsLive: Bool { self == .apple || self == .nemotronStreaming }

    /// Whether this engine can transcribe a locale; Apple's model is used otherwise.
    public func supports(_ localeIdentifier: String) -> Bool {
        let language = Self.language(of: localeIdentifier)
        switch self {
        case .apple: return true
        case .parakeet: return Self.parakeetLanguages.contains(language)
        case .parakeetV2, .parakeetCtc110m: return language == "en"
        case .nemotronStreaming: return Self.nemotronLatinLanguages.contains(language)
        }
    }

    public static func parakeetSupports(_ localeIdentifier: String) -> Bool {
        TranscriptionEngine.parakeet.supports(localeIdentifier)
    }

    static func language(of localeIdentifier: String) -> String {
        (localeIdentifier.split(whereSeparator: { $0 == "_" || $0 == "-" }).first.map(String.init) ?? "").lowercased()
    }
}

/// What the model screens show for each model, so the choice is easy to make: a
/// one-line description, relative accuracy and speed, languages and when it runs.
///
/// Accuracy and speed are 0...1 and only meaningful relative to each other. Sources:
/// - Speech: word error rates from NVIDIA's model cards and FluidAudio's CoreML
///   benchmarks (LibriSpeech test-clean: v2 ≈1.7%, v3 ≈2.3%, TDT-CTC 110M ≈2.5–3%).
///   Apple publishes no error rate for its on-device model; its accuracy is an
///   estimate. Speed for Apple's model is from the benchmark on an iPhone 16 Pro (71×).
/// - Speakers: Nemotron 3 ≈9.5% DER on AMI (FluidInference's conversion); the
///   pyannote pipelines are older and less accurate, and in the iPhone 16 Pro
///   benchmark the legacy one also found the wrong number of speakers. Speeds are
///   from that benchmark (Nemotron 410×, community-1 215×, legacy 88× real time).
public struct ModelCard: Sendable, Equatable {
    public var title: String
    public var summary: String
    public var accuracy: Double
    public var speed: Double
    public var languages: String
    public var runs: String

    public init(title: String, summary: String, accuracy: Double, speed: Double, languages: String, runs: String) {
        self.title = title
        self.summary = summary
        self.accuracy = accuracy
        self.speed = speed
        self.languages = languages
        self.runs = runs
    }
}

extension TranscriptionEngine {
    public var card: ModelCard {
        switch self {
        case .apple:
            ModelCard(
                title: "Apple speech model",
                summary: "Built in. Live transcript while you record, in many languages.",
                accuracy: 0.6, speed: 0.7, languages: "Many languages", runs: "Live")
        case .parakeet:
            ModelCard(
                title: "Parakeet TDT v3",
                summary: "NVIDIA's multilingual model. Rewrites the transcript after you stop.",
                accuracy: 0.85, speed: 0.8, languages: "25 European languages", runs: "After stop")
        case .parakeetV2:
            ModelCard(
                title: "Parakeet TDT v2 English",
                summary: "NVIDIA's most accurate English model. Rewrites the transcript after you stop.",
                accuracy: 0.92, speed: 0.8, languages: "English only", runs: "After stop")
        case .parakeetCtc110m:
            ModelCard(
                title: "Parakeet TDT-CTC 110M",
                summary: "Small and quick English model. Half the download, slightly less accurate.",
                accuracy: 0.75, speed: 0.95, languages: "English only", runs: "After stop")
        case .nemotronStreaming:
            ModelCard(
                title: "Nemotron 3.5 Streaming",
                summary: "NVIDIA's streaming model. Writes the transcript live while you record; nothing to redo after stop.",
                accuracy: 0.85, speed: 0.9, languages: "English, Spanish, French, Italian, Portuguese, German", runs: "Live")
        }
    }
}

extension DiarizationMethod {
    public var card: ModelCard {
        switch self {
        case .nemotron3:
            ModelCard(
                title: "Nemotron 3",
                summary: "NVIDIA's end-to-end diarizer. Handles overlapping speech; can run while you record.",
                accuracy: 0.9, speed: 0.95, languages: "Up to 8 speakers", runs: "Live or after stop")
        case .pyannoteCommunity1:
            ModelCard(
                title: "pyannote community-1",
                summary: "Clusters the whole recording at once. No fixed speaker limit.",
                accuracy: 0.72, speed: 0.85, languages: "Any number of speakers", runs: "After stop")
        case .pyannoteLegacy:
            ModelCard(
                title: "pyannote 3.1 (legacy)",
                summary: "The pipeline Fieldnote first shipped with, kept for comparison.",
                accuracy: 0.55, speed: 0.6, languages: "Any number of speakers", runs: "After stop")
        }
    }
}

/// Groups timed words into transcript lines, for speech models (Parakeet) that return
/// one long run of words rather than Apple's sentence-like results.
///
/// A line ends at sentence punctuation once it has a few words, at a pause, or at a
/// maximum length — short enough to read and to cite, long enough to carry a thought.
public enum WordLines {

    public static func lines(
        from words: [TranscriptWord],
        pause: TimeInterval = 0.8,
        maxWords: Int = 40,
        minWordsBeforeSentenceBreak: Int = 4
    ) -> [TranscriptSegment] {
        var lines: [TranscriptSegment] = []
        var current: [TranscriptWord] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                lines.append(TranscriptSegment(start: first.start, end: last.end, text: text, words: current))
            }
            current = []
        }

        for word in words {
            if let last = current.last, word.start - last.end > pause { flush() }
            current.append(word)
            let ending = word.text.trimmingCharacters(in: .whitespaces)
            let endsSentence = ending.hasSuffix(".") || ending.hasSuffix("?") || ending.hasSuffix("!")
            if (endsSentence && current.count >= minWordsBeforeSentenceBreak) || current.count >= maxWords {
                flush()
            }
        }
        flush()
        return lines
    }
}
