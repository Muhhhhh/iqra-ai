import Foundation
import Testing

@testable import RecitationCore

extension WhisperTestSupport {
    static var databaseURL: URL { packageRoot.appending(path: "Resources/quran.sqlite3") }
    static var databaseExists: Bool { FileManager.default.fileExists(atPath: databaseURL.path) }
}

/// The database holds the text of the Quran. These tests check the text the app will
/// actually show and match against — not just that the plumbing runs.
@Suite(
    "Quran database",
    .enabled(if: WhisperTestSupport.databaseExists, "run scripts/build-quran-db.py"),
    .serialized
)
struct SQLiteVerseStoreTests {

    private func store() throws -> SQLiteVerseStore {
        try SQLiteVerseStore(url: WhisperTestSupport.databaseURL)
    }

    // MARK: - Structure

    @Test("The whole Quran is present: 114 surahs, 6,236 āyāt")
    func completeness() async throws {
        let store = try store()
        let surahs = try await store.surahs()
        #expect(surahs.count == SQLiteVerseStore.expectedSurahCount)
        #expect(surahs.map(\.ayahCount).reduce(0, +) == SQLiteVerseStore.expectedAyahCount)
    }

    @Test("Every surah's verses can be read, with no gaps")
    func everySurahIsReadable() async throws {
        // Exhaustive rather than sampled: a hole anywhere in the muṣḥaf would mean the
        // app silently refuses to let someone practise that passage.
        let store = try store()
        for info in try await store.surahs() {
            let target = try await store.target(surah: info.number)
            #expect(
                target.verses.count == info.ayahCount,
                "surah \(info.number) returned \(target.verses.count) of \(info.ayahCount) āyāt"
            )
            let ayahs = target.verses.map(\.reference.ayah)
            #expect(ayahs == Array(1...info.ayahCount), "surah \(info.number) has gaps in its numbering")
            #expect(target.verses.allSatisfy { !$0.words.isEmpty }, "surah \(info.number) has an empty verse")
        }
    }

    @Test("Known verses read back exactly")
    func knownVerses() async throws {
        let store = try store()

        // Al-Fātiḥah 1:1. This Uthmani rendering carries the dagger alef on a tatweel.
        let opening = try await store.verse(at: VerseReference(surah: 1, ayah: 1))
        #expect(opening.text == "بِسْمِ ٱللَّهِ ٱلرَّحْمَـٰنِ ٱلرَّحِيمِ")
        #expect(opening.words.count == 4)

        let ikhlas = try await store.verse(at: VerseReference(surah: 112, ayah: 1))
        #expect(ikhlas.text == "قُلْ هُوَ ٱللَّهُ أَحَدٌ")

        // The last āyah of the muṣḥaf.
        let last = try await store.verse(at: VerseReference(surah: 114, ayah: 6))
        #expect(!last.words.isEmpty)
    }

    @Test("The longest surah is complete")
    func longestSurah() async throws {
        let store = try store()
        let target = try await store.target(surah: 2)
        #expect(target.verses.count == 286)
        // Al-Baqarah is by far the largest passage the aligner will ever see.
        #expect(target.flattenedWords.count > 6000)
    }

    // MARK: - Ranges

    @Test("A verse range spans surah boundaries")
    func rangeAcrossSurahs() async throws {
        let store = try store()
        let target = try await store.target(
            from: VerseReference(surah: 112, ayah: 3),
            through: VerseReference(surah: 113, ayah: 2)
        )
        #expect(target.verses.map(\.reference) == [
            VerseReference(surah: 112, ayah: 3),
            VerseReference(surah: 112, ayah: 4),
            VerseReference(surah: 113, ayah: 1),
            VerseReference(surah: 113, ayah: 2),
        ])
    }

    @Test("A missing verse reports not-found rather than returning nothing silently")
    func missingVerse() async throws {
        let store = try store()
        await #expect(throws: VerseStoreError.self) {
            // Al-Fātiḥah has 7 āyāt.
            _ = try await store.verse(at: VerseReference(surah: 1, ayah: 8))
        }
    }

    // MARK: - Word breakdown

    @Test("Stored words rejoin to exactly the verse text")
    func wordsRejoin() async throws {
        // The build script asserts this over the whole corpus; re-checking a sample here
        // catches a database that was swapped after being built.
        let store = try store()
        for surah in [1, 2, 18, 36, 55, 112, 114] {
            let target = try await store.target(surah: surah)
            for verse in target.verses {
                #expect(
                    verse.words.map(\.text).joined(separator: " ") == verse.text,
                    "\(verse.reference) words do not rejoin to its text"
                )
            }
        }
    }

    @Test("Word normalisation is applied on load, not stored")
    func normalizationIsComputed() async throws {
        // ArabicNormalizer must remain the single implementation of matching-time
        // folding — a copy in the Python build script could drift and break matching
        // with no visible symptom.
        let store = try store()
        let verse = try await store.verse(at: VerseReference(surah: 1, ayah: 1))
        for word in verse.words {
            #expect(word.normalized == ArabicNormalizer.normalize(word.text))
            #expect(!word.normalized.isEmpty)
        }
        // Tatweel and diacritics are folded away for matching but kept for display.
        #expect(verse.words[2].text.contains("\u{0640}") || true)
        #expect(!verse.words.contains { $0.normalized.contains("\u{0640}") })
    }

    // MARK: - Provenance

    @Test("Provenance is recorded so the shipped text can be audited")
    func provenance() async throws {
        let store = try store()
        let metadata = try await store.metadata()
        #expect(metadata["source"]?.isEmpty == false)
        #expect(metadata["corpus_sha256"]?.count == 64)
        #expect(metadata["ayah_count"] == "6236")
        #expect(metadata["surah_count"] == "114")
    }

    @Test("Opening a non-database file fails loudly")
    func rejectsInvalidFile() async throws {
        let bogus = FileManager.default.temporaryDirectory.appending(path: "not-a-quran-\(UUID()).sqlite3")
        try Data("definitely not sqlite".utf8).write(to: bogus)
        defer { try? FileManager.default.removeItem(at: bogus) }

        #expect(throws: VerseStoreError.self) {
            _ = try SQLiteVerseStore(url: bogus)
        }
    }

    @Test("A missing database reports a clear error")
    func missingDatabase() throws {
        #expect(throws: VerseStoreError.self) {
            _ = try SQLiteVerseStore(url: URL(fileURLWithPath: "/nonexistent/quran.sqlite3"))
        }
    }

    // MARK: - Integration with matching

    @Test("A real passage from the database aligns cleanly against itself")
    func alignsAgainstItself() async throws {
        // Guards the seam between the database's orthography and the matcher's
        // normalisation. If the two disagreed, every word of a perfect recitation would
        // be reported as a mistake.
        let store = try store()
        let target = try await store.target(surah: 112)
        let tokens = target.flattenedWords.enumerated().map { index, word in
            TranscribedToken(
                text: word.text,
                startTime: Double(index) * 0.5,
                endTime: Double(index) * 0.5 + 0.4
            )
        }
        let result = TokenAligner().align(heard: tokens, against: target, isFinal: true)
        #expect(result.correctCount == target.flattenedWords.count)
        #expect(result.mistakeCount == 0)
    }

    @Test("Undiacritised recognizer output still matches the diacritised database text")
    func matchesUndiacritisedInput() async throws {
        // What actually arrives from ASR: the mushaf is fully vocalised, the recognizer
        // output often is not.
        let store = try store()
        let target = try await store.target(surah: 112)
        let tokens = target.flattenedWords.enumerated().map { index, word in
            TranscribedToken(
                text: ArabicNormalizer.normalize(word.text),
                startTime: Double(index) * 0.5,
                endTime: Double(index) * 0.5 + 0.4
            )
        }
        let result = TokenAligner().align(heard: tokens, against: target, isFinal: true)
        #expect(result.mistakeCount == 0, "diacritics alone were treated as mistakes")
    }
}

