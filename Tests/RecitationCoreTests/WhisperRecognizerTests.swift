import Foundation
import Testing

@testable import RecitationCore

/// Locates the fixtures and the model.
///
/// The model is deliberately *not* a test resource: it is ~141 MB, is fetched by
/// scripts/fetch-model.sh rather than checked in, and would bloat every build. These
/// tests are skipped when it's absent so a fresh clone still has a green suite.
enum WhisperTestSupport {
    /// Package root, derived from this file's location at compile time.
    static let packageRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // RecitationCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // <package root>

    /// The Quran-tuned conversion, preferred when present.
    static let tarteelURL = packageRoot.appending(path: "Models/ggml-base-ar-quran-q8_0.bin")
    /// Stock multilingual weights, used as a baseline.
    static let stockURL = packageRoot.appending(path: "Models/ggml-base.bin")

    static var modelURL: URL {
        FileManager.default.fileExists(atPath: tarteelURL.path) ? tarteelURL : stockURL
    }

    static var modelExists: Bool {
        FileManager.default.fileExists(atPath: modelURL.path)
    }

    static var tarteelExists: Bool {
        FileManager.default.fileExists(atPath: tarteelURL.path)
    }

    /// The Core ML encoder whisper.cpp will look for beside the Tarteel weights.
    static var tarteelEncoderURL: URL {
        packageRoot.appending(path: "Models/ggml-base-ar-quran-encoder.mlmodelc")
    }

    static func fixture(_ name: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: "Resources/\(name)", withExtension: nil) else {
            throw FixtureError.missing(name)
        }
        return url
    }

    enum FixtureError: Error { case missing(String) }
}

@Suite(
    "Whisper recognizer",
    .enabled(if: WhisperTestSupport.modelExists, "Models/ggml-base.bin not present — run scripts/fetch-model.sh"),
    .serialized  // one model in memory at a time; these are heavyweight
)
struct WhisperRecognizerTests {

    @Test("A bundled WAV decodes to canonical 16 kHz mono float")
    func loadsFixture() throws {
        let chunk = try AudioFileLoader.load(url: try WhisperTestSupport.fixture("ikhlas-tts.wav"))

        #expect(chunk.sampleRate == AudioChunk.canonicalSampleRate)
        #expect(chunk.duration > 5)
        #expect(!chunk.isEmpty)
        // Real audio, not silence.
        #expect(chunk.rms > 0.001)
    }

    @Test(
        "English baseline: whisper transcribes the known jfk.wav sample",
        .enabled(if: FileManager.default.fileExists(atPath: WhisperTestSupport.stockURL.path))
    )
    func englishBaseline() async throws {
        // Proves the C bridge, model load, and decode path independently of any
        // Arabic-specific behaviour. If this fails, the integration is broken; if only
        // the Arabic test fails, it's a model-quality issue instead.
        // Deliberately the stock multilingual model: the Quran fine-tune has no reason
        // to handle English, so this isolates the C bridge and decode path from model
        // quality.
        let recognizer = WhisperSpeechRecognizer(
            modelURL: WhisperTestSupport.stockURL,
            options: .init(language: "en")
        )
        let chunk = try AudioFileLoader.load(url: try WhisperTestSupport.fixture("jfk.wav"))
        let transcription = try await recognizer.transcribe(chunk)

        #expect(!transcription.text.isEmpty)
        let lowered = transcription.text.lowercased()
        #expect(lowered.contains("country"), "unexpected transcript: \(transcription.text)")
        #expect(lowered.contains("ask not") || lowered.contains("ask what"), "unexpected transcript: \(transcription.text)")
    }

    @Test("Arabic: transcribing the bundled recitation produces Arabic words")
    func arabicTranscription() async throws {
        let recognizer = WhisperSpeechRecognizer(modelURL: WhisperTestSupport.modelURL)
        let chunk = try AudioFileLoader.load(url: try WhisperTestSupport.fixture("ikhlas-tts.wav"))
        let transcription = try await recognizer.transcribe(chunk)

        #expect(!transcription.text.isEmpty, "recognizer returned nothing")
        #expect(!transcription.tokens.isEmpty, "no word tokens produced")

        // Output must actually be Arabic script — forcing language="ar" should prevent
        // the model wandering into another language.
        let normalized = ArabicNormalizer.normalize(transcription.text)
        #expect(!normalized.isEmpty, "no Arabic characters in: \(transcription.text)")
    }

