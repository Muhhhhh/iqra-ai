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
        /// The same peak, with the search window extended past the end of the word.
        ///
        /// Several rules are *junction* rules: a tanwīn or a sākin nūn takes its ruling
        /// from the first letter of the **next** word, and the nasalisation that ruling
        /// requires is articulated across the boundary. Looking only inside the word that
        /// triggered the rule can therefore miss the very sound being checked.
        let peakByPadding: [Double]
        /// Session time of the frame the peak fell on, which is where the evidence is.
        let peakTime: TimeInterval
        /// The whole word's span, for the stronger removal.
        let wordRange: ClosedRange<TimeInterval>
        let frames: Int
        /// Set when the same occurrence was re-measured with its evidence removed.
        var peakAfterRemoval: Double?
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

        if let expected = arguments.forcedAlignPhonemes {
            try await forcedAlign(
                phonemes: expected,
                reference: arguments.forcedAlignVerse,
                reciter: reciter,
                analyzer: analyzer,
                vocabularyPath: arguments.phonemeVocabularyPath
            )
            return
        }

        if arguments.nasalityTest {
            try await measureNasality(arguments, reciter: reciter, model: analyzer, store: store)
            return
        }

        if arguments.referenceMadd {
            try await measureReferenceMadd(arguments, subject: reciter, model: analyzer, store: store)
            return
        }

        if arguments.goodnessTest {
            try await measureGoodness(arguments, reciter: reciter, model: analyzer, store: store)
            return
        }

        if arguments.alignedTajweed {
            try await measureAligned(arguments, reciter: reciter, model: analyzer, store: store)
            return
        }

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
                    let before = samples.count
                    collect(
                        occurrences: occurrences,
                        observed: observed,
                        timings: timings,
                        matched: Set(alignment.words.filter { $0.status == .correct }.map(\.targetIndex)),
                        minimumFrames: arguments.minimumFrames,
                        into: &samples,
                        skips: &skips
                    )

                    // Now take the evidence away and ask again.
                    guard arguments.tajweedNegatives else { continue }
                    for index in before..<samples.count {
                        let sample = samples[index]
                        guard sample.peak >= 0.5 else { continue }   // nothing to remove
                        // Optionally take out the whole word rather than the spike: if the
                        // verdict survives even that, the model is not reading the audio.
                        let centre = arguments.tajweedRemoveWholeWord
                            ? (sample.wordRange.lowerBound + sample.wordRange.upperBound) / 2
                            : sample.peakTime
                        guard var plan = spikeAndDonor(for: sample, in: observed, around: sample.peakTime),
                              true else { continue }
                        if arguments.tajweedRemoveWholeWord {
                            plan.span = sample.wordRange.upperBound - sample.wordRange.lowerBound
                        }
                        guard
                              let broken = corrupt(
                                  segment,
                                  around: centre,
                                  donorTime: plan.donor,
                                  span: plan.span
                              ),
                              let after = try? await analyzer.probabilities(for: broken)
                        else { continue }
                        samples[index].peakAfterRemoval = peak(
                            of: samples[index],
                            in: after,
                            around: sample.peakTime
                        )
                    }
                }
            }
        }

        await recognizer.unloadModel()
        await vad.unloadModel()

        report(samples: samples, skips: skips, occurrencesSeen: occurrencesSeen, ayat: ayatUsed)
    }

    /// Trailing extensions of the search window, in seconds.
    static let paddings: [TimeInterval] = [0, 0.1, 0.2, 0.3, 0.5]

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

            func window(extendingBy padding: TimeInterval) -> [Double] {
                let extra = Int((padding / observed.frameDuration).rounded())
                let end = min(series.count, upper + extra)
                guard end > lower else { return [] }
                var values: [Double] = []
                for frame in series[lower..<end] where frame.count > max(presentIndex, absentIndex) {
                    guard frame[0] < 0.5 else { continue }
                    values.append(expectation.present ? frame[presentIndex] : frame[absentIndex])
                }
                return values
            }

            var wanted: [Double] = []
            var against: [Double] = []
            var peakIndex = lower
            for index in lower..<upper {
                let frame = series[index]
                guard frame.count > max(presentIndex, absentIndex) else { continue }
                guard frame[0] < 0.5 else { continue }   // padding frame
                let presence = frame[presentIndex]
                let contrary = frame[absentIndex]
                let value = expectation.present ? presence : contrary
                if wanted.isEmpty || value > (wanted.max() ?? 0) { peakIndex = index }
                wanted.append(value)
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
                    peakByPadding: Self.paddings.map { window(extendingBy: $0).max() ?? 0 },
                    peakTime: observed.startTime + Double(peakIndex) * observed.frameDuration,
                    wordRange: range,
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

    /// The peak for one occurrence, re-read from a fresh observation of the same span.
    static func peak(
        of sample: Sample,
        in observed: MuaalemTajweedAnalyzer.Observation,
        around time: TimeInterval,
        span: TimeInterval = 0.4
    ) -> Double {
        guard let series = observed.probabilities[sample.head.rawValue] else { return 0 }
        let lower = max(0, Int(((time - span / 2 - observed.startTime) / observed.frameDuration).rounded(.down)))
        let upper = min(series.count, Int(((time + span / 2 - observed.startTime) / observed.frameDuration).rounded(.up)))
        guard upper > lower else { return 0 }
        let presentIndex = sample.head.presentIndex
        let absentIndex = sample.head.absentIndex
        var best = 0.0
        for frame in series[lower..<upper] where frame.count > max(presentIndex, absentIndex) {
            guard frame[0] < 0.5 else { continue }
            best = max(best, sample.expectsPresence ? frame[presentIndex] : frame[absentIndex])
        }
        return best
    }

    /// Shorten a stretch of audio without cutting it — the mistake as a reciter makes it.
    ///
    /// Splicing audio out of a vowel leaves a discontinuity, and a reciter who does not
    /// hold a madd does not produce a discontinuity: they produce a smoothly shorter
    /// vowel. Measuring against a spliced negative could not tell "the detector does not
    /// work" from "the test does not resemble the mistake", so this makes the faithful
    /// version.
    ///
    /// WSOLA: overlapping windows are taken from the source at a wider spacing than they
    /// are written back at, so the sound plays through faster while its pitch and timbre
    /// stay put. Each window's read position is nudged within a small search range to
    /// whichever offset best matches what has already been written, which is what keeps
    /// the periods lining up instead of phasing against each other.
    static func timeCompress(
        _ chunk: AudioChunk,
        range: Range<Int>,
        factor: Double
    ) -> AudioChunk? {
        let lower = max(0, range.lowerBound)
        let upper = min(chunk.samples.count, range.upperBound)
        guard upper - lower > 1600, factor > 0.1, factor != 1 else { return nil }

        let region = Array(chunk.samples[lower..<upper])
        let window = 480                       // 30 ms at 16 kHz
        let synthesisHop = window / 2
        // factor < 1 compresses (read further apart than written), > 1 stretches.
        let analysisHop = max(1, Int(Double(synthesisHop) / factor))
        let search = 160                       // ±10 ms to find the best join
        guard analysisHop != synthesisHop else { return nil }

        let hann = (0..<window).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(window - 1)) }
        var output = [Float](repeating: 0, count: Int(Double(region.count) * factor) + window)
        var weight = [Double](repeating: 0, count: output.count)

        var readAt = 0
        var writeAt = 0
        while readAt + window < region.count, writeAt + window < output.count {
            // Nudge the read position to whichever offset best continues what is written.
            var bestOffset = 0
            if writeAt > 0 {
                var bestScore = -Double.greatestFiniteMagnitude
                for offset in -search...search {
                    let start = readAt + offset
                    guard start >= 0, start + synthesisHop < region.count else { continue }
                    var score = 0.0
                    for index in 0..<synthesisHop where writeAt + index < output.count {
                        score += Double(output[writeAt + index]) * Double(region[start + index])
                    }
                    if score > bestScore { bestScore = score; bestOffset = offset }
                }
            }
            let start = max(0, min(region.count - window, readAt + bestOffset))
            for index in 0..<window {
                output[writeAt + index] += Float(Double(region[start + index]) * hann[index])
                weight[writeAt + index] += hann[index]
            }
            readAt += analysisHop
            writeAt += synthesisHop
        }

        let produced = min(writeAt + window, output.count)
        var compressed = [Float](repeating: 0, count: produced)
        for index in 0..<produced {
            compressed[index] = weight[index] > 0.01 ? output[index] / Float(weight[index]) : output[index]
        }

        var samples = Array(chunk.samples[0..<lower])
        samples.append(contentsOf: compressed)
        samples.append(contentsOf: chunk.samples[upper...])
        return AudioChunk(samples: samples, startTime: chunk.startTime)
    }

    // MARK: - Nasality, measured from the signal

    /// Does the acoustic signature of nasalisation separate a real ghunnah from a
    /// missing one, where the model could not?
    ///
    /// Every model-based attempt failed because the Muaalem heads were trained on
    /// recitation that is correct throughout — they have never seen an unnasalised nūn and
    /// predict the ṣifah the phonemes imply. This asks the signal instead: nasalisation
    /// adds a murmur near 250 Hz and drains energy near 1 kHz, so the low-to-mid energy
    /// ratio should rise during a ghunnah and not during an oral sound.
    ///
    /// Measured against the reciter's own neighbouring oral audio, so voice and room
    /// cancel. The negative is the same one used throughout: the nasal stretch replaced by
    /// audio the model marks as *not* nasal, same length, same voice.
    static func measureNasality(
        _ arguments: Arguments,
        reciter: Reciter,
        model: MuaalemTajweedAnalyzer,
        store: SQLiteVerseStore
    ) async throws {
        guard let scriptURL = PhonemeScript.locate() else {
            throw IqraEval.EvalError.missing("quran-phonemes.bin")
        }
        let script = try PhonemeScript(contentsOf: scriptURL)
        let library = ReciterAudioLibrary()
        let aligner = CTCForcedAligner(blank: 0)
        let nasality = NasalityMeasure()
        let rate = AudioChunk.canonicalSampleRate

        print("Nasality measured from the signal")
        print("  reciter  \(reciter.name) — assumed correct throughout")
        print("")

        var intact: [Double] = []
        var removed: [Double] = []

        for surah in arguments.surahs {
            let surahTarget = try await store.target(surah: surah)
            for verse in surahTarget.verses.prefix(arguments.limitPerSurah) {
                guard let entry = script[verse.reference], entry.ghonna.contains(1),
                      let url = try? await library.fetch(verse.reference, reciter: reciter),
                      let audio = try? AudioFileLoader.load(url: url),
                      let observed = try? await model.probabilities(for: audio),
                      let phonemes = observed.probabilities["phonemes"],
                      let spans = try? aligner.align(
                          probabilities: phonemes,
                          target: entry.symbols.map(Int.init)
                      )
                else { continue }

                // The audio a phoneme actually occupies runs from its own spike to the
                // next one — not the span of the spike itself. CTC marks events, not
                // extents, so a nūn's symbol span is the transition into the nasal while
                // the murmur that follows it sits in the blanks. Measuring the span
                // measured the wrong 40 ms, and it showed: with it, ghunnahs that had
                // been *removed* scored higher at the 90th percentile than intact ones.
                func region(_ span: CTCForcedAligner.Span) -> Range<Int>? {
                    let next = spans.first { $0.index > span.index }
                    let fromFrame = span.frames.lowerBound
                    let toFrame = next?.frames.lowerBound ?? span.frames.upperBound
                    guard toFrame > fromFrame else { return nil }
                    let from = Int((observed.startTime + Double(fromFrame) * observed.frameDuration) * rate)
                    let to = Int((observed.startTime + Double(toFrame) * observed.frameDuration) * rate)
                    guard from >= 0, to - from >= 400 else { return nil }
                    return from..<to
                }

                func samples(_ span: CTCForcedAligner.Span, in chunk: AudioChunk) -> [Float]? {
                    guard let range = region(span), range.upperBound <= chunk.samples.count else { return nil }
                    return Array(chunk.samples[range])
                }

                // The control is the reciter's **vowels** in this āyah, pooled. A nasal
                // murmur has to be compared against voiced oral sound: comparing it to
                // whatever non-nasal phoneme happens to be adjacent means comparing it to
                // fricatives and stops, whose spectra differ from a vowel's far more than
                // nasalisation does. Measured with that control the intact ghunnahs came
                // out at a median contrast of 0.5 dB spread across ±13 — no signal at all.
                let vowelSpans = spans.filter {
                    $0.index < entry.symbols.count && [32, 33, 34].contains(Int(entry.symbols[$0.index]))
                }
                var oralPool: [Float] = []
                for vowel in vowelSpans.prefix(12) {
                    if let piece = samples(vowel, in: audio) { oralPool.append(contentsOf: piece) }
                }
                guard oralPool.count >= 400 else { continue }
                let oral = oralPool

                for span in spans where span.index < entry.ghonna.count && entry.ghonna[span.index] == 1 {
                    guard let nasal = samples(span, in: audio),
                          let score = nasality.contrast(nasal: nasal, against: oral)
                    else { continue }
                    intact.append(score)

                    // Now take the nasalisation away and measure the same place again:
                    // the nasal stretch replaced by the reciter's own vowel audio.
                    guard let nasalRange = region(span),
                          let firstVowel = vowelSpans.first,
                          let donorRange = region(firstVowel)
                    else { continue }
                    let from = nasalRange.lowerBound
                    let donorFrom = donorRange.lowerBound
                    let length = nasal.count
                    guard donorFrom >= 0, donorFrom + length <= audio.samples.count,
                          from + length <= audio.samples.count else { continue }
                    var broken = audio.samples
                    for offset in 0..<length { broken[from + offset] = audio.samples[donorFrom + offset] }
                    let brokenChunk = AudioChunk(samples: broken, startTime: audio.startTime)
                    if let brokenNasal = samples(span, in: brokenChunk),
                       let brokenScore = nasality.contrast(nasal: brokenNasal, against: oral) {
                        removed.append(brokenScore)
                    }
                }
            }
        }

        guard !intact.isEmpty, !removed.isEmpty else { print("  nothing measurable"); return }
        let a = intact.sorted(), b = removed.sorted()
        func stat(_ values: [Double]) -> String {
            "median \(format(values[values.count / 2], 1)) dB, p10 \(format(percentile(values, 0.10), 1)), p90 \(format(percentile(values, 0.90), 1))"
        }
        print("  ghunnah intact   n=\(a.count)  \(stat(a))")
        print("  ghunnah removed  n=\(b.count)  \(stat(b))")
        print("")
        // What a threshold placed between them would achieve.
        for threshold in [0.0, 1.0, 2.0, 3.0, 4.0] {
            let falsePositives = a.count { $0 < threshold }
            let caught = b.count { $0 < threshold }
            print("  below \(format(threshold, 1)) dB: "
                  + "\(pct(Double(falsePositives) / Double(a.count))) of correct ghunnahs questioned, "
                  + "\(pct(Double(caught) / Double(b.count))) of removed ones caught")
        }
    }

    // MARK: - Reference-anchored madd

    /// Judge an elongation against a qārī reciting the same āyah, rather than against the
    /// reciter's own average.
    ///
    /// The self-referential version works but misses three elongations in four: it
    /// compares each madd to the median of the reciter's other madds of the same written
    /// length, which is noisy and needs several examples before it says anything. A
    /// reference recitation of *that* āyah is a per-elongation expectation instead.
    ///
    /// Durations are normalised by the reciter's own haraka within the same āyah — the
    /// median gap of the short vowels — so a slow murattal and a quick ḥadr are compared
    /// on the same scale. What is compared is the *ratio*: how many of their own harakāt
    /// each held that particular madd for.
    ///
    /// The risk this has to measure, not assume: madd lengths are partly a legitimate
    /// choice. Madd munfaṣil may be held 2, 4 or 5 counts within Ḥafṣ, and reciters
    /// differ. So the test uses a *different reciter* as the subject and Al-Husary as the
    /// reference — if correct recitation by another qārī trips this, the idea is wrong.
    static func measureReferenceMadd(
        _ arguments: Arguments,
        subject: Reciter,
        model: MuaalemTajweedAnalyzer,
        store: SQLiteVerseStore
    ) async throws {
        guard let scriptURL = PhonemeScript.locate() else {
            throw IqraEval.EvalError.missing("quran-phonemes.bin")
        }
        let script = try PhonemeScript(contentsOf: scriptURL)
        let library = ReciterAudioLibrary()
        let aligner = CTCForcedAligner(blank: 0)
        let reference = Reciter.husary

        print("Reference-anchored madd")
        print("  reference  \(reference.name)")
        print("  subject    \(subject.name) — a different qārī, reciting correctly")
        print("")

        /// Each vowel run's duration in harakāt of that reciter's own, for one recording.
        func profile(_ audio: AudioChunk, entry: PhonemeScript.Entry) async -> [Int: Double]? {
            guard let observed = try? await model.probabilities(for: audio),
                  let phonemes = observed.probabilities["phonemes"],
                  let spans = try? aligner.align(
                      probabilities: phonemes,
                      target: entry.symbols.map(Int.init)
                  )
            else { return nil }
            let byIndex = Dictionary(spans.map { ($0.index, $0) }, uniquingKeysWith: { a, _ in a })

            func gap(_ range: Range<Int>) -> Double? {
                guard byIndex[range.lowerBound] != nil else { return nil }
                let before = spans.last { $0.index < range.lowerBound }
                let after = spans.first { $0.index >= range.upperBound }
                guard let from = before?.frames.upperBound ?? byIndex[range.lowerBound]?.frames.lowerBound,
                      let to = after?.frames.lowerBound ?? byIndex[range.upperBound - 1]?.frames.upperBound,
                      to > from
                else { return nil }
                return Double(to - from) * observed.frameDuration
            }

            var runs: [(range: Range<Int>, harakat: Int)] = []
            var index = 0
            while index < entry.symbols.count {
                let symbol = Int(entry.symbols[index])
                var end = index + 1
                while end < entry.symbols.count, entry.symbols[end] == entry.symbols[index] { end += 1 }
                if [27, 28, 29, 30, 31].contains(symbol) { runs.append((index..<end, end - index)) }
                else if [32, 33, 34].contains(symbol), end - index == 1 { runs.append((index..<end, 1)) }
                index = end
            }

            // This reciter's haraka, in this āyah: the median short vowel.
            let shorts = runs.filter { $0.harakat == 1 }.compactMap { gap($0.range) }.sorted()
            guard shorts.count >= 3 else { return nil }
            let haraka = shorts[shorts.count / 2]
            guard haraka > 0 else { return nil }

            var byStart: [Int: Double] = [:]
            for run in runs where run.harakat > 2 {
                if let seconds = gap(run.range) { byStart[run.range.lowerBound] = seconds / haraka }
            }
            return byStart
        }

        var compared = 0
        var falseFlags = 0
        var attempted = 0
        var caught = 0
        var deviations: [Double] = []

        for surah in arguments.surahs {
            let surahTarget = try await store.target(surah: surah)
            for verse in surahTarget.verses.prefix(arguments.limitPerSurah) {
                guard let entry = script[verse.reference],
                      let referenceURL = try? await library.fetch(verse.reference, reciter: reference),
                      let subjectURL = try? await library.fetch(verse.reference, reciter: subject),
                      let referenceAudio = try? AudioFileLoader.load(url: referenceURL),
                      let subjectAudio = try? AudioFileLoader.load(url: subjectURL),
                      let referenceProfile = await profile(referenceAudio, entry: entry),
                      let subjectProfile = await profile(subjectAudio, entry: entry)
                else { continue }

                for (start, expected) in referenceProfile {
                    guard let actual = subjectProfile[start], expected > 0 else { continue }
                    compared += 1
                    deviations.append(actual / expected)
                    if actual < expected * arguments.referenceShortfall { falseFlags += 1 }
                }

                // Now shorten one elongation in the subject's recording and see whether
                // the comparison notices.
                guard let firstRun = referenceProfile.keys.sorted().first,
                      let observed = try? await model.probabilities(for: subjectAudio),
                      let phonemes = observed.probabilities["phonemes"],
                      let spans = try? aligner.align(
                          probabilities: phonemes,
                          target: entry.symbols.map(Int.init)
                      )
                else { continue }
                var end = firstRun + 1
                while end < entry.symbols.count, entry.symbols[end] == entry.symbols[firstRun] { end += 1 }
                guard let first = spans.first(where: { $0.index == firstRun }),
                      let last = spans.last(where: { $0.index < end })
                else { continue }
                let rate = AudioChunk.canonicalSampleRate
                let from = Int((observed.startTime + Double(first.frames.lowerBound) * observed.frameDuration) * rate)
                let to = Int((observed.startTime + Double(last.frames.upperBound) * observed.frameDuration) * rate)
                guard from >= 0, to <= subjectAudio.samples.count, to - from > 1600,
                      let shortened = timeCompress(subjectAudio, range: from..<to, factor: 0.5),
                      let brokenProfile = await profile(shortened, entry: entry),
                      let actual = brokenProfile[firstRun],
                      let expected = referenceProfile[firstRun], expected > 0
                else { continue }
                attempted += 1
                if actual < expected * arguments.referenceShortfall { caught += 1 }
            }
        }

        guard compared > 0 else { print("  nothing comparable"); return }
        let sorted = deviations.sorted()
        print("  elongations compared   \(compared)")
        print("  held, against the reference: median \(pct(sorted[sorted.count / 2])), "
              + "p5 \(pct(percentile(sorted, 0.05))), p95 \(pct(percentile(sorted, 0.95)))")
        print("  FALSE FLAGS            \(falseFlags)  (\(pct(Double(falseFlags) / Double(compared))) of correct recitation)")
        print("")
        print("  shortened to half      \(caught)/\(attempted)  (\(pct(Double(caught) / Double(max(attempted, 1)))))")
        print("")
        print("  A wide spread in the first line would mean reciters simply differ on how")
        print("  long they hold a madd, and that anchoring to a reference cannot work.")
    }

    // MARK: - Goodness of pronunciation

    /// Does alignment confidence collapse where the reciter said something else?
    ///
    /// If it does, the word matcher can be rebuilt on it: instead of transcribing freely
    /// and comparing two noisy strings — 41% of words wrong before the comparison even
    /// starts — force-align the text that is *known* and look for where the audio stops
    /// supporting it. That is how pronunciation scoring is normally done, and it does not
    /// depend on the recogniser at all.
    ///
    /// The ṣifah heads failed exactly this kind of test: they turned out to predict from
    /// surrounding context rather than report what was heard. The phoneme head might have
    /// the same flaw, so it gets the same experiment before anything is built on it. One
    /// word's audio is replaced with another word's, of the same length, and the question
    /// is whether that word's alignment confidence falls.
    static func measureGoodness(
        _ arguments: Arguments,
        reciter: Reciter,
        model: MuaalemTajweedAnalyzer,
        store: SQLiteVerseStore
    ) async throws {
        guard let scriptURL = PhonemeScript.locate() else {
            throw IqraEval.EvalError.missing("quran-phonemes.bin — run scripts/export-phonemes.py")
        }
        let script = try PhonemeScript(contentsOf: scriptURL)
        let library = ReciterAudioLibrary()
        let aligner = CTCForcedAligner(blank: 0)

        print("Goodness of pronunciation")
        print("  reciter  \(reciter.name)")
        print("")

        var intact: [Double] = []
        var replaced: [Double] = []
        var separated = 0
        var trials = 0

        for surah in arguments.surahs {
            let surahTarget = try await store.target(surah: surah)
            for verse in surahTarget.verses.prefix(arguments.limitPerSurah) {
                guard let entry = script[verse.reference], entry.wordCount >= 4,
                      let url = try? await library.fetch(verse.reference, reciter: reciter),
                      let audio = try? AudioFileLoader.load(url: url),
                      let observed = try? await model.probabilities(for: audio),
                      let phonemes = observed.probabilities["phonemes"],
                      let spans = try? aligner.align(
                          probabilities: phonemes,
                          target: entry.symbols.map(Int.init)
                      )
                else { continue }

                func confidence(_ spans: [CTCForcedAligner.Span], word: Int) -> Double? {
                    let mine = spans.filter {
                        $0.index < entry.wordOfPhoneme.count
                            && Int(entry.wordOfPhoneme[$0.index]) == word
                    }
                    guard !mine.isEmpty else { return nil }
                    return mine.map(\.confidence).reduce(0, +) / Double(mine.count)
                }

                // A word in the middle, and a donor from elsewhere in the same āyah.
                let victim = entry.wordCount / 2
                let donorWord = victim >= 2 ? 0 : entry.wordCount - 1
                guard let before = confidence(spans, word: victim),
                      let victimRange = entry.range(ofWord: victim),
                      let donorRange = entry.range(ofWord: donorWord)
                else { continue }

                func time(_ range: Range<Int>) -> (start: Double, end: Double)? {
                    let mine = spans.filter { $0.index >= range.lowerBound && $0.index < range.upperBound }
                    guard let first = mine.first, let last = mine.last else { return nil }
                    return (
                        observed.startTime + Double(first.frames.lowerBound) * observed.frameDuration,
                        observed.startTime + Double(last.frames.upperBound) * observed.frameDuration
                    )
                }
                guard let victimTime = time(victimRange), let donorTime = time(donorRange) else { continue }
                let span = min(victimTime.end - victimTime.start, donorTime.end - donorTime.start)
                guard span > 0.1 else { continue }

                guard let broken = corrupt(
                    audio,
                    around: (victimTime.start + victimTime.end) / 2,
                    donorTime: (donorTime.start + donorTime.end) / 2,
                    span: span
                ),
                      let after = try? await model.probabilities(for: broken),
                      let brokenPhonemes = after.probabilities["phonemes"],
                      let brokenSpans = try? aligner.align(
                          probabilities: brokenPhonemes,
                          target: entry.symbols.map(Int.init)
                      ),
                      let afterConfidence = confidence(brokenSpans, word: victim)
                else { continue }

                trials += 1
                intact.append(before)
                replaced.append(afterConfidence)
                if afterConfidence < before - 0.15 { separated += 1 }
            }
        }

        guard trials > 0 else { print("  no trials"); return }
        let meanIntact = intact.reduce(0, +) / Double(intact.count)
        let meanReplaced = replaced.reduce(0, +) / Double(replaced.count)
        print("  trials                     \(trials)")
        print("  confidence, word intact    \(pct(meanIntact))")
        print("  confidence, word replaced  \(pct(meanReplaced))")
        print("  fell by more than 15 pts   \(separated)/\(trials)  (\(pct(Double(separated) / Double(trials))))")
        print("")
        print("  If the second number is not clearly below the first, the phoneme head has")
        print("  the same flaw as the ṣifah heads and nothing should be built on it.")
    }

    // MARK: - Letter-level tajweed

    /// Does judging the phoneme instead of the word actually see a missing ghunnah?
    ///
    /// The word-level checker caught 13% of ghunnahs whose audio had been removed, while
    /// catching 86% of whole words removed — it was reading word identity. This runs the
    /// same experiment against `AlignedTajweedAnalyzer`, and can aim the removal far more
    /// precisely, because forced alignment says exactly which frames are the nūn.
    static func measureAligned(
        _ arguments: Arguments,
        reciter: Reciter,
        model: MuaalemTajweedAnalyzer,
        store: SQLiteVerseStore
    ) async throws {
        guard let scriptURL = PhonemeScript.locate() else {
            throw IqraEval.EvalError.missing("quran-phonemes.bin — run scripts/export-phonemes.py")
        }
        let script = try PhonemeScript(contentsOf: scriptURL)
        let analyzer = AlignedTajweedAnalyzer(model: model, script: script)
        let library = ReciterAudioLibrary()
        let aligner = CTCForcedAligner(blank: 0)

        print("Letter-level tajweed")
        print("  phoneme script  \(script.count) āyāt")
        print("  reciter         \(reciter.name) — assumed correct throughout")
        print("")

        var ayatTested = 0
        var falseFlags = 0
        var examinedClean = 0
        var attempted = 0
        var caught = 0
        var maddAttempted = 0
        var maddCaught = 0
        var falseMaddAttempted = 0
        var falseMaddCaught = 0

        for surah in arguments.surahs {
            let surahTarget = try await store.target(surah: surah)
            for verse in surahTarget.verses.prefix(arguments.limitPerSurah) {
                let target = RecitationTarget(verse: verse)
                guard let entry = script[verse.reference],
                      entry.ghonna.contains(1),
                      let url = try? await library.fetch(verse.reference, reciter: reciter),
                      let audio = try? AudioFileLoader.load(url: url)
                else { continue }

                // The whole āyah as one segment, every word present. Word timings are not
                // used for the judgement — forced alignment supplies those — they only
                // say which words the audio holds.
                func segment(_ chunk: AudioChunk) -> AlignedAudioSegment {
                    AlignedAudioSegment(
                        audio: chunk,
                        transcription: .empty,
                        words: target.flattenedWords.map {
                            WordEvaluation(
                                targetIndex: $0.globalIndex,
                                reference: $0.reference,
                                expectedText: $0.text,
                                status: .correct,
                                timeRange: 0...chunk.duration,
                                recognizerConfidence: 1
                            )
                        }
                    )
                }

                ayatTested += 1
                let clean = await analyzer.analyze(segments: [segment(audio)], target: target)
                falseFlags += clean.count
                examinedClean += await analyzer.coverage().examined

                // Shorten an elongation and see whether it is noticed. Cutting audio out
                // is the honest way to make this mistake: it is what a reciter who does
                // not hold the madd actually produces — the sound is simply not there for
                // as long.
                if let entryScript = script[verse.reference],
                   let observedForMadd = try? await model.probabilities(for: audio),
                   let phonemesForMadd = observedForMadd.probabilities["phonemes"],
                   let spansForMadd = try? aligner.align(
                       probabilities: phonemesForMadd,
                       target: entryScript.symbols.map(Int.init)
                   ) {
                    // Find a run of a repeated madd carrier longer than two.
                    var runStart = 0
                    var found: Range<Int>?
                    while runStart < entryScript.symbols.count {
                        let symbol = entryScript.symbols[runStart]
                        var end = runStart + 1
                        while end < entryScript.symbols.count, entryScript.symbols[end] == symbol { end += 1 }
                        if end - runStart > 2, [27, 28, 29, 30, 31].contains(Int(symbol)) {
                            found = runStart..<end
                            break
                        }
                        runStart = end
                    }

                    if let run = found {
                        let mine = spansForMadd.filter { $0.index >= run.lowerBound && $0.index < run.upperBound }
                        if let first = mine.first, let last = mine.last, last.frames.upperBound > first.frames.lowerBound {
                            let start = observedForMadd.startTime
                                + Double(first.frames.lowerBound) * observedForMadd.frameDuration
                            let end = observedForMadd.startTime
                                + Double(last.frames.upperBound) * observedForMadd.frameDuration
                            let rate = AudioChunk.canonicalSampleRate
                            // Take out the middle half of the elongation.
                            // Held for half as long, smoothly — not spliced.
                            let from = Int(start * rate)
                            let to = Int(end * rate)
                            if from >= 0, to <= audio.samples.count, to > from,
                               let chunk = timeCompress(audio, range: from..<to, factor: 0.5) {
                                maddAttempted += 1
                                let after = await analyzer.analyze(segments: [segment(chunk)], target: target)
                                if after.count > clean.count { maddCaught += 1 }

                                // What the alignment actually measures for the same run
                                // once the audio has been shortened. If this does not
                                // fall, the detector is not the problem — the alignment
                                // is not tracking the duration at all.
                                if arguments.verbose,
                                   let afterObserved = try? await model.probabilities(for: chunk),
                                   let afterPhonemes = afterObserved.probabilities["phonemes"],
                                   let afterSpans = try? aligner.align(
                                       probabilities: afterPhonemes,
                                       target: entryScript.symbols.map(Int.init)
                                   ) {
                                    // Two ways of measuring the same elongation:
                                    //   span   — first symbol spike to last
                                    //   gap    — end of the consonant before the run to
                                    //            the start of the consonant after it
                                    // CTC spikes mark events rather than extents, so the
                                    // sustained vowel lives in the silence *between*
                                    // spikes, which is what the gap measures.
                                    func measure(
                                        _ list: [CTCForcedAligner.Span],
                                        _ obs: MuaalemTajweedAnalyzer.Observation
                                    ) -> (span: Double, gap: Double)? {
                                        let mine = list.filter { $0.index >= run.lowerBound && $0.index < run.upperBound }
                                        guard let f = mine.first, let l = mine.last else { return nil }
                                        let span = Double(l.frames.upperBound - f.frames.lowerBound) * obs.frameDuration
                                        let before = list.last { $0.index < run.lowerBound }
                                        let after = list.first { $0.index >= run.upperBound }
                                        let from = before?.frames.upperBound ?? f.frames.lowerBound
                                        let to = after?.frames.lowerBound ?? l.frames.upperBound
                                        return (span, Double(max(0, to - from)) * obs.frameDuration)
                                    }
                                    if let cleanMeasure = measure(spansForMadd, observedForMadd),
                                       let afterMeasure = measure(afterSpans, afterObserved) {
                                        Swift.print("    madd \(run.count)h  span \(format(cleanMeasure.span, 2))→\(format(afterMeasure.span, 2))s"
                                                    + "   gap \(format(cleanMeasure.gap, 2))→\(format(afterMeasure.gap, 2))s")
                                    }
                                }
                            }
                        }
                    }
                }

                // The opposite mistake: a *single* vowel, which the text writes short,
                // stretched out into an elongation.
                if let entryScript = script[verse.reference],
                   let obs = try? await model.probabilities(for: audio),
                   let ph = obs.probabilities["phonemes"],
                   let sp = try? aligner.align(probabilities: ph, target: entryScript.symbols.map(Int.init)) {
                    var position = 1
                    var single: Int?
                    while position < entryScript.symbols.count - 2 {
                        let symbol = Int(entryScript.symbols[position])
                        let isRun = entryScript.symbols[position + 1] == entryScript.symbols[position]
                            || entryScript.symbols[position - 1] == entryScript.symbols[position]
                        if [32, 33, 34].contains(symbol), !isRun { single = position; break }
                        position += 1
                    }
                    if let index = single,
                       let span = sp.first(where: { $0.index == index }),
                       let next = sp.first(where: { $0.index > index }) {
                        let rate = AudioChunk.canonicalSampleRate
                        let from = Int((obs.startTime + Double(span.frames.lowerBound) * obs.frameDuration) * rate)
                        let to = Int((obs.startTime + Double(next.frames.lowerBound) * obs.frameDuration) * rate)
                        if from >= 0, to <= audio.samples.count, to - from > 1600,
                           let stretched = timeCompress(audio, range: from..<to, factor: 2.5) {
                            falseMaddAttempted += 1
                            let after = await analyzer.analyze(segments: [segment(stretched)], target: target)
                            if after.count > clean.count { falseMaddCaught += 1 }
                        }
                    }
                }

                // Locate a ghunnah phoneme precisely, and take its sound away.
                guard let observed = try? await model.probabilities(for: audio),
                      let phonemes = observed.probabilities["phonemes"],
                      let spans = try? aligner.align(
                          probabilities: phonemes,
                          target: entry.symbols.map(Int.init)
                      )
                else { continue }

                guard let nasal = spans.first(where: { span in
                    span.index < entry.ghonna.count && entry.ghonna[span.index] == 1
                        && span.confidence > 0.5 && span.frames.count >= 2
                }) else { continue }

                let start = observed.startTime + Double(nasal.frames.lowerBound) * observed.frameDuration
                let end = observed.startTime + Double(nasal.frames.upperBound) * observed.frameDuration
                guard let donorSpan = spans.first(where: { span in
                    span.index < entry.ghonna.count && entry.ghonna[span.index] == 2
                        && span.frames.count >= nasal.frames.count
                }) else { continue }
                let donor = observed.startTime
                    + Double(donorSpan.frames.lowerBound) * observed.frameDuration
                    + (end - start) / 2

                guard let broken = corrupt(
                    audio,
                    around: (start + end) / 2,
                    donorTime: donor,
                    span: end - start
                ) else { continue }

                attempted += 1
                let after = await analyzer.analyze(segments: [segment(broken)], target: target)
                if after.count > clean.count { caught += 1 }
            }
        }

        print("  āyāt tested          \(ayatTested)")
        print("  examined             \(examinedClean) phonemes carrying a rule")
        print("  FALSE FLAGS          \(falseFlags) on correct recitation")
        print("")
        print("── with one elongation shortened by half ".padding(toLength: 72, withPad: "─", startingAt: 0))
        print("  attempted            \(maddAttempted)")
        print("  CAUGHT               \(maddCaught)/\(maddAttempted)  "
              + "(\(pct(Double(maddCaught) / Double(max(maddAttempted, 1)))))")
        print("")
        print("── with a short vowel stretched into an elongation ".padding(toLength: 72, withPad: "─", startingAt: 0))
        print("  attempted            \(falseMaddAttempted)")
        print("  CAUGHT               \(falseMaddCaught)/\(falseMaddAttempted)  "
              + "(\(pct(Double(falseMaddCaught) / Double(max(falseMaddAttempted, 1)))))")
        print("")
        print("── with one ghunnah removed ".padding(toLength: 72, withPad: "─", startingAt: 0))
        print("  attempted            \(attempted)")
        print("  CAUGHT               \(caught)/\(attempted)  "
              + "(\(pct(Double(caught) / Double(max(attempted, 1)))))")
        print("")
        print("  The word-level checker caught 13% of the same removal. Read this beside")
        print("  the false-flag count above: catching more by saying more is not progress.")
    }

    // MARK: - Forced alignment

    /// Align one āyah's known phoneme sequence to its audio, and report what came out.
    ///
    /// The point is not the numbers but whether the idea holds: that the phoneme head,
    /// constrained to the sequence the reciter is supposed to be saying, can say *when*
    /// each letter was said. That is the missing piece — tajweed cannot be judged letter
    /// by letter without it.
    static func forcedAlign(
        phonemes expected: String,
        reference: VerseReference,
        reciter: Reciter,
        analyzer: MuaalemTajweedAnalyzer,
        vocabularyPath: String
    ) async throws {
        guard let data = FileManager.default.contents(atPath: vocabularyPath),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let table = json["phonemes"] as? [String: Int]
        else {
            throw IqraEval.EvalError.missing("phoneme vocabulary at \(vocabularyPath)")
        }

        let library = ReciterAudioLibrary()
        let url = try await library.fetch(reference, reciter: reciter)
        let audio = try AudioFileLoader.load(url: url)
        let observed = try await analyzer.probabilities(for: audio)
        guard let series = observed.probabilities["phonemes"] else {
            throw IqraEval.EvalError.missing("phonemes head in the model output")
        }

        // Spaces separate words; they are not symbols the model emits.
        let words = expected.split(separator: " ").map(String.init)
        var target: [Int] = []
        var wordOfSymbol: [Int] = []
        for (wordIndex, word) in words.enumerated() {
            // Scalars, not Characters: قُ is a single Swift Character but two symbols in
            // the model's vocabulary, and every piece of Arabic handling in this project
            // that forgot that has been wrong.
            for scalar in word.unicodeScalars {
                guard let id = table[String(scalar)] else {
                    throw IqraEval.EvalError.missing("symbol '\(scalar)' in the vocabulary")
                }
                target.append(id)
                wordOfSymbol.append(wordIndex)
            }
        }

        print("Forced alignment of \(reference)")
        print("  \(target.count) phonemes in \(words.count) words, \(series.count) frames of audio")
        print("")

        let spans = try CTCForcedAligner().align(probabilities: series, target: target)
        let confident = spans.count { $0.confidence >= 0.5 }
        print("  aligned            \(spans.count)/\(target.count) phonemes")
        print("  confident          \(confident) (\(pct(Double(confident) / Double(max(spans.count, 1)))) at 50% or better)")
        print("")
        print("  word boundaries recovered from the alignment:")
        for wordIndex in 0..<words.count {
            let mine = spans.filter { wordOfSymbol[$0.index] == wordIndex }
            guard let first = mine.first, let last = mine.last else { continue }
            let start = observed.startTime + Double(first.frames.lowerBound) * observed.frameDuration
            let end = observed.startTime + Double(last.frames.upperBound) * observed.frameDuration
            let mean = mine.map(\.confidence).reduce(0, +) / Double(mine.count)
            print("    \(words[wordIndex].padding(toLength: 18, withPad: " ", startingAt: 0)) "
                  + "\(format(start, 2))s – \(format(end, 2))s   confidence \(pct(mean))")
        }
    }

    static func format(_ value: Double, _ places: Int) -> String { IqraEval.format(value, places) }

    // MARK: - Negatives

    /// Remove the sound a rule requires, and see whether the checker notices.
    ///
    /// Every number this project has about tajweed is one-sided: measured on recitation
    /// that is correct, so it can say how often a qārī is wrongly questioned and nothing
    /// at all about how often a real mistake is caught. A checker that says nothing ever
    /// scores perfectly on that measure. This is the other half.
    ///
    /// The mistake is made by replacing the stretch of audio the model spikes on with the
    /// audio immediately before it, of exactly the same length. The nasalisation, or the
    /// echo, is gone; the voice, the level and every timestamp in the passage are
    /// untouched. That matters — silencing the region instead would test whether the
    /// checker notices *silence*, which is a much easier question and not the one being
    /// asked.
    ///
    /// It is circular in one respect, and worth naming: the model chooses where to cut.
    /// So this cannot prove the model knows where a ghunnah is. What it can show is
    /// whether removing the acoustic evidence changes the verdict — and if it does not,
    /// the checker is not reading the audio at all.
    static func corrupt(
        _ chunk: AudioChunk,
        around time: TimeInterval,
        donorTime: TimeInterval,
        span: TimeInterval
    ) -> AudioChunk? {
        let rate = AudioChunk.canonicalSampleRate
        let length = Int(span * rate)
        let start = Int((time - chunk.startTime - span / 2) * rate)
        let donor = Int((donorTime - chunk.startTime - span / 2) * rate)
        guard length > 0,
              start >= 0, start + length <= chunk.samples.count,
              donor >= 0, donor + length <= chunk.samples.count,
              abs(donor - start) >= length
        else { return nil }

        var samples = chunk.samples
        // Cross-faded at the joins, so the splice itself does not become the anomaly the
        // model reacts to.
        let fade = min(length / 8, Int(0.01 * rate))
        for offset in 0..<length {
            let replacement = samples[donor + offset]
            if offset < fade {
                let mix = Float(offset) / Float(max(fade, 1))
                samples[start + offset] = samples[start + offset] * (1 - mix) + replacement * mix
            } else if offset >= length - fade {
                let mix = Float(length - offset) / Float(max(fade, 1))
                samples[start + offset] = samples[start + offset] * (1 - mix) + replacement * mix
            } else {
                samples[start + offset] = replacement
            }
        }
        return AudioChunk(samples: samples, startTime: chunk.startTime)
    }

    /// The stretch of the rule's spike, and somewhere in the same segment the model says
    /// the attribute is *absent* — the only honest place to take replacement audio from.
    ///
    /// Copying from just before the spike was the first attempt and was wrong: a ghunnah
    /// runs two harakāt, so the audio immediately before its peak is usually still inside
    /// the same ghunnah. That replaced the nasal with more nasal, and unsurprisingly
    /// changed almost nothing.
    static func spikeAndDonor(
        for sample: Sample,
        in observed: MuaalemTajweedAnalyzer.Observation,
        around time: TimeInterval
    ) -> (span: TimeInterval, donor: TimeInterval)? {
        guard let series = observed.probabilities[sample.head.rawValue] else { return nil }
        let presentIndex = sample.head.presentIndex
        let absentIndex = sample.head.absentIndex
        let wanted = sample.expectsPresence ? presentIndex : absentIndex
        let other = sample.expectsPresence ? absentIndex : presentIndex

        let centre = Int(((time - observed.startTime) / observed.frameDuration).rounded())
        guard centre >= 0, centre < series.count else { return nil }

        func value(_ index: Int, _ classIndex: Int) -> Double {
            guard index >= 0, index < series.count, series[index].count > classIndex else { return 0 }
            guard series[index][0] < 0.5 else { return 0 }
            return series[index][classIndex]
        }

        // Grow outward while the attribute is still being asserted.
        var first = centre, last = centre
        while first > 0, value(first - 1, wanted) > 0.3 { first -= 1 }
        while last + 1 < series.count, value(last + 1, wanted) > 0.3 { last += 1 }
        let frames = last - first + 1
        let span = Double(frames) * observed.frameDuration

        // The frame most confident of the contrary, far enough away not to overlap.
        var donorIndex = -1
        var best = 0.0
        for index in 0..<series.count where abs(index - centre) > frames {
            let score = value(index, other)
            if score > best { best = score; donorIndex = index }
        }
        guard donorIndex >= 0, best > 0.5 else { return nil }
        return (span, observed.startTime + Double(donorIndex) * observed.frameDuration)
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
        // Does looking past the end of the word recover the occurrences with no spike?
        print("Peak by how far the window extends past the word (junction rules articulate")
        print("across the boundary, so the sound may not be inside the word that triggers it).")
        print("")
        print("  rule            " + Self.paddings.map { "  +\(Int($0 * 1000))ms" }.joined())
        for rule in byRule.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let group = byRule[rule]!
            let cells = (0..<Self.paddings.count).map { index -> String in
                let values = group.map { $0.peakByPadding[index] }.sorted()
                return " " + pct(percentile(values, 0.25))
            }
            print("  \(rule.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0)) p25" + cells.joined())
        }
        print("")

        // What loosening the threshold would cost, in the only currency that matters
        // here: correctly recited rules questioned.
        print("Fraction of correct recitation questioned, by how loose the threshold is:")
        print("  peak below   " + [0.02, 0.10, 0.25, 0.50, 0.75, 0.90].map { pct($0) }.joined())
        let judgedAll = samples.filter { MuaalemTajweedAnalyzer.audioVerifiable.contains($0.rule) }
        let rates = [0.02, 0.10, 0.25, 0.50, 0.75, 0.90].map { threshold -> String in
            let flagged = judgedAll.count { $0.peak < threshold && max($0.contrary, 1 - $0.peak) > 0.90 }
            return pct(Double(flagged) / Double(max(judgedAll.count, 1)))
        }
        print("  questioned   " + rates.joined())
        print("")
        print("The same, varying how hard the model must spike on the *contrary* reading")
        print("before anything is said (peak threshold held at 50%):")
        print("  contrary     " + [0.9, 0.75, 0.5, 0.25, 0.0].map { pct($0) }.joined())
        let contraryRates = [0.9, 0.75, 0.5, 0.25, 0.0].map { threshold -> String in
            let flagged = judgedAll.count { $0.peak < 0.5 && max($0.contrary, 1 - $0.peak) > threshold }
            return pct(Double(flagged) / Double(max(judgedAll.count, 1)))
        }
        print("  questioned   " + contraryRates.joined())
        print("")

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
        let removed = samples.compactMap { sample -> (Sample, Double)? in
            guard let after = sample.peakAfterRemoval else { return nil }
            return (sample, after)
        }
        if !removed.isEmpty {
            let options = MuaalemTajweedAnalyzer.Options()
            let caught = removed.count { $0.1 < options.presenceThreshold }
            print("")
            print("── with the evidence removed ".padding(toLength: 72, withPad: "─", startingAt: 0))
            print("  \(removed.count) occurrences that the model heard clearly were re-measured with the")
            print("  audio it spiked on replaced by the audio just before it — same length, same")
            print("  voice, same timings, no nasalisation or echo.")
            print("")
            let befores = removed.map { $0.0.peak }.sorted()
            let afters = removed.map { $0.1 }.sorted()
            print("  peak on the rule   before \(pct(percentile(befores, 0.5))) (median)   after \(pct(percentile(afters, 0.5))) (median)")
            print("  CAUGHT             \(caught)/\(removed.count)  (\(pct(Double(caught) / Double(removed.count))))")
            print("")
            print("  This is the first detection figure this project has had. It is not a")
            print("  measure of catching real misrecitation: the model chose where to cut, so it")
            print("  cannot show the model knows where a ghunnah is — only whether removing the")
            print("  sound changes the verdict. Read it beside the false-flag rate above.")
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
