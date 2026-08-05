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

    /// The ṣifāt the phonetiser labels, in the order the exported planes appear.
    ///
    /// The order is the file format and must match `scripts/export-phonemes.py`. It is
    /// not alphabetical and not the model's head order — it is simply the order chosen at
    /// export, so changing either side without the other silently reads one attribute as
    /// another.
    public enum Sifa: Int, Sendable, CaseIterable {
        case ghonna = 0
        case hamsOrJahr
        case shiddaOrRakhawa
        case tafkhimOrTarqiq
        case itbaq
        case qalqala
        case safeer
        case istitala
        case tafashie
        case tikraar
    }

    /// One āyah's phonemes, one entry per element.
    public struct Entry: Sendable {
        /// Class index into the model's phoneme head.
        public let symbols: [UInt8]
        /// Which word of the āyah each phoneme belongs to, 0-based.
        public let wordOfPhoneme: [UInt8]
        /// Every ṣifah the text requires of each phoneme, one plane each, in the order
        /// `Sifa.allCases`. 0 means the phonetiser had no expectation; otherwise the
        /// 1-based class within that ṣifah.
        ///
        /// All ten are carried rather than the two the app judges today. Forced alignment
        /// turns each of them into labelled audio at no cost — every ṣifah of every
        /// phoneme of every āyah, in recitation known to be correct — which is the raw
        /// material for training a detector that *hears* an attribute instead of
        /// predicting it from the letters around it.
        public let sifat: [[UInt8]]
        /// 1 idghām with ghunnah, 2 without, 0 none.
        ///
        /// Read from the Uthmani text at export, not from the phonemes, because the
        /// phonemes cannot carry it: assimilation merges the words it happens at — هُدًۭى
        /// مِّن رَّبِّهِمْ is one phonetic word — and a doubled mīm looks identical whether it
        /// came from أُمَّة or from مِن مَّاء. In the muṣḥaf it is a shadda on the first letter
        /// of a word whose predecessor ended in nūn sākinah or tanwīn, which is exact.
        public let idgham: [UInt8]
        /// Which madd, named by the phonetiser: 1 normal, 2 muttaṣil, 3 munfaṣil,
        /// 4 ʿāriḍ, 5 lāzim. 0 where the phoneme is not part of one.
        ///
        /// Munfaṣil, muttaṣil and ʿāriḍ are all written at four counts, so nothing
        /// downstream can tell them apart by length — and the app called every one of
        /// them wājib muttaṣil until this arrived.
        public let maddKind: [UInt8]
        public let wordCount: Int

        /// 1 must be nasalised, 2 must not, 0 no expectation.
        public var ghonna: [UInt8] { plane(.ghonna) }
        /// 1 must be echoed, 2 must not, 0 no expectation.
        public var qalqala: [UInt8] { plane(.qalqala) }

        public func plane(_ sifa: Sifa) -> [UInt8] {
            let index = sifa.rawValue
            return index < sifat.count ? sifat[index] : []
        }

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
        guard version == 2 else { throw LoadError.malformed("version \(version)") }
        let count = try int32()

        var loaded: [VerseReference: Entry] = [:]
        loaded.reserveCapacity(count)
        for _ in 0..<count {
            let surah = try uint16()
            let ayah = try uint16()
            let words = try uint16()
            let phonemes = try uint16()
            let symbols = try bytes(phonemes)
            let wordOf = try bytes(phonemes)
            var planes: [[UInt8]] = []
            planes.reserveCapacity(Sifa.allCases.count)
            for _ in Sifa.allCases { planes.append(try bytes(phonemes)) }
            let idgham = try bytes(phonemes)
            let maddKind = try bytes(phonemes)
            let entry = Entry(
                symbols: symbols,
                wordOfPhoneme: wordOf,
                sifat: planes,
                idgham: idgham,
                maddKind: maddKind,
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
