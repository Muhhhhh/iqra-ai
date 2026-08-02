import Foundation
import Testing

@testable import RecitationCore

/// The aligner is the piece most worth testing: it decides what the app tells someone
/// about their recitation. The bias these tests lock in is that a *missed* mistake is
/// acceptable and a *fabricated* one is not.
@Suite("Token alignment")
struct TokenAlignerTests {

    // MARK: - Helpers

    /// Build a target from space-separated words as a single verse.
    private func target(_ text: String, surah: Int = 1, ayah: Int = 1) -> RecitationTarget {
        RecitationTarget(verse: Verse(reference: VerseReference(surah: surah, ayah: ayah), text: text))
    }

    /// Build heard tokens with plausible sequential timestamps.
    private func heard(_ text: String, confidence: Double = 0.9) -> [TranscribedToken] {
        text.split(whereSeparator: \.isWhitespace).enumerated().map { index, word in
            TranscribedToken(
                text: String(word),
                startTime: Double(index) * 0.5,
                endTime: Double(index) * 0.5 + 0.45,
                confidence: confidence
            )
        }
    }

    private let aligner = TokenAligner()

    // MARK: - The happy path

    @Test("A perfect recitation marks every word correct")
    func perfectRecitation() {
        let text = "قُلْ هُوَ ٱللَّهُ أَحَدٌ"
        let result = aligner.align(heard: heard(text), against: target(text), isFinal: true)

        #expect(result.words.count == 4)
        #expect(result.words.allSatisfy { $0.status == .correct })
        #expect(result.insertions.isEmpty)
        #expect(result.mistakeCount == 0)
    }

    @Test("A word written with a dagger alef matches either modern spelling")
    func daggerAlefMatchesBothSpellings() {
        // The Uthmani text marks a long ā with a superscript alef; modern orthography
        // writes it out in some words and not in others, and the recogniser emits
        // modern orthography. Both readings must be accepted, or one half of them is
        // reported as a misrecitation.
        //
        // From 14:5 — بِـَٔايَـٰتِنَآ, which whisper transcribes بآياتنا. Before this the
        // word was flagged "check this" every time it was recited correctly.
        let expected = target("وَلَقَدْ أَرْسَلْنَا مُوسَىٰ بِـَٔايَـٰتِنَآ")
        let written = aligner.align(heard: heard("ولقد أرسلنا موسى بآياتنا"), against: expected, isFinal: true)
        #expect(written.words.allSatisfy { $0.status == .correct })

        // And the other convention — هَٰذَا against هذا — must keep working.
        let unwritten = target("هَٰذَا ذَٰلِكَ ٱلرَّحْمَٰنِ")
        let result = aligner.align(heard: heard("هذا ذلك الرحمن"), against: unwritten, isFinal: true)
        #expect(result.words.allSatisfy { $0.status == .correct })
    }

    @Test("A real difference of a written alef is still reported")
    func writtenAlefDifferenceSurvives() {
        // The dagger-alef tolerance must not spread to words that genuinely differ by a
        // written alef. قَالَ and قُل are different words, and confusing them is a real
        // mistake worth reporting.
        let expected = target("قَالَ رَبِّ")
        let result = aligner.align(heard: heard("قل رب"), against: expected, isFinal: true)

        #expect(result.words[0].status != .correct)
    }

    @Test("Diacritics and orthographic variants do not count as mistakes")
    func normalizationTolerance() {
        // Target is Uthmani with full diacritics; the recognizer emits bare modern
        // spelling with a plain alef where the mushaf has a wasla. Same recitation.
        let expected = target("ٱلْحَمْدُ لِلَّهِ رَبِّ ٱلْعَٰلَمِينَ")
        let result = aligner.align(heard: heard("الحمد لله رب العالمين"), against: expected, isFinal: true)

        #expect(result.words.allSatisfy { $0.status == .correct })
        #expect(result.mistakeCount == 0)
    }

    // MARK: - The four v1 mistake types

    @Test("A substituted word is reported as wrong, and only that word")
    func wrongWord() {
        let expected = target("قُلْ هُوَ ٱللَّهُ أَحَدٌ")
        let result = aligner.align(heard: heard("قل هو الله قال"), against: expected, isFinal: true)

        #expect(result.words[0].status == .correct)
        #expect(result.words[1].status == .correct)
        #expect(result.words[2].status == .correct)
        #expect(result.words[3].status == .wrong(heard: "قال"))
        #expect(result.insertions.isEmpty)
    }

