import Foundation
import RecitationCore

/// What the tajweed model says when the rule **is** applied correctly.
///
/// The thresholds deciding whether to question someone's tajweed were written by hand
/// before a single recitation had been measured through them. This derives them instead.
///
/// The method needs no labelled errors, which is what makes it possible at all. A
/// reference recitation by a qārī of Al-Husary's standing applies every rule the text
/// requires; so running the model across hundreds of those gives the distribution of its
/// output **on correct recitation**. A threshold placed at the low tail of that
/// distribution then has a meaning that can be stated: "this is below what expert
/// recitation produces, and here is the fraction of expert recitation it would have
/// wrongly questioned."
///
/// That is one-sided — it says nothing about what the model does when a rule is genuinely
/// absent, so it cannot report a detection rate. It answers the prior question: whether
/// the model separates correct recitation from anything at all, and where silence should
/// end. If the ghunnah head reads 0.6 on ghunnahs Husary certainly applied, no threshold
/// rescues it and there is nothing to calibrate.
///
/// Only words the matcher marked **correct** are used. A word the recogniser mangled has
/// unreliable timing, and reading the model's output over the wrong stretch of audio
/// would poison the distribution with noise that has nothing to do with tajweed.
enum TajweedCalibration {

    /// One measurement of one rule occurrence in known-correct recitation.
    struct Sample {
        let rule: TajweedRule
        let head: MuaalemTajweedAnalyzer.Head
        /// True when the rule requires the attribute present; false when it requires its
        /// absence (iẓhār is the nūn rule defined by *not* nasalising).
        let expectsPresence: Bool
        /// Mean probability of the attribute the rule requires, across the word.
        let mean: Double
        /// Best sustained stretch of it — the highest mean over `minimumFrames`
        /// consecutive frames.
        ///
        /// Reported beside the mean because a rule lives on particular letters, not on
        /// the whole word: a ghunnah is two harakāt of one nūn inside a word that may run
        /// six letters. Averaging across all of them dilutes the very thing being
        /// measured, and the more letters the word has the more diluted it gets.
        let sustained: Double
        /// Mean probability of the contrary reading, which is what the analyzer requires
        /// to be high before it says anything.
        let contrary: Double
        /// Highest single-frame probability of the required attribute anywhere in the word.
        ///
        /// The statistic that matters for a CTC model. CTC does not label every frame —
        /// it emits blank almost everywhere and spikes where it has something to say. A
        /// ghunnah is one spike on one nūn; the rest of the word is other letters, whose
        /// frames carry the *contrary* label quite correctly. Averaging across the word
        /// therefore measures "how much of this word is not a ghunnah", which is high for
        /// every word ever recited, correctly or not.
        let peak: Double
        let frames: Int
    }

    struct Skips {
        var noExpectation = 0
        var noTiming = 0
        var wordNotMatched = 0
        var tooFewFrames = 0
        var total: Int { noExpectation + noTiming + wordNotMatched + tooFewFrames }
    }

    // MARK: - Collection

