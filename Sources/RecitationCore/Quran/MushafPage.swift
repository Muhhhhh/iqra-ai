import Foundation

/// One item positioned on a muṣḥaf line.
public struct MushafWord: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        /// A recited word.
        case word
        /// The āyah-number ornament that closes a verse. Occupies space on the line but
        /// is not recited, so it is excluded from matching.
        case ayahEnd = "end"
    }

    public let reference: VerseReference
    /// Position within the verse, 1-based, as the layout data numbers it.
    public let position: Int
    /// Unicode Uthmani text — what the matcher compares against.
    public let text: String
    /// Glyph code for the page's QCF font: the same word in Uthman Taha's hand, shaped
    /// for its exact place on the line. Empty when the calligraphic data is unavailable.
    public let code: String
    public let kind: Kind
    /// Index into the page's recitation target, for recited words only.
    public let targetIndex: Int?
    public let translation: String
    public let transliteration: String

    public var id: String { "\(reference):\(position)" }

    public init(
        reference: VerseReference,
        position: Int,
        text: String,
        code: String = "",
        kind: Kind,
        targetIndex: Int?,
        translation: String,
        transliteration: String
    ) {
        self.reference = reference
        self.position = position
        self.text = text
        self.code = code
        self.kind = kind
        self.targetIndex = targetIndex
        self.translation = translation
        self.transliteration = transliteration
    }
}

/// One of the fifteen lines of a muṣḥaf page.
public struct MushafLine: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case words
        /// The decorative band naming a surah that begins here.
        case surahHeader(surah: Int)
        /// The basmala line that opens most surahs.
        case basmala(surah: Int)
    }

    public let number: Int
    public let kind: Kind
    public let words: [MushafWord]

    public var id: Int { number }

    public init(number: Int, kind: Kind, words: [MushafWord]) {
        self.number = number
        self.kind = kind
        self.words = words
    }
}

/// A page of the Madani muṣḥaf, laid out as printed.
///
/// The line breaks are the canonical ones — page 3 line 7 ends on the same word in every
/// printed copy — because they come from the layout data rather than from whatever fits
/// the window. That matters for memorisation: a ḥāfiẓ recalls the shape of the page.
public struct MushafPage: Sendable, Equatable, Identifiable {
    public static let count = 604

    public let number: Int
    public let lines: [MushafLine]
    public let juz: Int
    /// Surahs appearing on this page, in order.
    public let surahs: [Int]

    public var id: Int { number }

    public init(number: Int, lines: [MushafLine], juz: Int, surahs: [Int]) {
        self.number = number
        self.lines = lines
        self.juz = juz
        self.surahs = surahs
    }

    /// Every recited word on the page, in reading order.
    public var recitedWords: [MushafWord] {
        lines.flatMap { $0.words }.filter { $0.kind == .word }
    }

    /// Verses that appear on this page, in order.
    public var verses: [VerseReference] {
        var seen: Set<VerseReference> = []
        var order: [VerseReference] = []
        for word in lines.flatMap(\.words) where !seen.contains(word.reference) {
            seen.insert(word.reference)
            order.append(word.reference)
        }
        return order
    }
}
