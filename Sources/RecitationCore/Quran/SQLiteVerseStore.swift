import Foundation
import SQLite3

/// Metadata for one surah, for browsing.
public struct SurahInfo: Sendable, Equatable, Identifiable {
    public let number: Int
    /// Arabic name, e.g. الفاتحة.
    public let nameArabic: String
    /// Transliterated name, e.g. "Al-Fatihah".
    public let nameSimple: String
    /// English meaning, e.g. "The Opener".
    public let nameEnglish: String
    public let ayahCount: Int
    /// "makkah" or "madinah".
    public let revelationPlace: String

    public var id: Int { number }

    public init(
        number: Int,
        nameArabic: String,
        nameSimple: String,
        nameEnglish: String,
        ayahCount: Int,
        revelationPlace: String
    ) {
        self.number = number
        self.nameArabic = nameArabic
        self.nameSimple = nameSimple
        self.nameEnglish = nameEnglish
        self.ayahCount = ayahCount
        self.revelationPlace = revelationPlace
    }
}

/// Read-only access to the bundled Quran database.
///
/// The database is generated and verified by `scripts/build-quran-db.py`, which refuses
/// to emit a file that fails its structural checks and records a SHA-256 of the corpus.
/// This store re-checks the headline counts on open, so a truncated or substituted file
/// fails loudly at startup rather than silently serving wrong text.
///
/// Opened read-only, and never written to.
public actor SQLiteVerseStore: VerseStore {

    /// Owns the connection so it is closed deterministically. Swift 6 forbids touching
    /// actor state from a nonisolated `deinit`, so the actor cannot close it itself.
    private final class Connection: @unchecked Sendable {
        let handle: OpaquePointer
        init(handle: OpaquePointer) { self.handle = handle }
        deinit { sqlite3_close(handle) }
    }

    /// Structural facts, asserted on open.
    public static let expectedSurahCount = 114
    public static let expectedAyahCount = 6236

    private let connection: Connection
    private var surahCache: [SurahInfo]?

    public init(url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VerseStoreError.databaseUnavailable("no database at \(url.path)")
        }

        var handle: OpaquePointer?
        // Read-only: nothing in the app ever modifies scripture.
        let status = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil)
        guard status == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(status)"
            if let handle { sqlite3_close(handle) }
            throw VerseStoreError.databaseUnavailable("could not open \(url.lastPathComponent): \(message)")
        }
        self.connection = Connection(handle: handle)

        try Self.validate(handle: handle, name: url.lastPathComponent)
    }

    /// Cheap sanity check on open. Catches a truncated download or a swapped file.
    private static func validate(handle: OpaquePointer, name: String) throws {
        func count(_ sql: String) throws -> Int {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw VerseStoreError.databaseUnavailable(
                    "\(name) is not a valid Quran database: \(String(cString: sqlite3_errmsg(handle)))"
                )
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(statement, 0))
        }

        let surahs = try count("SELECT COUNT(*) FROM surahs")
        let ayahs = try count("SELECT COUNT(*) FROM verses")
        guard surahs == expectedSurahCount, ayahs == expectedAyahCount else {
            throw VerseStoreError.databaseUnavailable(
                "\(name) holds \(surahs) surahs and \(ayahs) āyāt; expected \(expectedSurahCount) and \(expectedAyahCount)"
            )
        }
    }

    // MARK: - Queries

    /// All 114 surahs, cached after the first read.
    public func surahs() throws -> [SurahInfo] {
        if let surahCache { return surahCache }

        var statement: OpaquePointer?
        let sql = """
            SELECT number, name_arabic, name_simple, name_english, ayah_count, revelation_place
            FROM surahs ORDER BY number
            """
        guard sqlite3_prepare_v2(connection.handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw VerseStoreError.databaseUnavailable(String(cString: sqlite3_errmsg(connection.handle)))
        }
        defer { sqlite3_finalize(statement) }

        var result: [SurahInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(
                SurahInfo(
                    number: Int(sqlite3_column_int(statement, 0)),
                    nameArabic: Self.text(statement, 1),
                    nameSimple: Self.text(statement, 2),
                    nameEnglish: Self.text(statement, 3),
                    ayahCount: Int(sqlite3_column_int(statement, 4)),
                    revelationPlace: Self.text(statement, 5)
                )
            )
        }
        surahCache = result
        return result
    }

    public func surahName(_ surah: Int) async throws -> String {
        guard let info = try surahs().first(where: { $0.number == surah }) else {
            throw VerseStoreError.verseNotFound(VerseReference(surah: surah, ayah: 1))
        }
        return info.nameSimple
    }

    public func verse(at reference: VerseReference) async throws -> Verse {
        let verses = try await self.verses(from: reference, through: reference)
        guard let verse = verses.first else { throw VerseStoreError.verseNotFound(reference) }
        return verse
    }

    public func verses(from start: VerseReference, through end: VerseReference) async throws -> [Verse] {
        // Compare on the composite (surah, ayah) so a range can span surah boundaries.
        let sql = """
            SELECT surah, ayah, text FROM verses
            WHERE (surah * 1000 + ayah) BETWEEN ? AND ?
            ORDER BY surah, ayah
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection.handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw VerseStoreError.databaseUnavailable(String(cString: sqlite3_errmsg(connection.handle)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(start.surah * 1000 + start.ayah))
        sqlite3_bind_int(statement, 2, Int32(end.surah * 1000 + end.ayah))

        var references: [(VerseReference, String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let reference = VerseReference(
                surah: Int(sqlite3_column_int(statement, 0)),
                ayah: Int(sqlite3_column_int(statement, 1))
            )
            references.append((reference, Self.text(statement, 2)))
        }
        guard !references.isEmpty else { throw VerseStoreError.verseNotFound(start) }

        return try references.map { reference, text in
            Verse(reference: reference, words: try words(for: reference, fallbackText: text))
        }
    }

    /// Read the stored word breakdown for a verse.
    ///
    /// The build script asserts that these words rejoin to exactly the verse text, so
    /// the table is authoritative. `fallbackText` covers the theoretically-impossible
    /// case of a verse with no word rows rather than returning an empty verse, which
    /// would read to the user as a passage with nothing in it.
    private func words(for reference: VerseReference, fallbackText: String) throws -> [VerseWord] {
        // `kind = 'word'` is essential: the table also holds the āyah-number ornament,
        // which is part of the printed page but is not recited. Including it would put a
        // numeral at the end of every verse and hand the matcher a token that can never
        // be matched — reported as a skipped word in every recitation.
        let sql = """
            SELECT position, text, translation, transliteration FROM words
            WHERE surah = ? AND ayah = ? AND kind = 'word' ORDER BY position
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection.handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw VerseStoreError.databaseUnavailable(String(cString: sqlite3_errmsg(connection.handle)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(reference.surah))
        sqlite3_bind_int(statement, 2, Int32(reference.ayah))

        var result: [VerseWord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            // `normalized` is computed here rather than stored, so ArabicNormalizer stays
            // the single implementation of matching-time folding. A Python copy in the
            // build script could drift and break matching invisibly.
            result.append(
                VerseWord(
                    index: result.count,
                    text: Self.text(statement, 1),
                    translation: Self.text(statement, 2),
                    transliteration: Self.text(statement, 3)
                )
            )
        }

        if result.isEmpty {
            return fallbackText.split(whereSeparator: \.isWhitespace)
                .enumerated()
                .map { VerseWord(index: $0.offset, text: String($0.element)) }
        }
        return result
    }

    /// Build a target spanning a whole surah.
    public func target(surah: Int) async throws -> RecitationTarget {
        guard let info = try surahs().first(where: { $0.number == surah }) else {
            throw VerseStoreError.verseNotFound(VerseReference(surah: surah, ayah: 1))
        }
        return try await target(
            from: VerseReference(surah: surah, ayah: 1),
            through: VerseReference(surah: surah, ayah: info.ayahCount)
        )
    }

    /// Provenance recorded by the build script — source, checksum, generation time.
    public func metadata() throws -> [String: String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection.handle, "SELECT key, value FROM metadata", -1, &statement, nil) == SQLITE_OK else {
            return [:]
        }
        defer { sqlite3_finalize(statement) }

        var result: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            result[Self.text(statement, 0)] = Self.text(statement, 1)
        }
        return result
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }
}

