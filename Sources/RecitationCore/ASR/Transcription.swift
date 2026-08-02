import Foundation

/// One token emitted by the speech recognizer, with its position in the session timeline.
///
/// Timestamps are on the **session** clock (not chunk-relative) so a token can be traced
/// straight back into the originating `AudioChunk` via `AudioChunk.slice(from:to:)`.
public struct TranscribedToken: Sendable, Equatable {
    public let text: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    /// Model confidence in 0...1. whisper.cpp exposes this per token; the stub reports 1.
    public let confidence: Double

    public init(text: String, startTime: TimeInterval, endTime: TimeInterval, confidence: Double = 1.0) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
    }

    public var duration: TimeInterval { max(0, endTime - startTime) }
}

/// The recognizer's output for a single audio chunk.
public struct Transcription: Sendable, Equatable {
    public let text: String
    public let tokens: [TranscribedToken]

    public init(text: String, tokens: [TranscribedToken]) {
        self.text = text
        self.tokens = tokens
    }

    public static let empty = Transcription(text: "", tokens: [])
}