    static func run(_ arguments: Arguments) async throws {
        guard let databaseURL = SQLiteVerseStore.locateDatabase() else {
            throw IqraEval.EvalError.missing("quran.sqlite3")
        }
        guard let modelURL = SpeechModelLocator.locate(SpeechModelConfiguration(size: arguments.modelSize)) else {
            throw IqraEval.EvalError.missing("whisper weights")
        }
        guard let vadModelURL = SpeechModelLocator.locateVAD() else {
            throw IqraEval.EvalError.missing("Silero VAD weights")
        }
        let tajweedModel: URL
        if let path = arguments.tajweedModelPath {
            tajweedModel = URL(fileURLWithPath: path)
        } else if let located = MuaalemTajweedAnalyzer.locateModel() {
            tajweedModel = located
        } else {
            throw IqraEval.EvalError.missing("Muaalem model — run scripts/convert-tajweed-model.py")
        }
        guard let frontend = MuaalemFeatures.locate() else {
            throw IqraEval.EvalError.missing("Muaalem front-end — run scripts/export-tajweed-frontend.py")
        }

        let store = try SQLiteVerseStore(url: databaseURL)
        let reciter = Reciter.catalogue.first { $0.id == arguments.reciterID } ?? .husary
        let library = ReciterAudioLibrary()
        let analyzer = MuaalemTajweedAnalyzer(
            modelURL: tajweedModel,
            features: try MuaalemFeatures(resourceURL: frontend)
        )

        if arguments.dumpTajweedOutput {
            let library2 = ReciterAudioLibrary()
            let url = try await library2.fetch(VerseReference(surah: 36, ayah: 1), reciter: reciter)
            let audio = try AudioFileLoader.load(url: url)
            print(try await analyzer.describeOutput(for: audio))
            return
        }

        print("Tajweed calibration")
        print("  tajweed model  \(tajweedModel.lastPathComponent)")
        print("  reciter        \(reciter.name) · \(reciter.style) — assumed correct throughout")
        print("  riwāyah        Ḥafṣ ʿan ʿĀṣim. Calibration does not transfer to another.")
        print("")

        let recognizer = WhisperSpeechRecognizer(
            modelURL: modelURL.url,
            options: .init(
                beamSize: arguments.beamSize,
                alignmentHeads: .matching(arguments.modelSize)
            )
        )
        let vad = SileroVoiceActivityDetector(modelURL: vadModelURL)
        let aligner = TokenAligner()

        var samples: [Sample] = []
        var skips = Skips()
        var occurrencesSeen = 0
        var ayatUsed = 0

        for surah in arguments.surahs {
            let surahTarget = try await store.target(surah: surah)
            for verse in surahTarget.verses.prefix(arguments.limitPerSurah) {
                let target = RecitationTarget(verse: verse)
                let occurrences = TajweedRuleDetector.occurrences(in: target)
                guard !occurrences.isEmpty else { continue }

                guard let url = try? await library.fetch(verse.reference, reciter: reciter),
                      let audio = try? AudioFileLoader.load(url: url) else { continue }

                // Lead-in silence so the VAD has something to open against, as when
                // someone presses Start and then begins.
                let padded = IqraEval.splice([audio])
                await vad.reset()

                var tokens: [TranscribedToken] = []
                var segments: [AudioChunk] = []
                var offset = 0
                let frameSamples = Int(0.1 * AudioChunk.canonicalSampleRate)
                while offset < padded.samples.count {
                    let end = min(offset + frameSamples, padded.samples.count)
                    let frame = AudioChunk(
                        samples: Array(padded.samples[offset..<end]),
                        startTime: Double(offset) / AudioChunk.canonicalSampleRate
                    )
                    for segment in await vad.process(frame) {
                        segments.append(segment)
                        if let transcription = try? await recognizer.transcribe(segment) {
                            tokens.append(contentsOf: transcription.tokens)
                        }
                    }
                    offset = end
                }
                if let tail = await vad.flush() {
                    segments.append(tail)
                    if let transcription = try? await recognizer.transcribe(tail) {
                        tokens.append(contentsOf: transcription.tokens)
                    }
                }
                guard !segments.isEmpty else { continue }

                let alignment = aligner.align(heard: tokens, against: target, isFinal: true)
                // Only words the matcher is confident about: their timings are the only
                // ones worth reading the model's output against.
                var timings: [Int: ClosedRange<TimeInterval>] = [:]
                for word in alignment.words where word.status == .correct {
                    if let range = word.timeRange { timings[word.targetIndex] = range }
                }

                ayatUsed += 1
                occurrencesSeen += occurrences.count

                for segment in segments {
                    guard let observed = try? await analyzer.probabilities(for: segment) else { continue }
                    collect(
                        occurrences: occurrences,
                        observed: observed,
                        timings: timings,
                        matched: Set(alignment.words.filter { $0.status == .correct }.map(\.targetIndex)),
                        minimumFrames: arguments.minimumFrames,
                        into: &samples,
                        skips: &skips
                    )
                }
            }
        }

        await recognizer.unloadModel()
        await vad.unloadModel()

        report(samples: samples, skips: skips, occurrencesSeen: occurrencesSeen, ayat: ayatUsed)
    }

