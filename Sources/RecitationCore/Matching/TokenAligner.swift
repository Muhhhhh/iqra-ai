import Foundation

/// Tuning knobs for the aligner. Defaults are deliberately forgiving.
public struct MatchingOptions: Sendable, Equatable {
    /// At or above this character similarity, two tokens are the same word.
    public var matchThreshold: Double
    /// Between `uncertainThreshold` and `matchThreshold`, we report `.uncertain`
    /// (an advisory hint) instead of `.wrong`. Below it, `.wrong`.
    public var uncertainThreshold: Double
    /// Recognizer confidence below which a substitution is downgraded to `.uncertain`.
    /// If the model wasn't sure it heard the word, we are not sure it was a mistake.
    public var confidenceFloor: Double
    /// Cost of leaving an expected word unmatched (a skip).
    public var deletionCost: Double
    /// Cost of an extra recited word (an insertion).
    public var insertionCost: Double
    /// Extra charge for *starting* a run of skipped or added words.
    ///
    /// This is what makes the aligner prefer one contiguous gap over several scattered
    /// ones, matching how people actually recite. Set to 0 for plain Levenshtein.
    public var gapOpenCost: Double
    /// How far around an unmatched word to look for the same word in the passage before
    /// calling it a genuine addition.
    ///
    /// Reciters correct themselves constantly — stumbling and repeating a word,
    /// restarting a phrase, going back to the start of the āyah. Those re-attempts are
    /// unmatched words, and reporting them as additions tells someone they inserted
    /// words into the Quran. Anything that also occurs this close by is treated as a
    /// repetition instead.
    ///
    /// Widened from 8 to 40 once input gain brought the rest of the recitation into the
    /// matcher: going back over an āyah puts the re-attempt far more than eight words
    /// from where the matcher last was. Measured on clean recitation, fabricated
    /// additions fell from 23 to 12 and re-recited āyāt misread as added words from 56
    /// to 24, with no change to word verdicts or to wrong-āyah detection. Past 40 there
    /// is no further gain.
    public var repetitionWindow: Int
    /// Recognizer confidence below which an unmatched word is not reported at all.
    ///
    /// Insertions were exempt from the confidence rule that governs every other verdict,
    /// which did not matter while half the recitation never reached the matcher. Once
    /// input gain fixed that, the extra tokens arrived and fabricated additions on
    /// correct recitation went from 7 to 24.
    public var insertionConfidenceFloor: Double
    /// How near another matched word a match must be to count as corroborated.
    ///
    /// Recitation is continuous, so matches arrive in runs. A single word matched with
    /// nothing near it is not someone reciting there — it is a noisy transcript finding
    /// one familiar-looking word somewhere else on the page. Measured over 21 muṣḥaf
    /// pages recited from the middle, isolated matches landed as far as 53 words past
    /// the end of what was recited and 42 words above its start, which on screen is the
    /// highlighting jumping to a completely different āyah.
    ///
    /// Set to 0 to accept isolated matches.
    public var corroborationWindow: Int
    /// How many matches a run detached from the main body needs before it is believed.
    ///
    /// Two is measurably the worst of both: the stray pair survives and detection falls
    /// anyway. The cost of corroborating at all is that a wrong āyah is caught 5 times
    /// in 9 rather than 7 — some of the evidence for "you recited the wrong passage" is
    /// exactly the scattered matches this discards. Taken deliberately: highlighting that
    /// lands on an āyah the reciter never touched is itself a false claim about their
    /// recitation, and this project ranks that above a missed detection.
    public var minimumMatchRun: Int