    @Test("Every word token carries a usable timestamp — the v2 tajweed contract")
    func wordTimestampsAreUsable() async throws {
        let recognizer = WhisperSpeechRecognizer(modelURL: WhisperTestSupport.modelURL)
        let chunk = try AudioFileLoader.load(url: try WhisperTestSupport.fixture("ikhlas-tts.wav"))
        let transcription = try await recognizer.transcribe(chunk)

        try #require(!transcription.tokens.isEmpty)

        for token in transcription.tokens {
            #expect(token.endTime >= token.startTime, "inverted range on “\(token.text)”")
            #expect(token.startTime >= 0)
            // Timestamps must land inside the audio that produced them, or slicing the
            // word's samples back out for DSP will silently yield the wrong region.
            #expect(token.startTime <= chunk.endTime + 0.5, "“\(token.text)” starts past the audio")
            #expect(token.confidence >= 0 && token.confidence <= 1)
        }

        // Words should advance through the audio rather than all collapsing to t=0.
        let starts = transcription.tokens.map(\.startTime)
        #expect(starts == starts.sorted(), "word timestamps are not monotonic")
        #expect(starts.last! > starts.first!, "all words share one timestamp")
    }

    @Test("Word audio can be sliced back out of the source chunk")
    func perWordAudioSlicing() async throws {
        let recognizer = WhisperSpeechRecognizer(modelURL: WhisperTestSupport.modelURL)
        let chunk = try AudioFileLoader.load(url: try WhisperTestSupport.fixture("ikhlas-tts.wav"))
        let transcription = try await recognizer.transcribe(chunk)

        try #require(!transcription.tokens.isEmpty)

        // Exactly the operation a DSP tajweed rule performs on a real recognizer's output.
        var sliced = 0
        for token in transcription.tokens {
            let audio = chunk.slice(from: token.startTime, to: token.endTime)
            if !audio.isEmpty { sliced += 1 }
        }
        #expect(sliced > 0, "no word audio could be sliced out")
    }

    @Test("Silence does not produce fabricated words")
    func silenceProducesNothing() async throws {
        // Whisper hallucinating over silence would surface downstream as invented
        // mistakes in someone's recitation. Guard it explicitly.
        let recognizer = WhisperSpeechRecognizer(modelURL: WhisperTestSupport.modelURL)
        let silence = AudioChunk(
            samples: [Float](repeating: 0, count: Int(AudioChunk.canonicalSampleRate * 3)),
            startTime: 0
        )
        let transcription = try await recognizer.transcribe(silence)
        let normalized = ArabicNormalizer.normalize(transcription.text)

        #expect(normalized.isEmpty, "hallucinated over silence: “\(transcription.text)”")
    }

    /// Reproducible noise, so a failure can be investigated rather than re-rolled.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }

    @Test("KNOWN GAP: loud non-speech noise still yields fabricated words")
    func noiseProducesNothing() async throws {
        // Deliberately above `silenceFloor`, so the energy pre-gate does not apply and
        // this reaches the model.
        //
        // This is a recorded limitation, not a passing behaviour. Whisper invents
        // confident Arabic over white noise, and three candidate guards were measured
        // and rejected:
        //   * no_speech_prob   — ~2e-8 on noise vs ~2e-5 on speech (rates noise as
        //                        *more* speech-like; unusable).
        //   * token confidence — noise mean 0.68 / min 0.57 vs speech 0.73 / 0.52
        //                        (a threshold drops real speech first).
        //   * degenerate timing — catches some draws, not others.
        //
        // This is a property of the model and is expected to stay true: rejecting
        // non-speech is the VAD's job, not the recogniser's. As of build step 4 the
        // assembled pipeline does uphold the guarantee — Silero refuses to segment noise,
        // so it never reaches whisper. See `SileroVADTests.noiseProducesNoWordsEndToEnd`,
        // which is the test that matters. This one stays to document *why* the VAD
        // cannot be bypassed.
        var generator = SeededGenerator(state: 0x5EED_1234_5EED_1234)
        let samples = (0..<Int(AudioChunk.canonicalSampleRate * 3)).map { _ in
            Float.random(in: -0.05...0.05, using: &generator)
        }
        let noise = AudioChunk(samples: samples, startTime: 0)
        try #require(noise.rms > WhisperSpeechRecognizer.Options.default.silenceFloor)

        let recognizer = WhisperSpeechRecognizer(modelURL: WhisperTestSupport.modelURL)
        let transcription = try await recognizer.transcribe(noise)

        await withKnownIssue("whisper hallucinates over non-speech; Silero VAD (step 4) is the fix", isIntermittent: true) {
            #expect(
                transcription.tokens.isEmpty,
                "hallucinated over noise: “\(transcription.text)”"
            )
        }
    }

    @Test("Real speech is not discarded by the hallucination guards")
    func guardsDoNotSuppressRealSpeech() async throws {
        // The counterpart to the noise test: the guards must be conservative in the
        // other direction too, or genuine recitation would silently vanish and be
        // reported as skipped words.
        let recognizer = WhisperSpeechRecognizer(modelURL: WhisperTestSupport.modelURL)
        let chunk = try AudioFileLoader.load(url: try WhisperTestSupport.fixture("ikhlas-tts.wav"))
        let transcription = try await recognizer.transcribe(chunk)

        #expect(transcription.tokens.count >= 8, "guards suppressed real speech: \(transcription.text)")
    }

    @Test("The model loads once and is reusable across chunks")
    func modelReuse() async throws {
        let recognizer = WhisperSpeechRecognizer(modelURL: WhisperTestSupport.modelURL)
        let chunk = try AudioFileLoader.load(url: try WhisperTestSupport.fixture("ikhlas-tts.wav"))

        #expect(await !recognizer.isLoaded)
        _ = try await recognizer.transcribe(chunk)
        #expect(await recognizer.isLoaded)
        // A second call must not reload or crash.
        _ = try await recognizer.transcribe(chunk)
        #expect(await recognizer.isLoaded)

        await recognizer.unloadModel()
        #expect(await !recognizer.isLoaded)
    }

    @Test("A missing model reports a clear error rather than crashing")
    func missingModel() async throws {
        let recognizer = WhisperSpeechRecognizer(
            modelURL: WhisperTestSupport.packageRoot.appending(path: "Models/does-not-exist.bin")
        )
        let chunk = AudioChunk(samples: [Float](repeating: 0.1, count: 16_000), startTime: 0)

        await #expect(throws: SpeechRecognizerError.self) {
            _ = try await recognizer.transcribe(chunk)
        }
    }
}

@Suite(
    "Quran-tuned model",
    .enabled(if: WhisperTestSupport.tarteelExists, "run scripts/convert-model.sh"),
    .serialized
)
struct TarteelModelTests {

    @Test("The converted model loads — the config max_length trap is handled")
    func modelLoads() async throws {
        // The upstream converter writes `max_length` as the decoder context size. Tarteel's
        // config sets it to 1024 (a generation default) while the real decoder is 448 rows,
        // producing a GGML file whisper.cpp rejects outright. scripts/convert-model.sh
        // corrects it; this test fails loudly if that correction is ever dropped.
        let recognizer = WhisperSpeechRecognizer(modelURL: WhisperTestSupport.tarteelURL)
        try await recognizer.loadModel()
        #expect(await recognizer.isLoaded)
    }