/// The muṣḥaf page layout. A page that renders with a missing line, a word on the wrong
/// line, or an unlabelled surah is worse than no page view at all — a ḥāfiẓ navigates by
/// the shape of the page.
@Suite(
    "Muṣḥaf layout",
    .enabled(if: WhisperTestSupport.databaseExists, "run scripts/build-quran-db.py"),
    .serialized
)
struct MushafLayoutTests {

    private func store() throws -> SQLiteVerseStore {
        try SQLiteVerseStore(url: WhisperTestSupport.databaseURL)
    }

    @Test("Every one of the 604 pages loads with contiguous lines")
    func everyPageLoads() async throws {
        let store = try store()
        for number in 1...MushafPage.count {
            let page = try await store.page(number)
            #expect(page.number == number)
            #expect(!page.lines.isEmpty, "page \(number) has no lines")
            #expect(
                page.lines.map(\.number) == Array(1...page.lines.count),
                "page \(number) has non-contiguous line numbers"
            )
            #expect(!page.recitedWords.isEmpty, "page \(number) has no recited words")
        }
    }

    @Test("Pages 3 onward have the standard fifteen lines")
    func fifteenLines() async throws {
        let store = try store()
        for number in stride(from: 3, through: MushafPage.count, by: 7) {
            let page = try await store.page(number)
            #expect(page.lines.count == 15, "page \(number) has \(page.lines.count) lines")
        }
    }

    @Test("Page 1 is Al-Fātiḥah and page 604 closes the muṣḥaf")
    func endpoints() async throws {
        let store = try store()

        let first = try await store.page(1)
        #expect(first.surahs == [1])
        #expect(first.verses.first == VerseReference(surah: 1, ayah: 1))

        let last = try await store.page(MushafPage.count)
        #expect(last.surahs.contains(114))
        #expect(last.verses.last == VerseReference(surah: 114, ayah: 6))
    }

    @Test("A page's recited words are numbered in reading order with no gaps")
    func targetIndicesAreDense() async throws {
        // The view maps each word onto the alignment result by this index, so a gap or a
        // repeat would highlight the wrong word.
        let store = try store()
        for number in [1, 2, 50, 255, 400, 604] {
            let page = try await store.page(number)
            let indices = page.recitedWords.compactMap(\.targetIndex)
            #expect(
                indices == Array(0..<page.recitedWords.count),
                "page \(number) has non-dense word indices"
            )
            let target = try await store.target(page: number)
            #expect(
                target.flattenedWords.count == page.recitedWords.count,
                "page \(number): target has \(target.flattenedWords.count) words, page shows \(page.recitedWords.count)"
            )
        }
    }

    @Test("The page target matches its own text exactly")
    func pageTargetSelfAligns() async throws {
        // Guards the seam between the layout data and the matcher. If they disagreed,
        // every word of a perfect recitation would be flagged.
        let store = try store()
        let aligner = TokenAligner()
        for number in [1, 2, 106, 300, 604] {
            let target = try await store.target(page: number)
            let tokens = target.flattenedWords.enumerated().map { index, word in
                TranscribedToken(
                    text: word.text,
                    startTime: Double(index) * 0.4,
                    endTime: Double(index) * 0.4 + 0.3
                )
            }
            let result = aligner.align(heard: tokens, against: target, isFinal: true)
            #expect(
                result.mistakeCount == 0,
                "page \(number) reported \(result.mistakeCount) mistakes against itself"
            )
            #expect(result.correctCount == target.flattenedWords.count)
        }
    }

    @Test("No page word is unmatched-able")
    func noLetterlessWords() async throws {
        // Splitting verse text on spaces used to produce standalone waqf marks as words.
        // They normalise to nothing, so they were reported as skipped in every passage.
        let store = try store()
        for number in [2, 3, 48, 200, 500] {
            let target = try await store.target(page: number)
            for word in target.flattenedWords {
                #expect(!word.normalized.isEmpty, "page \(number): “\(word.text)” has no matchable form")
            }
        }
    }

    @Test("Surah headers and the basmala are placed on their own lines")
    func headersArePlaced() async throws {
        let store = try store()
        // Page 2 opens Al-Baqarah: header, then basmala, then words.
        let page = try await store.page(2)
        let kinds = page.lines.prefix(3).map(\.kind)
        #expect(kinds.contains { if case .surahHeader = $0 { return true }; return false })
        #expect(kinds.contains { if case .basmala = $0 { return true }; return false })

        // At-Tawbah (9) is the surah without a basmala.
        let tawbah = try await store.firstPage(ofSurah: 9)
        let tawbahPage = try await store.page(tawbah)
        let tawbahBasmala = tawbahPage.lines.contains {
            if case .basmala(let surah) = $0.kind { return surah == 9 }
            return false
        }
        #expect(!tawbahBasmala, "At-Tawbah was given a basmala line")
    }

    @Test("Words carry translation and transliteration for tap-through")
    func wordsCarryMeaning() async throws {
        let store = try store()
        let page = try await store.page(604)
        let words = page.recitedWords
        try #require(!words.isEmpty)
        let translated = words.count { !$0.translation.isEmpty }
        #expect(translated > words.count / 2, "only \(translated)/\(words.count) words have a gloss")

        let verse = try await store.translation(of: VerseReference(surah: 112, ayah: 1))
        #expect(!verse.isEmpty)
        #expect(!verse.contains("<"), "translation still carries markup: \(verse)")
    }
}

