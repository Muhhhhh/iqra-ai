import Foundation
import Testing

@testable import RecitationCore

/// Where a tajweed rule applies follows from the orthography, so it can be checked
/// exactly against āyāt whose rules any student of tajweed knows by heart.
///
/// This is the half of tajweed the app can be confident about. Judging *execution* is a
/// separate, uncalibrated problem — see `DSPTajweedAnalyzer`.
@Suite("Tajweed rule detection")
struct TajweedDetectorTests {

    private func target(_ text: String, surah: Int = 1, ayah: Int = 1) -> RecitationTarget {
        RecitationTarget(verse: Verse(reference: VerseReference(surah: surah, ayah: ayah), text: text))
    }

    private func rules(_ text: String) -> [TajweedRule] {
        TajweedRuleDetector.occurrences(in: target(text)).map(\.rule)
    }

    private func occurrences(_ text: String) -> [TajweedOccurrence] {
        TajweedRuleDetector.occurrences(in: target(text))
    }

    // MARK: - Ghunnah

    @Test("Shadda on nūn or mīm is ghunnah")
    func ghunnah() {
        // إِنَّ — nūn with shadda.
        #expect(rules("إِنَّ").contains(.ghunnah))
        // ثُمَّ — mīm with shadda.
        #expect(rules("ثُمَّ").contains(.ghunnah))
        // No shadda, no ghunnah.
        #expect(!rules("مِن").contains(.ghunnah))
    }

    @Test("Ghunnah is held for two harakāt")
    func ghunnahDuration() {
        let found = occurrences("إِنَّ").first { $0.rule == .ghunnah }
        #expect(found?.expectedHarakat == 2)
    }

    // MARK: - Qalqalah

    @Test("A sākin qalqalah letter is detected")
    func qalqalah() {
        // يَقْطَعُونَ — qāf carrying sukun.
        #expect(rules("يَقْطَعُونَ").contains(.qalqalah))
        // أَبْصَـٰرِهِمْ — bāʾ carrying sukun.
        #expect(rules("أَبْصَـٰرِهِمْ").contains(.qalqalah))
    }

    @Test("A qalqalah letter with a vowel is not qalqalah")
    func qalqalahNeedsSukun() {
        // قُلْ — the qāf carries a damma, so no qalqalah on it.
        let found = occurrences("قُلْ").filter { $0.rule == .qalqalah }
        #expect(found.isEmpty, "qalqalah reported on a vowelled qāf")
    }

    @Test("A non-qalqalah letter with sukun is not qalqalah")
    func qalqalahLettersOnly() {
        // مِنْ — nūn with sukun is not one of ق ط ب ج د.
        #expect(!rules("مِنْ").contains(.qalqalah))
    }

    // MARK: - Nūn sākinah and tanwīn

    @Test("Nūn sākinah before ب is iqlāb")
    func iqlab() {
        // مِنۢ بَعْدِ — the classic iqlāb.
        let target = RecitationTarget(verse: Verse(
            reference: VerseReference(surah: 2, ayah: 1),
            text: "مِنۢ بَعْدِ"
        ))
        #expect(TajweedRuleDetector.occurrences(in: target).contains { $0.rule == .iqlab })
    }

    @Test("Nūn sākinah before a throat letter is izhār")
    func izhar() {
        // مِنْ هَادٍ — nūn sākinah then hāʾ.
        let target = RecitationTarget(verse: Verse(
            reference: VerseReference(surah: 13, ayah: 33),
            text: "مِنْ هَادٍ"
        ))
        #expect(TajweedRuleDetector.occurrences(in: target).contains { $0.rule == .izhar })
    }

    @Test("Nūn sākinah before ي ر م ل و ن is idghām")
    func idgham() {
        // مَن يَقُولُ — nūn sākinah then yāʾ.
        let target = RecitationTarget(verse: Verse(
            reference: VerseReference(surah: 2, ayah: 8),
            text: "مَن يَقُولُ"
        ))
        #expect(TajweedRuleDetector.occurrences(in: target).contains { $0.rule == .idgham })
    }

    @Test("Nūn sākinah before the remaining letters is ikhfāʾ")
    func ikhfa() {
        // مِن قَبْلُ — nūn sākinah then qāf.
        let target = RecitationTarget(verse: Verse(
            reference: VerseReference(surah: 2, ayah: 25),
            text: "مِن قَبْلُ"
        ))
        #expect(TajweedRuleDetector.occurrences(in: target).contains { $0.rule == .ikhfa })
    }

