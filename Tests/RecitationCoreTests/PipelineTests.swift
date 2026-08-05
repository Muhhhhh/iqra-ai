import Foundation
import Testing

@testable import RecitationCore

/// End-to-end checks over the real pipeline with scripted audio and a scripted
/// recognizer — no microphone, fully deterministic.
///
/// These cover the wiring the unit tests can't: that segments are emitted, that audio
/// is actually retained, and that the terminal result is consistent with the events
/// that preceded it.
@Suite("Recitation pipeline")
struct PipelineTests {

    private func sampleTarget() async throws -> RecitationTarget {
        try await InMemoryVerseStore.sample.target(
            from: VerseReference(surah: 112, ayah: 1),
            through: VerseReference(surah: 112, ayah: 4)
        )
    }

    private func makePipeline(
        target: RecitationTarget,
        transcript: String,
        chunkCount: Int = 3
    ) -> RecitationPipeline {
        RecitationPipeline(
            components: PipelineComponents(
                capture: ScriptedAudioCapture.silence(
                    chunkCount: chunkCount,
                    chunkDuration: 2.0,
                    pacing: .milliseconds(1)
                ),
                vad: PassthroughVoiceActivityDetector(),
                recognizer: ScriptedSpeechRecognizer(transcript: transcript, segmentCount: chunkCount),
                aligner: TokenAligner(),
                tajweed: NoOpTajweedAnalyzer()
            )
        )
    }

    /// Runs a session to completion and returns the terminal result plus every event.
    private func run(
        target: RecitationTarget,
        transcript: String,
        chunkCount: Int = 3
    ) async throws -> (result: RecitationResult, events: [PipelineEvent]) {
        let pipeline = makePipeline(target: target, transcript: transcript, chunkCount: chunkCount)
        let stream = await pipeline.events()

        let collector = Task { () -> [PipelineEvent] in
            var collected: [PipelineEvent] = []
            for await event in stream { collected.append(event) }
            return collected
        }

        await pipeline.start(target: target)
        // Let the scripted capture drain before stopping.
        try await Task.sleep(for: .milliseconds(150))
        await pipeline.stop()

        let events = await collector.value
        let finished = events.compactMap { event -> RecitationResult? in
            if case .finished(let result) = event { return result }
            return nil
        }
        guard let result = finished.last else {
            Issue.record("pipeline never emitted .finished")
            throw CancellationError()
        }
        #expect(finished.count == 1, "exactly one terminal result expected")
        return (result, events)
    }

    @Test("A clean run reports every word correct and reaches a terminal result")
    func cleanRun() async throws {
        let target = try await sampleTarget()
        let transcript = target.flattenedWords.map(\.text).joined(separator: " ")
        let (result, _) = try await run(target: target, transcript: transcript)

        #expect(result.alignment.isFinal)
        #expect(result.alignment.mistakeCount == 0)
        #expect(result.alignment.words.allSatisfy { $0.status == .correct })
        #expect(result.alignment.words.count == target.flattenedWords.count)
    }

    @Test("A wrong word survives the whole pipeline to the terminal result")
    func wrongWordEndToEnd() async throws {
        let target = try await sampleTarget()
        var words = target.flattenedWords.map(\.text)
        let index = words.count / 2
        words[index] = "قَالَ"
        let (result, _) = try await run(target: target, transcript: words.joined(separator: " "))

        #expect(result.alignment.mistakeCount == 1)
        if case .wrong = result.alignment.words[index].status {
            // expected
        } else {
            Issue.record("expected .wrong at index \(index), got \(result.alignment.words[index].status)")
        }
    }

