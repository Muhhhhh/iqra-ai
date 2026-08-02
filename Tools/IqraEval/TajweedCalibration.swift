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