    public init(
        matchThreshold: Double = 0.82,
        uncertainThreshold: Double = 0.55,
        confidenceFloor: Double = 0.45,
        deletionCost: Double = 1.0,
        insertionCost: Double = 1.0,
        gapOpenCost: Double = 0.5,
        repetitionWindow: Int = 40,
        insertionConfidenceFloor: Double = 0.45,
        corroborationWindow: Int = 6,
        minimumMatchRun: Int = 3
    ) {
        self.corroborationWindow = corroborationWindow
        self.minimumMatchRun = minimumMatchRun
        self.insertionConfidenceFloor = insertionConfidenceFloor
        self.matchThreshold = matchThreshold
        self.uncertainThreshold = uncertainThreshold
        self.confidenceFloor = confidenceFloor
        self.deletionCost = deletionCost
        self.insertionCost = insertionCost
        self.gapOpenCost = gapOpenCost
        self.repetitionWindow = repetitionWindow
    }

    public static let `default` = MatchingOptions()
}

/// Aligns recognized tokens against the expected words using affine-gap sequence
/// alignment over *tokens*, where substitution cost comes from character-level
/// similarity between the two words.
///
/// The point of alignment (rather than a bag-of-words similarity score) is that the
/// backtrace tells us *which* word went wrong and *how*: a substitution is a wrong word,
/// a deletion is a skip, an insertion is an added word.
public struct TokenAligner: Sendable {
    public let options: MatchingOptions

    public init(options: MatchingOptions = .default) {
        self.options = options
    }

    // MARK: - Public API

    /// Align a full token stream against the target text.
    ///
    /// - Parameter isFinal: pass `false` while recording is still in progress. Trailing
    ///   expected words that the reciter simply hasn't reached yet are then reported as
    ///   `.notYetRecited` rather than accused of being skipped.
    public func align(
        heard tokens: [TranscribedToken],
        against target: RecitationTarget,
        isFinal: Bool
    ) -> AlignmentResult {
        let expected = target.flattenedWords
        // Tokens arrive as raw recognizer output; normalise and drop anything that
        // reduces to nothing (punctuation-only tokens, Latin artefacts).
        let heard: [(token: TranscribedToken, normalized: String)] = tokens.compactMap { token in
            let normalized = ArabicNormalizer.normalize(token.text)
            return normalized.isEmpty ? nil : (token, normalized)
        }

        guard !expected.isEmpty else { return AlignmentResult(words: [], insertions: [], isFinal: isFinal) }

        // Each expected word carries every spelling that counts as itself — see
        // `ArabicNormalizer.matchingVariants`. Almost always exactly one.
        let operations = editScript(
            expected: expected.map { word in
                let variants = ArabicNormalizer.matchingVariants(of: word.text)
                // The database's stored form stays authoritative; the variants only add
                // readings it cannot represent.
                return variants.contains(word.normalized) ? variants : [word.normalized] + variants
            },
            heard: heard.map(\.normalized)
        )

        return buildResult(
            operations: operations,
            expected: expected,
            heard: heard,
            isFinal: isFinal
        )
    }

    // MARK: - Edit script

    enum Operation: Equatable {
        /// Expected word i paired with heard token j (may still be a mismatch).
        case align(expected: Int, heard: Int, similarity: Double)
        /// Expected word i had nothing recited for it.
        case delete(expected: Int)
        /// Heard token j has no expected word.
        case insert(heard: Int)
    }