    static func collect(
        occurrences: [TajweedOccurrence],
        observed: MuaalemTajweedAnalyzer.Observation,
        timings: [Int: ClosedRange<TimeInterval>],
        matched: Set<Int>,
        minimumFrames: Int,
        into samples: inout [Sample],
        skips: inout Skips
    ) {
        for occurrence in occurrences {
            guard let expectation = MuaalemTajweedAnalyzer.expectation(for: occurrence.rule) else {
                skips.noExpectation += 1
                continue
            }
            guard matched.contains(occurrence.targetIndex) else {
                skips.wordNotMatched += 1
                continue
            }
            guard let range = timings[occurrence.targetIndex] else {
                skips.noTiming += 1
                continue
            }
            guard let series = observed.probabilities[expectation.head.rawValue] else { continue }

            let first = Int(((range.lowerBound - observed.startTime) / observed.frameDuration).rounded(.down))
            let last = Int(((range.upperBound - observed.startTime) / observed.frameDuration).rounded(.up))
            let lower = max(0, first)
            let upper = min(series.count, last)
            guard upper > lower else {
                skips.tooFewFrames += 1
                continue
            }

            let presentIndex = expectation.head.presentIndex
            let absentIndex = expectation.head.absentIndex
            var wanted: [Double] = []
            var against: [Double] = []
            for frame in series[lower..<upper] where frame.count > max(presentIndex, absentIndex) {
                guard frame[0] < 0.5 else { continue }   // padding frame
                let presence = frame[presentIndex]
                let contrary = frame[absentIndex]
                wanted.append(expectation.present ? presence : contrary)
                against.append(expectation.present ? contrary : presence)
            }
            guard wanted.count >= minimumFrames else {
                skips.tooFewFrames += 1
                continue
            }

            samples.append(
                Sample(
                    rule: occurrence.rule,
                    head: expectation.head,
                    expectsPresence: expectation.present,
                    mean: wanted.reduce(0, +) / Double(wanted.count),
                    sustained: bestSustained(wanted, window: minimumFrames),
                    contrary: against.reduce(0, +) / Double(against.count),
                    peak: wanted.max() ?? 0,
                    frames: wanted.count
                )
            )
        }
    }

    /// Highest mean over any `window` consecutive frames.
    static func bestSustained(_ values: [Double], window: Int) -> Double {
        guard values.count >= window, window > 0 else {
            return values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        }
        var sum = values[0..<window].reduce(0, +)
        var best = sum
        for index in window..<values.count {
            sum += values[index] - values[index - window]
            best = max(best, sum)
        }
        return best / Double(window)
    }

    // MARK: - Reporting

