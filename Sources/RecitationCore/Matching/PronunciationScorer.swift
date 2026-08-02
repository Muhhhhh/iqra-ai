import Foundation

/// Asks the audio directly whether a word the matcher doubted was actually recited.
///
/// The matcher works by comparing two strings: what the recogniser transcribed against
/// what the text says. On real recitation roughly two words in five come back wrong
/// before that comparison even begins, so a great many of its doubts are the recogniser's
/// fault rather than the reciter's — measured at about one word in ten falsely flagged.
///
/// This asks a different question, and one the transcription cannot answer. The text is
/// known, so the expected phonemes can be forced onto the audio and scored where they
/// land: if the sounds are there, the word was recited, whatever the transcript said.
///
/// The measurement that justifies it — replace one word's audio with a different word's
/// of the same length, and see whether the alignment notices:
///
///     word intact            90.6% confidence
///     word's audio replaced  47.0%
///     fell by 15+ points     17 of 21 trials
///
/// That is a real acoustic signal, and worth contrasting with the ṣifah heads, which were
/// measured the same way and did not move at all — they turned out to predict from
/// context rather than report what was heard. The phoneme head does not have that flaw,
/// which is why this is built on it and tajweed verification is not.
///
/// **It can only clear a word, never condemn one.** A high score suppresses a doubt; a
/// low score changes nothing, because a low score is equally consistent with the aligner
/// having nothing to work with. That asymmetry is deliberate: this is here to stop the
/// app inventing mistakes, not to give it a second way to find them.
public actor PronunciationScorer {

    public struct Options: Sendable {
        /// Alignment confidence at or above which a doubted word is taken to have been
        /// recited after all.
        ///
        /// Chosen by measurement. Falsely flagged words, against skipped- and
        /// wrong-āyah detection, over nine passages of Al-Baqarah, An-Nisā' and Al-A'rāf:
        ///
        ///     clearing at   falsely flagged   omitted āyah   wrong āyah
        ///     off           34                5/9            7/9
        ///     0.8           32                5/9            7/9
        ///     0.7           29                5/9            7/9
        ///     0.6           27                5/9            7/9
        ///     0.5           27                5/9            7/9
        ///
        /// A fifth of the false flags go, detection does not move, and below 0.6 nothing
        /// further is gained. Detection holding across the whole range is the important
        /// part: this is only allowed to clear words, so the risk was that it cleared
        /// misrecited ones too, and at these thresholds it does not.
        public var clearingConfidence: Double

        public init(clearingConfidence: Double = 0.6) {
            self.clearingConfidence = clearingConfidence
        }

        public static let `default` = Options()
    }

    private let model: MuaalemTajweedAnalyzer
    private let script: PhonemeScript
    private let options: Options
    private let aligner = CTCForcedAligner(blank: 0)

    public init(model: MuaalemTajweedAnalyzer, script: PhonemeScript, options: Options = .default) {
        self.model = model
        self.script = script
        self.options = options
    }

    /// Words in this segment whose audio supports the expected text, whatever the
    /// recogniser made of them. Keyed by target index.
    public func wordsSupportedByAudio(
        in segment: AlignedAudioSegment,
        target: RecitationTarget
    ) async -> Set<Int> {
        var wordsByVerse: [VerseReference: [TargetWord]] = [:]
        for word in target.flattenedWords {
            wordsByVerse[word.reference, default: []].append(word)
        }

        let present = segment.words
            .filter { $0.timeRange != nil }
            .sorted { $0.targetIndex < $1.targetIndex }
        guard !present.isEmpty else { return [] }

        var symbols: [Int] = []
        var ownerOfSymbol: [Int] = []
        for evaluation in present {
            guard let entry = script[evaluation.reference],
                  let words = wordsByVerse[evaluation.reference],
                  let position = words.firstIndex(where: { $0.globalIndex == evaluation.targetIndex }),
                  let range = entry.range(ofWord: position)
            else { continue }
            for index in range {
                symbols.append(Int(entry.symbols[index]))
                ownerOfSymbol.append(evaluation.targetIndex)
            }
        }
        guard !symbols.isEmpty else { return [] }

        guard let observed = try? await model.probabilities(for: segment.audio),
              let phonemes = observed.probabilities["phonemes"],
              let spans = try? aligner.align(probabilities: phonemes, target: symbols)
        else { return [] }

        var totals: [Int: (sum: Double, count: Int)] = [:]
        for span in spans where span.index < ownerOfSymbol.count {
            let owner = ownerOfSymbol[span.index]
            var entry = totals[owner] ?? (0, 0)
            entry.sum += span.confidence
            entry.count += 1
            totals[owner] = entry
        }

        return Set(
            totals.compactMap { owner, entry in
                entry.count > 0 && entry.sum / Double(entry.count) >= options.clearingConfidence
                    ? owner
                    : nil
            }
        )
    }
}