    /// Affine-gap sequence alignment (Gotoh).
    ///
    /// Plain Levenshtein is not sufficient here, for two reasons that both produce
    /// fabricated mistakes:
    ///
    /// 1. **Contiguity.** Flat per-word gap costs make "match a run of words together"
    ///    and "match them scattered across the passage" cost the same. Reciters produce
    ///    contiguous runs, so an affine gap (one gap of four costs less than two gaps of
    ///    two) is what actually models recitation.
    /// 2. **Repeats.** Where the same phrase occurs many times, every occurrence is an
    ///    equally cheap match. Ties are broken toward the earliest, so reciting a
    ///    repeated verse once does not report every earlier occurrence as skipped.
    ///
    /// ## Why this is written the way it is
    ///
    /// Passages are whole surahs now, not a few āyāt: Al-Baqarah is 6,607 words, and
    /// the pipeline realigns after *every* speech segment. The obvious implementation —
    /// a similarity matrix plus three `Double` cost matrices — costs O(m·n) memory and
    /// re-derives a `[Character]` array from every word m·n times. Measured on
    /// Al-Baqarah at 10% recited that took 15.9 s per realignment; in full, 155 s and
    /// 1.5 GB.
    ///
    /// So: words are converted to character arrays once, the inner edit distance reuses
    /// scratch buffers, similarity is computed on the fly rather than stored, and the
    /// costs are kept as two rolling rows with a byte of backtrace direction per cell.
    /// Memory is O(m·n) *bytes* rather than O(m·n) doubles ×4, and the results are
    /// identical — this is an optimisation, not an approximation.
    /// - Parameter expected: one entry per expected word, each holding that word's
    ///   accepted spellings. A cell's cost uses whichever spelling fits best.
    func editScript(expected: [[String]], heard: [String]) -> [Operation] {
        let m = expected.count
        let n = heard.count
        guard m > 0 else { return (0..<n).map { .insert(heard: $0) } }
        guard n > 0 else { return (0..<m).map { .delete(expected: $0) } }

        // Converted once each, not once per cell.
        let expectedChars = expected.map { $0.map(Array.init) }
        let heardChars = heard.map(Array.init)

        let infinity = Double.greatestFiniteMagnitude / 4
        let open = options.gapOpenCost
        let deletion = options.deletionCost
        let insertion = options.insertionCost

        // Predecessor states, packed two bits each into one byte per cell.
        let fromMatch: UInt8 = 0, fromSkip: UInt8 = 1, fromExtra: UInt8 = 2
        let width = n + 1
        var directions = [UInt8](repeating: 0, count: (m + 1) * width)

        // Scratch for the inner character edit distance, sized once.
        let longestHeardWord = heardChars.map(\.count).max() ?? 0
        var scratchA = [Int](repeating: 0, count: longestHeardWord + 2)
        var scratchB = [Int](repeating: 0, count: longestHeardWord + 2)

        // match: ends with expected[i-1] aligned to heard[j-1]
        // skip:  ends with expected[i-1] unmatched (a skip)
        // extra: ends with heard[j-1] unmatched (an addition)
        var matchPrev = [Double](repeating: infinity, count: width)
        var skipPrev = [Double](repeating: infinity, count: width)
        var extraPrev = [Double](repeating: infinity, count: width)
        var matchRow = matchPrev, skipRow = skipPrev, extraRow = extraPrev

        matchPrev[0] = 0
        for j in 1...n {
            extraPrev[j] = open + Double(j) * insertion
            directions[j] = (j == 1 ? fromMatch : fromExtra) << 4
        }

        for i in 1...m {
            let expectedWord = expectedChars[i - 1]
            let rowOffset = i * width

            matchRow[0] = infinity
            extraRow[0] = infinity
            skipRow[0] = open + Double(i) * deletion
            directions[rowOffset] = (i == 1 ? fromMatch : fromSkip) << 2

            for j in 1...n {
                // --- match ---------------------------------------------------------
                let similarity = Self.bestSimilarity(
                    expectedWord, heardChars[j - 1], scratchA: &scratchA, scratchB: &scratchB
                )
                let substitution = 1.0 - similarity
                // Ties prefer skip, which biases equal-cost paths toward the earliest
                // match. See the note on repeated text above.
                var best = skipPrev[j - 1]
                var bestState = fromSkip
                if matchPrev[j - 1] < best { best = matchPrev[j - 1]; bestState = fromMatch }
                if extraPrev[j - 1] < best { best = extraPrev[j - 1]; bestState = fromExtra }
                matchRow[j] = substitution + best
                var packed = bestState

                // --- skip ----------------------------------------------------------
                var skipBest = skipPrev[j] + deletion
                var skipState = fromSkip
                let skipFromMatch = matchPrev[j] + open + deletion
                if skipFromMatch < skipBest { skipBest = skipFromMatch; skipState = fromMatch }
                let skipFromExtra = extraPrev[j] + open + deletion
                if skipFromExtra < skipBest { skipBest = skipFromExtra; skipState = fromExtra }
                skipRow[j] = skipBest
                packed |= skipState << 2

                // --- extra ---------------------------------------------------------
                var extraBest = extraRow[j - 1] + insertion
                var extraState = fromExtra
                let extraFromSkip = skipRow[j - 1] + open + insertion
                if extraFromSkip < extraBest { extraBest = extraFromSkip; extraState = fromSkip }
                let extraFromMatch = matchRow[j - 1] + open + insertion
                if extraFromMatch < extraBest { extraBest = extraFromMatch; extraState = fromMatch }
                extraRow[j] = extraBest
                packed |= extraState << 4

                directions[rowOffset + j] = packed
            }

            swap(&matchPrev, &matchRow)
            swap(&skipPrev, &skipRow)
            swap(&extraPrev, &extraRow)
        }

        // The alignment spans the whole expected text. Trailing words that were never
        // reached are relabelled downstream (see `buildResult`) rather than being made
        // free here — charging nothing for them would let the DP "give up early" more
        // cheaply than admitting a mid-passage skip, which mislabels real skips as
        // wrong words.
        var i = m
        var j = n
        var state: UInt8 = {
            let best = min(matchPrev[n], skipPrev[n], extraPrev[n])
            if abs(skipPrev[n] - best) < 1e-9 { return fromSkip }
            if abs(matchPrev[n] - best) < 1e-9 { return fromMatch }
            return fromExtra
        }()

        var operations: [Operation] = []
        operations.reserveCapacity(m + n)

        while i > 0 || j > 0 {
            let packed = directions[i * width + j]
            switch state {
            case fromMatch:
                guard i > 0, j > 0 else { state = i > 0 ? fromSkip : fromExtra; continue }
                // Recomputed for the O(m + n) cells on the path only.
                let similarity = Self.bestSimilarity(
                    expectedChars[i - 1], heardChars[j - 1], scratchA: &scratchA, scratchB: &scratchB
                )
                operations.append(.align(expected: i - 1, heard: j - 1, similarity: similarity))
                state = packed & 0b11
                i -= 1
                j -= 1

            case fromSkip:
                guard i > 0 else { state = fromExtra; continue }
                operations.append(.delete(expected: i - 1))
                state = (packed >> 2) & 0b11
                i -= 1

            default:
                guard j > 0 else { state = fromSkip; continue }
                operations.append(.insert(heard: j - 1))
                state = (packed >> 4) & 0b11
                j -= 1
            }
        }

        return operations.reversed()
    }


