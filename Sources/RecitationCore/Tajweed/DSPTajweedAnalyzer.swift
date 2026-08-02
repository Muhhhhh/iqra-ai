import Foundation

/// Measures elongation against the reciter's own pace.
///
/// ## What this can and cannot do
///
/// Tajweed durations are *relative*. A haraka is not a number of milliseconds; it is a
/// unit of the reciter's own tempo, and the same qāri' recites murattal and hadr at very
/// different speeds while being correct in both. So this analyzer never compares against
/// absolute thresholds. It derives the reciter's rate from their own recitation in the
/// same session, and asks whether the words carrying a long madd are proportionally
/// longer than the words that carry none.
///
/// That self-reference is what makes it defensible without a calibration corpus. It is
/// also the limit of what it can claim:
///
/// * It measures **whole words**, because word boundaries are all the alignment provides.
///   It cannot isolate the vowel inside a word, so it cannot tell a madd held too short
///   from a word rushed as a whole.
/// * It says nothing about qalqalah, ghunnah, ikhfāʾ or articulation. Those need
///   phoneme-level alignment, which is the neural model's job (obadx, arXiv 2509.00094).
/// * **Its thresholds have not been calibrated against expert reciters and have not been
///   reviewed by a qārī.** Everything it emits is `.low` or `.moderate` confidence and is
///   phrased as a prompt to listen again.
///
/// If in doubt it stays silent. A fabricated tajweed correction is far worse than a
/// missed one.
public struct DSPTajweedAnalyzer: TajweedAnalyzer {

    public struct Options: Sendable {
        /// A word must fall at least this far below its expected duration before it is
        /// mentioned at all. Wide, because the measurement is coarse.
        public var shortfallToMention: Double
        /// Below this it is reported with `.moderate` rather than `.low` confidence.
        public var shortfallForModerate: Double
        /// Minimum comparable words needed before the reciter's rate means anything.
        public var minimumBaselineWords: Int

        public init(
            shortfallToMention: Double = 0.35,
            shortfallForModerate: Double = 0.55,
            minimumBaselineWords: Int = 6
        ) {
            self.shortfallToMention = shortfallToMention
            self.shortfallForModerate = shortfallForModerate
            self.minimumBaselineWords = minimumBaselineWords
        }

        public static let `default` = Options()
    }

    private let options: Options

    public init(options: Options = .default) {
        self.options = options
    }

    public func analyze(
        segments: [AlignedAudioSegment],
        target: RecitationTarget
    ) async -> [TajweedNote] {
        let occurrences = TajweedRuleDetector.occurrences(in: target)
        guard !occurrences.isEmpty else { return [] }

        // The longest madd on each word decides what that word should cost in time.
        var longestMadd: [Int: TajweedOccurrence] = [:]
        for occurrence in occurrences where occurrence.rule.isMadd {
            let harakat = occurrence.expectedHarakat ?? 2
            if (longestMadd[occurrence.targetIndex]?.expectedHarakat ?? 0) < harakat {
                longestMadd[occurrence.targetIndex] = occurrence
            }
        }

        // Every word that was actually recited, with the span it occupied.
        var timings: [Int: (duration: TimeInterval, range: ClosedRange<TimeInterval>)] = [:]
        for segment in segments {
            for word in segment.words {
                guard let range = word.timeRange, range.upperBound > range.lowerBound else { continue }
                timings[word.targetIndex] = (range.upperBound - range.lowerBound, range)
            }
        }
        guard !timings.isEmpty else { return [] }

        let words = Dictionary(
            uniqueKeysWithValues: target.flattenedWords.map { ($0.globalIndex, $0) }
        )

        /// Letters, ignoring diacritics — the rough amount of sound a word contains.
        func letterCount(_ index: Int) -> Int {
            guard let word = words[index] else { return 0 }
            return ArabicNormalizer.normalize(word.text).unicodeScalars.count
        }

        // The reciter's own rate, taken only from words with no long madd. Using every
        // word would fold the very elongation being measured into the baseline.
        var baselineRates: [Double] = []
        for (index, timing) in timings {
            let madd = longestMadd[index]?.expectedHarakat ?? 2
            guard madd <= 2 else { continue }
            let letters = letterCount(index)
            guard letters >= 2 else { continue }
            baselineRates.append(timing.duration / Double(letters))
        }
        guard baselineRates.count >= options.minimumBaselineWords else { return [] }

        let rate = median(baselineRates)
        guard rate > 0 else { return [] }
        // One haraka is about the time the reciter spends on one letter at their own pace.
        let harakaUnit = rate

        var notes: [TajweedNote] = []
        for (index, occurrence) in longestMadd {
            guard let expectedHarakat = occurrence.expectedHarakat, expectedHarakat > 2 else { continue }
            guard let timing = timings[index] else { continue }
            let letters = letterCount(index)
            guard letters >= 2 else { continue }

            // The word's ordinary cost, plus the extra time the madd asks for beyond the
            // natural two harakāt already inside it.
            let ordinary = rate * Double(letters)
            let expected = ordinary + harakaUnit * Double(expectedHarakat - 2)
            guard expected > 0 else { continue }

            let shortfall = (expected - timing.duration) / expected
            guard shortfall >= options.shortfallToMention else { continue }

            let confidence: TajweedConfidence = shortfall >= options.shortfallForModerate ? .moderate : .low
            notes.append(
                TajweedNote(
                    rule: occurrence.rule,
                    targetIndex: index,
                    reference: occurrence.reference,
                    timeRange: timing.range,
                    confidence: confidence,
                    message: "\(occurrence.rule.title) on “\(occurrence.letters)” asks for about "
                        + "\(expectedHarakat) harakāt. This sounded shorter than the rest of your "
                        + "recitation would suggest — worth listening back.",
                    measurement: .init(
                        observed: timing.duration,
                        expected: expected,
                        unit: "s"
                    )
                )
            )
        }

        return notes.sorted { $0.targetIndex < $1.targetIndex }
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}
