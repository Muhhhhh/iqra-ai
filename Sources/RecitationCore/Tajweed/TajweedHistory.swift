import Foundation

/// What keeps being questioned, across sessions.
///
/// A single flag is weak evidence and this project has the measurement to say so: the same
/// reciter read Al-ʿAlaq three times and drew twelve flags between the readings, of which
/// exactly one sound — the qāf of ٱقْرَأْ — was flagged more than once. Either they recited
/// differently each time, which is what people do, or a lone verdict is largely noise.
/// Nothing available can separate those two, and it does not matter here, because the
/// conclusion is the same under both: a sound flagged once means little, and one flagged
/// on three separate readings means something whichever way the cause runs.
///
/// So the app stops judging each session as though it were the first. A word is identified
/// by where it sits — surah, āyah, and its position within that āyah — rather than by any
/// index into a target, because targets change when the app does; adding the basmala moved
/// every one of them by four.
///
/// Kept beside the reciter's other data and never sent anywhere.
public struct TajweedHistory: Codable, Sendable {

    /// One sound, and how it has fared.
    public struct Entry: Codable, Sendable, Hashable, Identifiable {
        public var surah: Int
        public var ayah: Int
        /// Position within the āyah, counting from zero.
        public var position: Int
        public var rule: TajweedRule
        /// Readings of this āyah in which the sound was questioned.
        public var flagged: Int
        /// Readings of this āyah, questioned or not.
        public var readings: Int
        /// The word itself, for showing back. Not part of identity.
        public var text: String

        public var id: String { "\(surah):\(ayah):\(position):\(rule.rawValue)" }

        /// How often this sound is questioned when the āyah is recited.
        public var rate: Double { readings > 0 ? Double(flagged) / Double(readings) : 0 }
    }

    public private(set) var entries: [String: Entry] = [:]
    /// Readings of each āyah, so a flag can be reported as a share rather than a count.
    public private(set) var readingsByVerse: [String: Int] = [:]

    public init() {}

    /// Take one finished session into the record.
    ///
    /// Counts a reading for every āyah the reciter actually reached, so a rule that was
    /// never in front of them does not dilute anything. Words are located by position
    /// within their āyah, which survives the target changing underneath.
    public mutating func record(words: [WordEvaluation], notes: [TajweedNote]) {
        var positions: [Int: (reference: VerseReference, position: Int, text: String)] = [:]
        var seen: [VerseReference: Int] = [:]
        var recited: Set<VerseReference> = []

        for word in words.sorted(by: { $0.targetIndex < $1.targetIndex }) {
            let next = seen[word.reference] ?? 0
            positions[word.targetIndex] = (word.reference, next, word.expectedText)
            seen[word.reference] = next + 1
            if word.status.wasRecited { recited.insert(word.reference) }
        }

        for reference in recited {
            readingsByVerse["\(reference.surah):\(reference.ayah)", default: 0] += 1
        }

        for note in notes {
            guard let where_ = positions[note.targetIndex], recited.contains(where_.reference)
            else { continue }
            let key = "\(where_.reference.surah):\(where_.reference.ayah):"
                + "\(where_.position):\(note.rule.rawValue)"
            var entry = entries[key] ?? Entry(
                surah: where_.reference.surah,
                ayah: where_.reference.ayah,
                position: where_.position,
                rule: note.rule,
                flagged: 0,
                readings: 0,
                text: where_.text
            )
            entry.flagged += 1
            entries[key] = entry
        }

        // Readings are counted from the verse totals rather than kept per entry, so a
        // sound questioned once in five readings reads as one in five and not as one in
        // one — which is what a per-entry count would have said, having only been created
        // the first time it was flagged.
        for key in entries.keys {
            let entry = entries[key]!
            entries[key]?.readings = readingsByVerse["\(entry.surah):\(entry.ayah)"] ?? entry.flagged
        }
    }

    /// What keeps coming back, most persistent first.
    ///
    /// Only sounds questioned more than once. A single flag is exactly the evidence this
    /// exists to discount, and listing it here would put it back.
    public func recurring(minimumFlags: Int = 2) -> [Entry] {
        entries.values
            .filter { $0.flagged >= minimumFlags }
            .sorted {
                $0.rate == $1.rate ? $0.flagged > $1.flagged : $0.rate > $1.rate
            }
    }

    // MARK: - Storage

    public static func location() -> URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: "Iqra/tajweed-history.json")
    }

    public static func load(from url: URL? = location()) -> TajweedHistory {
        guard let url, let data = try? Data(contentsOf: url),
              let history = try? JSONDecoder().decode(TajweedHistory.self, from: data)
        else { return TajweedHistory() }
        return history
    }

    public func save(to url: URL? = location()) {
        guard let url, let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url)
    }
}