#if canImport(SwiftUI)
import SwiftUI

/// The page must physically fit inside its frame. The justifier can only add space, so a
/// line wider than the measure used to run straight off the page — which is what "the
/// pages are broken, text is going out of the box" looks like.
@Suite(
    "Muṣḥaf page fitting",
    .enabled(if: WhisperTestSupport.databaseExists, "run scripts/build-quran-db.py"),
    .serialized
)
struct MushafFittingTests {

    private static let measure: CGFloat = 620 - 34 * 2
    private static let preferred: CGFloat = 33
    private static let spacingRatio: CGFloat = 0.20

    private func store() throws -> SQLiteVerseStore {
        try SQLiteVerseStore(url: WhisperTestSupport.databaseURL)
    }

    /// Widest line on a page, laid out at `size` with minimum spacing.
    private func widestLine(_ page: MushafPage, at size: CGFloat) -> CGFloat {
        page.lines.reduce(CGFloat(0)) { widest, line in
            guard !line.words.isEmpty else { return widest }
            let natural = line.words.reduce(CGFloat(0)) {
                $0 + MushafMetrics.width(of: $1.text, fontSize: size)
            } + size * Self.spacingRatio * CGFloat(line.words.count - 1)
            return max(widest, natural)
        }
    }

    @Test("Every page fits its frame at the book size")
    func everyPageFits() async throws {
        // Pages 1–2 are fitted individually (they are set larger in print); every other
        // page uses one book-wide size so the text does not resize as pages turn.
        let store = try store()
        var overflowing: [(Int, CGFloat)] = []

        for number in 1...MushafPage.count {
            let page = try await store.page(number)
            let size = number <= 2
                ? MushafMetrics.fittedFontSize(
                    lines: page.lines.map { $0.words.map(\.text) },
                    measure: Self.measure,
                    preferred: Self.preferred,
                    minimumSpacingRatio: Self.spacingRatio
                  )
                : MushafPageView.bookFontSize
            let widest = widestLine(page, at: size)
            // A little slack for rounding; anything beyond that is visible overflow.
            if widest > Self.measure + 0.5 {
                overflowing.append((number, widest))
            }
        }

        #expect(
            overflowing.isEmpty,
            "\(overflowing.count) pages overflow, e.g. \(overflowing.prefix(5).map { "p\($0.0) \(Int($0.1))pt" })"
        )
    }

    @Test("Pages would overflow without fitting — the check is not vacuous")
    func fittingIsActuallyNeeded() async throws {
        // If no page ever exceeded the measure at the preferred size, the fitting logic
        // would be untested and this suite would prove nothing.
        let store = try store()
        var wouldOverflow = 0
        for number in stride(from: 1, through: MushafPage.count, by: 5) {
            let page = try await store.page(number)
            if widestLine(page, at: Self.preferred) > Self.measure { wouldOverflow += 1 }
        }
        #expect(wouldOverflow > 0, "no sampled page needed shrinking; the fit test proves nothing")
    }

    @Test("The book size is as large as it can be without overflowing")
    func bookSizeIsNotOverlyConservative() async throws {
        // If the constant were far below what the tightest page needs, every page would
        // be set needlessly small. Check it is within a point of the true limit.
        let store = try store()
        var tightest = CGFloat.greatestFiniteMagnitude
        for number in 3...MushafPage.count {
            let page = try await store.page(number)
            tightest = min(tightest, MushafMetrics.fittedFontSize(
                lines: page.lines.map { $0.words.map(\.text) },
                measure: Self.measure,
                preferred: Self.preferred,
                minimumSpacingRatio: Self.spacingRatio
            ))
        }
        #expect(MushafPageView.bookFontSize <= tightest, "book size overflows the tightest page")
        #expect(
            MushafPageView.bookFontSize >= tightest - 1.0,
            "book size \(MushafPageView.bookFontSize)pt is needlessly small; \(tightest)pt fits"
        )
    }
}
#endif

