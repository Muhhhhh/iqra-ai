import Foundation

/// Asks which of two readings the audio supports, instead of measuring how long a sound was.
///
/// Every other approach in this project failed in one of two ways. Classifying a ṣifah from
/// reference recitation is unlearnable, because the labels come from the text and never
/// vary from it — a model given no audio at all scores a perfect AUC on all ten. Measuring
/// a duration works only where the sound is longer than the model's clock: madd runs for
/// hundreds of milliseconds and is caught, a qalqalah bounce runs 20 to 60 and the model
/// advances 40 a frame, so a page recited with every qalqalah deliberately swallowed drew
/// exactly as many flags as the same page recited properly. None.
///
/// This asks a different question. Take the phonemes the text calls for, make a second
/// sequence with the rule violated — the qalqalah echo deleted, the elongation cut to a
/// single count — and force both onto the same audio. Whichever explains it better is what
/// was recited.
///
/// Two properties matter. The comparison **cannot be confounded by the text**: both
/// hypotheses carry the same words in the same context, so nothing but the sound can
/// separate them, which is precisely what the failed approaches lacked. And it asks a
/// *discrete* question — is there acoustic support for this symbol — rather than a
/// duration, so a sound briefer than one frame is not automatically invisible.
///
/// It needs no training data, no corpus and no labels. It uses the phoneme head, which was
/// measured to hear: removing a phoneme's audio collapses its score, where the ṣifāt heads
/// barely move.
public struct HypothesisScorer: Sendable {

    /// One place the text and a violated reading disagree.
    public struct Comparison: Sendable {
        /// Index into the correct phoneme sequence where the rule applies.
        public let position: Int
        public let rule: TajweedRule
        /// Log probability per frame of the reading the text asks for.
        public let expected: Double
        /// The same for the reading with the rule violated.
        public let violated: Double

        /// How much better the correct reading explains the audio.
        ///
        /// Positive means the audio supports the text. Negative means it supports the
        /// mistake — the reciter is more likely to have said the wrong thing than the
        /// right one.
        public var support: Double { expected - violated }
    }

    /// ں — the hidden nūn of ikhfāʾ, as the phonetiser writes it.
    public static let ikhfaNun = 39
    /// ۾ — the nūn turned to a mīm before bāʾ, in iqlāb.
    public static let iqlabNun = 40
    /// ن said plainly, which is the mistake both rules describe.
    public static let plainNun = 25

    private let aligner: CTCForcedAligner
    private let blank = 0
    /// How many symbols either side of the disputed one the comparison covers.
    ///
    /// Not a free parameter for long: 0 compares only the sound itself, 1 takes its
    /// neighbours for air. Swept below.
    public let context: Int

    public init(aligner: CTCForcedAligner = CTCForcedAligner(blank: 0), context: Int = 1) {
        self.aligner = aligner
        self.context = context
    }

    /// Every place in a sequence where a rule can be violated, one position each.
    ///
    /// One per run, not per symbol: ikhfāʾ and iqlāb are written two or three times over
    /// for the length of their ghunnah, and each run is one place the reciter either
    /// applied the rule or did not.
    /// Where idghām falls, which the symbols alone cannot say.
    ///
    /// The assimilated letter is an ordinary doubled consonant — a doubled mīm is the same
    /// whether it came from أُمَّة or from مِن مَّاء — so the positions are read from the text
    /// at export and carried in their own plane. This takes the first phoneme of each run
    /// the plane marks.
    public static func idghamPositions(in plane: [UInt8]) -> [Int] {
        var found: [Int] = []
        var index = 0
        while index < plane.count {
            var end = index + 1
            while end < plane.count, plane[end] == plane[index] { end += 1 }
            if plane[index] != 0 { found.append(index) }
            index = end
        }
        return found
    }

