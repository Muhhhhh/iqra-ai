import Foundation

/// A reciter whose recitation can be downloaded for reference.
public struct Reciter: Sendable, Equatable, Identifiable, Hashable {
    /// Directory name on the audio host, which is also the local cache folder.
    public let id: String
    public let name: String
    public let arabicName: String
    /// Murattal is the measured style used for learning; mujawwad is the ornamented one.
    public let style: String
    /// Rough megabytes for the whole Quran at this bitrate, for the download UI.
    public let approximateMegabytes: Int

    public init(id: String, name: String, arabicName: String, style: String, approximateMegabytes: Int) {
        self.id = id
        self.name = name
        self.arabicName = arabicName
        self.style = style
        self.approximateMegabytes = approximateMegabytes
    }
}

extension Reciter {
    /// Mahmoud Khalil Al-Husary, murattal — the standard reference for learners, and the
    /// default here for that reason.
    public static let husary = Reciter(
        id: "Husary_128kbps",
        name: "Mahmoud Khalil Al-Husary",
        arabicName: "محمود خليل الحصري",
        style: "Murattal",
        approximateMegabytes: 1100
    )

    public static let catalogue: [Reciter] = [
        husary,
        Reciter(id: "Husary_Mujawwad_64kbps", name: "Al-Husary (Mujawwad)",
                arabicName: "محمود خليل الحصري — مجود", style: "Mujawwad", approximateMegabytes: 550),
        Reciter(id: "Abdul_Basit_Murattal_64kbps", name: "Abdul Basit Abdus Samad",
                arabicName: "عبد الباسط عبد الصمد", style: "Murattal", approximateMegabytes: 550),
        Reciter(id: "Minshawy_Murattal_128kbps", name: "Mohamed Siddiq El-Minshawi",
                arabicName: "محمد صديق المنشاوي", style: "Murattal", approximateMegabytes: 1100),
        Reciter(id: "Alafasy_128kbps", name: "Mishary Rashid Alafasy",
                arabicName: "مشاري راشد العفاسي", style: "Murattal", approximateMegabytes: 1100),
        Reciter(id: "Abdurrahmaan_As-Sudais_192kbps", name: "Abdurrahman As-Sudais",
                arabicName: "عبد الرحمن السديس", style: "Murattal", approximateMegabytes: 1700),
        Reciter(id: "Saood_ash-Shuraym_128kbps", name: "Saud Al-Shuraim",
                arabicName: "سعود الشريم", style: "Murattal", approximateMegabytes: 1100),
    ]
}

public enum ReciterAudioError: Error, Sendable {
    case notDownloaded(VerseReference)
    case downloadFailed(String)
    case offline
}

/// Downloads and caches per-āyah recitation for reference playback.
///
/// This is the one part of the app that touches the network, and it does so only when the
/// user asks. Everything that judges a recitation — the model, the VAD, the muṣḥaf — is
/// bundled and runs offline; this fetches a reference recording so you can *hear* the
/// āyah you stumbled on. Downloaded audio is cached permanently, so a passage you have
/// fetched once works offline afterwards.
public actor ReciterAudioLibrary {

    private let session: URLSession
    private let root: URL

    public init(root: URL? = nil) {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: configuration)

        if let root {
            self.root = root
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.root = support.appending(path: "Iqra/Reciters", directoryHint: .isDirectory)
        }
    }

    /// `001001.mp3` — three digits of surah, three of āyah.
    private func filename(for reference: VerseReference) -> String {
        String(format: "%03d%03d.mp3", reference.surah, reference.ayah)
    }

    public func localURL(for reference: VerseReference, reciter: Reciter) -> URL {
        root.appending(path: reciter.id, directoryHint: .isDirectory)
            .appending(path: filename(for: reference))
    }

    public func isDownloaded(_ reference: VerseReference, reciter: Reciter) -> Bool {
        FileManager.default.fileExists(atPath: localURL(for: reference, reciter: reciter).path)
    }

    /// Fetch one āyah, or return it from the cache.
    @discardableResult
    public func fetch(_ reference: VerseReference, reciter: Reciter) async throws -> URL {
        let destination = localURL(for: reference, reciter: reciter)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        guard let remote = URL(
            string: "https://everyayah.com/data/\(reciter.id)/\(filename(for: reference))"
        ) else {
            throw ReciterAudioError.downloadFailed("bad URL for \(reference)")
        }

        do {
            let (data, response) = try await session.data(from: remote)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw ReciterAudioError.downloadFailed("\(reference): HTTP \(code)")
            }
            // A truncated or error-page response would otherwise be cached as if it were
            // audio and fail silently at playback.
            guard data.count > 1_000 else {
                throw ReciterAudioError.downloadFailed("\(reference): response too small (\(data.count) bytes)")
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
            return destination
        } catch let error as ReciterAudioError {
            throw error
        } catch {
            throw ReciterAudioError.downloadFailed("\(reference): \(error.localizedDescription)")
        }
    }

    /// Fetch a run of āyāt, reporting progress. Used to make a page available offline.
    public func fetch(
        _ references: [VerseReference],
        reciter: Reciter,
        progress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) async -> (downloaded: Int, failures: [String]) {
        var downloaded = 0
        var failures: [String] = []
        for (index, reference) in references.enumerated() {
            if Task.isCancelled { break }
            do {
                _ = try await fetch(reference, reciter: reciter)
                downloaded += 1
            } catch {
                failures.append("\(error)")
            }
            progress(index + 1, references.count)
        }
        return (downloaded, failures)
    }

    /// How much of a passage is already on disk.
    public func downloadedCount(_ references: [VerseReference], reciter: Reciter) -> Int {
        references.count { isDownloaded($0, reciter: reciter) }
    }

    /// Bytes cached for one reciter, for the storage display.
    public func cacheSize(for reciter: Reciter) -> Int64 {
        let directory = root.appending(path: reciter.id, directoryHint: .isDirectory)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return entries.reduce(Int64(0)) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    public func removeCache(for reciter: Reciter) throws {
        let directory = root.appending(path: reciter.id, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
}
