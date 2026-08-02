import Foundation

/// One VAD-delimited chunk of speech, everything the pipeline learned about it, and —
/// critically — the audio itself.
///
/// v2 tajweed analysis is timing-and-signal math over exactly this: it needs the raw
/// samples plus the word-level time boundaries to measure madd duration, detect
/// qalqalah bursts, and find ghunnah nasalisation. So the buffer is retained here
/// rather than freed after transcription.
public struct AlignedAudioSegment: Sendable, Equatable, Identifiable {
    public let id: UUID
    /// Raw 16 kHz mono PCM for this segment, positioned on the session clock.
    public let audio: AudioChunk
    /// What the recognizer produced, with per-token timestamps.
    public let transcription: Transcription
    /// Target words this segment was judged to cover, with their verdicts.
    public let words: [WordEvaluation]

    public var startTime: TimeInterval { audio.startTime }
    public var endTime: TimeInterval { audio.endTime }

    public init(
        id: UUID = UUID(),
        audio: AudioChunk,
        transcription: Transcription,
        words: [WordEvaluation]
    ) {
        self.id = id
        self.audio = audio
        self.transcription = transcription
        self.words = words
    }

    /// Audio for a single evaluated word, if it has a known time range.
    /// This is the primary entry point for per-word DSP in `TajweedAnalyzer`.
    public func audio(for evaluation: WordEvaluation) -> AudioChunk? {
        guard let range = evaluation.timeRange else { return nil }
        let slice = audio.slice(from: range.lowerBound, to: range.upperBound)
        return slice.isEmpty ? nil : slice
    }
}

/// The pipeline's cumulative view of a recitation session.
public struct RecitationResult: Sendable, Equatable {
    public let target: RecitationTarget
    /// Per-word verdicts across the whole target.
    public let alignment: AlignmentResult
    /// Every segment so far, audio retained.
    public let segments: [AlignedAudioSegment]
    /// Advisory tajweed notes. Always empty in v1 (`NoOpTajweedAnalyzer`).
    public let tajweedNotes: [TajweedNote]

    public init(
        target: RecitationTarget,
        alignment: AlignmentResult,
        segments: [AlignedAudioSegment],
        tajweedNotes: [TajweedNote] = []
    ) {
        self.target = target
        self.alignment = alignment
        self.segments = segments
        self.tajweedNotes = tajweedNotes
    }

    /// Full transcription across all segments, in order.
    public var transcribedText: String {
        segments.map(\.transcription.text)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
