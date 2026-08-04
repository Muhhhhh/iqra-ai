import Foundation

/// Finds where each expected phoneme was actually said.
///
/// This is the piece that lets tajweed be judged at the level of the letter rather than
/// the word. Measuring the current checker with the evidence deliberately removed showed
/// it responds to whether the *word* was recited, not to whether the ṣifah inside it was
/// produced: take the nasalisation out of a word and leave the rest standing, and the
/// model goes on asserting the ghunnah at 99%. Judging a ghunnah means knowing which
/// frames belong to the nūn, and nothing in the pipeline knew that.
///
/// Free transcription cannot supply it — that is the 50%-word-error problem, and it is
/// the wrong question anyway. **The text is known.** What is unknown is where in the
/// audio each of its phonemes falls, and that is forced alignment: a constrained Viterbi
/// pass over the phoneme head's own frame probabilities, restricted to the one sequence
/// the reciter is supposed to be saying. The path is forced to spell out exactly that
/// sequence, so it cannot invent, reorder, or skip a phoneme; all it decides is timing.
///
/// The model is CTC, so the standard construction applies: the target is interleaved with
/// blanks, and a path may stay on a symbol, step to the next, or skip a blank between two
/// different symbols.
public struct CTCForcedAligner: Sendable {

    /// Where one expected symbol was said.
    public struct Span: Sendable, Equatable {
        /// Index into the target sequence handed in.
        public let index: Int
        /// The symbol itself, as a class index of the model's phoneme head.
        public let symbol: Int
        /// Frames it occupies, half-open.
        public let frames: Range<Int>
        /// Mean probability the model gave this symbol over those frames — low means the
        /// alignment had to put it somewhere, not that it was heard clearly.
        public let confidence: Double

        public init(index: Int, symbol: Int, frames: Range<Int>, confidence: Double) {
            self.index = index
            self.symbol = symbol
            self.frames = frames
            self.confidence = confidence
        }
    }

    /// CTC blank. The Muaalem vocabulary puts `[PAD]` at 0 for every head.
    public let blank: Int

    public init(blank: Int = 0) {
        self.blank = blank
    }

    public enum AlignmentError: Error, Sendable {
        /// More symbols than frames can possibly spell out.
        case audioTooShort(frames: Int, symbols: Int)
        case emptyInput
    }

    /// Align `target` against per-frame probabilities.
    ///
    /// - Parameter probabilities: `[frame][class]`, each row summing to 1.
    /// - Parameter target: expected symbols, as class indices. No blanks.
    /// How well a sequence explains the audio, and where each symbol fell.
    ///
    /// The score is the Viterbi path's log probability divided by the frames it spans, so
    /// sequences of different lengths can be compared. On its own it means little — an
    /// absolute likelihood depends on the voice, the recording and the passage. Its use is
    /// comparative: align the same audio against the phonemes the text asks for and
    /// against a variant with a rule violated, and the difference says which reading the
    /// audio supports.
    ///
    /// That comparison is the one form of tajweed judgement that cannot be confounded by
    /// the text. Both hypotheses carry identical words and identical context, so nothing
    /// but the sound can separate them — which is what every failed approach in this
    /// project lacked.
    public struct Alignment: Sendable {
        public let spans: [Span]
        /// Mean log probability per frame. Higher is better; always negative.
        public let score: Double
    }

    public func align(
        probabilities: [[Double]],
        target: [Int]
    ) throws -> [Span] {
        try scored(probabilities: probabilities, target: target).spans
    }

    /// The same alignment, keeping the path score.
    public func scored(
        probabilities: [[Double]],
        target: [Int]
    ) throws -> Alignment {
        guard !probabilities.isEmpty, !target.isEmpty else { throw AlignmentError.emptyInput }

        // The extended sequence: blank, symbol, blank, symbol, … blank.
        var extended: [Int] = [blank]
        extended.reserveCapacity(target.count * 2 + 1)
        for symbol in target {
            extended.append(symbol)
            extended.append(blank)
        }

        let frameCount = probabilities.count
        let stateCount = extended.count
        // Every symbol needs a frame, and a repeated symbol needs a blank between it and
        // its twin. Below that the sequence cannot be spelled out at all.
        var minimumFrames = target.count
        for index in 1..<max(target.count, 1) where target[index] == target[index - 1] {
            minimumFrames += 1
        }
        guard frameCount >= minimumFrames else {
            throw AlignmentError.audioTooShort(frames: frameCount, symbols: minimumFrames)
        }

        let negativeInfinity = -Double.greatestFiniteMagnitude / 4
        func logProbability(_ frame: Int, _ state: Int) -> Double {
            let symbol = extended[state]
            guard symbol < probabilities[frame].count else { return negativeInfinity }
            let value = probabilities[frame][symbol]
            return value > 0 ? log(value) : negativeInfinity
        }

        var previous = [Double](repeating: negativeInfinity, count: stateCount)
        var current = previous
        // One byte per cell: 0 stay, 1 advance one, 2 skip a blank.
        var backpointers = [UInt8](repeating: 0, count: frameCount * stateCount)

        // A path may open on the leading blank or on the first symbol.
        previous[0] = logProbability(0, 0)
        if stateCount > 1 { previous[1] = logProbability(0, 1) }

        for frame in 1..<frameCount {
            for state in 0..<stateCount {
                var best = previous[state]
                var move: UInt8 = 0
                if state >= 1, previous[state - 1] > best {
                    best = previous[state - 1]
                    move = 1
                }
                // Skipping the blank between two *different* symbols is allowed; between
                // two identical ones it is not, or they would collapse into one.
                if state >= 2,
                   extended[state] != blank,
                   extended[state] != extended[state - 2],
                   previous[state - 2] > best {
                    best = previous[state - 2]
                    move = 2
                }
                current[state] = best <= negativeInfinity ? negativeInfinity : best + logProbability(frame, state)
                backpointers[frame * stateCount + state] = move
            }
            swap(&previous, &current)
        }

        // A valid path ends on the last symbol or the blank after it.
        var state = stateCount - 1
        if stateCount >= 2, previous[stateCount - 2] > previous[stateCount - 1] {
            state = stateCount - 2
        }
        guard previous[state] > negativeInfinity else { throw AlignmentError.emptyInput }
        let score = previous[state] / Double(frameCount)

        // Walk back, recording which frames each state held.
        var statePerFrame = [Int](repeating: 0, count: frameCount)
        var frame = frameCount - 1
        while frame >= 0 {
            statePerFrame[frame] = state
            if frame > 0 {
                state -= Int(backpointers[frame * stateCount + state])
            }
            frame -= 1
        }

        // Collect the frames of each non-blank state, in order.
        var spans: [Span] = []
        spans.reserveCapacity(target.count)
        var index = 0
        var cursor = 0
        while cursor < frameCount {
            let state = statePerFrame[cursor]
            var end = cursor + 1
            while end < frameCount, statePerFrame[end] == state { end += 1 }
            if extended[state] != blank {
                let symbol = extended[state]
                var total = 0.0
                for frame in cursor..<end where symbol < probabilities[frame].count {
                    total += probabilities[frame][symbol]
                }
                spans.append(
                    Span(
                        index: index,
                        symbol: symbol,
                        frames: cursor..<end,
                        confidence: total / Double(end - cursor)
                    )
                )
                index += 1
            }
            cursor = end
        }
        return Alignment(spans: spans, score: score)
    }
}