    @Test("A skipped word is reported as skipped, and neighbours stay correct")
    func skippedWord() {
        let expected = target("قُلْ هُوَ ٱللَّهُ أَحَدٌ")
        let result = aligner.align(heard: heard("قل هو أحد"), against: expected, isFinal: true)

        #expect(result.words[0].status == .correct)
        #expect(result.words[1].status == .correct)
        #expect(result.words[2].status == .skipped)
        #expect(result.words[3].status == .correct)
    }

    @Test("An added word is reported as an insertion anchored to the preceding word")
    func addedWord() {
        let expected = target("قُلْ هُوَ ٱللَّهُ أَحَدٌ")
        let result = aligner.align(heard: heard("قل هو ثم الله أحد"), against: expected, isFinal: true)

        #expect(result.words.allSatisfy { $0.status == .correct })
        #expect(result.insertions.count == 1)
        #expect(result.insertions.first?.text == "ثم")
        // Heard after "هو", which is target index 1.
        #expect(result.insertions.first?.afterTargetIndex == 1)
    }

    @Test("An entirely omitted verse is reported as a skipped verse, not scattered words")
    func skippedVerse() {
        let expected = RecitationTarget(verses: [
            Verse(reference: VerseReference(surah: 112, ayah: 1), text: "قُلْ هُوَ ٱللَّهُ أَحَدٌ"),
            Verse(reference: VerseReference(surah: 112, ayah: 2), text: "ٱللَّهُ ٱلصَّمَدُ"),
            Verse(reference: VerseReference(surah: 112, ayah: 3), text: "لَمْ يَلِدْ وَلَمْ يُولَدْ"),
        ])
        // Verse 2 omitted.
        let result = aligner.align(
            heard: heard("قل هو الله أحد لم يلد ولم يولد"),
            against: expected,
            isFinal: true
        )

        #expect(result.skippedVerses == [VerseReference(surah: 112, ayah: 2)])
        let verseThreeWords = result.words.filter { $0.reference == VerseReference(surah: 112, ayah: 3) }
        #expect(verseThreeWords.allSatisfy { $0.status == .correct })
    }

    // MARK: - Conservatism

    @Test("A stray match far from everything else is not believed")
    func isolatedDistantMatchIsDiscarded() {
        // Recitation is continuous, so matches arrive in runs. One or two words matched
        // forty words away from the rest is a noisy transcript finding something
        // familiar-looking elsewhere on the page — and on screen it lights up an āyah the
        // reciter never touched, which is a false claim about their recitation.
        var words: [Verse] = []
        for ayah in 1...12 {
            words.append(Verse(
                reference: VerseReference(surah: 2, ayah: ayah),
                text: "كلمة\(ayah) لفظة\(ayah) عبارة\(ayah) جملة\(ayah) نصية\(ayah)"
            ))
        }
        let expected = RecitationTarget(verses: words)
        // Recites āyah 1 properly, and one word of āyah 10 surfaces from nowhere.
        let result = aligner.align(
            heard: heard("كلمة1 لفظة1 عبارة1 جملة1 نصية1 عبارة10"),
            against: expected,
            isFinal: true
        )

        let farMatches = result.words.filter {
            $0.reference.ayah == 10 && ($0.status == .correct || $0.status == .uncertain(heard: "عبارة10"))
        }
        #expect(farMatches.isEmpty, "a lone match ten āyāt away was believed")
        #expect(result.words.prefix(5).allSatisfy { $0.status == .correct })
    }

    @Test("A near-miss is advisory, never an outright mistake")
    func nearMissIsUncertainNotWrong() {
        // One-character difference: much more likely an ASR artefact than a misrecitation.
        let expected = target("ٱلصَّمَدُ")
        let result = aligner.align(heard: heard("الصمدi"), against: expected, isFinal: true)

        // Whatever it is, it must not be escalated to a hard error.
        #expect(result.words[0].status != .wrong(heard: "الصمدi"))
        #expect(result.mistakeCount == 0)
    }

