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
        /// How far below the expected length an elongation must fall before it is
        /// mentioned. Wide, because the measurement is a ratio of two estimates.
        public var maddShortfall: Double
        /// Two-count madds needed in the same passage before the reciter's pace means
        /// anything at all.
        public var minimumBaselineMadds: Int
        /// Judge ghunnah and qalqalah from the ṣifah heads.
        ///
        /// **Off, and it should stay off.** Measured with the sound deliberately removed,
        /// those heads caught 2.7% of missing ghunnahs while flagging 67 correct ones:
        /// they predict the ṣifah from surrounding phonetic content rather than reporting
        /// what was heard, so they cannot answer the question at all. Kept behind a flag
        /// because the measurement is worth being able to repeat, not because the feature
        /// is worth having.
        public var judgesSifat: Bool

        public init(
            presenceThreshold: Double = 0.35,
            contraryThreshold: Double = 0.6,
            alignmentConfidence: Double = 0.4,
            maddShortfall: Double = 0.6,
            minimumBaselineMadds: Int = 3,
            judgesSifat: Bool = false
        ) {
            self.judgesSifat = judgesSifat
            self.maddShortfall = maddShortfall
            self.minimumBaselineMadds = minimumBaselineMadds
            self.presenceThreshold = presenceThreshold
            self.contraryThreshold = contraryThreshold
            self.alignmentConfidence = alignmentConfidence
        }

        public static let `default` = Options()
    }

    /// Symbols that carry elongation. A madd's length is written into the phonetic
    /// script as a repeat: `مُۥۥسَاا` holds a two-count wāw madd and a two-count alif.
    /// The run length *is* the expected number of harakāt, which is why madd can be
    /// judged here at all — it is a question of duration, and duration is exactly what
    /// forced alignment measures.
    static let maddCarriers: Set<Int> = [27, 28, 29, 30, 31]

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
            required += options.judgesSifat ? owner.count { $0.ghonna == 1 || $0.qalqala == 1 } : 0

            guard let observed = try? await model.probabilities(for: segment.audio),
                  let phonemes = observed.probabilities["phonemes"],
                  let spans = try? aligner.align(probabilities: phonemes, target: symbols)
            else { continue }

            notes += maddNotes(spans: spans, owner: owner, symbols: symbols, examined: &examined)
            required += maddRuns(in: symbols).count

            for span in spans where options.judgesSifat && span.index < owner.count {
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

    /// Runs of a repeated madd carrier: (range in the sequence, expected harakāt).
    private func maddRuns(in symbols: [Int]) -> [(range: Range<Int>, harakat: Int)] {
        var runs: [(Range<Int>, Int)] = []
        var index = 0
        while index < symbols.count {
            let symbol = symbols[index]
            var end = index + 1
            while end < symbols.count, symbols[end] == symbol { end += 1 }
            let length = end - index
            if length >= 2, Self.maddCarriers.contains(symbol) {
                runs.append((index..<end, length))
            }
            index = end
        }
        return runs
    }

    /// Was each elongation held for as long as it should have been?
    ///
    /// Measured against the reciter's own pace, taken from their two-count madds in the
    /// same breath. Absolute durations are meaningless here — murattal and ḥadr differ by
    /// more than any threshold could accommodate — but the *ratio* between a six-count
    /// madd and a two-count one is fixed by the rule, not by the reciter.
    ///
    /// This is the one tajweed rule this analyzer can support honestly. It uses no ṣifah
    /// head, and those were measured to predict from context rather than report what was
    /// heard.
    private func maddNotes(
        spans: [CTCForcedAligner.Span],
        owner: [(word: TargetWord, ghonna: UInt8, qalqala: UInt8)],
        symbols: [Int],
        examined: inout Int
    ) -> [TajweedNote] {
        let byIndex = Dictionary(spans.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        var measured: [(range: Range<Int>, harakat: Int, seconds: Double, confident: Bool)] = []

        for run in maddRuns(in: symbols) {
            var seconds = 0.0
            var frames = 0
            var confident = true
            for index in run.range {
                guard let span = byIndex[index] else { confident = false; continue }
                frames += span.frames.count
                // A *much* lower bar than the ṣifah checks use, and deliberately so.
                // Shortening an elongation is itself something the aligner is less sure
                // about, so requiring high confidence here would look away from exactly
                // the case being checked — measured at 0 caught out of 42 before this was
                // relaxed. What matters for madd is the duration, and the alignment is
                // forced to span the audio whether it is confident or not.
                if span.confidence < 0.05 { confident = false }
            }
            guard frames > 0 else { continue }
            seconds = Double(frames) * 0.04   // the model's frame rate
            measured.append((run.range, run.harakat, seconds, confident))
        }

        // The reciter's own haraka, from their natural two-count madds.
        let baselines = measured.filter { $0.harakat == 2 && $0.confident }.map { $0.seconds / 2 }
        guard baselines.count >= options.minimumBaselineMadds else { return [] }
        let baseline = baselines.sorted()[baselines.count / 2]

        var notes: [TajweedNote] = []
        for entry in measured where entry.harakat > 2 && entry.confident {
            examined += 1
            let expected = Double(entry.harakat) * baseline
            guard entry.seconds < expected * options.maddShortfall else { continue }
            guard let word = owner.indices.contains(entry.range.lowerBound)
                ? owner[entry.range.lowerBound].word : nil else { continue }
            let span = byIndex[entry.range.lowerBound]
            let start = span.map { Double($0.frames.lowerBound) * 0.04 } ?? 0
            notes.append(
                TajweedNote(
                    rule: entry.harakat >= 6 ? .maddLazim : .maddWajibMuttasil,
                    targetIndex: word.globalIndex,
                    reference: word.reference,
                    timeRange: start...(start + entry.seconds),
                    confidence: entry.seconds < expected * 0.5 ? .moderate : .low,
                    message: "This elongation sounds short — it should run about \(entry.harakat) harakāt.",
                    measurement: .init(observed: entry.seconds, expected: expected, unit: "s")
                )
            )
        }
        return notes
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
