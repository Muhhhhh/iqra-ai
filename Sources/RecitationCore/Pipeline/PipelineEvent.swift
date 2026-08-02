import Foundation

public enum PipelineState: Sendable, Equatable {
    case idle
    case starting
    case listening
    /// Capture paused by the OS (call, Siri, route change). iOS only in practice.
    case interrupted
    case finishing
    case stopped
}

/// What the pipeline reports to a UI shell.
///
/// Both app shells consume this same stream, which is why neither needs to know
/// anything about VAD, whisper, or alignment.
public enum PipelineEvent: Sendable {
    case stateChanged(PipelineState)
    /// Live input level in 0...1, plus the peak, so the UI can warn about clipping.
    case level(rms: Float, peak: Float)
    /// A segment finished transcribing. Carries its audio and timestamps.
    case segment(AlignedAudioSegment)
    /// Updated verdicts for the whole target. `isFinal` is false while recording.
    case alignment(AlignmentResult)
    /// Tajweed findings so far, with how much has been examined to produce them.
    case tajweed(notes: [TajweedNote], coverage: TajweedCoverage)
    /// Terminal result, emitted once after `stop()`.
    case finished(RecitationResult)
    case failed(PipelineFailure)
}

public struct PipelineFailure: Error, Sendable {
    public enum Stage: String, Sendable {
        case capture, segmentation, recognition, matching
    }

    public let stage: Stage
    public let message: String

    public init(stage: Stage, message: String) {
        self.stage = stage
        self.message = message
    }
}