    @Test("A low-confidence recognition is never escalated to a mistake")
    func lowConfidenceNeverEscalates() {
        let expected = target("قُلْ هُوَ ٱللَّهُ أَحَدٌ")
        // Completely different word, but the model barely heard it.
        let tokens = heard("قل هو الله زخرف", confidence: 0.2)
        let result = aligner.align(heard: tokens, against: expected, isFinal: true)

        if case .wrong = result.words[3].status {
            Issue.record("low-confidence recognition was escalated to .wrong")
        }
        #expect(result.words[3].status == .uncertain(heard: "زخرف"))
    }

    @Test("Silence produces no mistakes while still recording")
    func partialRunDoesNotAccuse() {
        let expected = target("قُلْ هُوَ ٱللَّهُ أَحَدٌ")
        let result = aligner.align(heard: [], against: expected, isFinal: false)

        #expect(result.words.allSatisfy { $0.status == .notYetRecited })
        #expect(result.mistakeCount == 0)
    }

    @Test("Words not yet reached are pending, not skipped, mid-recitation")
    func trailingWordsArePendingWhilePartial() {
        let expected = target("قُلْ هُوَ ٱللَّهُ أَحَدٌ")
        let result = aligner.align(heard: heard("قل هو"), against: expected, isFinal: false)

        #expect(result.words[0].status == .correct)
        #expect(result.words[1].status == .correct)
        #expect(result.words[2].status == .notYetRecited)
        #expect(result.words[3].status == .notYetRecited)
        #expect(result.mistakeCount == 0)
    }

    @Test("Stopping early is not reported as skipping the rest")
    func stoppingEarlyIsNotSkipping() {
        // Reciting the opening and stopping must never be reported as skipping what
        // follows. Only words the reciter carried on *past* were actually skipped.
        let expected = target("قُلْ هُوَ ٱللَّهُ أَحَدٌ")
        let result = aligner.align(heard: heard("قل هو"), against: expected, isFinal: true)

        #expect(result.words[0].status == .correct)
        #expect(result.words[1].status == .correct)
        #expect(result.words[2].status == .notYetRecited)
        #expect(result.words[3].status == .notYetRecited)
        #expect(result.mistakeCount == 0)
    }

    @Test("Stopping after one verse does not report the remaining verses as skipped")
    func stoppingAfterFirstVerse() {
        // The exact case seen in the app: one verse recited out of seven.
        let expected = RecitationTarget(verses: (1...7).map { ayah in
            Verse(reference: VerseReference(surah: 1, ayah: ayah), text: "كلمة أولى كلمة ثانية")
        })
        let result = aligner.align(heard: heard("كلمة أولى كلمة ثانية"), against: expected, isFinal: true)

        #expect(result.skippedVerses.isEmpty, "stopping early was reported as skipped verses")
        #expect(result.mistakeCount == 0)
    }

    @Test("A word passed over mid-recitation is still reported as skipped")
    func genuineSkipStillReported() {
        // The counterpart: the fix must not suppress real skips. Here the reciter
        // continued past the omitted word, so it genuinely was skipped.
        let expected = target("قُلْ هُوَ ٱللَّهُ أَحَدٌ")
        let result = aligner.align(heard: heard("قل هو أحد"), against: expected, isFinal: true)

        #expect(result.words[2].status == .skipped)
        #expect(result.words[3].status == .correct)
    }

    @Test("Beginning part-way through the passage does not accuse the words above it")
    func startingMidPassageIsNotSkipping() {
        // Practising a page almost always means starting at the āyah being worked on
        // rather than at the top of the page. Everything before the first word actually
        // recited was never begun, so it is pending — not omitted.
        let expected = RecitationTarget(verses: [
            Verse(reference: VerseReference(surah: 112, ayah: 1), text: "قُلْ هُوَ ٱللَّهُ أَحَدٌ"),
            Verse(reference: VerseReference(surah: 112, ayah: 2), text: "ٱللَّهُ ٱلصَّمَدُ"),
        ])
        let result = aligner.align(heard: heard("الله الصمد"), against: expected, isFinal: true)

        #expect(result.words.prefix(4).allSatisfy { $0.status == .notYetRecited })
        #expect(result.words.suffix(2).allSatisfy { $0.status == .correct })
        #expect(result.skippedVerses.isEmpty, "starting later was reported as a skipped verse")
        #expect(result.mistakeCount == 0)
    }