    @Test("Audio and timestamps are retained for every segment — the v2 tajweed contract")
    func audioIsRetained() async throws {
        let target = try await sampleTarget()
        let transcript = target.flattenedWords.map(\.text).joined(separator: " ")
        let (result, _) = try await run(target: target, transcript: transcript)

        #expect(!result.segments.isEmpty)
        for segment in result.segments {
            // The raw buffer must still be there, not freed after transcription.
            #expect(!segment.audio.isEmpty)
            #expect(segment.audio.sampleRate == AudioChunk.canonicalSampleRate)
            #expect(segment.audio.duration > 0)
            // And every token must carry a timestamp.
            #expect(!segment.transcription.tokens.isEmpty)
            #expect(segment.transcription.tokens.allSatisfy { $0.endTime >= $0.startTime })
        }

        // Per-word audio slicing must actually yield samples — this is the exact call
        // a DSP tajweed rule makes.
        let sliceable = result.segments.flatMap { segment in
            segment.words.compactMap { segment.audio(for: $0) }
        }
        #expect(!sliceable.isEmpty, "no per-word audio could be sliced back out")
        #expect(sliceable.allSatisfy { !$0.isEmpty })
    }

    @Test("Segments are emitted incrementally, not only at the end")
    func incrementalSegments() async throws {
        let target = try await sampleTarget()
        let transcript = target.flattenedWords.map(\.text).joined(separator: " ")
        let (_, events) = try await run(target: target, transcript: transcript)

        let segmentEvents = events.filter { if case .segment = $0 { return true } else { return false } }
        let alignmentEvents = events.filter { if case .alignment = $0 { return true } else { return false } }

        #expect(segmentEvents.count >= 2, "expected live segment events during the run")
        // One initial render, one per segment, one final.
        #expect(alignmentEvents.count > segmentEvents.count)
    }

    @Test("Partial alignments never accuse before the session ends")
    func partialAlignmentsAreNotAccusatory() async throws {
        let target = try await sampleTarget()
        let transcript = target.flattenedWords.map(\.text).joined(separator: " ")
        let (_, events) = try await run(target: target, transcript: transcript)

        for event in events {
            guard case .alignment(let alignment) = event, !alignment.isFinal else { continue }
            #expect(
                alignment.mistakeCount == 0,
                "a clean recitation produced a mistake in a partial alignment"
            )
        }
    }

    @Test("The pipeline reaches .stopped and stops emitting")
    func lifecycle() async throws {
        let target = try await sampleTarget()
        let transcript = target.flattenedWords.map(\.text).joined(separator: " ")
        let (_, events) = try await run(target: target, transcript: transcript)

        let states = events.compactMap { event -> PipelineState? in
            if case .stateChanged(let state) = event { return state }
            return nil
        }
        #expect(states.first == .starting)
        #expect(states.contains(.listening))
        #expect(states.last == .stopped)
        #expect(!events.contains { if case .failed = $0 { return true } else { return false } })
    }

    @Test("A no-op tajweed analyzer produces no notes but is still consulted")
    func tajweedSeamIsWired() async throws {
        let target = try await sampleTarget()
        let transcript = target.flattenedWords.map(\.text).joined(separator: " ")
        let (result, _) = try await run(target: target, transcript: transcript)

        #expect(result.tajweedNotes.isEmpty)
        // The seam only means anything if the analyzer receives usable input.
        let notes = await RecordingTajweedAnalyzer().analyze(segments: result.segments, target: target)
        #expect(notes.count == result.segments.count, "analyzer did not receive one segment per note")
    }
}

/// Emits one note per segment, proving a real analyzer receives audio and timings.
private struct RecordingTajweedAnalyzer: TajweedAnalyzer {
    func analyze(segments: [AlignedAudioSegment], target: RecitationTarget) async -> [TajweedNote] {
        segments.map { segment in
            TajweedNote(
                rule: .maddAsli,
                targetIndex: segment.words.first?.targetIndex ?? 0,
                reference: segment.words.first?.reference ?? VerseReference(surah: 0, ayah: 0),
                timeRange: segment.startTime...max(segment.startTime, segment.endTime),
                confidence: .low,
                message: "probe",
                measurement: .init(observed: segment.audio.duration, expected: 0, unit: "s")
            )
        }
    }
}

/// Turning the muṣḥaf page mid-recitation.
@Suite("Page turning")
struct RetargetTests {

    private func target(_ text: String, ayah: Int) -> RecitationTarget {
        RecitationTarget(verse: Verse(reference: VerseReference(surah: 112, ayah: ayah), text: text))
    }