    @Test("Tanwīn behaves like nūn sākinah across the word boundary")
    func tanwinFollowsTheSameRules() {
        // هُدًى لِّلْمُتَّقِينَ — tanwīn then lām. Lām and rā' assimilate *without*
        // nasalisation, which is a different rule from the other four letters and not a
        // detail: expecting a ghunnah here marks a correct recitation as a mistake.
        let target = RecitationTarget(verse: Verse(
            reference: VerseReference(surah: 2, ayah: 2),
            text: "هُدًى لِّلْمُتَّقِينَ"
        ))
        let found = TajweedRuleDetector.occurrences(in: target)
        #expect(found.contains { $0.rule == .idghamBilaGhunnah })
        #expect(!found.contains { $0.rule == .idgham })
    }

    @Test("Idgham into ينمو carries ghunnah, into لر it does not")
    func idghamSplitsByGhunnah() {
        // مَن يَقُولُ — nūn sākinah then yā': idghām bi-ghunnah.
        let withGhunnah = TajweedRuleDetector.occurrences(in: RecitationTarget(verse: Verse(
            reference: VerseReference(surah: 2, ayah: 8),
            text: "مَن يَقُولُ"
        )))
        #expect(withGhunnah.contains { $0.rule == .idgham })

        // مِن رَّبِّهِمْ — nūn sākinah then rā': idghām bilā ghunnah.
        let without = TajweedRuleDetector.occurrences(in: RecitationTarget(verse: Verse(
            reference: VerseReference(surah: 2, ayah: 5),
            text: "مِن رَّبِّهِمْ"
        )))
        #expect(without.contains { $0.rule == .idghamBilaGhunnah })
    }

    // MARK: - Madd

    @Test("A madd letter before a hamza in the same word is madd wājib")
    func maddWajib() {
        // جَآءَ — alef madd then hamza, four harakāt.
        let found = occurrences("جَآءَ").first { $0.rule == .maddWajibMuttasil }
        #expect(found != nil, "madd wajib not detected in جَآءَ")
        #expect(found?.expectedHarakat == 4)
    }

    @Test("A madd at the end of a word before a hamza is madd jāʾiz")
    func maddJaiz() {
        // بِمَآ أُنزِلَ — madd at the word end, next word opens with hamza.
        let target = RecitationTarget(verse: Verse(
            reference: VerseReference(surah: 2, ayah: 4),
            text: "بِمَآ أُنزِلَ"
        ))
        let found = TajweedRuleDetector.occurrences(in: target).first { $0.rule == .maddJaizMunfasil }
        #expect(found != nil, "madd jaiz munfasil not detected")
        #expect(found?.expectedHarakat == 4)
    }

    @Test("A madd before a shadda is madd lāzim, six harakāt")
    func maddLazim() {
        // ٱلضَّآلِّينَ — the closing word of Al-Fātiḥah, madd lāzim.
        let found = occurrences("ٱلضَّآلِّينَ").first { $0.rule == .maddLazim }
        #expect(found != nil, "madd lazim not detected in ٱلضَّآلِّينَ")
        #expect(found?.expectedHarakat == 6)
    }

    @Test("An ordinary long vowel is madd asli, two harakāt")
    func maddAsli() {
        // نَسْتَعِينُ — the yāʾ madd, natural length.
        let found = occurrences("نَسْتَعِينُ").first { $0.rule == .maddAsli }
        #expect(found != nil, "madd asli not detected")
        #expect(found?.expectedHarakat == 2)
    }

    @Test("A word with no long vowel produces no madd")
    func noSpuriousMadd() {
        // قُلْ has no madd letter at all.
        #expect(!rules("قُلْ").contains { $0.isMadd })
    }

    // MARK: - Structure

