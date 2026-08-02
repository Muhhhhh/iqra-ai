import Foundation
import Observation
import RecitationCore

/// Browsing state over the bundled Quran database: which surah, which āyāt.
///
/// Separate from `AppSettings`, which holds pipeline tuning. This is the user's
/// place in the muṣḥaf.
@MainActor
@Observable
final class QuranLibrary {
    static let shared = QuranLibrary()

    private(set) var surahs: [SurahInfo] = []
    private(set) var loadError: String?
    private(set) var store: SQLiteVerseStore?
    /// Provenance from the database, shown in Settings so the shipped text is auditable.
    private(set) var databaseMetadata: [String: String] = [:]

    /// The page currently open. Practising a page at a time is how memorisation works,
    /// and it also keeps alignment bounded — a page is ~80 words, not a whole surah.
    var currentPage: Int = 1 { didSet { if currentPage != oldValue { loadPage() } } }
    private(set) var page: MushafPage?
    var searchText: String = ""

    var selectedSurah: Int = 1 {
        didSet {
            guard selectedSurah != oldValue else { return }
            Task { @MainActor in
                guard let store else { return }
                if let first = try? await store.firstPage(ofSurah: selectedSurah) {
                    currentPage = first
                }
            }
        }
    }

    /// Surah names by number, for the page header and the surah band.
    private(set) var surahNames: [Int: String] = [:]
    private(set) var surahArabicNames: [Int: String] = [:]

    private init() {
        load()
    }

    var isAvailable: Bool { store != nil }

    var currentSurah: SurahInfo? {
        surahs.first { $0.number == selectedSurah }
    }

    var filteredSurahs: [SurahInfo] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return surahs }
        if let number = Int(query) {
            return surahs.filter { $0.number == number }
        }
        return surahs.filter {
            $0.nameSimple.lowercased().contains(query)
                || $0.nameEnglish.lowercased().contains(query)
                || $0.nameArabic.contains(query)
        }
    }

    private func load() {
        guard let url = SQLiteVerseStore.locateDatabase() else {
            loadError = "No Quran database found. Run scripts/build-quran-db.py."
            return
        }
        do {
            let store = try SQLiteVerseStore(url: url)
            self.store = store
            // The store validates its own contents on open, so anything that gets here
            // is structurally sound. Reading the surah list is cheap and cached.
            Task { @MainActor in
                do {
                    self.surahs = try await store.surahs()
                    self.surahNames = Dictionary(
                        uniqueKeysWithValues: self.surahs.map { ($0.number, $0.nameSimple) }
                    )
                    self.surahArabicNames = Dictionary(
                        uniqueKeysWithValues: self.surahs.map { ($0.number, $0.nameArabic) }
                    )
                    self.databaseMetadata = try await store.metadata()
                    self.loadPage()
                } catch {
                    self.loadError = "Could not read surah list: \(error)"
                }
            }
        } catch {
            loadError = "\(error)"
        }
    }

    private func loadPage() {
        guard let store else { return }
        let number = currentPage
        Task { @MainActor in
            do {
                let loaded = try await store.page(number)
                guard self.currentPage == number else { return }
                self.page = loaded
                if let first = loaded.surahs.first, self.selectedSurah != first,
                   !loaded.surahs.contains(self.selectedSurah) {
                    self.selectedSurah = first
                }
            } catch {
                self.loadError = "Could not load page \(number): \(error)"
            }
        }
    }

    /// Dominant tajweed rule per word on the open page.
    ///
    /// Derived from the Uthmani text, so it is available before a single word is recited
    /// — this half of tajweed does not depend on the audio at all.
    private(set) var tajweedByWord: [Int: TajweedRule] = [:]
    /// Where each rule falls inside its word, so the page can colour the letters the
    /// rule actually applies to rather than the whole word.
    private(set) var tajweedSpansByWord: [Int: [TajweedOccurrence]] = [:]

    private func loadTajweed(for target: RecitationTarget) {
        var byWord: [Int: [TajweedRule]] = [:]
        var spans: [Int: [TajweedOccurrence]] = [:]
        for occurrence in TajweedRuleDetector.occurrences(in: target) {
            byWord[occurrence.targetIndex, default: []].append(occurrence.rule)
            spans[occurrence.targetIndex, default: []].append(occurrence)
        }
        tajweedByWord = byWord.compactMapValues { TajweedStyle.dominant($0) }
        tajweedSpansByWord = spans
    }

    /// The recitation target for the open page.
    func makeTarget() async -> RecitationTarget? {
        guard let store else { return nil }
        do {
            let target = try await store.target(page: currentPage)
            loadTajweed(for: target)
            return target
        } catch {
            loadError = "Could not load page \(currentPage): \(error)"
            return nil
        }
    }

    func translation(of reference: VerseReference) async -> String {
        guard let store else { return "" }
        return (try? await store.translation(of: reference)) ?? ""
    }

    func goToPage(_ number: Int) {
        currentPage = max(1, min(number, MushafPage.count))
    }

    var canGoBack: Bool { currentPage > 1 }
    var canGoForward: Bool { currentPage < MushafPage.count }
}