    @Test("A verse omitted between two recited verses is still reported as skipped")
    func skippedMiddleVerseStillReported() {
        // The counterpart, and the reason the rule is "recited on both sides" rather
        // than "anything unmatched is fine": the reciter demonstrably passed over this
        // verse, because they carried on into the one after it.
        let expected = RecitationTarget(verses: [
            Verse(reference: VerseReference(surah: 112, ayah: 1), text: "قُلْ هُوَ ٱللَّهُ أَحَدٌ"),
            Verse(reference: VerseReference(surah: 112, ayah: 2), text: "ٱللَّهُ ٱلصَّمَدُ"),
            Verse(reference: VerseReference(surah: 112, ayah: 3), text: "لَمْ يَلِدْ وَلَمْ يُولَدْ"),
        ])
        let result = aligner.align(heard: heard("قل هو الله أحد لم يلد ولم يولد"), against: expected, isFinal: true)

        #expect(result.skippedVerses == [VerseReference(surah: 112, ayah: 2)])
    }

    @Test("A stumble at a mid-passage start is a repetition, not an added word")
    func stumbleAtMidPassageStartIsNotAnAddition() {
        // An unmatched word before the first match has no preceding word to anchor to.
        // Looking near the top of the passage instead of where the reciter began would
        // find nothing similar and report an addition — telling someone they added a
        // word to the Quran because they cleared their throat over the first one.
        // Distinct vocabulary per verse: with a repeated refrain the stumble would have
        // a legitimate earlier match and the test would prove nothing.
        let expected = RecitationTarget(verses: [
            Verse(reference: VerseReference(surah: 2, ayah: 1), text: "شجرة زيتونة مباركة"),
            Verse(reference: VerseReference(surah: 2, ayah: 2), text: "سراج وهاج منير"),
            Verse(reference: VerseReference(surah: 2, ayah: 3), text: "كوكب دري يوقد"),
        ])
        // Starts at verse 3, stumbling over its first word before getting it out.
        let result = aligner.align(heard: heard("كوكب كوكب دري يوقد"), against: expected, isFinal: true)

        #expect(result.insertions.allSatisfy { $0.kind == .repetition })
        #expect(result.mistakeCount == 0)
    }

    // MARK: - Provenance for v2

    @Test("Matched words carry the timestamps tajweed analysis will need")
    func matchedWordsCarryTiming() {
        let text = "قُلْ هُوَ ٱللَّهُ أَحَدٌ"
        let result = aligner.align(heard: heard(text), against: target(text), isFinal: true)

        for word in result.words {
            #expect(word.timeRange != nil)
            #expect(word.recognizerConfidence != nil)
        }
        // Timestamps must be ordered and non-overlapping across the recitation.
        let starts = result.words.compactMap { $0.timeRange?.lowerBound }
        #expect(starts == starts.sorted())
    }

    @Test("Skipped words carry no time range — there is no audio to point at")
    func skippedWordsHaveNoTiming() {
        let expected = target("قُلْ هُوَ ٱللَّهُ أَحَدٌ")
        let result = aligner.align(heard: heard("قل هو أحد"), against: expected, isFinal: true)

        #expect(result.words[2].status == .skipped)
        #expect(result.words[2].timeRange == nil)
    }

    // MARK: - Edge cases

    @Test("An empty target yields an empty result rather than trapping")
    func emptyTarget() {
        let result = aligner.align(heard: heard("قل هو"), against: RecitationTarget(verses: []), isFinal: true)
        #expect(result.words.isEmpty)
    }

    @Test("Reciting a completely different passage does not crash or mis-anchor")
    func totallyDifferentPassage() {
        let expected = target("قُلْ هُوَ ٱللَّهُ أَحَدٌ")
        let recited = "الحمد لله رب العالمين"
        let tokens = heard(recited)
        let result = aligner.align(heard: tokens, against: expected, isFinal: true)

        #expect(result.words.count == 4)
        #expect(result.correctCount == 0)
        // Every heard token must be accounted for, as either a substitution or an insertion —
        // nothing may be silently dropped by the alignment.
        let substitutions = result.words.count(where: { $0.status.heardText != nil })
        #expect(substitutions + result.insertions.count == tokens.count)
    }
}

