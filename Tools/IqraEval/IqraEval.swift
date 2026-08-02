import Foundation
import RecitationCore

/// Measures the recognition pipeline against **real recitation**.
///
/// Every accuracy figure this project had before this tool came from a synthetic TTS
/// clip, which has no madd, no tajweed, no melodic line and no breath pauses. It is not
/// the signal the app receives, so it could not say what actually limits accuracy.
///
/// The material here is real: reference recitations from everyayah.com, whose text is
/// known exactly from the bundled database. That gives aligned audio/text pairs for all
/// 6,236 āyāt without labelling anything.
///
/// Two numbers matter, and they are not the same:
///
/// * **Transcription accuracy** — word error rate against the known text.
/// * **Mistake behaviour** — how often clean recitation is falsely flagged, and how
///   often a deliberately introduced mistake is caught. The first of those is the number
///   this app lives by: telling someone they misrecited when they did not is the failure
///   it must never have. A pipeline that catches everything by flagging everything is
///   worse than useless here, so detection is never reported without its false-flag rate
///   beside it.
///
/// Mistakes are made by splicing whole āyāt, which needs no word-level boundaries in the
/// reference audio and therefore introduces no alignment assumptions of its own.
@main
struct IqraEval {

    static func main() async {
        let arguments = Arguments(CommandLine.arguments)
        if arguments.wantsHelp {
            print(Arguments.usage)
            return
        }

        do {
            try await run(arguments)
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    // MARK: - Setup

    static func run(_ arguments: Arguments) async throws {
        guard let databaseURL = SQLiteVerseStore.locateDatabase() else {
            throw EvalError.missing("quran.sqlite3 — run scripts/build-quran-db.py")
        }
        guard let model = SpeechModelLocator.locate(SpeechModelConfiguration(size: arguments.modelSize)) else {
            throw EvalError.missing("whisper weights — run scripts/convert-model.sh")
        }
        guard let vadModel = SpeechModelLocator.locateVAD() else {
            throw EvalError.missing("Silero VAD weights — run scripts/fetch-vad-model.sh")
        }
        let store = try SQLiteVerseStore(url: databaseURL)
        let reciter = Reciter.catalogue.first { $0.id == arguments.reciterID } ?? .husary
        let library = ReciterAudioLibrary()

        print("Iqra evaluation")
        print("  model     \(model.url.lastPathComponent) (\(model.hasCoreMLEncoder ? "Core ML encoder" : "Metal/CPU encoder"))")
        print("  reciter   \(reciter.name) · \(reciter.style)")
        print("  surahs    \(arguments.surahs.map(String.init).joined(separator: ", "))")
        print("")

        // --- Material -----------------------------------------------------------
        let cases = try await buildCases(
            surahs: arguments.surahs,
            store: store,
            reciter: reciter,
            library: library,
            kinds: arguments.kinds,
            limitPerSurah: arguments.limitPerSurah
        )
        guard !cases.isEmpty else { throw EvalError.missing("no cases could be built") }
        print("Built \(cases.count) cases from \(arguments.surahs.count) surahs.\n")

        // --- Sweep --------------------------------------------------------------
        var summaries: [(silence: TimeInterval, report: Report)] = []
        for trailingSilence in arguments.trailingSilences {
            print("── trailing silence \(format(trailingSilence, 2)) s ".padding(toLength: 72, withPad: "─", startingAt: 0))
            let report = try await measure(
                cases: cases,
                modelURL: model.url,
                vadModelURL: vadModel,
                trailingSilence: trailingSilence,
                beamSize: arguments.beamSize,
                verbose: arguments.verbose
            )
            report.printSummary()
            summaries.append((trailingSilence, report))
            print("")
        }

        if summaries.count > 1 { printComparison(summaries) }
    }

    // MARK: - Cases

    /// What a case is meant to prove.
    enum Kind: String, CaseIterable {
        /// Recited correctly and completely. Anything flagged here is a false alarm.
        case clean
        /// One āyah's audio removed while the target still expects it.
        case skippedAyah = "skip"
        /// One āyah replaced by a different one — the reciter reading the wrong text.
        case wrongPassage = "wrong"
        /// An āyah recited twice, as when going back to correct yourself. Legitimate:
        /// it must be read as a repetition, never as words added to the Quran.
        case repeatedAyah = "repeat"
    }

    struct Case {
        let kind: Kind
        let label: String
        /// What the reciter is supposed to be reciting.
        let target: RecitationTarget
        /// The audio actually presented, already spliced.
        let audio: AudioChunk
        /// For `skippedAyah`, the āyah whose audio was removed.
        let omitted: VerseReference?
        /// For `wrongPassage`, the āyah whose audio was replaced.
        let corrupted: VerseReference?
        /// Ground-truth text of what is actually audible, for word error rate.
        let spokenText: String
    }

    /// Three consecutive āyāt per case: enough for a skip to have text on both sides of
    /// it, which is what makes it a skip rather than a late start or an early stop.
    static func buildCases(
        surahs: [Int],
        store: SQLiteVerseStore,
        reciter: Reciter,
        library: ReciterAudioLibrary,
        kinds: [Kind],
        limitPerSurah: Int
    ) async throws -> [Case] {
        var cases: [Case] = []
        // A different surah's āyah, for the "reading the wrong text" case.
        let intruder = try await store.verses(
            from: VerseReference(surah: 109, ayah: 1),
            through: VerseReference(surah: 109, ayah: 1)
        ).first

        for surah in surahs {
            let target = try await store.target(surah: surah)
            let verses = target.verses
            guard verses.count >= 3 else { continue }

            var built = 0
            for start in 0...(verses.count - 3) where built < limitPerSurah {
                let triple = Array(verses[start..<(start + 3)])
                var audio: [VerseReference: AudioChunk] = [:]
                do {
                    for verse in triple {
                        let url = try await library.fetch(verse.reference, reciter: reciter)
                        audio[verse.reference] = try AudioFileLoader.load(url: url)
                    }
                } catch {
                    FileHandle.standardError.write(Data("  skipping \(triple[0].reference): \(error)\n".utf8))
                    continue
                }

                let passage = RecitationTarget(verses: triple)
                let ordered = triple.map { audio[$0.reference]! }

                for kind in kinds {
                    switch kind {
                    case .clean:
                        cases.append(Case(
                            kind: kind,
                            label: "\(triple[0].reference)–\(triple[2].reference)",
                            target: passage,
                            audio: splice(ordered),
                            omitted: nil,
                            corrupted: nil,
                            spokenText: triple.map(\.text).joined(separator: " ")
                        ))

                    case .skippedAyah:
                        cases.append(Case(
                            kind: kind,
                            label: "\(triple[1].reference) removed",
                            target: passage,
                            audio: splice([ordered[0], ordered[2]]),
                            omitted: triple[1].reference,
                            corrupted: nil,
                            spokenText: [triple[0].text, triple[2].text].joined(separator: " ")
                        ))

                    case .wrongPassage:
                        guard let intruder,
                              intruder.reference.surah != surah,
                              let intruderURL = try? await library.fetch(intruder.reference, reciter: reciter),
                              let intruderAudio = try? AudioFileLoader.load(url: intruderURL)
                        else { continue }
                        cases.append(Case(
                            kind: kind,
                            label: "\(triple[1].reference) ← \(intruder.reference)",
                            target: passage,
                            audio: splice([ordered[0], intruderAudio, ordered[2]]),
                            omitted: nil,
                            corrupted: triple[1].reference,
                            spokenText: [triple[0].text, intruder.text, triple[2].text].joined(separator: " ")
                        ))

                    case .repeatedAyah:
                        cases.append(Case(
                            kind: kind,
                            label: "\(triple[1].reference) twice",
                            target: passage,
                            audio: splice([ordered[0], ordered[1], ordered[1], ordered[2]]),
                            omitted: nil,
                            corrupted: nil,
                            spokenText: [triple[0].text, triple[1].text, triple[1].text, triple[2].text]
                                .joined(separator: " ")
                        ))
                    }
                }
                built += 1
            }
        }
        return cases
    }

    /// Join āyāt with a pause between them, and a little silence at each end.
    ///
    /// The leading silence is not padding: the VAD needs some non-speech before the
    /// first word to have anything to open a segment against, exactly as it does when
    /// someone presses Start and then begins.
    static func splice(_ chunks: [AudioChunk], gap: TimeInterval = 0.5, lead: TimeInterval = 0.6) -> AudioChunk {
        let rate = AudioChunk.canonicalSampleRate
        var samples = [Float](repeating: 0, count: Int(lead * rate))
        let gapSamples = [Float](repeating: 0, count: Int(gap * rate))
        for (index, chunk) in chunks.enumerated() {
            if index > 0 { samples.append(contentsOf: gapSamples) }
            samples.append(contentsOf: chunk.samples)
        }
        samples.append(contentsOf: gapSamples)
        return AudioChunk(samples: samples, startTime: 0)
    }

    // MARK: - Running the pipeline

    /// Drives the same components in the same order as `RecitationPipeline`, but
    /// synchronously: frame → VAD → segment → recognise → accumulate, then flush and
    /// align once at the end. Running the actor would add scheduling races to a
    /// measurement, without changing what is measured.
    static func measure(
        cases: [Case],
        modelURL: URL,
        vadModelURL: URL,
        trailingSilence: TimeInterval,
        beamSize: Int,
        verbose: Bool
    ) async throws -> Report {
        let recognizer = WhisperSpeechRecognizer(
            modelURL: modelURL,
            options: .init(beamSize: beamSize)
        )
        let vad = SileroVoiceActivityDetector(
            modelURL: vadModelURL,
            options: .init(
                segmentation: .init(trailingSilence: trailingSilence)
            )
        )
        let aligner = TokenAligner()

        var report = Report(trailingSilence: trailingSilence)
        let frameSamples = Int(0.1 * AudioChunk.canonicalSampleRate)

        for testCase in cases {
            await vad.reset()
            var tokens: [TranscribedToken] = []
            var segmentCount = 0
            let started = Date()

            var offset = 0
            while offset < testCase.audio.samples.count {
                let end = min(offset + frameSamples, testCase.audio.samples.count)
                let frame = AudioChunk(
                    samples: Array(testCase.audio.samples[offset..<end]),
                    startTime: Double(offset) / AudioChunk.canonicalSampleRate
                )
                for segment in await vad.process(frame) {
                    segmentCount += 1
                    if let transcription = try? await recognizer.transcribe(segment) {
                        tokens.append(contentsOf: transcription.tokens)
                    }
                }
                offset = end
            }
            if let tail = await vad.flush() {
                segmentCount += 1
                if let transcription = try? await recognizer.transcribe(tail) {
                    tokens.append(contentsOf: transcription.tokens)
                }
            }

            let elapsed = Date().timeIntervalSince(started)
            let duration = Double(testCase.audio.samples.count) / AudioChunk.canonicalSampleRate
            let result = aligner.align(heard: tokens, against: testCase.target, isFinal: true)
            report.record(
                testCase,
                result: result,
                heard: tokens.map(\.text).joined(separator: " "),
                segments: segmentCount,
                realTimeFactor: elapsed / max(duration, 0.001),
                verbose: verbose
            )
        }

        await recognizer.unloadModel()
        await vad.unloadModel()
        return report
    }

    // MARK: - Reporting

    struct Report {
        let trailingSilence: TimeInterval

        var cleanCases = 0
        var cleanWords = 0
        var falseFlags = 0
        var fabricatedAdditions = 0
        var spotlessCases = 0

        var skipCases = 0
        var skipsCaught = 0

        var wrongCases = 0
        var wrongCaught = 0
        var wrongCollateral = 0

        var repeatCases = 0
        var repeatsMisreadAsAdditions = 0

        /// Heard words containing U+FFFD — whisper's byte-level BPE splits an Arabic
        /// character across two tokens, and decoding each token separately destroys it.
        /// Such a word can never match anything, so every one is a false flag waiting
        /// to happen. This must stay at zero.
        var corruptedWords = 0
        var wordErrors = 0
        var referenceWords = 0
        var segments = 0
        var realTimeFactors: [Double] = []

        mutating func record(
            _ testCase: Case,
            result: AlignmentResult,
            heard: String,
            segments segmentCount: Int,
            realTimeFactor: Double,
            verbose: Bool
        ) {
            segments += segmentCount
            realTimeFactors.append(realTimeFactor)

            corruptedWords += heard.split(whereSeparator: \.isWhitespace)
                .count { $0.unicodeScalars.contains("\u{FFFD}") }

            let reference = normalizedWords(testCase.spokenText)
            referenceWords += reference.count
            wordErrors += editDistance(reference, normalizedWords(heard))

            switch testCase.kind {
            case .clean:
                cleanCases += 1
                cleanWords += result.words.count
                falseFlags += result.mistakeCount
                fabricatedAdditions += result.additions.count
                if result.mistakeCount == 0 && result.additions.isEmpty { spotlessCases += 1 }

            case .skippedAyah:
                skipCases += 1
                if let omitted = testCase.omitted, result.skippedVerses.contains(omitted) {
                    skipsCaught += 1
                }

            case .wrongPassage:
                wrongCases += 1
                let flaggedInCorrupted = result.words.contains {
                    $0.reference == testCase.corrupted && $0.status.isMistake
                }
                if flaggedInCorrupted { wrongCaught += 1 }
                // Mistakes reported outside the replaced āyah are collateral: the
                // reciter got those right.
                wrongCollateral += result.words.count {
                    $0.reference != testCase.corrupted && $0.status.isMistake
                }

            case .repeatedAyah:
                repeatCases += 1
                repeatsMisreadAsAdditions += result.additions.count
            }

            if verbose {
                print("  [\(testCase.kind.rawValue)] \(testCase.label): "
                      + "\(result.mistakeCount) flagged, \(result.additions.count) added, "
                      + "\(result.skippedVerses.count) verses skipped, \(segmentCount) segments")
            }
        }

        func printSummary() {
            let out = { (line: String) in Swift.print(line) }
            if corruptedWords > 0 {
                out("  CORRUPTED WORDS      \(corruptedWords) heard words contain U+FFFD — token bytes lost")
            }
            if referenceWords > 0 {
                out("  word error rate      \(format(100 * Double(wordErrors) / Double(referenceWords), 1))%  "
                    + "(\(wordErrors) errors in \(referenceWords) words)")
            }
            if cleanCases > 0 {
                out("  FALSE FLAGS          \(format(100 * Double(falseFlags) / Double(max(cleanWords, 1)), 2))% of words  "
                    + "(\(falseFlags) in \(cleanWords)), \(fabricatedAdditions) invented additions")
                out("  clean passages       \(spotlessCases)/\(cleanCases) with nothing flagged at all")
            }
            if skipCases > 0 {
                out("  omitted āyah caught  \(skipsCaught)/\(skipCases)  (\(format(100 * Double(skipsCaught) / Double(skipCases), 0))%)")
            }
            if wrongCases > 0 {
                out("  wrong āyah caught    \(wrongCaught)/\(wrongCases)  (\(format(100 * Double(wrongCaught) / Double(wrongCases), 0))%), "
                    + "\(wrongCollateral) words flagged outside it")
            }
            if repeatCases > 0 {
                out("  repeated āyah        \(repeatsMisreadAsAdditions) misread as added words across \(repeatCases) cases")
            }
            let factors = realTimeFactors.sorted()
            if let median = factors.isEmpty ? nil : factors[factors.count / 2] {
                out("  speed                \(format(median, 2))× real time (median), \(segments) segments total")
            }
        }
    }

    static func printComparison(_ summaries: [(silence: TimeInterval, report: Report)]) {
        print("── comparison ".padding(toLength: 72, withPad: "─", startingAt: 0))
        print("  silence   WER     false flags   clean passages   skips   wrong   speed")
        for entry in summaries {
            let r = entry.report
            let wer = r.referenceWords > 0 ? format(100 * Double(r.wordErrors) / Double(r.referenceWords), 1) + "%" : "—"
            let falseRate = r.cleanWords > 0 ? format(100 * Double(r.falseFlags) / Double(r.cleanWords), 2) + "%" : "—"
            let spotless = r.cleanCases > 0 ? "\(r.spotlessCases)/\(r.cleanCases)" : "—"
            let skips = r.skipCases > 0 ? "\(r.skipsCaught)/\(r.skipCases)" : "—"
            let wrong = r.wrongCases > 0 ? "\(r.wrongCaught)/\(r.wrongCases)" : "—"
            let factors = r.realTimeFactors.sorted()
            let speed = factors.isEmpty ? "—" : format(factors[factors.count / 2], 2) + "×"
            print("  \(format(entry.silence, 2)) s".padding(toLength: 12, withPad: " ", startingAt: 0)
                  + wer.padding(toLength: 8, withPad: " ", startingAt: 0)
                  + falseRate.padding(toLength: 14, withPad: " ", startingAt: 0)
                  + spotless.padding(toLength: 17, withPad: " ", startingAt: 0)
                  + skips.padding(toLength: 8, withPad: " ", startingAt: 0)
                  + wrong.padding(toLength: 8, withPad: " ", startingAt: 0)
                  + speed)
        }
        print("")
        print("  False flags are the number to minimise: they are the app telling someone")
        print("  they misrecited when they did not. Detection rates are only meaningful")
        print("  read beside them.")
    }

    // MARK: - Text comparison

    static func normalizedWords(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace)
            .map { ArabicNormalizer.normalize(String($0)) }
            .filter { !$0.isEmpty }
    }

    /// Word-level Levenshtein, for word error rate.
    static func editDistance(_ lhs: [String], _ rhs: [String]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        var previous = Array(0...rhs.count)
        var current = [Int](repeating: 0, count: rhs.count + 1)
        for i in 1...lhs.count {
            current[0] = i
            for j in 1...rhs.count {
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + (lhs[i - 1] == rhs[j - 1] ? 0 : 1)
                )
            }
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }

    static func format(_ value: Double, _ places: Int) -> String {
        // Plain interpolation of a rounded value: String(format:) with mixed varargs
        // has segfaulted in this codebase before.
        let scale = pow(10.0, Double(places))
        let rounded = (value * scale).rounded() / scale
        return places == 0 ? "\(Int(rounded))" : "\(rounded)"
    }

    enum EvalError: Error, CustomStringConvertible {
        case missing(String)
        var description: String {
            switch self {
            case .missing(let what): return "missing \(what)"
            }
        }
    }
}

// MARK: - Arguments

struct Arguments {
    /// A mix on purpose. The short muffaṣal surahs alone contain almost no dagger
    /// alefs — 17 words across eleven surahs — so an eval set drawn only from them is
    /// blind to a spelling ambiguity that affects 11% of the Quran (9,301 words). The
    /// long surahs carry it densely: Al-Baqarah alone has 698.
    var surahs: [Int] = [2, 4, 7, 20, 36, 55, 67, 78, 112, 114]
    var trailingSilences: [TimeInterval] = [0.6]
    var kinds: [IqraEval.Kind] = IqraEval.Kind.allCases
    var reciterID: String = Reciter.husary.id
    var modelSize: SpeechModelConfiguration.Size = .base
    var beamSize: Int = 1
    var limitPerSurah: Int = 2
    var verbose = false
    var wantsHelp = false