    static func report(samples: [Sample], skips: Skips, occurrencesSeen: Int, ayat: Int) {
        print("Measured \(samples.count) rule occurrences in \(ayat) āyāt "
              + "(\(occurrencesSeen) required by the text).")
        if skips.total > 0 {
            print("  not measured:")
            if skips.wordNotMatched > 0 {
                print("    \(skips.wordNotMatched)  the word was not recognised, so its timing cannot be trusted")
            }
            if skips.noTiming > 0 { print("    \(skips.noTiming)  no time range for the word") }
            if skips.noExpectation > 0 {
                print("    \(skips.noExpectation)  madd rules — checked by duration, not by this model")
            }
            if skips.tooFewFrames > 0 { print("    \(skips.tooFewFrames)  too few frames of audio") }
        }
        print("")

        guard !samples.isEmpty else {
            print("Nothing to calibrate. If most occurrences went unmeasured because the word")
            print("was not recognised, that is the finding: audio tajweed checking is gated")
            print("behind word matching, and at the current word error rate most rules never")
            print("get looked at, whether or not the reciter applied them.")
            return
        }

        let spread = samples.map { abs($0.mean - $0.contrary) }
        let meanSpread = spread.reduce(0, +) / Double(spread.count)
        if meanSpread < 0.05 {
            print("⚠️  The model has no opinion.")
            print("")
            print("   Across \(samples.count) occurrences the probability of the attribute the rule")
            print("   requires and the probability of its contrary differ by \(pct(meanSpread)) on average.")
            print("   For a three-class head, output this flat is a uniform distribution: the model")
            print("   is not distinguishing nasalised from not, or echoed from not, anywhere.")
            print("")
            print("   No threshold fixes this, and neither does fine-tuning it — the artefact being")
            print("   run is not producing signal to tune. The conversion is the thing to fix.")
            print("")
        }

        let byRule = Dictionary(grouping: samples, by: \.rule)
        print("Probability of the attribute each rule requires, on recitation that has it.")
        print("A threshold at p5 would question 5% of Al-Husary's own recitation.")
        print("")
        print("               mean over word          │ peak in word (CTC spike)")
        print("  rule            n    p5    med   mean │   p1     p5    p25    med")
        for rule in byRule.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let group = byRule[rule]!
            let means = group.map(\.mean).sorted()
            let sustained = group.map(\.sustained).sorted()
            let contrary = group.map(\.contrary).sorted()
            let name = (rule.rawValue + (group[0].expectsPresence ? "" : " (absent)"))
                .padding(toLength: 20, withPad: " ", startingAt: 0)
            let peaks = group.map(\.peak).sorted()
            _ = sustained
            _ = contrary
            print("  \(name.prefix(14).padding(toLength: 14, withPad: " ", startingAt: 0)) \(pad(group.count, 4)) "
                  + "\(pct(percentile(means, 0.05))) \(pct(percentile(means, 0.50))) "
                  + "\(pct(means.reduce(0, +) / Double(means.count))) │ "
                  + "\(pct(percentile(peaks, 0.01)))  \(pct(percentile(peaks, 0.05)))  "
                  + "\(pct(percentile(peaks, 0.25)))  \(pct(percentile(peaks, 0.50)))")
        }
        print("")

        // What the shipped thresholds would do to correct recitation.
        let options = MuaalemTajweedAnalyzer.Options()
        // Exactly what the analyzer does: peak-based, and only the rules it judges.
        let judged = samples.filter { MuaalemTajweedAnalyzer.audioVerifiable.contains($0.rule) }
        let contraryPeak = { (sample: Sample) in max(sample.contrary, 1 - sample.peak) }
        let wouldFlag = judged.count {
            $0.peak < options.presenceThreshold && contraryPeak($0) > options.contraryThreshold
        }
        print("Against the thresholds currently shipped "
              + "(question below a peak of \(pct(options.presenceThreshold)), "
              + "contrary above \(pct(options.contraryThreshold))):")
        print("  \(wouldFlag) of \(judged.count) correct occurrences of the rules actually judged")
        print("  would be questioned — \(pct(Double(wouldFlag) / Double(max(judged.count, 1)))) of expert recitation.")
        let excluded = samples.count - judged.count
        if excluded > 0 {
            print("  \(excluded) occurrences of idghām and iqlāb are excluded from audio checking;")
            print("  they are still detected in the text and coloured on the page.")
        }
        print("")
        print("Setting a threshold is choosing that number. It is not a measure of how many")
        print("real mistakes would be caught: nothing here contains a mistake. That needs")
        print("recitation with known errors in it, and a qārī to confirm they are errors.")
    }

    static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = max(0, min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded())))
        return sorted[index]
    }

    static func pct(_ value: Double) -> String {
        let rounded = (value * 1000).rounded() / 10
        return "\(rounded)%".padding(toLength: 6, withPad: " ", startingAt: 0)
    }

    static func pad(_ value: Int, _ width: Int) -> String {
        "\(value)".padding(toLength: width, withPad: " ", startingAt: 0)
    }
}
