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

    /// The basmala that opens a surah, as words the matcher can expect.
    ///
    /// Recited at the head of every surah but At-Tawbah, and printed there in the muṣḥaf —
    /// yet it is an āyah only of Al-Fātiḥah. Everywhere else the text of āyah 1 begins with
    /// the surah's own first word, so a reciter who says the basmala, as almost everyone
    /// does, produces four words the matcher has no target for. They come back as words
    /// that were never in the text: invented, in a checker whose whole purpose is not to
    /// invent.
    ///
    /// Numbered āyah 0, which is not a verse number in any muṣḥaf and is the point. It
    /// keeps the basmala out of āyah 1's text, where it does not belong, while giving it a
    /// reference of its own so a verdict can be attributed to it. Nothing that reads the
    /// phonetic script finds an entry for it, so tajweed simply passes over it rather than
    /// judging a line that is not part of the surah.
    ///
    /// Returns nil for Al-Fātiḥah, where it already is āyah 1, and for At-Tawbah, which
    /// opens without it.
    public static func basmala(surah: Int) -> Verse? {
        guard surah != 1, surah != 9, (1...114).contains(surah) else { return nil }
        return Verse(
            reference: VerseReference(surah: surah, ayah: 0),
            text: "بِسْمِ ٱللَّهِ ٱلرَّحْمَـٰنِ ٱلرَّحِيمِ"
        )
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
