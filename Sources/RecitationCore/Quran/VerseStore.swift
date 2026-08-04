import Foundation

public enum VerseStoreError: Error, Sendable, Equatable {
    case verseNotFound(VerseReference)
    case databaseUnavailable(String)
}

/// Read access to the bundled Quran text.
///
/// Step 5 adds `SQLiteVerseStore` behind this protocol, backed by a bundled database
/// built from Tarteel's Quranic Universal Library (MIT). Everything ships in the app —
/// there is no runtime network access anywhere in this project.
public protocol VerseStore: Sendable {
    func verse(at reference: VerseReference) async throws -> Verse
    func verses(from: VerseReference, through: VerseReference) async throws -> [Verse]
    func surahName(_ surah: Int) async throws -> String
}

extension VerseStore {
    /// Build a recitation target spanning a verse range.
    public func target(from start: VerseReference, through end: VerseReference) async throws -> RecitationTarget {
        // Every surah that begins in the range gets its basmala, for the reason
        // `Verse.basmala` records: it is recited and printed, but is an āyah only of
        // Al-Fātiḥah, so without it four words the reciter certainly said have nothing
        // to match and come back as words they never uttered.
        RecitationTarget(
            verses: SQLiteVerseStore.withBasmala(try await verses(from: start, through: end))
        )
    }
}

/// v1 store: a handful of short, very widely memorised surahs, hardcoded.
///
/// Enough to demo and test the full flow before the SQLite database exists. The text
/// is Uthmani with full diacritics, matching what the real database will serve, so
/// `ArabicNormalizer` is exercised the same way it will be in production.
public struct InMemoryVerseStore: VerseStore {
    private let versesByReference: [VerseReference: Verse]
    private let surahNames: [Int: String]

    public init(verses: [Verse], surahNames: [Int: String] = [:]) {
        self.versesByReference = Dictionary(uniqueKeysWithValues: verses.map { ($0.reference, $0) })
        self.surahNames = surahNames
    }

    public func verse(at reference: VerseReference) async throws -> Verse {
        guard let verse = versesByReference[reference] else {
            throw VerseStoreError.verseNotFound(reference)
        }
        return verse
    }

    public func verses(from start: VerseReference, through end: VerseReference) async throws -> [Verse] {
        let matches = versesByReference.values
            .filter { $0.reference >= start && $0.reference <= end }
            .sorted { $0.reference < $1.reference }
        guard !matches.isEmpty else { throw VerseStoreError.verseNotFound(start) }
        return matches
    }

    public func surahName(_ surah: Int) async throws -> String {
        surahNames[surah] ?? "Surah \(surah)"
    }
}

extension InMemoryVerseStore {
    /// Al-Fātiḥah (1:1–7) and Al-Ikhlāṣ (112:1–4).
    public static let sample: InMemoryVerseStore = {
        let fatiha: [String] = [
            "بِسْمِ ٱللَّهِ ٱلرَّحْمَٰنِ ٱلرَّحِيمِ",
            "ٱلْحَمْدُ لِلَّهِ رَبِّ ٱلْعَٰلَمِينَ",
            "ٱلرَّحْمَٰنِ ٱلرَّحِيمِ",
            "مَٰلِكِ يَوْمِ ٱلدِّينِ",
            "إِيَّاكَ نَعْبُدُ وَإِيَّاكَ نَسْتَعِينُ",
            "ٱهْدِنَا ٱلصِّرَٰطَ ٱلْمُسْتَقِيمَ",
            "صِرَٰطَ ٱلَّذِينَ أَنْعَمْتَ عَلَيْهِمْ غَيْرِ ٱلْمَغْضُوبِ عَلَيْهِمْ وَلَا ٱلضَّآلِّينَ",
        ]
        let ikhlas: [String] = [
            "قُلْ هُوَ ٱللَّهُ أَحَدٌ",
            "ٱللَّهُ ٱلصَّمَدُ",
            "لَمْ يَلِدْ وَلَمْ يُولَدْ",
            "وَلَمْ يَكُن لَّهُۥ كُفُوًا أَحَدٌۢ",
        ]

        var verses: [Verse] = []
        for (index, text) in fatiha.enumerated() {
            verses.append(Verse(reference: VerseReference(surah: 1, ayah: index + 1), text: text))
        }
        for (index, text) in ikhlas.enumerated() {
            verses.append(Verse(reference: VerseReference(surah: 112, ayah: index + 1), text: text))
        }

        return InMemoryVerseStore(
            verses: verses,
            surahNames: [1: "Al-Fātiḥah", 112: "Al-Ikhlāṣ"]
        )
    }()
}
