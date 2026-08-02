import Foundation
import Testing

@testable import RecitationCore

extension WhisperTestSupport {
    static var vadModelURL: URL { packageRoot.appending(path: "Models/ggml-silero-v5.1.2.bin") }
    static var vadModelExists: Bool { FileManager.default.fileExists(atPath: vadModelURL.path) }
}

@Suite(
    "Silero voice activity detection",
    .enabled(if: WhisperTestSupport.vadModelExists, "run scripts/fetch-vad-model.sh"),
    .serialized
)
struct SileroVADTests {

    /// Feed a whole chunk through the detector frame by frame, as capture would.
    private func segments(
        of chunk: AudioChunk,
        detector: SileroVoiceActivityDetector,
        frameDuration: TimeInterval = 0.064
    ) async -> [AudioChunk] {
        let frameSize = Int(frameDuration * chunk.sampleRate)
        var emitted: [AudioChunk] = []
        var offset = 0
        while offset < chunk.samples.count {
            let end = min(offset + frameSize, chunk.samples.count)
            let frame = AudioChunk(
                samples: Array(chunk.samples[offset..<end]),
                sampleRate: chunk.sampleRate,
                startTime: chunk.startTime + TimeInterval(offset) / chunk.sampleRate
            )
            emitted += await detector.process(frame)
            offset = end
        }
        if let tail = await detector.flush() { emitted.append(tail) }
        return emitted
    }

    private func noise(seconds: Double, amplitude: Float = 0.05, seed: UInt64 = 0x5EED_1234_5EED_1234) -> AudioChunk {
        var state = seed
        func next() -> Float {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Float(Int64(bitPattern: state) % 1000) / 1000.0 * amplitude
        }
        return AudioChunk(
            samples: (0..<Int(seconds * AudioChunk.canonicalSampleRate)).map { _ in next() },
            startTime: 0
        )
    }

    @Test("The model loads and reports a sane analysis window")
    func modelLoads() async throws {
        let vad = SileroVoiceActivityDetector(modelURL: WhisperTestSupport.vadModelURL)
        try await vad.loadModel()
        #expect(await vad.isLoaded)
    }

    @Test("Real speech is segmented")
    func detectsSpeech() async throws {
        let vad = SileroVoiceActivityDetector(modelURL: WhisperTestSupport.vadModelURL)
        let chunk = try AudioFileLoader.load(url: try WhisperTestSupport.fixture("ikhlas-tts.wav"))
        let emitted = await segments(of: chunk, detector: vad)

        #expect(!emitted.isEmpty, "no speech detected in real recitation audio")
        let speechDuration = emitted.reduce(0) { $0 + $1.duration }
        // Most of the fixture is speech; a detector that only found a sliver of it would
        // silently truncate the recitation.
        #expect(speechDuration > chunk.duration * 0.5, "only \(speechDuration)s of \(chunk.duration)s detected")
    }

    @Test("Silence produces no segments")
    func rejectsSilence() async throws {
        let vad = SileroVoiceActivityDetector(modelURL: WhisperTestSupport.vadModelURL)
        let silence = AudioChunk(
            samples: [Float](repeating: 0, count: Int(AudioChunk.canonicalSampleRate * 3)),
            startTime: 0
        )
        #expect(await segments(of: silence, detector: vad).isEmpty)
    }

    @Test("Loud non-speech noise produces no segments")
    func rejectsNoise() async throws {
        // The gap step 2 could not close. An energy gate passes this straight through,
        // and whisper then invents confident Arabic over it. Rejecting non-speech is the
        // VAD's job, and this is the test that it does it.
        let vad = SileroVoiceActivityDetector(modelURL: WhisperTestSupport.vadModelURL)
        let chunk = noise(seconds: 3)
        try #require(chunk.rms > 0.005, "fixture must clear the recognizer's energy floor")

        let emitted = await segments(of: chunk, detector: vad)
        #expect(emitted.isEmpty, "noise produced \(emitted.count) speech segment(s)")
    }

    @Test("Segment timestamps stay on the session clock and in order")
    func timestampsAreCoherent() async throws {
        let vad = SileroVoiceActivityDetector(modelURL: WhisperTestSupport.vadModelURL)
        let chunk = try AudioFileLoader.load(url: try WhisperTestSupport.fixture("ikhlas-tts.wav"))
        let emitted = await segments(of: chunk, detector: vad)
        try #require(!emitted.isEmpty)

        for segment in emitted {
            #expect(segment.startTime >= 0)
            #expect(segment.endTime <= chunk.duration + 0.1, "segment runs past the audio")
            #expect(segment.duration > 0)
        }
        let starts = emitted.map(\.startTime)
        #expect(starts == starts.sorted(), "segments out of order")
    }

