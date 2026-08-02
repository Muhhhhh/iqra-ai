import Foundation

/// Verdict for one expected word of the target text.
///
/// Note the deliberate gap between `.uncertain` and `.wrong`: anything the aligner is
/// not confident about lands in `.uncertain`, which the UI shows as a neutral "check
/// this" hint rather than an error. Telling someone they misrecited when they did not
/// is the costly failure here, so the matcher is biased to under-report.
public enum WordStatus: Sendable, Equatable {
    /// Recited and matched.
    case correct
    /// Something was recited here, close but not a clean match — advisory only, never an error.
    case uncertain(heard: String)
    /// Confidently a different word.
    case wrong(heard: String)
    /// Passed over: the reciter moved on to a later word without saying this one.
    case skipped
    /// Not reached yet. Only produced for partial (still-recording) alignments.
    case notYetRecited

    public var isMistake: Bool {
        switch self {
        case .wrong, .skipped: return true
        case .correct, .uncertain, .notYetRecited: return false
        }
    }

    /// What the reciter was heard saying at this position, if anything.
    public var heardText: String? {
        switch self {
        case .uncertain(let heard), .wrong(let heard): return heard
        case .correct, .skipped, .notYetRecited: return nil
        }
    }
}

/// The verdict for one expected word, plus the audio provenance v2 needs.
public struct WordEvaluation: Sendable, Equatable, Identifiable {
    /// Index into `RecitationTarget.flattenedWords`.
    public let targetIndex: Int
    public let reference: VerseReference
    /// Display text, diacritics intact.
    public let expectedText: String
    public let status: WordStatus
    /// Span on the session clock covered by the matched token, if there was one.
    /// This is the handle a `TajweedAnalyzer` uses to slice out this word's audio.
    public let timeRange: ClosedRange<TimeInterval>?
    /// Recognizer confidence for the matched token.
    public let recognizerConfidence: Double?

    public var id: Int { targetIndex }

    public init(
        targetIndex: Int,
        reference: VerseReference,
        expectedText: String,
        status: WordStatus,
        timeRange: ClosedRange<TimeInterval>? = nil,
        recognizerConfidence: Double? = nil
    ) {
        self.targetIndex = targetIndex
        self.reference = reference
        self.expectedText = expectedText
        self.status = status
        self.timeRange = timeRange
        self.recognizerConfidence = recognizerConfidence
    }
}

/// A word that was recited but did not consume an expected word.
public struct InsertedWord: Sendable, Equatable {
    /// Why this word is here.
    public enum Kind: Sendable, Equatable {
        /// A word from nowhere in the surrounding text — a genuine addition.
        case addition
        /// A word that also occurs close by in the passage.
        ///
        /// This is what self-correction looks like: stumbling and repeating a word,
        /// restarting a phrase, or re-reciting a verse. Reporting these as "added words"
        /// tells someone they inserted words into the Quran when they were in fact
        /// correcting themselves, so they are counted and displayed separately.
        case repetition
    }

    public let text: String
    /// Index of the target word this was heard *after*; nil means before the first word.
    public let afterTargetIndex: Int?
    public let timeRange: ClosedRange<TimeInterval>?
    public let kind: Kind

    public init(
        text: String,
        afterTargetIndex: Int?,
        timeRange: ClosedRange<TimeInterval>? = nil,
        kind: Kind = .addition
    ) {
        self.text = text
        self.afterTargetIndex = afterTargetIndex
        self.timeRange = timeRange
        self.kind = kind
    }
}

/// Full result of aligning what was heard against what was expected.
public struct AlignmentResult: Sendable, Equatable {
    public let words: [WordEvaluation]
    public let insertions: [InsertedWord]
    /// False while still recording — trailing unrecited words are `.notYetRecited`, not `.skipped`.
    public let isFinal: Bool

    public init(words: [WordEvaluation], insertions: [InsertedWord], isFinal: Bool) {
        self.words = words
        self.insertions = insertions
        self.isFinal = isFinal
    }

    public static let empty = AlignmentResult(words: [], insertions: [], isFinal: false)

    public var mistakeCount: Int { words.count(where: { $0.status.isMistake }) }
    public var correctCount: Int { words.count(where: { $0.status == .correct }) }

    /// Words genuinely inserted into the text.
    public var additions: [InsertedWord] { insertions.filter { $0.kind == .addition } }
    /// Words re-recited while self-correcting. Not a mistake.
    public var repetitions: [InsertedWord] { insertions.filter { $0.kind == .repetition } }

    /// True once the reciter has reached the end of the passage.
    ///
    /// - Parameter tolerance: how many words from the end count as "the end". One means
    ///   the final word itself must be matched. Widening it turns the page sooner, at the
    ///   cost of turning early when the closing words are misrecognised.
    public func hasReachedEnd(tolerance: Int = 1) -> Bool {
        guard !words.isEmpty else { return false }
        let tail = words.suffix(max(1, tolerance))
        return tail.contains { status in
            switch status.status {
            case .correct, .uncertain: return true
            case .wrong, .skipped, .notYetRecited: return false
            }
        }
    }

    /// Verses where *every* word was skipped — reported as a skipped verse rather than
    /// a run of individually skipped words.
    public var skippedVerses: [VerseReference] {
        var byVerse: [VerseReference: [WordStatus]] = [:]
        var order: [VerseReference] = []
        for word in words {
            if byVerse[word.reference] == nil { order.append(word.reference) }
            byVerse[word.reference, default: []].append(word.status)
        }
        return order.filter { reference in
            guard let statuses = byVerse[reference], !statuses.isEmpty else { return false }
            return statuses.allSatisfy { $0 == .skipped }
        }
    }
}