    // MARK: - Result assembly

    private func buildResult(
        operations: [Operation],
        expected: [TargetWord],
        heard: [(token: TranscribedToken, normalized: String)],
        isFinal: Bool
    ) -> AlignmentResult {
        var statuses = [WordStatus?](repeating: nil, count: expected.count)
        var ranges = [ClosedRange<TimeInterval>?](repeating: nil, count: expected.count)
        var confidences = [Double?](repeating: nil, count: expected.count)
        var insertions: [InsertedWord] = []
        var pendingInsertions: [(heardIndex: Int, afterTargetIndex: Int?)] = []
        /// Highest expected index we've seen consumed — anchors insertions and tells us
        /// how far the reciter actually got.
        var lastTargetIndex: Int? = nil
        var furthestMatched = -1
        /// Lowest expected index the reciter actually reached — where they began.
        var firstMatched: Int? = nil

        for operation in operations {
            switch operation {
            case .align(let expectedIndex, let heardIndex, let similarity):
                let token = heard[heardIndex].token
                let range = token.startTime...max(token.startTime, token.endTime)
                ranges[expectedIndex] = range
                confidences[expectedIndex] = token.confidence
                statuses[expectedIndex] = verdict(
                    similarity: similarity,
                    confidence: token.confidence,
                    heard: token.text
                )
                lastTargetIndex = expectedIndex
                furthestMatched = max(furthestMatched, expectedIndex)
                firstMatched = min(firstMatched ?? expectedIndex, expectedIndex)

            case .delete(let expectedIndex):
                statuses[expectedIndex] = .skipped
                lastTargetIndex = expectedIndex

            case .insert(let heardIndex):
                // Classified after the loop: an unmatched word before the first match has
                // no preceding word to anchor to, and the place to look for it is where
                // the reciter began — which is not known until a match has been seen.
                pendingInsertions.append((heardIndex, lastTargetIndex))
            }
        }

        // Drop matches with nothing near them: one word matched forty words from any
        // other is the transcript wandering, not the reciter. Dropped to
        // `notYetRecited` rather than to a mistake — there is no evidence either way,
        // and inventing a verdict is the one thing that must not happen here.
        if options.corroborationWindow > 0 {
            let matched = statuses.indices.filter { index in
                switch statuses[index] {
                case .correct, .uncertain: return true
                default: return false
                }
            }
            if matched.count > 1 {
                let window = options.corroborationWindow
                // Group matches into runs. Testing each match against its nearest
                // neighbour is not enough: two spurious matches beside each other
                // corroborate one another, and a stray *pair* forty words away lights up
                // a distant āyah exactly as a stray single does.
                var clusters: [[Int]] = []
                for index in matched {
                    if var last = clusters.last, let previous = last.last, index - previous <= window {
                        last.append(index)
                        clusters[clusters.count - 1] = last
                    } else {
                        clusters.append([index])
                    }
                }

                // The reciter is wherever the bulk of the evidence is.
                if let main = clusters.max(by: { $0.count < $1.count }), main.count >= 2 {
                    for cluster in clusters where cluster.count < options.minimumMatchRun {
                        let distance = min(
                            abs((cluster.first ?? 0) - (main.last ?? 0)),
                            abs((main.first ?? 0) - (cluster.last ?? 0))
                        )
                        guard distance > window else { continue }
                        for index in cluster {
                            statuses[index] = nil
                            ranges[index] = nil
                            confidences[index] = nil
                        }
                    }
                    furthestMatched = statuses.indices.last { index in
                        switch statuses[index] {
                        case .correct, .uncertain: return true
                        default: return false
                        }
                    } ?? -1
                }
            }
        }

        // A word counts as *skipped* only if the reciter recited on both sides of it.
        //
        // Outside that span the passage was never recited at all, and saying otherwise
        // invents a mistake nobody made:
        //
        // * **After the last match** — stopping after the first verse of a seven-verse
        //   passage is not "skipping six verses". This also covers the ordinary case of
        //   recording still being in progress.
        // * **Before the first match** — someone practising a page rarely starts at its
        //   first word. Beginning in the middle, or at the āyah they are working on, is
        //   not an omission of everything above it. It is also where the recogniser is
        //   least reliable: the opening word of a session is the one the VAD is most
        //   likely to clip, so leading gaps are the *least* trustworthy evidence of a
        //   real skip.
        //
        // A genuine skip of the opening words therefore goes unreported. That is the
        // intended direction of the trade: staying silent about a mistake costs a
        // practice prompt, while inventing one tells someone they misrecited the Quran.
        let unreachedFrom = furthestMatched + 1
        let startedFrom = startOfRecitation(in: statuses)

        for pending in pendingInsertions {
            let token = heard[pending.heardIndex].token
            // The same rule substitutions already follow: if the model was not sure what
            // it heard, we are not sure the reciter said it. An unmatched low-confidence
            // token is far more likely a recogniser artefact than a word someone added to
            // the Quran, and saying nothing costs nothing.
            guard token.confidence >= options.insertionConfidenceFloor else { continue }
            insertions.append(
                InsertedWord(
                    text: token.text,
                    afterTargetIndex: pending.afterTargetIndex,
                    timeRange: token.startTime...max(token.startTime, token.endTime),
                    kind: classify(
                        heard: heard[pending.heardIndex].normalized,
                        near: pending.afterTargetIndex ?? startedFrom,
                        in: expected
                    )
                )
            )
        }

        let words = expected.enumerated().map { index, targetWord -> WordEvaluation in
            var status = statuses[index] ?? (isFinal ? .skipped : .notYetRecited)
            if index >= unreachedFrom, status == .skipped {
                status = .notYetRecited
            }
            if index < startedFrom {
                // Nothing above the starting point is evidence of anything, including a
                // mismatch — see `startOfRecitation`. The timing goes with it: there is
                // no audio of this word to point at.
                return WordEvaluation(
                    targetIndex: targetWord.globalIndex,
                    reference: targetWord.reference,
                    expectedText: targetWord.text,
                    status: .notYetRecited,
                    timeRange: nil,
                    recognizerConfidence: nil
                )
            }
            return WordEvaluation(
                targetIndex: targetWord.globalIndex,
                reference: targetWord.reference,
                expectedText: targetWord.text,
                status: status,
                timeRange: ranges[index],
                recognizerConfidence: confidences[index]
            )
        }

        return AlignmentResult(words: words, insertions: insertions, isFinal: isFinal)
    }