    @Test("Occurrences point at real characters of the word they belong to")
    func rangesAreValid() {
        let target = RecitationTarget(verse: Verse(
            reference: VerseReference(surah: 1, ayah: 7),
            text: "صِرَٰطَ ٱلَّذِينَ أَنْعَمْتَ عَلَيْهِمْ غَيْرِ ٱلْمَغْضُوبِ عَلَيْهِمْ وَلَا ٱلضَّآلِّينَ"
        ))
        let words = target.flattenedWords
        for occurrence in TajweedRuleDetector.occurrences(in: target) {
            let word = words.first { $0.globalIndex == occurrence.targetIndex }
            let text = try? #require(word?.text)
            guard let text else { continue }
            // Offsets are Unicode scalars, not Characters — a letter and its diacritics
            // are one Character, which is exactly the distinction these rules turn on.
            let scalars = Array(text.unicodeScalars)
            #expect(occurrence.range.lowerBound >= 0)
            #expect(occurrence.range.upperBound <= scalars.count)
            #expect(!occurrence.letters.isEmpty)
            #expect(String(String.UnicodeScalarView(scalars[occurrence.range])) == occurrence.letters)
        }
    }

    @Test("Al-Fātiḥah yields the rules a student would expect")
    func fatihaOverall() async throws {
        let store = InMemoryVerseStore.sample
        let target = try await store.target(
            from: VerseReference(surah: 1, ayah: 1),
            through: VerseReference(surah: 1, ayah: 7)
        )
        let found = TajweedRuleDetector.occurrences(in: target)
        let kinds = Set(found.map(\.rule))

        // Al-Fātiḥah contains madd, ghunnah (ٱلرَّحْمَٰنِ has no shadda-nūn, but إِيَّاكَ does
        // not either — the shadda-yāʾ is not ghunnah; ٱلضَّآلِّينَ closes with madd lāzim).
        #expect(kinds.contains(.maddAsli), "no madd asli found in Al-Fātiḥah")
        #expect(kinds.contains(.maddLazim), "madd lāzim in ٱلضَّآلِّينَ not found")
        #expect(!found.isEmpty)
        // Every occurrence must belong to a word actually in the passage.
        let indices = Set(target.flattenedWords.map(\.globalIndex))
        #expect(found.allSatisfy { indices.contains($0.targetIndex) })
    }

    @Test("Detection over a whole muṣḥaf page stays sane")
    func wholePage() async throws {
        // Guards against a rule that fires on nearly every character, which would make
        // the colouring meaningless.
        let store = InMemoryVerseStore.sample
        let target = try await store.target(
            from: VerseReference(surah: 1, ayah: 1),
            through: VerseReference(surah: 1, ayah: 7)
        )
        let found = TajweedRuleDetector.occurrences(in: target)
        let wordCount = target.flattenedWords.count
        #expect(found.count < wordCount * 4, "\(found.count) rules over \(wordCount) words looks runaway")
    }
}

/// The audio half. Deliberately conservative — it must stay silent far more often than
/// it speaks, because a fabricated tajweed correction is worse than a missed one.
@Suite("Tajweed audio analysis")
struct DSPTajweedAnalyzerTests {

    /// Build a session where every word takes `rate` seconds per letter, except the ones
    /// named, which are scaled.
    private func session(
        target: RecitationTarget,
        rate: Double,
        scale: [Int: Double] = [:]
    ) -> [AlignedAudioSegment] {
        var cursor: TimeInterval = 0
        var evaluations: [WordEvaluation] = []
        for word in target.flattenedWords {
            let letters = Double(ArabicNormalizer.normalize(word.text).unicodeScalars.count)
            let duration = rate * letters * (scale[word.globalIndex] ?? 1.0)
            evaluations.append(
                WordEvaluation(
                    targetIndex: word.globalIndex,
                    reference: word.reference,
                    expectedText: word.text,
                    status: .correct,
                    timeRange: cursor...(cursor + duration)
                )
            )
            cursor += duration
        }
        let audio = AudioChunk(
            samples: [Float](repeating: 0.1, count: Int(cursor * AudioChunk.canonicalSampleRate) + 1),
            startTime: 0
        )
        return [AlignedAudioSegment(audio: audio, transcription: .empty, words: evaluations)]
    }

    private func fatiha() async throws -> RecitationTarget {
        try await InMemoryVerseStore.sample.target(
            from: VerseReference(surah: 1, ayah: 1),
            through: VerseReference(surah: 1, ayah: 7)
        )
    }

