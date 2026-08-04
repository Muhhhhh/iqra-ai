import Foundation

/// Checks the two tajweed rules that can be judged as quantities: madd and qalqalah.
///
/// Both are checked the same way, and the way is the whole point. A ṣifah asked as a
/// *quality* — is this nasal, is this emphatic — cannot be answered from a corpus of
/// correct recitation, because every label such a corpus carries is derived from the text
/// and never varies from it. Measured directly: a classifier given no audio at all, only
/// the phonemes either side, scores a perfect AUC on all ten ṣifāt and beats every model
/// given the sound. See `scripts/train-sifat.py --audit`. The model's own ṣifah heads fail
/// the same way, for the same reason — removing a ghunnah's audio entirely changed their
/// verdict 2.7% of the time.
///
/// A *quantity* escapes that. How long a sound lasted is measurable without the model
/// having any opinion about it: the expected phonemes are forced onto the audio
/// (`CTCForcedAligner`) and the duration is read off the result. The text supplies the
/// expectation and the reciter supplies the scale, so nothing has to be learned from
/// labels at all.
///
/// **Madd** asks whether an elongation ran its length. `quran_transcript` writes the count
/// into the script as a repeated symbol — `مُۥۥسَاا` states two counts of wāw and two of alif
/// — and each is compared against the reciter's own vowels of that same written length.
///
/// **Qalqalah** asks whether the bounce was given room. A sākin qāf is a closure, a burst,
/// then a short voiced echo; a reciter who skips it releases the stop straight into what
/// follows and that interval collapses. Compared against this reciter's own releases *of
/// the same letter*, since a ب and a ق do not release alike.
///
/// Measured over 58 āyāt each of Al-Husary, Al-Minshawi and Al-Afasy, against elongations
/// halved and qalqalah releases excised:
///
///     rule        caught          false flags in 174 āyāt
///     qalqalah    10/39  (26%)     3
///     madd        18/141 (13%)    10
///
/// Modest detectors rather than good ones. They are also the only two tajweed checks in
/// this app that have ever survived measurement, and both survived by asking how long
/// something lasted rather than what it was.
///
/// Two further checks are implemented, measured, and off. A vowel drawn out where the text
/// has none costs about four and a half false flags per catch
/// (`Options.flagsOverlongVowels`); a ghunnah's hold caught none of 27 rushed nasals while
/// questioning 57 correct ones (`Options.judgesGhunnahHold`).
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
        /// mentioned.
        ///
        /// Far less severe than "half as long" would suggest, because the gap between the
        /// neighbouring consonants also contains the transitions either side, so it moves
        /// by less than the vowel does. Swept against elongations shortened to half their
        /// length, over 81 measured madds:
        ///
        ///     shortfall   falsely flagged   caught
        ///     0.90        21                14/42
        ///     0.85        10                14/42
        ///     0.80         5                16/42
        ///     0.75         4                10/42
        ///
        /// 0.8 is better than its neighbours on both counts at once, which is the only
        /// reason to prefer a middle value.
        public var maddShortfall: Double
        /// How far *above* its expected length a vowel must run before it is mentioned.
        ///
        /// Only consulted when `flagsOverlongVowels` is on.
        public var maddExcess: Double
        /// Also report vowels drawn out longer than the text asks for.
        ///
        /// **Off by default, and the reason is the price.** Detecting a short vowel
        /// stretched into an elongation is possible, but not cheaply — measured over 47
        /// passages of correct recitation against vowels stretched to 2.5× their length:
        ///
        ///     over-length at   falsely flagged   stretched caught   shortened caught
        ///     off               4                —                  11/42
        ///     2.5              18                1/43               12/42
        ///     2.0              33                7/43               11/42
        ///     1.8              48                10/43              10/42
        ///     1.6              63                13/43              12/42
        ///
        /// About four and a half false flags for every genuine catch, and at the useful
        /// settings roughly one wrong flag per āyah of correct recitation. Reciters also
        /// legitimately stretch vowels for reasons the text does not record — tarteel
        /// pace, breath, emphasis — so some of what this calls an error is not one.
        ///
        /// Left available because it does work, and someone drilling a specific passage
        /// may want it. Left off because a check that is wrong four times for every time
        /// it is right does not belong on by default in this app.
        public var flagsOverlongVowels: Bool
        /// How far below the reciter's own ghunnahs one must fall before it is
        /// questioned. Set by the same sweep as `maddShortfall`.
        public var ghunnahShortfall: Double
        /// Judge how long a ghunnah was held.
        ///
        /// **Off, on measurement.** Over 58 āyāt of Al-Husary it questioned 57 correct
        /// ghunnahs — very nearly one an āyah — and caught 0 of 27 deliberately rushed
        /// ones. It was not a threshold that needed tightening: the check was contributing
        /// nothing but noise, and it was doing so in the app.
        ///
        /// The cause is that a nūn's hold is not one quantity. A doubled nūn is a clean
        /// sustained sound; the nasal of an ikhfāʾ or iqlāb is a transition whose length
        /// is set by the letter that follows. Restricting to the doubled letter, which the
        /// code already does, was not enough — even among doubled nūns the hold varies
        /// with the vowel after it and with where the phrase is going.
        ///
        /// Qalqalah avoids this by grouping its baseline per letter, which is the same
        /// remedy `durationsByHarakat` applies to madd. The equivalent grouping for ghunnah
        /// would be by following letter, and there are too few of each in a session to
        /// build a median from. Left available, and off.
        public var judgesGhunnahHold: Bool
        /// How far below the reciter's own releases of that same letter a qalqalah must
        /// fall before it is questioned.
        ///
        /// 0.7 measured over three reciters, 58 āyāt each, against releases excised to
        /// two fifths: 10 of 39 caught for 3 false flags. Both halves of that came from
        /// grouping the baseline per letter and skipping the last phoneme of a passage —
        /// before those, the same threshold caught 1 of 13 for 12 false flags. Qalqalah
        /// kubrā at a pause is a heavier bounce by rule, and a ب is not a ق.
        public var qalqalaShortfall: Double
        /// Beyond this ratio to what was expected, a duration is treated as an alignment
        /// failure rather than a recitation error, and nothing is said.
        ///
        /// The first real session recorded through the app made the case for it. Sūrat
        /// al-Kahf, 11 āyāt, and the check reported a short vowel held for 3.44 s — 21×
        /// its expected length — with the audio in that stretch at full level throughout.
        /// Nobody holds a fatḥa for three and a half seconds. Forced alignment had put the
        /// neighbouring consonants several words apart, and the gap between them was
        /// measuring other speech.
        ///
        /// The cause is that the app segments to 20 s while every threshold here was
        /// fitted on single āyāt of a few seconds, and this file already records that
        /// alignment decays over long passages. Chunked re-alignment exists for that
        /// (`IqraEval --refine`) and has never been brought into the app. Until it is,
        /// this is the floor under the damage: a measurement that absurd is not evidence
        /// about someone's recitation, and the honest response to it is silence.
        ///
        /// Set from that session's observed failures rather than from a sweep, so it is a
        /// bound on nonsense and not a tuned threshold.
        public var implausibleRatio: ClosedRange<Double>
        /// Mean alignment confidence a *word* needs before its elongations are judged.
        ///
        /// Forced alignment returns a path whatever it is given, so this asks whether the
        /// audio actually contains the word before any duration is read off it. Per word,
        /// never per phoneme: a shortened elongation lowers confidence on the phonemes
        /// around it, and gating on those looks away from exactly the case being checked.
        public var wordSupport: Double
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
            maddShortfall: Double = 0.8,
            maddExcess: Double = 1.8,
            flagsOverlongVowels: Bool = false,
            ghunnahShortfall: Double = 0.7,
            judgesGhunnahHold: Bool = false,
            qalqalaShortfall: Double = 0.7,
            implausibleRatio: ClosedRange<Double> = 0.35...3.5,
            wordSupport: Double = 0.5,
            minimumBaselineMadds: Int = 3,
            judgesSifat: Bool = false
        ) {
            self.judgesSifat = judgesSifat
            self.maddShortfall = maddShortfall
            self.maddExcess = maddExcess
            self.flagsOverlongVowels = flagsOverlongVowels
            self.ghunnahShortfall = ghunnahShortfall
            self.judgesGhunnahHold = judgesGhunnahHold
            self.qalqalaShortfall = qalqalaShortfall
            self.implausibleRatio = implausibleRatio
            self.wordSupport = wordSupport
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

    /// The short vowels: fatḥa, ḍamma, kasra.
    ///
    /// Needed for the opposite mistake — an elongation where the text has none. A long
    /// vowel is always written as a repeated carrier, so a *single* carrier essentially
    /// never occurs and looking for one found nothing at all. A vowel the text writes
    /// short is one of these, and drawing one out is what "madd where there is no madd"
    /// actually looks like in the script.
    static let shortVowels: Set<Int> = [32, 33, 34]

    private let model: MuaalemTajweedAnalyzer
    private let script: PhonemeScript
    private let options: Options
    private let aligner = CTCForcedAligner(blank: 0)
    private var lastCoverage: TajweedCoverage = .none
    /// Seconds per haraka, gathered from every two-count madd heard this session.
    ///
    /// Held across calls rather than recomputed per passage. A single āyah rarely holds
    /// the three natural madds needed to establish a pace, so a per-passage baseline
    /// simply refused to judge — measured at 1 detection in 42 attempts, with the
    /// elongations it declined to look at making up almost all of the gap. Recitation
    /// pace does not change between one āyah and the next, so there is no reason to
    /// throw the evidence away at the passage boundary.
    private var harakaSamples: [Double] = []
    /// Durations of every elongation heard this session, grouped by how many harakāt it
    /// is supposed to run for.
    ///
    /// A four-count madd is compared against the reciter's *other* four-count madds, not
    /// against twice their two-count pace. Extrapolating from the short ones proved too
    /// lenient to be useful: measured on Al-Husary, his four-counts run about 0.56 s
    /// where twice his two-count pace predicts 0.48 s, so the shortfall threshold sat
    /// almost exactly where halving the elongation lands — and halved madds were caught
    /// 0 times in 42. Comparing like with like removes the extrapolation.
    private var durationsByHarakat: [Int: [Double]] = [:]
    /// How long the reciter holds a ghunnah, gathered across the session.
    private var ghunnahHolds: [Double] = []
    /// How long the reciter's qalqalah releases run, gathered across the session.
    ///
    /// Qalqalah is sparse — about 0.7 phonemes an āyah carry it, against several
    /// elongations — so a passage-local baseline would almost never have enough to judge
    /// against. Same reasoning as `harakaSamples`: the way someone bounces a sākin qāf
    /// does not change between one āyah and the next.
    ///
    /// Grouped by which letter it is. The five qalqalah letters are not interchangeable —
    /// a ب releases quite differently from a ق — and pooling them produces a median that
    /// describes none of them, which is exactly how the ghunnah hold check came to
    /// question 57 correct recitations to catch none.
    private var qalqalaReleases: [Int: [Double]] = [:]

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
            // Only words the matcher is confident were recited, and confident *which*
            // word they were.
            //
            // Judging a madd means reading a duration off a forced alignment, and a
            // forced alignment always returns a path whether or not the audio contains
            // the words it was given. If the matcher was wrong about which words this
            // stretch holds — and at this pipeline's word error rate it often is — the
            // phonemes being aligned do not correspond to the sound, every duration read
            // from them is arbitrary, and the elongations "found" in it were never
            // recited at all. That is how the check ends up inventing elongations.
            let spoken = segment.words
                .filter { $0.timeRange != nil && $0.status == .correct }
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

            // A second gate, on the audio rather than the transcript: the words whose
            // expected sounds the alignment actually found. Deliberately measured per
            // *word* and not per phoneme — a shortened elongation lowers confidence on
            // the phonemes around it, so a phoneme-level gate would look away from the
            // very case being checked. That mistake cost 42 undetected madds earlier.
            var supported: Set<Int> = []
            var perWord: [Int: (sum: Double, count: Int)] = [:]
            for span in spans where span.index < owner.count {
                let index = owner[span.index].word.globalIndex
                var entry = perWord[index] ?? (0, 0)
                entry.sum += span.confidence
                entry.count += 1
                perWord[index] = entry
            }
            for (index, entry) in perWord
            where entry.count > 0 && entry.sum / Double(entry.count) >= options.wordSupport {
                supported.insert(index)
            }

            notes += maddNotes(
                spans: spans,
                owner: owner,
                symbols: symbols,
                supported: supported,
                examined: &examined
            )
            if options.judgesGhunnahHold {
                notes += ghunnahNotes(
                    spans: spans,
                    owner: owner,
                    supported: supported,
                    examined: &examined
                )
                required += ghunnahRuns(in: owner).count
            }
            notes += qalqalaNotes(
                spans: spans,
                owner: owner,
                symbols: symbols,
                supported: supported,
                examined: &examined
            )
            required += qalqalaPositions(in: owner).count
            // What this analyzer will actually try to judge: elongations, minus the final
            // vowel of the passage, and minus the short ones unless over-length checking
            // is on. Counting anything else would make the coverage report compare two
            // different things — which it did, quoting the ṣifāt rules on the page
            // against the elongations examined.
            required += maddRuns(in: symbols).count { run in
                guard run.range.upperBound < symbols.count - 1 else { return false }
                return options.flagsOverlongVowels || run.harakat > 2
            }

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

    /// Every vowel in the sequence: (range, how many counts it is written for).
    ///
    /// Single vowels are included, not only repeats. A madd where the text has none — a
    /// short vowel drawn out into an elongation — is as much a mistake as an elongation
    /// left short, and it can only be seen by measuring the vowels that are *supposed* to
    /// be brief.
    private func maddRuns(in symbols: [Int]) -> [(range: Range<Int>, harakat: Int)] {
        var runs: [(Range<Int>, Int)] = []
        var index = 0
        while index < symbols.count {
            let symbol = symbols[index]
            var end = index + 1
            while end < symbols.count, symbols[end] == symbol { end += 1 }
            if Self.maddCarriers.contains(symbol) {
                runs.append((index..<end, end - index))
            } else if Self.shortVowels.contains(symbol), end - index == 1 {
                // One count: however long the reciter's haraka is, this is one of them.
                runs.append((index..<end, 1))
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
        supported: Set<Int>,
        examined: inout Int
    ) -> [TajweedNote] {
        let byIndex = Dictionary(spans.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        var measured: [(range: Range<Int>, harakat: Int, seconds: Double, startFrame: Int, confident: Bool)] = []

        for run in maddRuns(in: symbols) {
            // The gap between the consonant before the elongation and the one after it.
            //
            // Not the span of the madd symbols themselves, which was the obvious choice
            // and does not work: CTC spikes mark *events*, not extents, so the repeated
            // symbols land on the vowel's onset and on the transition out of it wherever
            // the vowel's own length happens to fall between. Measured directly — halve
            // a vowel's audio and the symbol span stays put:
            //
            //     madd 4h   span 0.56 → 0.56 s     gap 1.64 → 1.40 s
            //     madd 4h   span 0.56 → 0.56 s     gap 2.00 → 1.72 s
            //     madd 6h   span 0.88 → 0.88 s     gap 2.92 → 2.48 s
            //
            // The sustained sound lives in the silence *between* spikes, so the interval
            // between the neighbouring consonants is what actually carries the duration.
            // It moves by less than the audio does, because it also contains the
            // transitions either side — which is why the shortfall threshold has to be
            // far less severe than a naive reading of "half as long" suggests.
            var confident = true
            var lower = Int.max
            var upper = 0
            for index in run.range {
                guard let span = byIndex[index] else { confident = false; continue }
                lower = min(lower, span.frames.lowerBound)
                upper = max(upper, span.frames.upperBound)
                // No confidence bar at all, and this took three attempts to accept.
                // Cutting an elongation short lowers the aligner's confidence in the
                // phonemes around the cut — so *every* threshold, however low, excluded
                // precisely the recitations being checked. At 0.4 and at 0.05 the
                // shortened madds produced no measurement whatsoever: 0 caught out of 42
                // both times, not because the duration looked right but because it was
                // never looked at. Forced alignment spans the audio whether it is
                // confident or not, and duration is the whole question here.
            }
            guard upper > lower else { continue }
            // Widen to the neighbouring consonants where they exist.
            let before = spans.last { $0.index < run.range.lowerBound }
            let after = spans.first { $0.index >= run.range.upperBound }
            let from = before?.frames.upperBound ?? lower
            let to = after?.frames.lowerBound ?? upper
            let frames = to > from ? to - from : upper - lower
            let seconds = Double(frames) * 0.04   // the model's frame rate
            measured.append((run.range, run.harakat, seconds, from, confident))
        }

        // Judge against evidence gathered *before* this passage. Feeding the current
        // measurements in first — especially from a shortened elongation — dilutes the
        // peer median with the very duration being questioned.
        var notes: [TajweedNote] = []
        if harakaSamples.count >= options.minimumBaselineMadds {
            let baseline = harakaSamples.sorted()[harakaSamples.count / 2]
            for entry in measured where entry.confident {
                // The final vowel of a passage is skipped: stopping on a word lengthens
                // it legitimately — madd ʿāriḍ liʾs-sukūn — and whether the reciter
                // pauses there is their choice, not something the text states.
                guard entry.range.upperBound < symbols.count - 1 else { continue }
                // Whose word this elongation belongs to, and whether the audio bore it out.
                guard owner.indices.contains(entry.range.lowerBound),
                      supported.contains(owner[entry.range.lowerBound].word.globalIndex)
                else { continue }
                examined += 1

                // The reciter's own vowels of this same written length. Comparing like
                // with like, because the gap measure includes the transitions either
                // side and those do not scale with the count.
                let peers = (durationsByHarakat[entry.harakat] ?? []).sorted()
                let expected = peers.count >= options.minimumBaselineMadds
                    ? peers[peers.count / 2]
                    : Double(entry.harakat) * baseline

                // Two mistakes, opposite in direction. An elongation left short, and a
                // vowel drawn out where the text asks for none — the second is only
                // visible because short vowels are measured too, not just the madds.
                // An alignment that has drifted produces ratios no recitation can: this
                // session logged 21×. Say nothing rather than accuse someone of it.
                guard expected > 0,
                      options.implausibleRatio.contains(entry.seconds / expected)
                else { continue }

                let tooShort = entry.harakat > 2 && entry.seconds < expected * options.maddShortfall
                let tooLong = options.flagsOverlongVowels
                    && entry.seconds > expected * options.maddExcess
                guard tooShort || tooLong else { continue }
                guard let word = owner.indices.contains(entry.range.lowerBound)
                    ? owner[entry.range.lowerBound].word : nil else { continue }

                let start = Double(entry.startFrame) * 0.04
                notes.append(
                    TajweedNote(
                        rule: entry.harakat >= 6 ? .maddLazim
                            : entry.harakat > 2 ? .maddWajibMuttasil : .maddAsli,
                        targetIndex: word.globalIndex,
                        reference: word.reference,
                        timeRange: start...(start + entry.seconds),
                        confidence: .low,
                        message: tooLong
                            ? (entry.harakat <= 1
                                ? "This sounds drawn out — the text has no elongation here."
                                : "This sounds longer than the \(entry.harakat) harakāt the text asks for.")
                            : "This elongation sounds short — it should run about \(entry.harakat) harakāt.",
                        measurement: .init(observed: entry.seconds, expected: expected, unit: "s")
                    )
                )
            }
        }

        // The reciter's own haraka, from their natural two-count madds — this passage's
        // and every earlier one's.
        harakaSamples.append(contentsOf: measured.filter { $0.harakat == 2 && $0.confident }.map { $0.seconds / 2 })
        if harakaSamples.count > 200 { harakaSamples.removeFirst(harakaSamples.count - 200) }
        for entry in measured where entry.confident {
            durationsByHarakat[entry.harakat, default: []].append(entry.seconds)
            if durationsByHarakat[entry.harakat]!.count > 60 {
                durationsByHarakat[entry.harakat]!.removeFirst()
            }
        }
        return notes
    }

    /// Runs of consecutive phonemes that must all be nasalised — one ghunnah each.
    ///
    /// A doubled nūn is written twice in the phonetic script, so the sound to be held
    /// spans two symbols rather than one.
    private func ghunnahRuns(
        in owner: [(word: TargetWord, ghonna: UInt8, qalqala: UInt8)]
    ) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var index = 0
        while index < owner.count {
            guard owner[index].ghonna == 1 else { index += 1; continue }
            var end = index + 1
            while end < owner.count, owner[end].ghonna == 1 { end += 1 }
            // Only the doubled letter — نّ and مّ, written twice in the script.
            //
            // Every position the text marks for nasalisation is not the same sound. A
            // doubled nūn is a clean sustained hold; the nasal of an ikhfāʾ or an iqlāb
            // is a transition into the following letter, and how long it lasts depends on
            // what follows rather than on the rule. Pooling them gave a median that
            // described none of them: at every threshold from 0.8 down to 0.4 it
            // questioned 75 to 99 correct ghunnahs to catch three or four rushed ones.
            if end - index >= 2 { runs.append(index..<end) }
            index = end
        }
        return runs
    }

    /// Was the ghunnah held for its two harakāt?
    ///
    /// A ghunnah is two things at once: a nasal sound, and a nasal sound *held for two
    /// counts*. Only the first has resisted measurement. Whether the model can hear
    /// nasality — it cannot, reliably — has no bearing on whether the letter lasted as
    /// long as it should have, and that half is measurable with exactly the machinery
    /// that already checks madd.
    ///
    /// So this catches the reciter who says the nūn but runs straight past it, which is
    /// the commoner fault of the two and the one a beginner makes. It cannot catch the
    /// reciter who holds the letter for the right length without nasalising it: to this
    /// check that is a correct ghunnah, and it says nothing about it.
    private func ghunnahNotes(
        spans: [CTCForcedAligner.Span],
        owner: [(word: TargetWord, ghonna: UInt8, qalqala: UInt8)],
        supported: Set<Int>,
        examined: inout Int
    ) -> [TajweedNote] {
        let byIndex = Dictionary(spans.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        var measured: [(range: Range<Int>, seconds: Double, startFrame: Int)] = []

        for run in ghunnahRuns(in: owner) {
            guard let first = byIndex[run.lowerBound] else { continue }
            // From the nasal's own onset to the next sound's: the hold lives between
            // spikes, not inside one. Same lesson as madd, and it cost 42 undetected
            // elongations to learn the first time.
            let next = spans.first { $0.index >= run.upperBound }
            let from = first.frames.lowerBound
            let to = next?.frames.lowerBound ?? (byIndex[run.upperBound - 1]?.frames.upperBound ?? from)
            guard to > from else { continue }
            measured.append((run, Double(to - from) * 0.04, from))
        }

        var notes: [TajweedNote] = []
        if ghunnahHolds.count >= options.minimumBaselineMadds {
            let expected = ghunnahHolds.sorted()[ghunnahHolds.count / 2]
            for entry in measured {
                guard owner.indices.contains(entry.range.lowerBound) else { continue }
                let word = owner[entry.range.lowerBound].word
                guard supported.contains(word.globalIndex) else { continue }
                examined += 1
                guard entry.seconds < expected * options.ghunnahShortfall else { continue }
                let start = Double(entry.startFrame) * 0.04
                notes.append(
                    TajweedNote(
                        rule: .ghunnah,
                        targetIndex: word.globalIndex,
                        reference: word.reference,
                        timeRange: start...(start + entry.seconds),
                        confidence: .low,
                        message: "This ghunnah sounds short — the nūn or mīm should be held about two harakāt.",
                        measurement: .init(observed: entry.seconds, expected: expected, unit: "s")
                    )
                )
            }
        }

        ghunnahHolds.append(contentsOf: measured.map(\.seconds))
        if ghunnahHolds.count > 120 { ghunnahHolds.removeFirst(ghunnahHolds.count - 120) }
        return notes
    }

    /// Phonemes the text marks for qalqalah, each its own bounce.
    ///
    /// Not grouped into runs the way ghunnah is. A doubled nūn is one held sound written
    /// twice, but a sākin qāf followed by another qalqalah letter is two separate bounces,
    /// and merging them would measure one release where the reciter owes two.
    private func qalqalaPositions(
        in owner: [(word: TargetWord, ghonna: UInt8, qalqala: UInt8)]
    ) -> [Int] {
        owner.indices.filter { owner[$0].qalqala == 1 }
    }

    /// Was the qalqalah actually released, or did the stop run straight into what follows?
    ///
    /// The same measurement as madd and the ghunnah hold, and it is here for the same
    /// reason: qalqalah has a duration, and duration is what forced alignment can report
    /// honestly. A sākin qāf is a closure, a burst, and then a short voiced echo before the
    /// next sound begins. CTC puts its spike on the burst — that is where the letter
    /// becomes recognisable — so the echo lies in the interval between that spike and the
    /// next one, exactly where a madd's sustained vowel lies.
    ///
    /// A reciter who skips the qalqalah does not omit the letter; they release it straight
    /// into the following sound, and that interval collapses. So this asks whether the
    /// bounce was given room, measured against how much room this reciter gives their
    /// other bounces.
    ///
    /// It cannot tell a well-shaped echo from a flat one of the same length, any more than
    /// the ghunnah check can hear nasality. Both judge the half of the rule that is a
    /// quantity. The other half needs audio where the ṣifah is absent, which no corpus of
    /// correct recitation contains.
    private func qalqalaNotes(
        spans: [CTCForcedAligner.Span],
        owner: [(word: TargetWord, ghonna: UInt8, qalqala: UInt8)],
        symbols: [Int],
        supported: Set<Int>,
        examined: inout Int
    ) -> [TajweedNote] {
        let byIndex = Dictionary(spans.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        var measured: [(index: Int, letter: Int, seconds: Double, startFrame: Int)] = []

        for position in qalqalaPositions(in: owner) {
            guard let span = byIndex[position], position < symbols.count else { continue }
            // The last phoneme of the passage is skipped, for the reason the final vowel
            // is skipped in madd. Stopping on a sākin stop produces qalqalah kubrā, a
            // markedly heavier bounce, and whether the reciter pauses there is their
            // choice rather than something the text states.
            guard position < owner.count - 1 else { continue }
            // From this stop's burst to the onset of the next sound. No confidence gate,
            // for the reason the madd measurement records: swallowing the release lowers
            // the aligner's confidence around it, so any bar excludes the very case being
            // checked.
            let next = spans.first { $0.index > position }
            let from = span.frames.lowerBound
            guard let to = next?.frames.lowerBound, to > from else { continue }
            measured.append((position, symbols[position], Double(to - from) * 0.04, from))
        }

        var notes: [TajweedNote] = []
        for entry in measured {
            // This letter's own releases, gathered before this passage.
            let peers = (qalqalaReleases[entry.letter] ?? []).sorted()
            guard peers.count >= options.minimumBaselineMadds else { continue }
            let expected = peers[peers.count / 2]

            guard owner.indices.contains(entry.index) else { continue }
            let word = owner[entry.index].word
            guard supported.contains(word.globalIndex) else { continue }
            examined += 1
            guard expected > 0,
                  options.implausibleRatio.contains(entry.seconds / expected)
            else { continue }
            guard entry.seconds < expected * options.qalqalaShortfall else { continue }
            let start = Double(entry.startFrame) * 0.04
            notes.append(
                TajweedNote(
                    rule: .qalqalah,
                    targetIndex: word.globalIndex,
                    reference: word.reference,
                    timeRange: start...(start + entry.seconds),
                    confidence: .low,
                    message: "This qalqalah sounds swallowed — the letter should bounce before the next sound.",
                    measurement: .init(observed: entry.seconds, expected: expected, unit: "s")
                )
            )
        }

        for entry in measured {
            qalqalaReleases[entry.letter, default: []].append(entry.seconds)
            if qalqalaReleases[entry.letter]!.count > 40 {
                qalqalaReleases[entry.letter]!.removeFirst()
            }
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