    /// Where the reciter actually began: the first word they demonstrably got right,
    /// provided the passage does not simply start there.
    ///
    /// Someone practising a page usually starts at the āyah they are working on rather
    /// than at the top, and the words above it were never attempted. Finding that
    /// boundary needs one more step than "first word matched", because of how the DP
    /// resolves the first sound it hears. A stray token at the start — a throat-clear,
    /// half a word before the reciter settles, room noise the VAD let through — is
    /// cheaper to pair with the unrecited word above the starting point (a substitution,
    /// at most 1.0) than to call an addition (gap open plus insertion, 1.5). So the word
    /// immediately above where you began gets marked *wrong*, quoting a sound you made
    /// before you started. The boundary therefore walks past mismatches too, and stops
    /// at the first word actually recited correctly.
    ///
    /// The walk only happens when the passage begins with unrecited words. Starting at
    /// the top and misreading the very first word has no such run in front of it, so
    /// that mistake is reported normally — which is the case that matters most.
    private func startOfRecitation(in statuses: [WordStatus?]) -> Int {
        // Everything mismatched and nothing confirmed: the reciter was reading
        // *something*, so those verdicts stand rather than the whole passage going quiet.
        guard let firstCorrect = statuses.firstIndex(of: .correct) else { return 0 }
        // Only a run that includes genuinely unrecited words counts as "started later".
        // Without this, misreading the opening word of a passage begun at its start
        // would be silently forgiven, and that is a mistake worth telling someone about.
        guard statuses[..<firstCorrect].contains(.skipped) else { return 0 }
        return firstCorrect
    }