    static let usage = """
    iqra-eval — measure the pipeline against real recitation

      --surahs 112,110,108        surahs to draw passages from
      --trailing-silence 0.6,1.0  VAD settings to sweep (seconds)
      --cases clean,skip,wrong,repeat
      --reciter husary
      --model base
      --beam 1
      --limit 2                   passages per surah
      --verbose                   print every case
    """

    init(_ arguments: [String]) {
        var index = 1
        func next() -> String? {
            index += 1
            return index < arguments.count ? arguments[index] : nil
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--surahs": surahs = next()?.split(separator: ",").compactMap { Int($0) } ?? surahs
            case "--trailing-silence": trailingSilences = next()?.split(separator: ",").compactMap { Double($0) } ?? trailingSilences
            case "--cases": kinds = next()?.split(separator: ",").compactMap { IqraEval.Kind(rawValue: String($0)) } ?? kinds
            case "--reciter": reciterID = next() ?? reciterID
            case "--model": modelSize = next().flatMap { SpeechModelConfiguration.Size(rawValue: $0) } ?? modelSize
            case "--beam": beamSize = next().flatMap { Int($0) } ?? beamSize
            case "--limit": limitPerSurah = next().flatMap { Int($0) } ?? limitPerSurah
            case "--verbose": verbose = true
            case "-h", "--help": wantsHelp = true
            default: break
            }
            index += 1
        }
    }
}