    public static func positions(in symbols: [Int], rule: TajweedRule) -> [Int] {
        let wanted: Int
        switch rule {
        case .qalqalah: wanted = AlignedTajweedAnalyzer.qalqalaEcho
        case .ikhfa: wanted = ikhfaNun
        case .iqlab: wanted = iqlabNun
        default: return []
        }
        var found: [Int] = []
        var index = 0
        while index < symbols.count {
            var end = index + 1
            while end < symbols.count, symbols[end] == symbols[index] { end += 1 }
            if symbols[index] == wanted { found.append(index) }
            index = end
        }
        return found
    }

    /// The sequence with one rule violated, or nil where the violation cannot be written.
    ///
    /// A rule is only testable this way when breaking it changes which symbols are
    /// spoken. Qalqalah and madd qualify — the phonetiser writes the bounce as its own
    /// symbol and an elongation as a repeat, so removing them is a well-defined edit.
    /// Tafkhīm and hams do not: the same symbols are spoken either way, and no second
    /// sequence exists to compare against.
    public static func violate(
        _ symbols: [Int],
        at position: Int,
        rule: TajweedRule
    ) -> [Int]? {
        guard let edit = edit(symbols, at: position, rule: rule) else { return nil }
        var broken = symbols
        broken.replaceSubrange(edit.range, with: edit.replacement)
        return broken
    }

    /// The edit itself: which symbols the mistake replaces, and with what.
    ///
    /// Returned as an edit rather than a whole rewritten sequence so the comparison can be
    /// made where the two readings actually differ. A violation touches two or three
    /// symbols; aligning a rewritten āyah end to end for each one was most of what made
    /// analysis slow.
    public static func edit(
        _ symbols: [Int],
        at position: Int,
        rule: TajweedRule
    ) -> (range: Range<Int>, replacement: [Int])? {
        guard symbols.indices.contains(position) else { return nil }
        func run(of symbol: Int) -> Range<Int> {
            var start = position
            while start > 0, symbols[start - 1] == symbol { start -= 1 }
            var end = position + 1
            while end < symbols.count, symbols[end] == symbol { end += 1 }
            return start..<end
        }
        switch rule {
        case .qalqalah:
            // The bounce simply not made: the stop released straight into what follows.
            guard symbols[position] == AlignedTajweedAnalyzer.qalqalaEcho else { return nil }
            return (position..<(position + 1), [])
        case .idgham, .idghamBilaGhunnah:
            // The nūn said rather than merged. Idghām writes the assimilated nūn as a
            // doubling of the letter that swallowed it, so a reciter who fails to merge
            // says two sounds where the text asks for one held: a plain ن, then the
            // letter once. That is the edit.
            let symbol = symbols[position]
            return (run(of: symbol), [Self.plainNun, symbol])
        case .ikhfa, .iqlab:
            // A nūn sākinah said plainly, which is what these two rules forbid.
            //
            // The phonetiser gives each its own symbol — ں for ikhfāʾ, ۾ for iqlāb — and
            // writes it two or three times over for the ghunnah's length. Reciting the
            // rule wrongly does not shorten that sound, it replaces it: the reciter says a
            // clear nūn where the text asks for a hidden one, or for a mīm before bāʾ. So
            // the violated reading is the whole run swapped for a single ن.
            let symbol = symbols[position]
            guard symbol == Self.ikhfaNun || symbol == Self.iqlabNun else { return nil }
            return (run(of: symbol), [Self.plainNun])
        case _ where rule.isMadd:
            // The elongation cut to a single count, which is what rushing one sounds
            // like — the vowel is there, its length is not.
            let symbol = symbols[position]
            let span = run(of: symbol)
            guard span.count >= 2 else { return nil }
            return (span, [symbol])
        default:
            return nil
        }
    }

