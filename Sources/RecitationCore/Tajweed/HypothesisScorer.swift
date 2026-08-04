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

    private let aligner: CTCForcedAligner

    public init(aligner: CTCForcedAligner = CTCForcedAligner(blank: 0)) {
        self.aligner = aligner
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

    /// Score the text's reading against a violated one, over the same audio.
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
        return Comparison(
            position: position,
            rule: rule,
            expected: correct.score,
            violated: wrong.score
        )
    }
}
