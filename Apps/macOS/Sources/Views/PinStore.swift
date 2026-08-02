import Foundation
import Observation
import RecitationCore

/// A place in the muṣḥaf the reader wants to come back to: a whole surah, or one āyah.
///
/// The page is resolved when the pin is made and stored with it, so opening a pin is a
/// single jump with no lookup — and so a pin still works if the database is unavailable.
struct Pin: Codable, Hashable, Identifiable {
    var surah: Int
    /// Nil pins the whole surah.
    var ayah: Int?
    var page: Int

    var id: String { ayah.map { "\(surah):\($0)" } ?? "surah-\(surah)" }

    var reference: VerseReference? {
        ayah.map { VerseReference(surah: surah, ayah: $0) }
    }

    var isSurah: Bool { ayah == nil }
}

/// The reader's pinned places, kept across launches.
///
/// A bookmark that disappears when the app quits is not a bookmark, so this is the one
/// piece of state written to disk. It holds nothing but positions in the muṣḥaf — no
/// audio, no transcripts, nothing about how anyone recited.
@MainActor
@Observable
final class PinStore {
    static let shared = PinStore()

    private static let defaultsKey = "IqraPins"

    private(set) var pins: [Pin] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([Pin].self, from: data) {
            pins = decoded
        }
    }

    func contains(surah: Int, ayah: Int? = nil) -> Bool {
        pins.contains { $0.surah == surah && $0.ayah == ayah }
    }

    /// Pin if absent, unpin if present. Returns the state afterwards.
    @discardableResult
    func toggle(surah: Int, ayah: Int? = nil, page: Int) -> Bool {
        if contains(surah: surah, ayah: ayah) {
            pins.removeAll { $0.surah == surah && $0.ayah == ayah }
            save()
            return false
        }
        pins.append(Pin(surah: surah, ayah: ayah, page: page))
        // Muṣḥaf order, so the list reads the way the book does.
        pins.sort { ($0.surah, $0.ayah ?? 0) < ($1.surah, $1.ayah ?? 0) }
        save()
        return true
    }

    func remove(_ pin: Pin) {
        pins.removeAll { $0.id == pin.id }
        save()
    }

    func removeAll() {
        pins.removeAll()
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(pins) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