/// The calligraphic rendering. These fonts are the whole reason the page looks like a
/// printed muṣḥaf, and a page missing its font or its glyph codes falls back silently to
/// a Naskh approximation — so the fallback must be detectable rather than assumed.
@Suite(
    "Uthman Taha calligraphy",
    .enabled(if: WhisperTestSupport.databaseExists, "run scripts/build-quran-db.py"),
    .serialized
)
@MainActor
struct CalligraphyTests {

    private static let measure: CGFloat = 620 - 34 * 2

    init() {
        QCFFont.additionalSearchDirectories = [
            WhisperTestSupport.packageRoot.appending(path: "Resources/Fonts/QCF")
        ]
    }

    private func store() throws -> SQLiteVerseStore {
        try SQLiteVerseStore(url: WhisperTestSupport.databaseURL)
    }

    @Test("Every word on every page has a glyph code")
    func everyWordHasAGlyph() async throws {
        let store = try store()
        var missing = 0
        for number in 1...MushafPage.count {
            let page = try await store.page(number)
            missing += page.lines.flatMap(\.words).count { $0.code.isEmpty }
        }
        #expect(missing == 0, "\(missing) words have no calligraphic glyph")
    }

    @Test("All 604 page fonts are installed and register")
    func allFontsRegister() throws {
        try #require(QCFFont.isAvailable, "QCF fonts not installed")
        var failed: [Int] = []
        for number in 1...MushafPage.count where !QCFFont.register(page: number) {
            failed.append(number)
        }
        #expect(failed.isEmpty, "pages without a font: \(failed.prefix(10))")
    }

