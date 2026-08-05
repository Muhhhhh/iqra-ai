import Foundation

/// Turns a continuous frame stream into discrete speech segments, split at pauses.
///
/// Step 4 replaces `EnergyVoiceActivityDetector` with a Silero VAD implementation
/// behind this same protocol. Nothing downstream changes.
public protocol VoiceActivityDetector: Sendable {
    /// Feed one frame. Returns any speech segments that just completed.
    func process(_ frame: AudioChunk) async -> [AudioChunk]
    /// Flush whatever speech is buffered — call when capture stops so the last
    /// segment isn't lost.
    func flush() async -> AudioChunk?
    /// The speech gathered so far, without closing it. Used for provisional readings.
    ///
    /// Defaulted to nothing: a detector that keeps no buffer has nothing to show early,
    /// and the pipeline simply skips the provisional pass for it.
    func pending() async -> AudioChunk?
    func reset() async
}

public extension VoiceActivityDetector {
    func pending() async -> AudioChunk? { nil }
}

/// Fallback VAD: RMS threshold with hangover, no model.
///
/// Superseded by `SileroVoiceActivityDetector` in build step 4, and kept only for when
/// the Silero model is unavailable and as a baseline to compare against. An energy gate
/// cannot distinguish a held vowel from a quiet passage, and cannot distinguish speech
/// from noise at all.
public actor EnergyVoiceActivityDetector: VoiceActivityDetector {
    public struct Options: Sendable {
        /// RMS above which a frame counts as speech.
        public var speechThreshold: Float
        public var segmentation: SpeechSegmentAssembler.Options

        public init(
            speechThreshold: Float = 0.015,
            segmentation: SpeechSegmentAssembler.Options = .default
        ) {
            self.speechThreshold = speechThreshold
            self.segmentation = segmentation
        }

        public static let `default` = Options()
    }

    private let options: Options
    private var assembler: SpeechSegmentAssembler

    public init(options: Options = .default) {
        self.options = options
        self.assembler = SpeechSegmentAssembler(options: options.segmentation)
    }

    public func pending() async -> AudioChunk? { assembler.pending }

    public func process(_ frame: AudioChunk) async -> [AudioChunk] {
        assembler.consume(frame, isSpeech: frame.rms >= options.speechThreshold)
    }

    public func flush() async -> AudioChunk? {
        assembler.flush()
    }

    public func reset() async {
        assembler.reset()
    }
}

/// Emits every frame as its own segment. Used with `ScriptedAudioCapture` so the
/// demo path is fully deterministic.
public struct PassthroughVoiceActivityDetector: VoiceActivityDetector {
    public init() {}
    public func process(_ frame: AudioChunk) async -> [AudioChunk] { frame.isEmpty ? [] : [frame] }
    public func flush() async -> AudioChunk? { nil }
    public func reset() async {}
}
