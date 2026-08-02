import Foundation

public enum SpeechRecognizerError: Error, Sendable {
    case modelUnavailable(String)
    case inferenceFailed(String)
}

/// Transcribes one audio segment.
///
/// Step 2/3 add `WhisperSpeechRecognizer` behind this protocol: whisper.cpp with a
/// Core ML encoder on the Neural Engine, running the Quran-tuned Tarteel model.
/// Implementations must emit **token-level timestamps** — v2 tajweed depends on them,
/// so a recognizer that only returns flat text is not sufficient.
public protocol SpeechRecognizer: Sendable {
    func transcribe(_ chunk: AudioChunk) async throws -> Transcription
}

/// Which ASR weights to load. Kept configurable so the model can be traded down to
/// `tiny` on iOS (app-size sensitive) or up on macOS.
public struct SpeechModelConfiguration: Sendable, Equatable {
    public enum Size: String, Sendable, CaseIterable {
        case tiny, base, small, medium
    }

    public var size: Size
    /// Quantisation suffix used by the whisper.cpp GGML file, e.g. `q8_0`.
    public var quantization: String?
    /// Load the Core ML encoder and run it on the Neural Engine.
    public var useCoreMLEncoder: Bool
    /// Forced decode language. Fixed to Arabic — the target text is always Arabic, and
    /// letting the model auto-detect invites nonsense transcriptions on short chunks.
    public var language: String

    public init(
        size: Size = .base,
        quantization: String? = "q8_0",
        useCoreMLEncoder: Bool = true,
        language: String = "ar"
    ) {
        self.size = size
        self.quantization = quantization
        self.useCoreMLEncoder = useCoreMLEncoder
        self.language = language
    }

    /// Filename stem the conversion scripts produce, e.g. `ggml-base-ar-quran-q8_0`.
    public var modelStem: String {
        let base = "ggml-\(size.rawValue)-ar-quran"
        guard let quantization else { return base }
        return "\(base)-\(quantization)"
    }

    public static let `default` = SpeechModelConfiguration()
}

/// v1 stand-in: replays a canned transcript, one segment at a time, ignoring the audio.
///
/// This exists so the whole pipeline — capture, segmentation, alignment, highlighting —
/// can be exercised and tested before whisper.cpp is wired up. Feed it a transcript
/// containing deliberate mistakes to see the aligner's verdicts end to end.
public actor ScriptedSpeechRecognizer: SpeechRecognizer {
    private let scripts: [String]
    private var cursor = 0

    public init(scripts: [String]) {
        self.scripts = scripts
    }

    /// Splits a whole transcript into `segmentCount` roughly equal word groups.
    public init(transcript: String, segmentCount: Int) {
        let words = transcript.split(whereSeparator: \.isWhitespace).map(String.init)
        guard segmentCount > 0, !words.isEmpty else {
            self.scripts = []
            return
        }
        let perSegment = Int((Double(words.count) / Double(segmentCount)).rounded(.up))
        self.scripts = stride(from: 0, to: words.count, by: max(perSegment, 1)).map { start in
            words[start..<min(start + perSegment, words.count)].joined(separator: " ")
        }
    }

    public func transcribe(_ chunk: AudioChunk) async throws -> Transcription {
        guard cursor < scripts.count else { return .empty }
        let text = scripts[cursor]
        cursor += 1

        // Spread tokens evenly across the chunk so downstream timing code has something
        // plausible to work with. The real recognizer supplies true timestamps.
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return .empty }
        let perWord = chunk.duration / Double(words.count)
        let tokens = words.enumerated().map { index, word in
            TranscribedToken(
                text: word,
                startTime: chunk.startTime + Double(index) * perWord,
                endTime: chunk.startTime + Double(index + 1) * perWord,
                confidence: 0.9
            )
        }
        return Transcription(text: text, tokens: tokens)
    }

    public func reset() {
        cursor = 0
    }
}