    /// Decide whether an unmatched word is a self-correction or a genuine addition.
    ///
    /// A word that also appears close by in the passage is almost always the reciter
    /// going back over something: repeating a word after stumbling, restarting a phrase,
    /// or re-reciting an āyah. Only a word that matches nothing nearby is really an
    /// addition to the text.
    private func classify(
        heard: String,
        near anchor: Int?,
        in expected: [TargetWord]
    ) -> InsertedWord.Kind {
        guard !expected.isEmpty else { return .addition }
        // The anchor is the last expected word consumed; a restart looks backward and a
        // stumble-and-continue looks forward, so search both ways.
        let centre = anchor ?? 0
        let lower = max(0, centre - options.repetitionWindow)
        let upper = min(expected.count - 1, centre + options.repetitionWindow)
        guard lower <= upper else { return .addition }

        let heardCharacters = Array(heard)
        var scratchA = [Int](repeating: 0, count: heardCharacters.count + 2)
        var scratchB = [Int](repeating: 0, count: heardCharacters.count + 2)

        for index in lower...upper {
            let similarity = Self.similarity(
                Array(expected[index].normalized), heardCharacters,
                scratchA: &scratchA, scratchB: &scratchB
            )
            // Deliberately the *uncertain* threshold, not the match threshold: the
            // asymmetry runs the other way here. Mistaking a genuine addition for a
            // repetition merely under-reports; mistaking a stumbled half-word for an
            // addition tells someone they added words to the Quran. A truncated
            // "الل" before restarting "ٱللَّهُ" scores 0.75 — a stumble, not an addition.
            if similarity >= options.uncertainThreshold { return .repetition }
        }
        return .addition
    }