    /// How well an alignment explains one stretch of frames, per frame.
    ///
    /// The whole-sequence score cannot be used to judge one phoneme. It is the path
    /// likelihood over the entire āyah, so anything that makes the āyah align worse drags
    /// every comparison inside it down together — measured on a recording where the
    /// reciter was deliberately mispronouncing *nūns*, every qalqalah in the same verses
    /// shifted by −0.042 and started being flagged, though the bounces were untouched.
    ///
    /// Restricted to the frames around the symbol in question, the comparison answers
    /// about that sound and nothing else.
    private func score(
        _ spans: [CTCForcedAligner.Span],
        probabilities: [[Double]],
        over frames: Range<Int>
    ) -> Double {
        var symbolAt = [Int](repeating: blank, count: probabilities.count)
        for span in spans {
            for frame in span.frames where frame < symbolAt.count { symbolAt[frame] = span.symbol }
        }
        var total = 0.0
        var counted = 0
        for frame in frames where frame >= 0 && frame < probabilities.count {
            let symbol = symbolAt[frame]
            guard symbol < probabilities[frame].count else { continue }
            let value = probabilities[frame][symbol]
            total += value > 0 ? log(value) : -30
            counted += 1
        }
        return counted > 0 ? total / Double(counted) : 0
    }

    /// Score the text's reading against a violated one, over the same audio.
    ///
    /// Only the neighbourhood of the edit is re-aligned. A violation touches two or three
    /// symbols and the path either side of it is the correct one's, so re-deriving a whole
    /// āyah for each question was work thrown away — and there are several questions in
    /// most āyāt. The margin is generous enough that the sub-path settles well before it
    /// reaches the frames being scored.
    public func compare(
        probabilities: [[Double]],
        symbols: [Int],
        at position: Int,
        rule: TajweedRule,
        correct known: CTCForcedAligner.Alignment? = nil
    ) -> Comparison? {
        guard let edit = Self.edit(symbols, at: position, rule: rule),
              let correct = known
                  ?? (try? aligner.scored(probabilities: probabilities, target: symbols))
        else { return nil }

        let byIndex = Dictionary(
            correct.spans.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first }
        )
        guard let here = byIndex[position] else { return nil }

        // The frames to score: the disputed sound plus `context` symbols either side.
        let before = correct.spans.last { $0.index <= position - context }
        let after = correct.spans.first { $0.index >= position + context }
        let windowLower = context == 0 ? here.frames.lowerBound
            : (before?.frames.lowerBound ?? here.frames.lowerBound)
        let windowUpper = context == 0 ? here.frames.upperBound
            : (after?.frames.upperBound ?? here.frames.upperBound)
        guard windowUpper > windowLower else { return nil }
        let window = windowLower..<windowUpper

        // The stretch to re-align: wider again, so the sub-path is settled by the time it
        // reaches the window.
        let margin = 4
        let low = max(0, edit.range.lowerBound - margin)
        let high = min(symbols.count, edit.range.upperBound + margin)
        let firstFrame = byIndex[low].map(\.frames.lowerBound) ?? 0
        let lastFrame = byIndex[high - 1].map(\.frames.upperBound) ?? probabilities.count
        let frames = max(0, firstFrame)..<min(probabilities.count, max(lastFrame, firstFrame + 1))
        guard frames.count > 1, window.lowerBound >= frames.lowerBound,
              window.upperBound <= frames.upperBound
        else { return nil }

        var piece = Array(symbols[low..<high])
        piece.replaceSubrange(
            (edit.range.lowerBound - low)..<(edit.range.upperBound - low),
            with: edit.replacement
        )
        guard !piece.isEmpty,
              let broken = try? aligner.scored(
                  probabilities: Array(probabilities[frames]), target: piece
              )
        else { return nil }

        // The sub-alignment's frames are relative to `frames.lowerBound`.
        let offset = frames.lowerBound
        let shifted = broken.spans.map { span in
            let moved = (span.frames.lowerBound + offset)..<(span.frames.upperBound + offset)
            return CTCForcedAligner.Span(
                index: span.index,
                symbol: span.symbol,
                frames: moved,
                confidence: span.confidence
            )
        }

        return Comparison(
            position: position,
            rule: rule,
            expected: score(correct.spans, probabilities: probabilities, over: window),
            violated: score(shifted, probabilities: probabilities, over: window)
        )
    }
}