    @Test("An evenly paced recitation that holds its madd produces no notes")
    func evenRecitationIsSilent() async throws {
        // Every word takes time proportional to its letters, and words with a long madd
        // are given the extra harakāt they ask for.
        let target = try await fatiha()
        let occurrences = TajweedRuleDetector.occurrences(in: target)
        var scale: [Int: Double] = [:]
        for occurrence in occurrences where occurrence.rule.isMadd {
            guard let harakat = occurrence.expectedHarakat, harakat > 2 else { continue }
            let letters = Double(
                ArabicNormalizer.normalize(
                    target.flattenedWords.first { $0.globalIndex == occurrence.targetIndex }?.text ?? ""
                ).unicodeScalars.count
            )
            guard letters > 0 else { continue }
            scale[occurrence.targetIndex] = (letters + Double(harakat - 2)) / letters
        }

        let notes = await DSPTajweedAnalyzer().analyze(
            segments: session(target: target, rate: 0.12, scale: scale),
            target: target
        )
        #expect(notes.isEmpty, "an even recitation was flagged: \(notes.map(\.message))")
    }

    @Test("A long madd rushed to nothing is mentioned")
    func rushedMaddIsMentioned() async throws {
        let target = try await fatiha()
        let lazim = TajweedRuleDetector.occurrences(in: target)
            .first { $0.rule == .maddLazim }
        let occurrence = try #require(lazim, "no madd lazim in Al-Fātiḥah to test with")

        // That word recited at a third of the surrounding pace.
        let notes = await DSPTajweedAnalyzer().analyze(
            segments: session(target: target, rate: 0.12, scale: [occurrence.targetIndex: 0.33]),
            target: target
        )
        #expect(notes.contains { $0.targetIndex == occurrence.targetIndex })
        #expect(notes.allSatisfy { $0.confidence <= .moderate }, "a tajweed note claimed high confidence")
    }

    @Test("Nothing is claimed without enough of the reciter's own pace to compare against")
    func needsABaseline() async throws {
        // Two words is not a tempo. With too little to compare against the analyzer must
        // say nothing rather than guess.
        let target = RecitationTarget(verse: Verse(
            reference: VerseReference(surah: 1, ayah: 7),
            text: "وَلَا ٱلضَّآلِّينَ"
        ))
        let notes = await DSPTajweedAnalyzer().analyze(
            segments: session(target: target, rate: 0.12),
            target: target
        )
        #expect(notes.isEmpty)
    }

    @Test("No audio means no notes")
    func silentWithoutAudio() async throws {
        let target = try await fatiha()
        let notes = await DSPTajweedAnalyzer().analyze(segments: [], target: target)
        #expect(notes.isEmpty)
    }

    @Test("Notes carry the measurement behind them")
    func notesAreAuditable() async throws {
        // A hint that cannot be checked is not much of a hint; the reciter should be able
        // to see what was measured and disagree with it.
        let target = try await fatiha()
        let occurrence = try #require(
            TajweedRuleDetector.occurrences(in: target).first { $0.rule == .maddLazim }
        )
        let notes = await DSPTajweedAnalyzer().analyze(
            segments: session(target: target, rate: 0.12, scale: [occurrence.targetIndex: 0.3]),
            target: target
        )
        for note in notes {
            #expect(note.measurement != nil)
            #expect((note.measurement?.observed ?? 0) > 0)
            #expect((note.measurement?.expected ?? 0) > 0)
            #expect(note.timeRange.upperBound >= note.timeRange.lowerBound)
        }
    }
}

#if canImport(CoreML)
/// The neural verifier. What matters here is the *mapping* — which head decides which
/// rule, and in which direction — because a sign error would report a correct iẓhār as
/// wrong and stay silent on a missing ghunnah.
@Suite("Neural tajweed verification")
struct MuaalemAnalyzerTests {

    private var modelURL: URL? {
        MuaalemTajweedAnalyzer.locateModel(
            additionalDirectories: [WhisperTestSupport.packageRoot.appending(path: "Models")]
        )
    }

    @Test("Nasalisation decides the nūn rules, and iẓhār is the inverted case")
    func expectationMapping() {
        // ikhfāʾ, iqlāb and idghām all hide the nūn *with* ghunnah; iẓhār exists
        // precisely to pronounce it without. One head, opposite expectations.
        for rule in [TajweedRule.ghunnah, .ikhfa, .iqlab, .idgham] {
            let expectation = MuaalemTajweedAnalyzer.expectation(for: rule)
            #expect(expectation?.head == .ghonna, "\(rule) should be judged by nasalisation")
            #expect(expectation?.present == true, "\(rule) should expect nasalisation")
        }
        let izhar = MuaalemTajweedAnalyzer.expectation(for: .izhar)
        #expect(izhar?.head == .ghonna)
        #expect(izhar?.present == false, "iẓhār must expect the absence of nasalisation")
    }

