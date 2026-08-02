import Foundation

/// Judges tajweed on the letters the rule applies to, using forced alignment.
///
/// The analyzer this replaces asked its question of a whole word: was anything in these
/// six letters nasalised? Measured with the evidence deliberately removed, that turned
/// out to answer a different question than intended — take the nasalisation out of a word
/// and leave the rest standing and the model went on asserting the ghunnah at 99%, so the
/// verdict tracked whether the *word* was recited rather than whether the ṣifah was
/// produced. A reciter who says the word without giving the nūn its ghunnah is exactly
/// who this feature exists for, and exactly who it could not see.
///
/// Here the expected phoneme sequence is aligned to the audio first
/// (`CTCForcedAligner`), which says which frames are the nūn. The ṣifah heads are then
/// read over those frames alone. The expectation comes from the same phonetiser the model
/// was trained against (`PhonemeScript`), so "this phoneme must be nasalised" and "this
/// frame sounds nasalised" are statements in one vocabulary.
///
/// It remains conservative in the same way as everything else here: silence unless the
/// model is confidently against the rule, over a phoneme it aligned confidently.
public actor AlignedTajweedAnalyzer: TajweedAnalyzer {

    public struct Options: Sendable {
        /// Probability of the required ṣifah below which the rule is questioned.
        public var presenceThreshold: Double
        /// The model must read the contrary at least this strongly before anything is
        /// said. Between the two it stays silent.
        public var contraryThreshold: Double
        /// Alignment confidence a phoneme needs before its ṣifāt are judged at all.
        ///
        /// Forced alignment always returns a full path — it has to place every phoneme
        /// somewhere. Where it had no acoustic reason for the placement it says so, and
        /// judging a ghunnah on frames the aligner was guessing about would be inventing
        /// evidence.
        public var alignmentConfidence: Double

        public init(
            presenceThreshold: Double = 0.35,
            contraryThreshold: Double = 0.6,
            alignmentConfidence: Double = 0.4
        ) {
            self.presenceThreshold = presenceThreshold
            self.contraryThreshold = contraryThreshold
            self.alignmentConfidence = alignmentConfidence
        }

        public static let `default` = Options()
    }

    private let model: MuaalemTajweedAnalyzer
    private let script: PhonemeScript
    private let options: Options
    private let aligner = CTCForcedAligner(blank: 0)
    private var lastCoverage: TajweedCoverage = .none

    public init(model: MuaalemTajweedAnalyzer, script: PhonemeScript, options: Options = .default) {
        self.model = model
        self.script = script
        self.options = options
    }

    public func coverage() async -> TajweedCoverage { lastCoverage }

    // MARK: - Analysis

    public func analyze(
        segments: [AlignedAudioSegment],
        target: RecitationTarget
    ) async -> [TajweedNote] {
        // Words of the target, grouped so a phoneme's (āyah, word) can find its index.
        var wordsByVerse: [VerseReference: [TargetWord]] = [:]
        for word in target.flattenedWords {
            wordsByVerse[word.reference, default: []].append(word)
        }

        var notes: [TajweedNote] = []
        var required = 0
        var examined = 0

        for segment in segments {
            // Only words this segment actually carries, in order — aligning an āyah's
            // whole phoneme sequence to audio holding half of it would misplace
            // everything after the join.
            let spoken = segment.words
                .filter { $0.timeRange != nil }
                .sorted { $0.targetIndex < $1.targetIndex }
            guard !spoken.isEmpty else { continue }

            var symbols: [Int] = []
            /// For each phoneme: which target word it belongs to, and what it must carry.
            var owner: [(word: TargetWord, ghonna: UInt8, qalqala: UInt8)] = []

            for evaluation in spoken {
                guard let entry = script[evaluation.reference],
                      let words = wordsByVerse[evaluation.reference],
                      let position = words.firstIndex(where: { $0.globalIndex == evaluation.targetIndex }),
                      let range = entry.range(ofWord: position)
                else { continue }

                let word = words[position]
                for index in range {
                    symbols.append(Int(entry.symbols[index]))
                    owner.append((word, entry.ghonna[index], entry.qalqala[index]))
                }
            }
            guard !symbols.isEmpty else { continue }
            required += owner.count { $0.ghonna == 1 || $0.qalqala == 1 }

            guard let observed = try? await model.probabilities(for: segment.audio),
                  let phonemes = observed.probabilities["phonemes"],
                  let spans = try? aligner.align(probabilities: phonemes, target: symbols)
            else { continue }

            for span in spans where span.index < owner.count {
                guard span.confidence >= options.alignmentConfidence else { continue }
                let expectation = owner[span.index]

                if expectation.ghonna != 0,
                   let note = verify(
                       head: .ghonna,
                       expectingPresence: expectation.ghonna == 1,
                       rule: .ghunnah,
                       span: span,
                       word: expectation.word,
                       observed: observed,
                       examined: &examined
                   ) {
                    notes.append(note)
                }

                if expectation.qalqala != 0,
                   let note = verify(
                       head: .qalqla,
                       expectingPresence: expectation.qalqala == 1,
                       rule: .qalqalah,
                       span: span,
                       word: expectation.word,
                       observed: observed,
                       examined: &examined
                   ) {
                    notes.append(note)
                }
            }
        }

        // One note per word: several phonemes of the same word failing the same rule is
        // one thing to listen back to, not four.
        var seen = Set<String>()
        let deduplicated = notes.filter { seen.insert("\($0.targetIndex):\($0.rule.rawValue)").inserted }

        lastCoverage = TajweedCoverage(
            required: required,
            judgeable: required,
            examined: examined,
            skippedWithoutTiming: max(0, required - examined),
            questioned: deduplicated.count
        )
        return deduplicated.sorted { $0.targetIndex < $1.targetIndex }
    }

    /// Read one ṣifah head over one phoneme's frames.
    private func verify(
        head: MuaalemTajweedAnalyzer.Head,
        expectingPresence: Bool,
        rule: TajweedRule,
        span: CTCForcedAligner.Span,
        word: TargetWord,
        observed: MuaalemTajweedAnalyzer.Observation,
        examined: inout Int
    ) -> TajweedNote? {
        guard let series = observed.probabilities[head.rawValue] else { return nil }
        let present = head.presentIndex
        let absent = head.absentIndex

        var wanted = 0.0
        var contrary = 0.0
        var counted = 0
        for frame in span.frames where frame < series.count {
            let row = series[frame]
            guard row.count > max(present, absent), row[0] < 0.5 else { continue }
            wanted = max(wanted, expectingPresence ? row[present] : row[absent])
            contrary = max(contrary, expectingPresence ? row[absent] : row[present])
            counted += 1
        }
        guard counted > 0 else { return nil }
        examined += 1

        guard wanted < options.presenceThreshold, contrary > options.contraryThreshold else { return nil }

        let start = observed.startTime + Double(span.frames.lowerBound) * observed.frameDuration
        let end = observed.startTime + Double(span.frames.upperBound) * observed.frameDuration
        return TajweedNote(
            rule: rule,
            targetIndex: word.globalIndex,
            reference: word.reference,
            timeRange: start...max(start, end),
            confidence: contrary > 0.85 ? .moderate : .low,
            message: expectingPresence
                ? "This letter should carry \(rule.title.lowercased()) — listen back to it."
                : "This letter should not carry \(rule.title.lowercased()) — listen back to it.",
            measurement: .init(observed: wanted, expected: options.presenceThreshold, unit: "")
        )
    }
}
