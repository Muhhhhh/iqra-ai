import Foundation

/// The phonetic script of every āyah, and the ṣifāt each phoneme should carry.
///
/// Built offline by `scripts/export-phonemes.py` from `quran_transcript` — the phonetiser
/// the Muaalem model was trained against — so the symbols here are class indices into the
/// model's own phoneme head, and the expectations are in the same vocabulary as its
/// predictions. No translation layer sits between what is expected and what is heard.
///
/// It is riwāyah-specific. The madd lengths chosen at export decide how many vowel
/// symbols a word carries, so this file describes Ḥafṣ ʿan ʿĀṣim and nothing else.
public struct PhonemeScript: Sendable {

    /// One āyah's phonemes, one entry per element.
    public struct Entry: Sendable {
        /// Class index into the model's phoneme head.
        public let symbols: [UInt8]
        /// Which word of the āyah each phoneme belongs to, 0-based.
        public let wordOfPhoneme: [UInt8]
        /// 1 must be nasalised, 2 must not, 0 no expectation.
        public let ghonna: [UInt8]
        /// 1 must be echoed, 2 must not, 0 no expectation.
        public let qalqala: [UInt8]
        public let wordCount: Int

        /// Phoneme positions belonging to a given word.
        public func range(ofWord index: Int) -> Range<Int>? {
            guard let first = wordOfPhoneme.firstIndex(of: UInt8(clamping: index)),
                  let last = wordOfPhoneme.lastIndex(of: UInt8(clamping: index))
            else { return nil }
            return first..<(last + 1)
        }
    }

    private let entries: [VerseReference: Entry]

    public enum LoadError: Error, Sendable {
        case missing(String)
        case malformed(String)
    }

    public init(contentsOf url: URL) throws {
        guard let data = try? Data(contentsOf: url) else { throw LoadError.missing(url.path) }
        guard data.count > 12, data.prefix(4) == Data("QPH1".utf8) else {
            throw LoadError.malformed("not a phoneme script file")
        }

        var offset = 4
        func int32() throws -> Int {
            guard offset + 4 <= data.count else { throw LoadError.malformed("truncated") }
            defer { offset += 4 }
            return Int(data.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.load(as: Int32.self) })
        }
        func uint16() throws -> Int {
            guard offset + 2 <= data.count else { throw LoadError.malformed("truncated") }
            defer { offset += 2 }
            return Int(data.subdata(in: offset..<(offset + 2)).withUnsafeBytes { $0.load(as: UInt16.self) })
        }
        func bytes(_ count: Int) throws -> [UInt8] {
            guard offset + count <= data.count else { throw LoadError.malformed("truncated") }
            defer { offset += count }
            return [UInt8](data.subdata(in: offset..<(offset + count)))
        }

        let version = try int32()
        guard version == 1 else { throw LoadError.malformed("version \(version)") }
        let count = try int32()

        var loaded: [VerseReference: Entry] = [:]
        loaded.reserveCapacity(count)
        for _ in 0..<count {
            let surah = try uint16()
            let ayah = try uint16()
            let words = try uint16()
            let phonemes = try uint16()
            let entry = Entry(
                symbols: try bytes(phonemes),
                wordOfPhoneme: try bytes(phonemes),
                ghonna: try bytes(phonemes),
                qalqala: try bytes(phonemes),
                wordCount: words
            )
            loaded[VerseReference(surah: surah, ayah: ayah)] = entry
        }
        entries = loaded
    }

    public subscript(reference: VerseReference) -> Entry? { entries[reference] }
    public var count: Int { entries.count }

    /// Locate the exported file beside the app's other resources.
    public static func locate(in bundle: Bundle = .main, additionalDirectories: [URL] = []) -> URL? {
        if let url = bundle.url(forResource: "quran-phonemes", withExtension: "bin") { return url }
        var directories = additionalDirectories
        var current = URL(fileURLWithPath: bundle.bundlePath).standardized
        for _ in 0..<8 {
            directories.append(current.appending(path: "Resources"))
            let parent = current.deletingLastPathComponent()
            if parent == current { break }
            current = parent
        }
        for directory in directories {
            let url = directory.appending(path: "quran-phonemes.bin")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}