extension SQLiteVerseStore {
    /// Locate the bundled database, mirroring `SpeechModelLocator`'s search: the app
    /// bundle first, then the repo checkout during development.
    public static func locateDatabase(
        in bundle: Bundle = .main,
        additionalDirectories: [URL] = []
    ) -> URL? {
        if let url = bundle.url(forResource: "quran", withExtension: "sqlite3") {
            return url
        }
        var directories = additionalDirectories
        var current = URL(fileURLWithPath: bundle.bundlePath).standardized
        for _ in 0..<8 {
            directories.append(current.appending(path: "Resources"))
            let parent = current.deletingLastPathComponent()
            if parent == current { break }
            current = parent
        }
        for directory in directories {
            let url = directory.appending(path: "quran.sqlite3")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}

// MARK: - Muṣḥaf layout

extension SQLiteVerseStore {

    /// Load a page of the Madani muṣḥaf, laid out as printed.
    public func page(_ number: Int) throws -> MushafPage {
        let clamped = max(1, min(number, MushafPage.count))

        // Line kinds first, so header and basmala lines are known even though they carry
        // no words.
        var lineKinds: [Int: (kind: String, surah: Int)] = [:]
        try eachRow(
            "SELECT line, kind, surah FROM page_lines WHERE page = ? ORDER BY line",
            bind: [clamped]
        ) { statement in
            lineKinds[Int(sqlite3_column_int(statement, 0))] = (
                Self.text(statement, 1),
                Int(sqlite3_column_int(statement, 2))
            )
        }
        guard !lineKinds.isEmpty else {
            throw VerseStoreError.verseNotFound(VerseReference(surah: 0, ayah: clamped))
        }

        var wordsByLine: [Int: [MushafWord]] = [:]
        var recitedIndex = 0
        var juz = 0
        var surahOrder: [Int] = []

        try eachRow(
            """
            SELECT w.line, w.surah, w.ayah, w.position, w.text, w.kind,
                   w.translation, w.transliteration, v.juz, w.code_v1
            FROM words w
            JOIN verses v ON v.surah = w.surah AND v.ayah = w.ayah
            WHERE w.page = ?
            ORDER BY w.line, w.surah, w.ayah, w.position
            """,
            bind: [clamped]
        ) { statement in
            let line = Int(sqlite3_column_int(statement, 0))
            let surah = Int(sqlite3_column_int(statement, 1))
            let reference = VerseReference(surah: surah, ayah: Int(sqlite3_column_int(statement, 2)))
            let kind = MushafWord.Kind(rawValue: Self.text(statement, 5)) ?? .word
            if juz == 0 { juz = Int(sqlite3_column_int(statement, 8)) }
            if !surahOrder.contains(surah) { surahOrder.append(surah) }

            wordsByLine[line, default: []].append(
                MushafWord(
                    reference: reference,
                    position: Int(sqlite3_column_int(statement, 3)),
                    text: Self.text(statement, 4),
                    code: Self.text(statement, 9),
                    kind: kind,
                    targetIndex: nil,
                    translation: Self.text(statement, 6),
                    transliteration: Self.text(statement, 7)
                )
            )
        }

        var lines = lineKinds.keys.sorted().map { number -> MushafLine in
            let descriptor = lineKinds[number]!
            let kind: MushafLine.Kind
            switch descriptor.kind {
            case "surah_header": kind = .surahHeader(surah: descriptor.surah)
            case "basmala":
                kind = .basmala(surah: descriptor.surah)
                // The basmala line is drawn from a `page_lines` row and carries no words
                // in the database, so until now it was text on the page and nothing to
                // the matcher. A reciter says it — almost everyone does — and four words
                // with no target came back as words they never uttered.
                //
                // Given words here rather than in `target(page:)` so that the page and the
                // target cannot disagree: they are numbered in the same pass as every
                // other word, and the view can highlight them like any other.
                if let basmala = Verse.basmala(surah: descriptor.surah) {
                    wordsByLine[number] = basmala.words.enumerated().map { offset, word in
                        MushafWord(
                            reference: basmala.reference,
                            position: offset,
                            text: word.text,
                            // No QCF glyph code: the calligraphic fonts have none for a
                            // line the layout data never gave words to, so this renders as
                            // Unicode text, which is what it did before.
                            code: "",
                            kind: .word,
                            targetIndex: nil,
                            translation: "",
                            transliteration: ""
                        )
                    }
                }
            default: kind = .words
            }
            return MushafLine(number: number, kind: kind, words: wordsByLine[number] ?? [])
        }

        // Number every recited word in reading order, basmala included, so the view can
        // map each one onto the alignment result without a second lookup.
        var recited = 0
        lines = lines.map { line in
            MushafLine(
                number: line.number,
                kind: line.kind,
                words: line.words.map { word in
                    guard word.kind == .word else { return word }
                    defer { recited += 1 }
                    return word.withTargetIndex(recited)
                }
            )
        }
        _ = recitedIndex

        return MushafPage(number: clamped, lines: lines, juz: juz, surahs: surahOrder)
    }

    /// The recitation target for a page: its recited words, grouped by verse.
    ///
    /// Practising a page at a time is how memorisation actually works, and it also keeps
    /// the alignment bounded — a page is ~80 words rather than a whole surah.
    public func target(page number: Int) throws -> RecitationTarget {
        let page = try self.page(number)
        var byVerse: [VerseReference: [VerseWord]] = [:]
        var order: [VerseReference] = []

        for word in page.recitedWords {
            if byVerse[word.reference] == nil { order.append(word.reference) }
            byVerse[word.reference, default: []].append(
                VerseWord(
                    index: byVerse[word.reference]?.count ?? 0,
                    text: word.text,
                    translation: word.translation,
                    transliteration: word.transliteration
                )
            )
        }

        return RecitationTarget(
            verses: order.map { Verse(reference: $0, words: byVerse[$0] ?? []) }
        )
    }

    /// Put the basmala in front of every surah that begins here.
    ///
    /// The muṣḥaf prints it and the reciter says it, but it is an āyah only of
    /// Al-Fātiḥah, so without this the matcher has no target for four words that are
    /// almost always recited and reports them as invented. Added wherever a verse 1
    /// appears — which is exactly where a surah starts, whether the target is a page, a
    /// whole surah or an arbitrary range.
    static func withBasmala(_ verses: [Verse]) -> [Verse] {
        var out: [Verse] = []
        out.reserveCapacity(verses.count + 2)
        for verse in verses {
            if verse.reference.ayah == 1, let basmala = Verse.basmala(surah: verse.reference.surah) {
                out.append(basmala)
            }
            out.append(verse)
        }
        return out
    }

    /// The page a surah begins on.
    public func firstPage(ofSurah surah: Int) throws -> Int {
        var result = 1
        try eachRow("SELECT first_page FROM surahs WHERE number = ?", bind: [surah]) { statement in
            result = Int(sqlite3_column_int(statement, 0))
        }
        return result
    }

    /// English translation of a verse, for the tap-through panel.
    public func translation(of reference: VerseReference) throws -> String {
        var result = ""
        try eachRow(
            "SELECT translation FROM verses WHERE surah = ? AND ayah = ?",
            bind: [reference.surah, reference.ayah]
        ) { statement in
            result = Self.text(statement, 0)
        }
        return result
    }

    /// Prepare, bind integers, and step a query, handing each row to `row`.
    private func eachRow(
        _ sql: String,
        bind values: [Int],
        _ row: (OpaquePointer?) -> Void
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection.handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw VerseStoreError.databaseUnavailable(String(cString: sqlite3_errmsg(connection.handle)))
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            sqlite3_bind_int(statement, Int32(offset + 1), Int32(value))
        }
        while sqlite3_step(statement) == SQLITE_ROW {
            row(statement)
        }
    }
}