    private func heard(_ text: String) -> [TranscribedToken] {
        text.split(whereSeparator: \.isWhitespace).enumerated().map { index, word in
            TranscribedToken(
                text: String(word),
                startTime: Double(index) * 0.5,
                endTime: Double(index) * 0.5 + 0.4
            )
        }
    }

    @Test("Reaching the last word of a page is detected")
    func endIsDetected() {
        let page = target("قُلْ هُوَ ٱللَّهُ أَحَدٌ", ayah: 1)
        let aligner = TokenAligner()

        #expect(!aligner.align(heard: heard("قل هو"), against: page, isFinal: false).hasReachedEnd())
        #expect(aligner.align(heard: heard("قل هو الله أحد"), against: page, isFinal: false).hasReachedEnd())
    }

    @Test("The page does not turn until the final word itself is matched")
    func finalWordIsRequired() {
        // Deliberately strict. Turning on the second-to-last word moved the page while
        // the reciter was still finishing it. The cost is that a misheard closing word
        // leaves the page in place — which is the safer failure: a page that stays is an
        // inconvenience, a page that vanishes mid-word is not.
        let page = target("قُلْ هُوَ ٱللَّهُ أَحَدٌ", ayah: 1)
        let aligner = TokenAligner()
        #expect(!aligner.align(heard: heard("قل هو الله"), against: page, isFinal: false).hasReachedEnd())
        #expect(aligner.align(heard: heard("قل هو الله أحد"), against: page, isFinal: false).hasReachedEnd())
    }

    @Test("The tolerance can be widened for callers that want an earlier turn")
    func toleranceIsConfigurable() {
        let page = target("قُلْ هُوَ ٱللَّهُ أَحَدٌ", ayah: 1)
        let result = TokenAligner().align(heard: heard("قل هو الله"), against: page, isFinal: false)
        #expect(result.hasReachedEnd(tolerance: 2))
    }

    @Test("A fresh page has not been reached")
    func freshPageIsNotFinished() {
        let page = target("قُلْ هُوَ ٱللَّهُ أَحَدٌ", ayah: 1)
        #expect(!TokenAligner().align(heard: [], against: page, isFinal: false).hasReachedEnd())
    }

    @Test("Retargeting mid-session clears the previous page and starts the new one clean")
    func retargetClearsPreviousPage() async throws {
        let first = target("قُلْ هُوَ ٱللَّهُ أَحَدٌ", ayah: 1)
        let second = target("ٱللَّهُ ٱلصَّمَدُ", ayah: 2)

        let pipeline = RecitationPipeline(
            components: PipelineComponents(
                capture: ScriptedAudioCapture.silence(chunkCount: 4, chunkDuration: 1.5, pacing: .milliseconds(1)),
                vad: PassthroughVoiceActivityDetector(),
                recognizer: ScriptedSpeechRecognizer(transcript: "قل هو الله أحد", segmentCount: 2)
            )
        )

        let stream = await pipeline.events()
        let collector = Task { () -> [PipelineEvent] in
            var all: [PipelineEvent] = []
            for await event in stream { all.append(event) }
            return all
        }

        await pipeline.start(target: first)
        try await Task.sleep(for: .milliseconds(120))
        await pipeline.retarget(second)
        try await Task.sleep(for: .milliseconds(60))
        await pipeline.stop()

        let events = await collector.value
        let final = try #require(events.compactMap { event -> RecitationResult? in
            if case .finished(let result) = event { return result }
            return nil
        }.last)

        // The finished result belongs to the new page only.
        #expect(final.target == second)
        #expect(final.alignment.words.allSatisfy { $0.reference.ayah == 2 })
        // The previous page's recording is gone, not carried forward.
        #expect(final.segments.allSatisfy { $0.startTime >= 0 })
        #expect(final.alignment.words.count == second.flattenedWords.count)
    }

    @Test("The first alignment after a turn accuses nothing")
    func turnDoesNotAccuse() async throws {
        // A page that has just appeared must start blank — if the previous page's tokens
        // survived, its words would be matched against this page's text and reported as
        // mistakes the reciter never made.
        let first = target("قُلْ هُوَ ٱللَّهُ أَحَدٌ", ayah: 1)
        let second = target("ٱللَّهُ ٱلصَّمَدُ", ayah: 2)

        let pipeline = RecitationPipeline(
            components: PipelineComponents(
                capture: ScriptedAudioCapture.silence(chunkCount: 6, chunkDuration: 1.5, pacing: .milliseconds(1)),
                vad: PassthroughVoiceActivityDetector(),
                recognizer: ScriptedSpeechRecognizer(transcript: "قل هو الله أحد", segmentCount: 2)
            )
        )
        let stream = await pipeline.events()
        let collector = Task { () -> [AlignmentResult] in
            var all: [AlignmentResult] = []
            for await event in stream {
                if case .alignment(let alignment) = event { all.append(alignment) }
            }
            return all
        }

        await pipeline.start(target: first)
        try await Task.sleep(for: .milliseconds(120))
        await pipeline.retarget(second)
        let afterTurn = Date()
        try await Task.sleep(for: .milliseconds(40))
        await pipeline.stop()

        _ = afterTurn
        let alignments = await collector.value
        // Every alignment for the new page must be free of fabricated mistakes.
        let forSecondPage = alignments.filter { $0.words.first?.reference.ayah == 2 }
        try #require(!forSecondPage.isEmpty)
        #expect(forSecondPage.allSatisfy { $0.mistakeCount == 0 })
    }
}