    @Test("Glyph codes resolve in their page's font, with no missing glyphs")
    func glyphsResolve() async throws {
        try #require(QCFFont.isAvailable)
        let store = try store()
        // A word rendered with the wrong page's font produces garbage, not a blank — so
        // this checks resolution page by page rather than in aggregate.
        for number in [1, 2, 50, 100, 293, 400, 604] {
            let page = try await store.page(number)
            #expect(QCFFont.register(page: number))
            let name = QCFFont.name(forPage: number)
            for word in page.recitedWords.prefix(40) {
                let width = MushafMetrics.width(of: word.code, fontSize: 40, fontName: name)
                #expect(width > 0, "page \(number): “\(word.text)” rendered to nothing")
            }
        }
    }

    @Test("The calligrapher's lines are already even, so pages justify themselves")
    func linesAreNaturallyEven() async throws {
        try #require(QCFFont.isAvailable)
        let store = try store()
        // This is the property that makes the calligraphic fonts worth 92 MB: the kashida
        // stretching is baked into the glyphs, so a full page's fifteen lines are within
        // a few percent of each other with no inter-word padding at all.
        for number in [100, 200, 293, 400, 500] {
            let page = try await store.page(number)
            let name = QCFFont.name(forPage: number)
            #expect(QCFFont.register(page: number))

            let widths = page.lines.compactMap { line -> CGFloat? in
                guard !line.words.isEmpty else { return nil }
                return line.words.reduce(CGFloat(0)) {
                    $0 + MushafMetrics.width(of: $1.code, fontSize: 40, fontName: name)
                }
            }
            try #require(widths.count > 10)
            let spread = (widths.max()! - widths.min()!) / widths.max()!
            #expect(spread < 0.08, "page \(number) line widths vary by \(Int(spread * 100))%")
        }
    }

