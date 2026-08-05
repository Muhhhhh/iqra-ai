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
        guard symbols.indices.contains(position) else { return nil }
        switch rule {
        case .qalqalah:
            // The bounce simply not made: the stop released straight into what follows.
            guard symbols[position] == AlignedTajweedAnalyzer.qalqalaEcho else { return nil }
            var without = symbols
            without.remove(at: position)
            return without
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
            var start = position
            while start > 0, symbols[start - 1] == symbol { start -= 1 }
            var end = position + 1
            while end < symbols.count, symbols[end] == symbol { end += 1 }
            var plain = symbols
            plain.replaceSubrange(start..<end, with: [Self.plainNun])
            return plain
        case _ where rule.isMadd:
            // The elongation cut to a single count, which is what rushing one sounds
            // like — the vowel is there, its length is not.
            let symbol = symbols[position]
            var start = position
            while start > 0, symbols[start - 1] == symbol { start -= 1 }
            var end = position + 1
            while end < symbols.count, symbols[end] == symbol { end += 1 }
            guard end - start >= 2 else { return nil }
            var shortened = symbols
            shortened.removeSubrange((start + 1)..<end)
            return shortened
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
        _ alignment: CTCForcedAligner.Alignment,
        probabilities: [[Double]],
        over frames: Range<Int>
    ) -> Double {
        var symbolAt = [Int](repeating: blank, count: probabilities.count)
        for span in alignment.spans {
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
    /// Both are aligned over the whole āyah — the path has to be found in context — but
    /// only the frames around the disputed sound are compared, with a little air either
    /// side so a boundary is not cut through.
    public func compare(
        probabilities: [[Double]],
        symbols: [Int],
        at position: Int,
        rule: TajweedRule
    ) -> Comparison? {
        guard let broken = Self.violate(symbols, at: position, rule: rule),
              let correct = try? aligner.scored(probabilities: probabilities, target: symbols),
              let wrong = try? aligner.scored(probabilities: probabilities, target: broken)
        else { return nil }

        // The window: from the symbol before the disputed one to the symbol after it.
        guard let here = correct.spans.first(where: { $0.index == position }) else { return nil }
        let before = correct.spans.last { $0.index <= position - context }
        let after = correct.spans.first { $0.index >= position + context }
        let lower = context == 0 ? here.frames.lowerBound
            : (before?.frames.lowerBound ?? here.frames.lowerBound)
        let upper = context == 0 ? here.frames.upperBound
            : (after?.frames.upperBound ?? here.frames.upperBound)
        guard upper > lower else { return nil }
        let window = lower..<upper

        return Comparison(
            position: position,
            rule: rule,
            expected: score(correct, probabilities: probabilities, over: window),
            violated: score(wrong, probabilities: probabilities, over: window)
        )
    }
}