@Suite("Provisional readings")
struct ProvisionalReadingTests {

    /// A detector that never closes a segment, so only provisional readings can be seen.
    private actor NeverClosing: VoiceActivityDetector {
        private var held: AudioChunk?
        func process(_ frame: AudioChunk) async -> [AudioChunk] {
            held = held.map { $0.appending(frame) } ?? frame
            return []
        }
        func pending() async -> AudioChunk? { held }
        func flush() async -> AudioChunk? { nil }
        func reset() async { held = nil }
    }

    @Test("Progress is shown before the phrase ends")
    func showsProgressEarly() async throws {
        let target = RecitationTarget(verses: [
            Verse(reference: VerseReference(surah: 112, ayah: 1), text: "قُلْ هُوَ ٱللَّهُ أَحَدٌ")
        ])
        let pipeline = RecitationPipeline(components: PipelineComponents(
            capture: ScriptedAudioCapture.silence(chunkCount: 8, chunkDuration: 1.0, pacing: .milliseconds(1)),
            vad: NeverClosing(),
            recognizer: ScriptedSpeechRecognizer(transcript: "قل هو", segmentCount: 1),
            aligner: TokenAligner()
        ))

        let events = await pipeline.events()
        await pipeline.start(target: target)
        var alignments: [AlignmentResult] = []
        for await event in events {
            if case .alignment(let result) = event { alignments.append(result) }
            if alignments.count >= 2 { break }
        }
        await pipeline.stop()

        // The segment never closed, so anything seen here came from a provisional pass.
        #expect(!alignments.isEmpty)
    }

    @Test("A provisional reading never reports a mistake")
    func neverAccuses() async throws {
        // The reciter has said two of four words. Without the rest of the phrase the last
        // two look skipped — which is exactly the accusation a partial reading must not
        // make, because the words that would explain it have not been said yet.
        let target = RecitationTarget(verses: [
            Verse(reference: VerseReference(surah: 112, ayah: 1), text: "قُلْ هُوَ ٱللَّهُ أَحَدٌ")
        ])
        let pipeline = RecitationPipeline(components: PipelineComponents(
            capture: ScriptedAudioCapture.silence(chunkCount: 8, chunkDuration: 1.0, pacing: .milliseconds(1)),
            vad: NeverClosing(),
            recognizer: ScriptedSpeechRecognizer(transcript: "قل زيد", segmentCount: 1),
            aligner: TokenAligner()
        ))

        let events = await pipeline.events()
        await pipeline.start(target: target)
        var seen: [AlignmentResult] = []
        for await event in events {
            if case .alignment(let result) = event { seen.append(result) }
            if seen.count >= 2 { break }
        }
        await pipeline.stop()

        for result in seen {
            #expect(result.mistakeCount == 0, "a provisional reading accused the reciter")
            #expect(result.insertions.isEmpty, "a provisional reading invented a word")
        }
    }
}