    /// Turn a similarity + recognizer confidence into a verdict, erring toward silence.
    private func verdict(similarity: Double, confidence: Double, heard: String) -> WordStatus {
        if similarity >= options.matchThreshold {
            return .correct
        }
        // The model itself wasn't sure what it heard — don't escalate to a mistake.
        if confidence < options.confidenceFloor {
            return .uncertain(heard: heard)
        }
        if similarity >= options.uncertainThreshold {
            return .uncertain(heard: heard)
        }
        return .wrong(heard: heard)
    }

    // MARK: - Character-level similarity

    /// Normalised similarity in 0...1 from character edit distance.
    /// Both inputs are expected to be `ArabicNormalizer`-normalised already.
    public static func similarity(_ lhs: String, _ rhs: String) -> Double {
        if lhs == rhs { return 1.0 }
        if lhs.isEmpty || rhs.isEmpty { return 0.0 }
        var scratchA = [Int](repeating: 0, count: rhs.count + 2)
        var scratchB = [Int](repeating: 0, count: rhs.count + 2)
        return similarity(Array(lhs), Array(rhs), scratchA: &scratchA, scratchB: &scratchB)
    }

    /// The best similarity across an expected word's accepted spellings.
    ///
    /// One spelling is the overwhelmingly common case, so this costs nothing extra
    /// except on the words that are genuinely ambiguous.
    static func bestSimilarity(
        _ variants: [[Character]],
        _ heard: [Character],
        scratchA: inout [Int],
        scratchB: inout [Int]
    ) -> Double {
        var best = 0.0
        for variant in variants {
            let score = similarity(variant, heard, scratchA: &scratchA, scratchB: &scratchB)
            if score > best { best = score }
            if best >= 1.0 { break }
        }
        return best
    }

    /// Similarity over pre-converted character arrays, reusing caller-owned scratch.
    ///
    /// The hot path: called once per DP cell, so it must not allocate. Building the
    /// character arrays and the scratch buffers is the caller's job precisely so that
    /// neither happens m×n times.
    static func similarity(
        _ lhs: [Character],
        _ rhs: [Character],
        scratchA: inout [Int],
        scratchB: inout [Int]
    ) -> Double {
        if lhs.isEmpty || rhs.isEmpty { return 0.0 }
        if lhs == rhs { return 1.0 }
        let distance = characterEditDistance(lhs, rhs, previous: &scratchA, current: &scratchB)
        return 1.0 - (Double(distance) / Double(max(lhs.count, rhs.count)))
    }

    static func characterEditDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        var previous = [Int](repeating: 0, count: rhs.count + 2)
        var current = [Int](repeating: 0, count: rhs.count + 2)
        return characterEditDistance(lhs, rhs, previous: &previous, current: &current)
    }

    /// Levenshtein over two rolling rows supplied by the caller, so the hot path
    /// performs no allocation.
    static func characterEditDistance(
        _ lhs: [Character],
        _ rhs: [Character],
        previous: inout [Int],
        current: inout [Int]
    ) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        for j in 0...rhs.count { previous[j] = j }
        for i in 1...lhs.count {
            current[0] = i
            let lhsCharacter = lhs[i - 1]
            for j in 1...rhs.count {
                let substitutionCost = lhsCharacter == rhs[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + substitutionCost
                )
            }
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }
}
