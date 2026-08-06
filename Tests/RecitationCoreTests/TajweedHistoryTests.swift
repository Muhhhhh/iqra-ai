import Foundation
import Testing
@testable import RecitationCore

@Suite("Tajweed history")
struct TajweedHistoryTests {

    private func verse(_ surah: Int, _ ayah: Int, words: [String], from index: Int = 0,
                       status: WordStatus = .correct) -> [WordEvaluation] {
        words.enumerated().map { offset, text in
            WordEvaluation(
                targetIndex: index + offset,
                reference: VerseReference(surah: surah, ayah: ayah),
                expectedText: text,
                status: status,
                timeRange: 0...1,
                recognizerConfidence: 1
            )
        }
    }

    private func note(_ rule: TajweedRule, at index: Int, _ surah: Int, _ ayah: Int) -> TajweedNote {
        TajweedNote(
            rule: rule,
            targetIndex: index,
            reference: VerseReference(surah: surah, ayah: ayah),
            timeRange: 0...1,
            confidence: .low,
            message: ""
        )
    }

    @Test("A sound flagged once is not reported")
    func singleFlagIsNotRecurring() {
        // The whole point. Twelve flags across three readings of one page produced exactly
        // one sound flagged twice, so a lone verdict is the evidence this discounts.
        var history = TajweedHistory()
        history.record(
            words: verse(96, 3, words: ["ٱقْرَأْ", "وَرَبُّكَ"]),
            notes: [note(.qalqalah, at: 0, 96, 3)]
        )
        #expect(history.recurring().isEmpty)
    }

    @Test("The same sound flagged twice is")
    func repeatedFlagIsRecurring() {
        var history = TajweedHistory()
        for _ in 0..<2 {
            history.record(
                words: verse(96, 3, words: ["ٱقْرَأْ", "وَرَبُّكَ"]),
                notes: [note(.qalqalah, at: 0, 96, 3)]
            )
        }
        let recurring = history.recurring()
        #expect(recurring.count == 1)
        #expect(recurring.first?.text == "ٱقْرَأْ")
        #expect(recurring.first?.flagged == 2)
        #expect(recurring.first?.rate == 1.0)
    }

    @Test("A rate counts readings the sound was not flagged in")
    func rateUsesAllReadings() {
        // Flagged twice in five readings is one in five, not two in two. Counting readings
        // per entry would give the latter, since an entry only exists from the first time
        // it was flagged.
        var history = TajweedHistory()
        for reading in 0..<5 {
            history.record(
                words: verse(96, 3, words: ["ٱقْرَأْ", "وَرَبُّكَ"]),
                notes: reading < 2 ? [note(.qalqalah, at: 0, 96, 3)] : []
            )
        }
        let entry = try! #require(history.recurring().first)
        #expect(entry.flagged == 2)
        #expect(entry.readings == 5)
        #expect(abs(entry.rate - 0.4) < 0.001)
    }

    @Test("A word is found by its place, not by an index that moves")
    func locatedByPosition() {
        // Adding the basmala shifted every target index by four. A history keyed on those
        // would have started counting the same sound as a different one.
        var history = TajweedHistory()
        history.record(
            words: verse(96, 3, words: ["ٱقْرَأْ", "وَرَبُّكَ"], from: 0),
            notes: [note(.qalqalah, at: 0, 96, 3)]
        )
        history.record(
            words: verse(96, 3, words: ["ٱقْرَأْ", "وَرَبُّكَ"], from: 4),
            notes: [note(.qalqalah, at: 4, 96, 3)]
        )
        #expect(history.recurring().count == 1, "the same sound was counted twice over")
    }

    @Test("An āyah that was never recited counts as nothing")
    func unrecitedVersesDoNotCount() {
        var history = TajweedHistory()
        history.record(
            words: verse(96, 3, words: ["ٱقْرَأْ"], status: .notYetRecited),
            notes: []
        )
        #expect(history.readingsByVerse.isEmpty)
    }

    @Test("It survives being written and read back")
    func roundTrips() throws {
        var history = TajweedHistory()
        for _ in 0..<3 {
            history.record(
                words: verse(96, 3, words: ["ٱقْرَأْ"]),
                notes: [note(.qalqalah, at: 0, 96, 3)]
            )
        }
        let url = FileManager.default.temporaryDirectory
            .appending(path: "history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        history.save(to: url)

        let read = TajweedHistory.load(from: url)
        #expect(read.recurring().first?.flagged == 3)
        #expect(read.recurring().first?.rule == .qalqalah)
    }
}