@Suite("Arabic normalization")
struct ArabicNormalizerTests {

    @Test("Harakāt, tatweel, and Quranic annotation marks are stripped")
    func stripsMarks() {
        #expect(ArabicNormalizer.normalize("ٱلرَّحْمَٰنِ") == ArabicNormalizer.normalize("الرحمن"))
        #expect(ArabicNormalizer.normalize("قُــــلْ") == "قل")
    }

    @Test("Alef variants fold together")
    func foldsAlef() {
        let forms = ["أحد", "احد", "إحد", "آحد", "ٱحد"]
        let normalized = Set(forms.map(ArabicNormalizer.normalize))
        #expect(normalized.count == 1)
    }

    @Test("Alef maqsura folds to ya and ta marbuta folds to ha")
    func foldsFinalForms() {
        #expect(ArabicNormalizer.normalize("علی") == ArabicNormalizer.normalize("علي"))
        #expect(ArabicNormalizer.normalize("رحمة") == ArabicNormalizer.normalize("رحمه"))
    }

    @Test("Non-Arabic characters and punctuation are dropped")
    func dropsNoise() {
        #expect(ArabicNormalizer.normalize("قل، (hello) 123 هو") == "قل هو")
    }

    @Test("Tokenizing drops empties")
    func tokenize() {
        #expect(ArabicNormalizer.tokenize("  قُلْ   هُوَ  ") == ["قل", "هو"])
    }
}

@Suite("Alignment of repeated text")
struct RepeatedTextAlignmentTests {

    private let aligner = TokenAligner()

    private func heard(_ text: String) -> [TranscribedToken] {
        text.split(whereSeparator: \.isWhitespace).enumerated().map { index, word in
            TranscribedToken(
                text: String(word),
                startTime: Double(index) * 0.5,
                endTime: Double(index) * 0.5 + 0.45
            )
        }
    }

    /// Ar-Raḥmān's refrain, which recurs 31 times in the surah.
    private let refrain = "فَبِأَيِّ آلَاءِ رَبِّكُمَا تُكَذِّبَانِ"

    @Test("Reciting a refrain once does not report earlier occurrences as skipped")
    func repeatedRefrainMatchesEarliest() {
        // Every occurrence is an equally good match, so the aligner must not pick a late
        // one — doing so would accuse the reciter of skipping everything before it.
        let target = RecitationTarget(verses: (1...10).map { ayah in
            Verse(reference: VerseReference(surah: 55, ayah: ayah), text: refrain)
        })
        let result = aligner.align(heard: heard(refrain), against: target, isFinal: true)

        #expect(result.skippedVerses.isEmpty, "matched a late occurrence: \(result.skippedVerses)")
        #expect(result.mistakeCount == 0)
        // The first verse is the one credited.
        let first = result.words.filter { $0.reference == VerseReference(surah: 55, ayah: 1) }
        #expect(first.allSatisfy { $0.status == .correct })
    }

    @Test("A contiguous run is preferred over the same words matched scattered")
    func prefersContiguousMatch() {
        // "الله" appears in both verses. Matching the recited pair contiguously inside
        // verse 2 is correct; splitting them across both verses is not.
        let target = RecitationTarget(verses: [
            Verse(reference: VerseReference(surah: 112, ayah: 1), text: "قُلْ هُوَ ٱللَّهُ أَحَدٌ"),
            Verse(reference: VerseReference(surah: 112, ayah: 2), text: "ٱللَّهُ ٱلصَّمَدُ"),
        ])
        let result = aligner.align(heard: heard("الله الصمد"), against: target, isFinal: true)

        let verseTwo = result.words.filter { $0.reference == VerseReference(surah: 112, ayah: 2) }
        #expect(verseTwo.allSatisfy { $0.status == .correct }, "did not match verse 2 contiguously")
        // Verse 1 must be left wholly untouched rather than having its "ٱللَّهُ" consumed:
        // a split match would credit one word of it and mark the rest.
        let verseOne = result.words.filter { $0.reference == VerseReference(surah: 112, ayah: 1) }
        #expect(verseOne.allSatisfy { $0.status == .notYetRecited }, "the match was split across both verses")
    }
}

