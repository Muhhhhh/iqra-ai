import Foundation

/// Turns a stream of (audio, is-this-speech) decisions into speech segments.
///
/// Deliberately separated from *how* the decision is made. `EnergyVoiceActivityDetector`
/// decides by RMS threshold and `SileroVoiceActivityDetector` by neural probability, but
/// the segment bookkeeping — pre-roll, hangover, minimum and maximum durations — is
/// identical and subtle enough to be worth having exactly one tested copy of.
public struct SpeechSegmentAssembler {

    public struct Options: Sendable {
        /// Silence needed before a segment is closed.
        ///
        /// This is the single most consequential number in the pipeline, and 0.6 s — the
        /// value carried over from the microphone work — was badly wrong for recitation.
        /// Reciters pause constantly: at waqf marks, between āyāt, for breath. Every one
        /// of those pauses was closing a segment, and whisper is far worse on short
        /// fragments than on long ones, because it has no context to decode against.
        ///
        /// Measured with `Tools/IqraEval` over 74 passages of Al-Husary's murattal
        /// (real recitation, not the synthetic clip earlier figures came from):
        ///
        ///     silence   WER     falsely flagged words   passages with nothing flagged
        ///     0.6 s     57.6%   23.9%                   1/19
        ///     0.9 s     50.1%   16.7%                   3/19
        ///     1.2 s     45.6%   13.8%                   3/19
        ///     1.6 s     43.0%   10.9%                   7/19
        ///     2.0 s     39.3%   11.7%                   8/19
        ///     2.5 s     37.5%   10.5%                   7/19
        ///
        /// Falsely flagged words more than halved. Detection of an omitted āyah rose
        /// with it (8/19 → 15/19) rather than trading against it, because both failures
        /// had the same cause: fragments too short to transcribe. Past 1.6 s the curve
        /// flattens into noise, so that is the setting — every further tenth of a second
        /// is feedback the reciter waits for after they stop.
        public var trailingSilence: TimeInterval
        /// Segments shorter than this are treated as noise and dropped.
        public var minimumSegmentDuration: TimeInterval
        /// Hard cap so a continuous passage still gets transcribed incrementally.
        public var maximumSegmentDuration: TimeInterval
        /// How much audio from *before* the speech decision to prepend.
        ///
        /// Speech does not start at full volume — a word's onset ramps up through
        /// whatever threshold is in use. Without a pre-roll those first frames are lost
        /// and the recognizer hears a truncated word, which then reads as a *wrong* word
        /// rather than a clipped one. Measured against بِسْمِ, dropping the onset turned
        /// it into من.
        public var preRoll: TimeInterval

        public init(
            trailingSilence: TimeInterval = 1.6,
            minimumSegmentDuration: TimeInterval = 0.35,
            maximumSegmentDuration: TimeInterval = 12.0,
            preRoll: TimeInterval = 0.35
        ) {
            self.trailingSilence = trailingSilence
            self.minimumSegmentDuration = minimumSegmentDuration
            self.maximumSegmentDuration = maximumSegmentDuration
            self.preRoll = preRoll
        }

        public static let `default` = Options()
    }

    private let options: Options
    private var buffer: AudioChunk?
    private var silenceDuration: TimeInterval = 0
    /// Most recent non-speech audio, kept so a segment can open with the onset that
    /// preceded detection rather than starting mid-word.
    private var preRollBuffer: [AudioChunk] = []

    public init(options: Options = .default) {
        self.options = options
    }

    /// Feed one piece of audio along with whether it contains speech.
    /// Returns any segments that just completed.
    public mutating func consume(_ chunk: AudioChunk, isSpeech: Bool) -> [AudioChunk] {
        if isSpeech {
            silenceDuration = 0
            if let existing = buffer {
                buffer = existing.appending(chunk)
            } else {
                buffer = openSegment(with: chunk)
            }
        } else if buffer != nil {
            // Keep trailing silence in the buffer: whisper transcribes better with a
            // little padding, and v2 madd measurement needs the vowel's actual decay.
            buffer = buffer.map { $0.appending(chunk) }
            silenceDuration += chunk.duration
        } else {
            retainAsPreRoll(chunk)
        }

        guard let current = buffer else { return [] }

        let closedByPause = silenceDuration >= options.trailingSilence
        let closedByLength = current.duration >= options.maximumSegmentDuration
        guard closedByPause || closedByLength else { return [] }

        buffer = nil
        silenceDuration = 0
        guard current.duration >= options.minimumSegmentDuration else { return [] }
        return [current]
    }

    /// Emit whatever speech is still buffered. Call when capture stops so the final
    /// segment isn't lost.
    public mutating func flush() -> AudioChunk? {
        defer { reset() }
        guard let current = buffer, current.duration >= options.minimumSegmentDuration else { return nil }
        return current
    }

    public mutating func reset() {
        buffer = nil
        silenceDuration = 0
        preRollBuffer.removeAll(keepingCapacity: true)
    }

    /// Open a new segment led by the retained pre-roll.
    private mutating func openSegment(with chunk: AudioChunk) -> AudioChunk {
        let lead = preRollBuffer.reduce(into: nil as AudioChunk?) { result, held in
            result = result.map { $0.appending(held) } ?? held
        }
        preRollBuffer.removeAll(keepingCapacity: true)
        return lead.map { $0.appending(chunk) } ?? chunk
    }

    private mutating func retainAsPreRoll(_ chunk: AudioChunk) {
        preRollBuffer.append(chunk)
        var held = preRollBuffer.reduce(0) { $0 + $1.duration }
        while held > options.preRoll, preRollBuffer.count > 1 {
            held -= preRollBuffer.removeFirst().duration
        }
    }
}
