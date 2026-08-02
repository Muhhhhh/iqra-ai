import CWhisper
import Foundation

/// whisper.cpp-backed recognizer.
///
/// An actor, so the context (which is not thread-safe) is only ever touched from one
/// task at a time and inference never runs on the main thread.
///
/// Word-level timestamps are non-negotiable here: v2 tajweed measures durations over
/// the aligned audio, so the recognizer must report *where* each word was, not just
/// what was said. That means `token_timestamps` stays on, and the subword tokens
/// whisper emits are regrouped into words below.
public actor WhisperSpeechRecognizer: SpeechRecognizer {

    /// Runtime knobs distinct from `SpeechModelConfiguration`, which only describes
    /// which weights to load.
    public struct Options: Sendable {
        public var threadCount: Int
        /// Force a decode language. Nil auto-detects — not recommended here: the target
        /// is always Arabic, and auto-detect on short chunks produces confident nonsense
        /// in the wrong language.
        public var language: String?
        /// Beam search width. 1 uses greedy decoding, which is markedly faster and is
        /// the right default for live use.
        public var beamSize: Int
        /// Discard segments whose no-speech probability exceeds this.
        ///
        /// Kept because it is standard practice and costs nothing, but **do not rely on
        /// it**: measured on this model, `no_speech_prob` was ~2e-8 for pure white noise
        /// versus ~2e-5 for real speech. It rates noise as *more* speech-like than
        /// speech, so it cannot separate the two. `minimumTimedTokenFraction` is the
        /// guard that actually works.
        public var noSpeechThreshold: Float
        /// Suppress the model's tendency to emit "[BLANK_AUDIO]"-style annotations.
        public var suppressNonSpeechTokens: Bool
        /// Chunks quieter than this RMS are returned empty without running inference.
        ///
        /// Whisper reliably invents words when handed silence — a verified failure, not a
        /// theoretical one. Anything it invents becomes a fabricated mistake in someone's
        /// recitation, so silence is refused before it ever reaches the model.
        public var silenceFloor: Float
        /// Reject the whole transcription unless at least this fraction of its words
        /// occupy real time.
        ///
        /// When whisper hallucinates over non-speech it collapses the invented words
        /// onto a single instant — measured on white noise, two of three words had
        /// exactly zero duration and all three sat at the segment boundary, while every
        /// word of real speech advanced with a distinct span. Neither `no_speech_prob`
        /// nor token confidence separated the two cases (noise scored *better* on both),
        /// so degenerate timing is the signal that works.
        ///
        /// Rejecting the whole transcription rather than pruning individual words is
        /// deliberate: dropping words from an otherwise-good transcript would surface as
        /// invented "skipped word" reports, which is the harm this is meant to prevent.
        public var minimumTimedTokenFraction: Double
        /// Derive word timestamps by DTW over the decoder's cross-attention instead of
        /// trusting the timestamp tokens the model emits.
        ///
        /// Fine-tuned models are typically trained on short clips *without* timestamp
        /// tokens, so their emitted timings degrade badly — the Tarteel model collapses
        /// ten of fifteen words onto a single instant at the end of the audio. DTW
        /// recovers alignment from attention, which the fine-tune preserves. v2 tajweed
        /// measures durations over these boundaries, so their quality is not cosmetic.
        public var useDTWTimestamps: Bool

        public init(
            threadCount: Int = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)),
            language: String? = "ar",
            beamSize: Int = 1,
            noSpeechThreshold: Float = 0.6,
            suppressNonSpeechTokens: Bool = true,
            silenceFloor: Float = 0.005,
            minimumTimedTokenFraction: Double = 0.25,
            useDTWTimestamps: Bool = true
        ) {
            self.threadCount = threadCount
            self.language = language
            self.beamSize = beamSize
            self.noSpeechThreshold = noSpeechThreshold
            self.suppressNonSpeechTokens = suppressNonSpeechTokens
            self.silenceFloor = silenceFloor
            self.minimumTimedTokenFraction = minimumTimedTokenFraction
            self.useDTWTimestamps = useDTWTimestamps
        }

        public static let `default` = Options()
    }

    /// Owns the whisper context pointer so it is freed deterministically.
    ///
    /// The pointer can't live directly on the actor: Swift 6 forbids touching isolated
    /// state from a nonisolated `deinit`, so the actor would have no safe place to call
    /// `whisper_free`. Handing ownership to a class moves the cleanup to that class's
    /// own deinit instead. `@unchecked Sendable` is sound because the actor is the only
    /// thing that ever holds or dereferences it.
    private final class Context: @unchecked Sendable {
        let pointer: OpaquePointer

        init(pointer: OpaquePointer) {
            self.pointer = pointer
        }

        deinit {
            whisper_free(pointer)
        }
    }

    private let modelURL: URL
    private let options: Options
    private var context: Context?

    /// whisper pads every input to 30 s internally, but very short buffers still decode
    /// poorly and can trigger hallucination. Anything below this is padded with silence.
    private static let minimumSamples = Int(AudioChunk.canonicalSampleRate)  // 1 s

    public init(modelURL: URL, options: Options = .default) {
        self.modelURL = modelURL
        self.options = options
    }

    // MARK: - Model lifecycle

    /// Load the model. Called lazily by `transcribe`, but worth calling up front:
    /// loading takes a moment, and the first Core ML inference after a fresh conversion
    /// is far slower while the ANE compiles the encoder.
    public func loadModel() throws {
        guard context == nil else { return }

        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw SpeechRecognizerError.modelUnavailable(
                "no model at \(modelURL.path). See scripts/README.md."
            )
        }

        var params = whisper_context_default_params()
        // Core ML is used when a matching -encoder.mlmodelc sits beside the weights.
        // The libraries are built with ALLOW_FALLBACK, so this silently drops to the
        // Metal/CPU encoder when that file is absent.
        params.use_gpu = true

        if options.useDTWTimestamps {
            params.dtw_token_timestamps = true
            // The alignment-head preset must match the architecture, not the fine-tune:
            // Tarteel's model is Whisper base with retrained weights, so BASE is correct.
            params.dtw_aheads_preset = WHISPER_AHEADS_BASE
            // whisper.cpp silently disables DTW when flash attention is on — it needs the
            // cross-attention weights that flash attention never materialises. It logs
            // "dtw_token_timestamps is not supported with flash_attn - disabling" and
            // carries on, so the only symptom is t_dtw coming back as -1.
            params.flash_attn = false
        }

        guard let loaded = whisper_init_from_file_with_params(modelURL.path, params) else {
            throw SpeechRecognizerError.modelUnavailable("whisper failed to load \(modelURL.lastPathComponent)")
        }
        context = Context(pointer: loaded)
    }

    /// Releases the weights. The context is freed when the last reference drops.
    public func unloadModel() {
        context = nil
    }

    /// True once the weights are resident.
    public var isLoaded: Bool { context != nil }

    // MARK: - Transcription

    public func transcribe(_ chunk: AudioChunk) async throws -> Transcription {
        try loadModel()
        guard let context = context?.pointer else {
            throw SpeechRecognizerError.modelUnavailable("context unexpectedly nil")
        }
        guard !chunk.isEmpty else { return .empty }

        // First line of defence against hallucination: never ask the model about audio
        // that carries no speech energy.
        guard chunk.rms >= options.silenceFloor else { return .empty }

        var samples = chunk.samples
        if samples.count < Self.minimumSamples {
            samples.append(contentsOf: [Float](repeating: 0, count: Self.minimumSamples - samples.count))
        }

        var params = whisper_full_default_params(
            options.beamSize > 1 ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY
        )
        params.n_threads = Int32(options.threadCount)
        params.translate = false
        params.no_context = true          // each chunk is judged on its own audio
        params.single_segment = false
        params.token_timestamps = true    // required for v2 tajweed
        params.no_timestamps = false
        params.suppress_nst = options.suppressNonSpeechTokens
        params.no_speech_thold = options.noSpeechThreshold
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        if options.beamSize > 1 {
            params.beam_search.beam_size = Int32(options.beamSize)
        }

        // `language` must outlive whisper_full, so hold the C string for the call.
        let status: Int32
        if let language = options.language {
            status = language.withCString { pointer in
                params.language = pointer
                return samples.withUnsafeBufferPointer { buffer in
                    whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
                }
            }
        } else {
            params.language = nil
            status = samples.withUnsafeBufferPointer { buffer in
                whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
            }
        }

        guard status == 0 else {
            throw SpeechRecognizerError.inferenceFailed("whisper_full returned \(status)")
        }

        let transcription = Self.collectTranscription(
            context: context,
            chunkStart: chunk.startTime,
            noSpeechThreshold: options.noSpeechThreshold,
            useDTW: options.useDTWTimestamps
        )

        // Final guard: if most words occupy no time, this is a hallucination over
        // non-speech audio, not a recitation. Report nothing rather than something wrong.
        guard !transcription.tokens.isEmpty else { return transcription }
        let timed = transcription.tokens.count { $0.duration > 0 }
        let fraction = Double(timed) / Double(transcription.tokens.count)
        guard fraction >= options.minimumTimedTokenFraction else { return .empty }

        return transcription
    }

    // MARK: - Token regrouping

    /// whisper emits BPE subword tokens; we need words with time spans.
    ///
    /// A new word begins at a token whose text starts with a space, so grouping on that
    /// boundary reconstructs words. Deriving each word's *span* then depends on which
    /// timestamp source is trustworthy:
    ///
    /// * **DTW** (`t_dtw`) is a single anchor per token — the moment it was emitted —
    ///   so a word runs from its own anchor to the next word's. This is the reliable
    ///   source for fine-tuned models, whose emitted timestamp tokens degrade.
    /// * **Emitted timestamps** (`t0`/`t1`) are already ranges, and are used when DTW
    ///   is off or produced nothing usable.
    private static func collectTranscription(
        context: OpaquePointer,
        chunkStart: TimeInterval,
        noSpeechThreshold: Float,
        useDTW: Bool
    ) -> Transcription {
        struct Word {
            /// Raw token bytes, decoded only once the word is complete.
            ///
            /// whisper's vocabulary is byte-level BPE, so a single Arabic character —
            /// three bytes in UTF-8 — is routinely split across two tokens. Decoding
            /// each token to a `String` on its own turns both halves into U+FFFD
            /// replacement characters, and the original bytes are gone: the word arrives
            /// at the matcher as "ب\u{FFFD}\u{FFFD}يتنا", matches nothing, and is
            /// reported as a mistake the reciter did not make.
            var bytes: [UInt8]
            var emittedStart: TimeInterval
            var emittedEnd: TimeInterval
            /// DTW anchor, if the model produced one.
            var anchor: TimeInterval?
            var probabilities: [Double]
        }

        var collected: [Word] = []
        var fullText = ""
        var pending: Word?
        var lastSegmentEnd: TimeInterval = chunkStart

        func flush() {
            guard var current = pending else { return }
            pending = nil
            // Decode once, with every byte of the word present.
            current.bytes = Array(
                String(decoding: current.bytes, as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces)
                    .utf8
            )
            guard !current.bytes.isEmpty else { return }
            collected.append(current)
        }

        let segmentCount = whisper_full_n_segments(context)
        for segmentIndex in 0..<segmentCount {
            // whisper's own judgement that this segment was not speech. `no_speech_thold`
            // only steers the decoder's temperature fallback — it does not stop the
            // segment being returned — so the filtering is ours to do.
            let noSpeechProbability = whisper_full_get_segment_no_speech_prob(context, segmentIndex)
            if noSpeechProbability > noSpeechThreshold { continue }

            if let raw = whisper_full_get_segment_text(context, segmentIndex) {
                fullText += String(cString: raw)
            }
            lastSegmentEnd = chunkStart + TimeInterval(whisper_full_get_segment_t1(context, segmentIndex)) / 100.0

            let tokenCount = whisper_full_n_tokens(context, segmentIndex)
            for tokenIndex in 0..<tokenCount {
                let id = whisper_full_get_token_id(context, segmentIndex, tokenIndex)
                // Special tokens (timestamps, <|endoftext|>, language tags) carry no text.
                if id >= whisper_token_eot(context) { continue }
                guard let raw = whisper_full_get_token_text(context, segmentIndex, tokenIndex) else { continue }
                var tokenBytes: [UInt8] = []
                var cursor = raw
                while cursor.pointee != 0 {
                    tokenBytes.append(UInt8(bitPattern: cursor.pointee))
                    cursor += 1
                }
                if tokenBytes.isEmpty { continue }

                let data = whisper_full_get_token_data(context, segmentIndex, tokenIndex)
                // All whisper timings are centiseconds relative to the chunk.
                let start = chunkStart + TimeInterval(data.t0) / 100.0
                let end = chunkStart + TimeInterval(data.t1) / 100.0
                let anchor: TimeInterval? = (useDTW && data.t_dtw >= 0)
                    ? chunkStart + TimeInterval(data.t_dtw) / 100.0
                    : nil

                // A word boundary is a leading space. Space is ASCII, so testing the
                // first byte is safe even mid-character — a continuation byte is never
                // 0x20.
                if tokenBytes.first == 0x20 || pending == nil {
                    flush()
                    pending = Word(
                        bytes: tokenBytes,
                        emittedStart: start,
                        emittedEnd: end,
                        anchor: anchor,
                        probabilities: [Double(data.p)]
                    )
                } else if var current = pending {
                    current.bytes.append(contentsOf: tokenBytes)
                    current.emittedEnd = max(current.emittedEnd, end)
                    current.probabilities.append(Double(data.p))
                    pending = current
                }
            }
        }
        flush()

        // Prefer DTW anchors only if the model actually produced a usable spread of
        // them; otherwise fall back to the emitted ranges.
        let anchors = collected.compactMap(\.anchor)
        let useAnchors = anchors.count == collected.count
            && collected.count > 1
            && (anchors.max()! - anchors.min()!) > 0.05

        let tokens = collected.enumerated().map { index, word -> TranscribedToken in
            let confidence = word.probabilities.isEmpty
                ? 0.0
                : word.probabilities.reduce(0, +) / Double(word.probabilities.count)

            let start: TimeInterval
            let end: TimeInterval
            if useAnchors, let anchor = word.anchor {
                start = anchor
                // A word runs until the next word begins; the last one runs to the end
                // of its segment.
                let next = index + 1 < collected.count ? collected[index + 1].anchor : nil
                end = max(anchor, next ?? max(lastSegmentEnd, anchor))
            } else {
                start = word.emittedStart
                end = max(word.emittedStart, word.emittedEnd)
            }

            return TranscribedToken(
                text: String(decoding: word.bytes, as: UTF8.self),
                startTime: start,
                endTime: end,
                confidence: min(max(confidence, 0), 1)
            )
        }

        return Transcription(
            text: fullText.trimmingCharacters(in: .whitespacesAndNewlines),
            tokens: tokens
        )
    }
}