    @Test("The Core ML encoder is named where whisper.cpp will find it")
    func coreMLEncoderIsDiscoverable() throws {
        // whisper.cpp strips a trailing -qX_X before appending "-encoder.mlmodelc", so the
        // encoder must NOT carry the quantisation suffix. Getting this wrong is silent:
        // ALLOW_FALLBACK means it just runs on Metal/CPU instead of the ANE.
        #expect(
            FileManager.default.fileExists(atPath: WhisperTestSupport.tarteelEncoderURL.path),
            "expected \(WhisperTestSupport.tarteelEncoderURL.lastPathComponent)"
        )
        let stem = SpeechModelLocator.strippingQuantizationSuffix("ggml-base-ar-quran-q8_0")
        #expect(stem == "ggml-base-ar-quran")
    }

    @Test("The locator finds the converted model and reports the Core ML encoder")
    func locatorFindsModel() throws {
        let located = try #require(
            SpeechModelLocator.locate(
                .default,
                additionalDirectories: [WhisperTestSupport.packageRoot.appending(path: "Models")]
            )
        )
        #expect(located.url.lastPathComponent == "ggml-base-ar-quran-q8_0.bin")
        #expect(located.hasCoreMLEncoder)
    }

    @Test("DTW produces a usable timestamp for every word")
    func dtwTimestampsAreComplete() async throws {
        // Without DTW this model timestamps only the first few words and collapses the
        // rest onto one instant — measured at 5 of 15. v2 tajweed measures durations over
        // these spans, so partial timing makes the whole feature impossible.
        let recognizer = WhisperSpeechRecognizer(
            modelURL: WhisperTestSupport.tarteelURL,
            options: .init(useDTWTimestamps: true)
        )
        let chunk = try AudioFileLoader.load(url: try WhisperTestSupport.fixture("ikhlas-tts.wav"))
        let transcription = try await recognizer.transcribe(chunk)

        try #require(transcription.tokens.count >= 10)
        let timed = transcription.tokens.count { $0.duration > 0 }
        #expect(
            timed == transcription.tokens.count,
            "only \(timed)/\(transcription.tokens.count) words carry a duration"
        )

        let starts = transcription.tokens.map(\.startTime)
        #expect(starts == starts.sorted(), "word timestamps are not monotonic")
        // Words must be spread across the audio, not bunched at one end.
        #expect(starts.last! - starts.first! > chunk.duration * 0.4)
    }

    @Test("The Quran-tuned model beats the stock model on recitation")
    func outperformsStockModel() async throws {
        // The whole justification for the conversion pipeline. Measured on the bundled
        // fixture: stock 5/15 words matched, Tarteel 11/15.
        guard FileManager.default.fileExists(atPath: WhisperTestSupport.stockURL.path) else { return }

        let target = try await InMemoryVerseStore.sample.target(
            from: VerseReference(surah: 112, ayah: 1),
            through: VerseReference(surah: 112, ayah: 4)
        )
        let chunk = try AudioFileLoader.load(url: try WhisperTestSupport.fixture("ikhlas-tts.wav"))
        let aligner = TokenAligner()

        func matchedWords(_ url: URL) async throws -> Int {
            let recognizer = WhisperSpeechRecognizer(modelURL: url)
            let transcription = try await recognizer.transcribe(chunk)
            return aligner.align(heard: transcription.tokens, against: target, isFinal: true).correctCount
        }

        let stock = try await matchedWords(WhisperTestSupport.stockURL)
        let tarteel = try await matchedWords(WhisperTestSupport.tarteelURL)

        #expect(tarteel > stock, "Quran-tuned model (\(tarteel)) did not beat stock (\(stock))")
        #expect(tarteel >= 10, "accuracy regressed: \(tarteel)/\(target.flattenedWords.count)")
    }

    @Test("Transcription stays comfortably faster than real time")
    func latencyIsAcceptable() async throws {
        // Live use needs each VAD segment transcribed well inside its own duration.
        let recognizer = WhisperSpeechRecognizer(modelURL: WhisperTestSupport.tarteelURL)
        let chunk = try AudioFileLoader.load(url: try WhisperTestSupport.fixture("ikhlas-tts.wav"))
        _ = try await recognizer.transcribe(chunk)  // warm-up: the ANE compiles on first use

        let start = Date()
        _ = try await recognizer.transcribe(chunk)
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < chunk.duration / 5, "only \(chunk.duration / elapsed)x realtime")
    }
}