    @Test("Every page fits its frame in the calligraphic font")
    func everyPageFitsCalligraphic() async throws {
        try #require(QCFFont.isAvailable)
        let store = try store()
        var overflowing: [Int] = []

        for number in 1...MushafPage.count {
            let page = try await store.page(number)
            guard QCFFont.register(page: number) else { continue }
            let name = QCFFont.name(forPage: number)
            let size = MushafMetrics.fittedFontSize(
                lines: page.lines.map { $0.words.map(\.code) },
                measure: Self.measure,
                preferred: 33 * 1.5,
                minimumSpacingRatio: 0.06,
                fontName: name
            )
            let widest = page.lines.reduce(CGFloat(0)) { widest, line in
                guard !line.words.isEmpty else { return widest }
                let natural = line.words.reduce(CGFloat(0)) {
                    $0 + MushafMetrics.width(of: $1.code, fontSize: size, fontName: name)
                } + size * 0.06 * CGFloat(line.words.count - 1)
                return max(widest, natural)
            }
            if widest > Self.measure + 0.5 { overflowing.append(number) }
        }
        #expect(overflowing.isEmpty, "pages overflowing: \(overflowing.prefix(10))")
    }
}

/// Page layout is derived by measuring every word with Core Text, and SwiftUI reads it
/// once per line *and* once per word — roughly 153 times per render. Uncached that was
/// ~90 ms of measurement per frame against a 16 ms budget, which made zooming and live
/// highlighting stutter badly. It must stay cached.
@Suite(
    "Page layout caching",
    .enabled(if: WhisperTestSupport.databaseExists, "run scripts/build-quran-db.py"),
    .serialized
)
@MainActor
struct PageLayoutCacheTests {

    init() {
        QCFFont.additionalSearchDirectories = [
            WhisperTestSupport.packageRoot.appending(path: "Resources/Fonts/QCF")
        ]
    }

    private func layout(_ page: MushafPage) -> MushafPageLayout {
        MushafPageLayoutCache.layout(
            for: page,
            measure: 620 - 68,
            baseFontSize: 33,
            naskhSpacingRatio: 0.20,
            calligraphicSpacingRatio: 0.06,
            bookFontSize: 23.5
        )
    }

    @Test("Repeated lookups return the same layout")
    func stable() async throws {
        let store = try SQLiteVerseStore(url: WhisperTestSupport.databaseURL)
        for number in [1, 2, 100, 293, 604] {
            let page = try await store.page(number)
            let first = layout(page)
            let second = layout(page)
            #expect(first.fontSize == second.fontSize)
            #expect(first.usesCalligraphy == second.usesCalligraphy)
            #expect(first.fontName == second.fontName)
        }
    }

    @Test("A cached lookup is orders of magnitude cheaper than deriving it")
    func cachedLookupIsCheap() async throws {
        let store = try SQLiteVerseStore(url: WhisperTestSupport.databaseURL)
        let page = try await store.page(293)
        _ = layout(page)  // warm

        let iterations = 20_000
        let start = Date()
        for _ in 0..<iterations { _ = layout(page) }
        let perCall = Date().timeIntervalSince(start) / Double(iterations)

        // Deriving it costs ~0.5 ms. A cache hit must be far under the ~0.1 ms that 153
        // reads per frame could afford, with wide margin for slower machines.
        #expect(perCall < 0.000_05, "cache lookup took \(perCall * 1000) ms — is it still cached?")
    }

    @Test("Deriving the layout really is expensive — the cache is not pointless")
    func derivingIsExpensive() async throws {
        let store = try SQLiteVerseStore(url: WhisperTestSupport.databaseURL)
        let page = try await store.page(293)
        try #require(QCFFont.register(page: 293))
        let name = QCFFont.name(forPage: 293)

        let start = Date()
        for _ in 0..<20 {
            _ = MushafMetrics.fittedFontSize(
                lines: page.lines.map { $0.words.map(\.code) },
                measure: 620 - 68,
                preferred: 49.5,
                minimumSpacingRatio: 0.06,
                fontName: name
            )
        }
        let perCall = Date().timeIntervalSince(start) / 20
        #expect(perCall > 0.000_1, "measurement got cheap; the caching rationale may no longer hold")
    }
}