    @Test("Reset clears the LSTM state between sessions")
    func resetIsClean() async throws {
        // A stale hidden state would colour the opening of the next recitation, which is
        // exactly where the reciter is most likely to be judged wrongly.
        let vad = SileroVoiceActivityDetector(modelURL: WhisperTestSupport.vadModelURL)
        let chunk = try AudioFileLoader.load(url: try WhisperTestSupport.fixture("ikhlas-tts.wav"))

        let first = await segments(of: chunk, detector: vad)
        await vad.reset()
        let second = await segments(of: chunk, detector: vad)

        #expect(first.count == second.count, "segmentation differed after reset")
        if let a = first.first, let b = second.first {
            #expect(abs(a.startTime - b.startTime) < 0.1)
        }
    }

    @Test("A segment opens before the speech it detected")
    func preRollIsApplied() async throws {
        let vad = SileroVoiceActivityDetector(
            modelURL: WhisperTestSupport.vadModelURL,
            options: .init(segmentation: .init(preRoll: 0.3))
        )
        let speech = try AudioFileLoader.load(url: try WhisperTestSupport.fixture("ikhlas-tts.wav"))
        // Lead with silence so there is something for the pre-roll to retain.
        let padded = AudioChunk(
            samples: [Float](repeating: 0, count: Int(AudioChunk.canonicalSampleRate)) + speech.samples,
            startTime: 0
        )
        let emitted = await segments(of: padded, detector: vad)
        let first = try #require(emitted.first)

        // Speech starts at t = 1.0; the segment must begin before that.
        #expect(first.startTime < 1.0, "segment began at the detection point, clipping the onset")
        #expect(first.startTime > 0.4, "pre-roll reached further back than configured")
    }

    // MARK: - End to end

    @Test(
        "Noise produces no transcribed words through the real pipeline",
        .enabled(if: WhisperTestSupport.modelExists)
    )
    func noiseProducesNoWordsEndToEnd() async throws {
        // The guarantee that actually matters. `WhisperRecognizerTests` records that
        // whisper *will* invent Arabic if handed noise directly — that is a property of
        // the model and remains true. What must never happen is that noise reaches the
        // recognizer at all, and this asserts the assembled pipeline upholds it.
        let target = try await InMemoryVerseStore.sample.target(
            from: VerseReference(surah: 112, ayah: 1),
            through: VerseReference(surah: 112, ayah: 4)
        )
        let chunk = noise(seconds: 4)
        try #require(chunk.rms > 0.005)

        let pipeline = RecitationPipeline(
            components: PipelineComponents(
                capture: ScriptedAudioCapture(
                    chunks: stride(from: 0, to: chunk.samples.count, by: 1024).map { offset in
                        AudioChunk(
                            samples: Array(chunk.samples[offset..<min(offset + 1024, chunk.samples.count)]),
                            startTime: TimeInterval(offset) / chunk.sampleRate
                        )
                    },
                    pacing: .milliseconds(0)
                ),
                vad: SileroVoiceActivityDetector(modelURL: WhisperTestSupport.vadModelURL),
                recognizer: WhisperSpeechRecognizer(modelURL: WhisperTestSupport.modelURL),
                aligner: TokenAligner()
            )
        )

        let stream = await pipeline.events()
        let collector = Task { () -> [PipelineEvent] in
            var all: [PipelineEvent] = []
            for await event in stream { all.append(event) }
            return all
        }
        await pipeline.start(target: target)
        try await Task.sleep(for: .milliseconds(600))
        await pipeline.stop()

        let events = await collector.value
        let result = events.compactMap { event -> RecitationResult? in
            if case .finished(let r) = event { return r }
            return nil
        }.last
        let final = try #require(result)

        #expect(final.segments.isEmpty, "noise was segmented as speech")
        #expect(final.transcribedText.isEmpty, "noise transcribed as: \(final.transcribedText)")
        #expect(final.alignment.mistakeCount == 0, "noise produced fabricated mistakes")
        #expect(final.alignment.insertions.isEmpty)
    }
}
