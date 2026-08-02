import Foundation
import Observation
import RecitationCore

/// Reference-recitation state for the UI: what is downloaded, what is playing.
@MainActor
@Observable
final class ReciterModel {
    static let shared = ReciterModel()

    private let library = ReciterAudioLibrary()
    private let player = ReferenceAudioPlayer()

    private(set) var playing: VerseReference?
    private(set) var busy: Set<VerseReference> = []
    private(set) var lastError: String?
    /// Progress of a bulk download, as (done, total).
    private(set) var downloadProgress: (done: Int, total: Int)?
    private(set) var cachedBytes: Int64 = 0

    private init() {}

    var isDownloading: Bool { downloadProgress != nil }

    /// Play an āyah, fetching it first if it is not already on disk.
    func play(_ reference: VerseReference, reciter: Reciter) {
        lastError = nil
        if playing == reference {
            player.stop()
            playing = nil
            return
        }
        busy.insert(reference)
        Task { @MainActor in
            defer { busy.remove(reference) }
            do {
                let url = try await library.fetch(reference, reciter: reciter)
                try player.play(url, reference: reference)
                playing = reference
            } catch {
                lastError = "\(error)"
            }
        }
    }

    func stop() {
        player.stop()
        playing = nil
    }

    /// Make a whole passage available offline.
    func download(_ references: [VerseReference], reciter: Reciter) {
        guard !references.isEmpty, downloadProgress == nil else { return }
        lastError = nil
        downloadProgress = (0, references.count)
        Task { @MainActor in
            let result = await library.fetch(references, reciter: reciter) { done, total in
                Task { @MainActor in self.downloadProgress = (done, total) }
            }
            downloadProgress = nil
            if result.downloaded < references.count {
                lastError = "\(references.count - result.downloaded) āyāt could not be downloaded."
            }
            await refreshCacheSize(for: reciter)
        }
    }

    func refreshCacheSize(for reciter: Reciter) async {
        cachedBytes = await library.cacheSize(for: reciter)
    }

    func clearCache(for reciter: Reciter) {
        Task { @MainActor in
            try? await library.removeCache(for: reciter)
            await refreshCacheSize(for: reciter)
        }
    }
}
