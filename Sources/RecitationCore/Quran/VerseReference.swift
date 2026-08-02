import Foundation

/// Canonical surah:ayah address.
public struct VerseReference: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let surah: Int
    public let ayah: Int

    public init(surah: Int, ayah: Int) {
        self.surah = surah
        self.ayah = ayah
    }

    public var description: String { "\(surah):\(ayah)" }

    public static func < (lhs: VerseReference, rhs: VerseReference) -> Bool {
        (lhs.surah, lhs.ayah) < (rhs.surah, rhs.ayah)
    }
}

/// A single word of a verse, as stored in the bundled Quran database.
public struct VerseWord: Sendable, Equatable, Identifiable {
    /// Position within the verse, 0-based.
    public let index: Int
    /// Text with full diacritics, for display in the mushaf view.
    public let text: String
    /// Diacritic-stripped, alef-normalised form used for matching. See `ArabicNormalizer`.
    public let normalized: String
    /// Count of harakāt this word's madd letters should be held for, when known.
    /// Unused in v1; carried so `TajweedAnalyzer` has an expectation to measure against.
    public let expectedMaddCounts: [Int]
    /// Word-by-word English gloss, shown when the word is tapped.
    public let translation: String
    public let transliteration: String

    public var id: Int { index }

    public init(
        index: Int,
        text: String,
        normalized: String? = nil,
        expectedMaddCounts: [Int] = [],
        translation: String = "",
        transliteration: String = ""
    ) {
        self.index = index
        self.text = text
        self.normalized = normalized ?? ArabicNormalizer.normalize(text)
        self.expectedMaddCounts = expectedMaddCounts
        self.translation = translation
        self.transliteration = transliteration
    }
}

/// A verse plus its word-by-word breakdown.
public struct Verse: Sendable, Equatable, Identifiable {
    public let reference: VerseReference
    public let words: [VerseWord]

    public var id: VerseReference { reference }
    public var text: String { words.map(\.text).joined(separator: " ") }

    public init(reference: VerseReference, words: [VerseWord]) {
        self.reference = reference
        self.words = words
    }

    /// Convenience for building a verse from whitespace-separated text.
    ///
    /// Tokens that carry no Arabic letter are dropped. Splitting Uthmani text on spaces
    /// yields standalone waqf marks (ۖ ۛ) as tokens — 490 in Al-Baqarah alone — and a
    /// token that normalises to nothing can never be matched, so it would be reported as
    /// a skipped word in every single recitation.
    public init(reference: VerseReference, text: String) {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let words = tokens
            .filter { !ArabicNormalizer.normalize($0).isEmpty }
            .enumerated()
            .map { VerseWord(index: $0.offset, text: $0.element) }
        self.init(reference: reference, words: words)
    }
}

/// A contiguous span of verses the user is currently reciting against.
public struct RecitationTarget: Sendable, Equatable {
    public let verses: [Verse]

    public init(verses: [Verse]) {
        self.verses = verses
    }

    public init(verse: Verse) {
        self.init(verses: [verse])
    }

    /// Every word across every verse, flattened — this is what the aligner matches against.
    /// The verse boundary is preserved so a whole skipped verse is reportable as such.
    ///
    /// Words with no matchable form are excluded defensively: one could never be matched,
    /// so it would be reported as skipped in every recitation regardless of what was
    /// recited.
    public var flattenedWords: [TargetWord] {
        var out: [TargetWord] = []
        for verse in verses {
            for word in verse.words where !word.normalized.isEmpty {
                out.append(TargetWord(globalIndex: out.count, reference: verse.reference, word: word))
            }
        }
        return out
    }
}

/// A verse word lifted into the flattened target sequence, keeping its verse address.
public struct TargetWord: Sendable, Equatable, Identifiable {
    public let globalIndex: Int
    public let reference: VerseReference
    public let word: VerseWord

    public var id: Int { globalIndex }
    public var text: String { word.text }
    public var normalized: String { word.normalized }

    public init(globalIndex: Int, reference: VerseReference, word: VerseWord) {
        self.globalIndex = globalIndex
        self.reference = reference
        self.word = word
    }
}