    @Test("Qalqalah is judged by its own head")
    func qalqalahMapping() {
        let expectation = MuaalemTajweedAnalyzer.expectation(for: .qalqalah)
        #expect(expectation?.head == .qalqla)
        #expect(expectation?.present == true)
    }

    @Test("Madd is left to duration measurement, not the model")
    func maddIsNotClaimed() {
        // The model has no head for elongation, so claiming madd from it would be
        // inventing a signal that is not there.
        for rule in [TajweedRule.maddAsli, .maddWajibMuttasil, .maddJaizMunfasil, .maddLazim] {
            #expect(MuaalemTajweedAnalyzer.expectation(for: rule) == nil)
        }
    }

    @Test("Present and absent class indices match the model's own vocabulary")
    func classIndices() {
        // From vocab.json: ghonna {مغن: 1, لا غنة: 2}, qalqla {مقلقل: 1, لا قلقلة: 2},
        // tafkheem {مفخم: 1, مرقق: 2}. Index 0 is [PAD] in every head.
        #expect(MuaalemTajweedAnalyzer.Head.ghonna.presentIndex == 1)
        #expect(MuaalemTajweedAnalyzer.Head.ghonna.absentIndex == 2)
        #expect(MuaalemTajweedAnalyzer.Head.qalqla.presentIndex == 1)
        #expect(MuaalemTajweedAnalyzer.Head.qalqla.absentIndex == 2)
        #expect(MuaalemTajweedAnalyzer.Head.tafkheemOrTaqeeq.presentIndex == 1)
        #expect(MuaalemTajweedAnalyzer.Head.tafkheemOrTaqeeq.absentIndex == 2)
    }

    @Test(
        "The model loads and returns one probability series per head",
        .enabled(if: MuaalemTajweedAnalyzer.locateModel(
            additionalDirectories: [WhisperTestSupport.packageRoot.appending(path: "Models")]
        ) != nil && WhisperTestSupport.frontendExists,
        "run scripts/convert-tajweed-model.py")
    )
    func runsOnRealAudio() async throws {
        let model = try #require(modelURL)
        let features = try MuaalemFeatures(resourceURL: WhisperTestSupport.frontendURL)
        let analyzer = MuaalemTajweedAnalyzer(modelURL: model, features: features)
        try await analyzer.loadModel()

        let chunk = try AudioFileLoader.load(url: try WhisperTestSupport.fixture("ikhlas-tts.wav"))
        let observed = try await analyzer.probabilities(for: chunk)

        for head in ["ghonna", "qalqla", "tafkheem_or_taqeeq", "phonemes"] {
            let series = try #require(observed.probabilities[head], "no output for \(head)")
            #expect(!series.isEmpty)
            // Softmax rows must be probabilities.
            for frame in series.prefix(20) {
                let total = frame.reduce(0, +)
                #expect(abs(total - 1.0) < 0.01, "\(head) frame does not sum to 1: \(total)")
                #expect(frame.allSatisfy { $0 >= 0 && $0 <= 1 })
            }
        }
        // 25 frames a second, so the series should track the audio's length.
        let expectedFrames = Int(chunk.duration * 25)
        let actual = observed.probabilities["ghonna"]?.count ?? 0
        #expect(abs(actual - expectedFrames) < expectedFrames / 4,
                "got \(actual) frames for \(chunk.duration)s, expected around \(expectedFrames)")
    }

    @Test("Silence produces no tajweed claims")
    func silenceIsSilent() async throws {
        guard let model = modelURL, WhisperTestSupport.frontendExists else { return }
        let features = try MuaalemFeatures(resourceURL: WhisperTestSupport.frontendURL)
        let analyzer = MuaalemTajweedAnalyzer(modelURL: model, features: features)

        let target = RecitationTarget(verse: Verse(
            reference: VerseReference(surah: 112, ayah: 1), text: "قُلْ هُوَ ٱللَّهُ أَحَدٌ"
        ))
        // No segments at all: nothing was recited, so nothing can be said about it.
        let notes = await analyzer.analyze(segments: [], target: target)
        #expect(notes.isEmpty)
    }
}
#endif