/// Reciters correct themselves constantly. Reporting a re-attempt as an added word tells
/// someone they inserted words into the Quran, which is the same class of fabricated
/// accusation as a false "wrong word".
@Suite("Self-correction")
struct SelfCorrectionTests {

    private let aligner = TokenAligner()

    private func target(_ text: String) -> RecitationTarget {
        RecitationTarget(verse: Verse(reference: VerseReference(surah: 112, ayah: 1), text: text))
    }

    private func heard(_ words: [String]) -> [TranscribedToken] {
        words.enumerated().map { index, word in
            TranscribedToken(
                text: word,
                startTime: Double(index) * 0.5,
                endTime: Double(index) * 0.5 + 0.4,
                confidence: 0.9
            )
        }
    }

    private let passage = "قُلْ هُوَ ٱللَّهُ أَحَدٌ"

    @Test("Stumbling and repeating a word is not an added word")
    func repeatedWord() {
        let result = aligner.align(
            heard: heard(["قل", "هو", "الله", "الله", "أحد"]),
            against: target(passage),
            isFinal: true
        )
        #expect(result.mistakeCount == 0)
        #expect(result.additions.isEmpty, "repetition reported as an addition")
        #expect(result.repetitions.count == 1)
    }

    @Test("Restarting a phrase mid-word is not an added word")
    func restartedPhrase() {
        // "قل هو الل…" then starting again — including the truncated half-word, which is
        // the most likely thing to be mistaken for an insertion.
        let result = aligner.align(
            heard: heard(["قل", "هو", "الل", "قل", "هو", "الله", "أحد"]),
            against: target(passage),
            isFinal: true
        )
        #expect(result.mistakeCount == 0)
        #expect(result.additions.isEmpty, "restart reported as additions: \(result.additions.map(\.text))")
        #expect(result.repetitions.count == 3)
    }

    @Test("Re-reciting the whole passage is not eight added words")
    func repeatedWholePassage() {
        let result = aligner.align(
            heard: heard(["قل", "هو", "الله", "أحد", "قل", "هو", "الله", "أحد"]),
            against: target(passage),
            isFinal: true
        )
        #expect(result.mistakeCount == 0)
        #expect(result.additions.isEmpty)
        #expect(result.repetitions.count == 4)
        #expect(result.words.allSatisfy { $0.status == .correct })
    }

    @Test("A genuinely foreign word is still reported as an addition")
    func genuineAdditionSurvives() {
        // The classifier must not swallow real insertions — a word that appears nowhere
        // nearby in the passage is still an addition.
        let result = aligner.align(
            heard: heard(["قل", "هو", "زخرف", "الله", "أحد"]),
            against: target(passage),
            isFinal: true
        )
        #expect(result.additions.count == 1)
        #expect(result.additions.first?.text == "زخرف")
        #expect(result.repetitions.isEmpty)
    }

    @Test("A word repeated from far away is still an addition")
    func distantRepeatIsStillAnAddition() {
        // The repetition window is wide by default — 40 words — because going back over
        // an āyah to correct yourself lands far from where the matcher was. It is not
        // unbounded, and this is the reason: a word belonging to a completely different
        // part of the passage is not a re-attempt at what is being recited now.
        //
        // Tested against an explicit narrow window rather than the default, so the
        // passage can use real words that are actually distinct from one another. The
        // default's value is a measured tuning figure; what matters here is that the
        // bound exists and is applied.
        let narrow = TokenAligner(options: .init(repetitionWindow: 4))
        let vocabulary = [
            "قل", "هو", "الله", "احد", "الصمد", "لم", "يلد", "ولم", "يولد", "يكن",
            "له", "كفوا", "رب", "الناس", "ملك", "اله", "شر", "الوسواس",
        ]
        let long = RecitationTarget(verses: (0..<6).map { index in
            Verse(
                reference: VerseReference(surah: 55, ayah: index + 1),
                text: vocabulary[(index * 3)..<(index * 3 + 3)].joined(separator: " ")
            )
        })
        var words = long.flattenedWords.map(\.text)
        // A word from the very end, spoken near the beginning — far outside the window.
        words.insert(long.flattenedWords.last!.text, at: 1)
        let result = narrow.align(heard: heard(words), against: long, isFinal: true)

        #expect(result.additions.count == 1, "a distant word was excused as a repetition")
    }
}
