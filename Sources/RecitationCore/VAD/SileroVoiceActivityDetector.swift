import CWhisper
import Foundation

/// Silero VAD, running through whisper.cpp's ggml implementation.
///
/// Replaces `EnergyVoiceActivityDetector`. An energy gate cannot tell a held vowel from
/// a quiet passage, and cannot tell speech from noise at all — recitation has long quiet
/// stretches that a bare RMS threshold cuts in the wrong places, and rejecting non-speech
/// is precisely what stops the recognizer inventing words over room noise.
///
/// Uses the streaming entry point (`whisper_vad_detect_speech_no_reset`), which carries
/// the LSTM state across calls. `reset()` clears it, which matters between sessions: a
/// stale hidden state would colour the start of the next recitation.
public actor SileroVoiceActivityDetector: VoiceActivityDetector {

    public struct Options: Sendable {
        /// Probability above which a window counts as speech.
        ///
        /// Silero's own default is 0.5. This sits lower because the cost here is
        /// asymmetric: dropping the quiet onset of a word truncates it and produces a
        /// fabricated "wrong word", whereas letting a little extra audio through costs
        /// only a few milliseconds of inference. The segment assembler's minimum
        /// duration discards anything genuinely spurious.
        public var speechThreshold: Float
        public var segmentation: SpeechSegmentAssembler.Options
        public var threadCount: Int

        public init(
            speechThreshold: Float = 0.35,
            segmentation: SpeechSegmentAssembler.Options = .default,
            threadCount: Int = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount - 2))
        ) {
            self.speechThreshold = speechThreshold
            self.segmentation = segmentation
            self.threadCount = threadCount
        }

        public static let `default` = Options()
    }

    /// Owns the VAD context pointer so it is freed deterministically — Swift 6 forbids
    /// touching actor state from a nonisolated `deinit`, so the actor cannot free it
    /// itself. Only the actor ever dereferences this.
    private final class Context: @unchecked Sendable {
        let pointer: OpaquePointer
        init(pointer: OpaquePointer) { self.pointer = pointer }
        deinit { whisper_vad_free(pointer) }
    }

    private let modelURL: URL
    private let options: Options
    private var context: Context?
    /// Samples not yet forming a whole analysis window.
    private var pending: [Float] = []
    /// Session time of `pending[0]`.
    private var pendingStart: TimeInterval = 0
    private var hasPendingStart = false
    private var assembler: SpeechSegmentAssembler
    /// Analysis window length, read from the model rather than assumed.
    private var windowSize = 512

    public init(modelURL: URL, options: Options = .default) {
        self.modelURL = modelURL
        self.options = options
        self.assembler = SpeechSegmentAssembler(options: options.segmentation)
    }

    // MARK: - Model lifecycle

    public func loadModel() throws {
        guard context == nil else { return }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw VoiceActivityDetectorError.modelUnavailable(
                "no VAD model at \(modelURL.path). Run scripts/fetch-vad-model.sh."
            )
        }

        var params = whisper_vad_default_context_params()
        params.n_threads = Int32(options.threadCount)
        // The model is ~1 MB and runs per 32 ms window; dispatching that to the GPU
        // costs more in latency than it saves.
        params.use_gpu = false

        guard let loaded = whisper_vad_init_from_file_with_params(modelURL.path, params) else {
            throw VoiceActivityDetectorError.modelUnavailable("failed to load \(modelURL.lastPathComponent)")
        }
        let context = Context(pointer: loaded)
        self.context = context
        windowSize = Self.discoverWindowSize(context.pointer)
    }

    public var isLoaded: Bool { context != nil }

    /// Release the model and its Metal resources.
    ///
    /// Must be called before the process exits. ggml frees its Metal device from a
    /// static destructor at exit; if a context is still alive at that point the teardown
    /// aborts, which the user sees as a crash report every time they quit.
    public func unloadModel() {
        context = nil
    }

    /// The window length is stored in the model file and not exposed by the C API, so
    /// probe for it: feed a known number of samples and see how many probabilities come
    /// back. Assuming Silero's usual 512 would silently misalign timing if the bundled
    /// model ever changed.
    private static func discoverWindowSize(_ context: OpaquePointer) -> Int {
        let probeLength = 4096
        let silence = [Float](repeating: 0, count: probeLength)
        let ok = silence.withUnsafeBufferPointer { buffer in
            whisper_vad_detect_speech_no_reset(context, buffer.baseAddress, Int32(probeLength))
        }
        let count = ok ? Int(whisper_vad_n_probs(context)) : 0
        whisper_vad_reset_state(context)
        guard count > 0, probeLength % count == 0 else { return 512 }
        return probeLength / count
    }

    // MARK: - VoiceActivityDetector

    public func process(_ frame: AudioChunk) async -> [AudioChunk] {
        guard !frame.isEmpty else { return [] }
        do {
            try loadModel()
        } catch {
            // Without a model there is nothing sane to do here. Emitting the frame
            // unsegmented would hand raw audio to the recognizer; emitting nothing at
            // least fails silently rather than fabricating a transcription.
            return []
        }
        guard let context = context?.pointer else { return [] }

        if !hasPendingStart {
            pendingStart = frame.startTime
            hasPendingStart = true
        }
        pending.append(contentsOf: frame.samples)

        // Only whole windows are analysed; a partial window is padded internally, which
        // would misalign every subsequent timestamp.
        let wholeWindows = pending.count / windowSize
        guard wholeWindows > 0 else { return [] }

        let analysedCount = wholeWindows * windowSize
        let analysed = Array(pending[0..<analysedCount])
        let analysedStart = pendingStart

        pending.removeFirst(analysedCount)
        pendingStart += TimeInterval(analysedCount) / frame.sampleRate

        let ok = analysed.withUnsafeBufferPointer { buffer in
            whisper_vad_detect_speech_no_reset(context, buffer.baseAddress, Int32(analysedCount))
        }
        guard ok else { return [] }

        let probabilityCount = Int(whisper_vad_n_probs(context))
        guard probabilityCount > 0, let probabilities = whisper_vad_probs(context) else { return [] }

        var emitted: [AudioChunk] = []
        for index in 0..<min(probabilityCount, wholeWindows) {
            let start = index * windowSize
            let window = AudioChunk(
                samples: Array(analysed[start..<(start + windowSize)]),
                sampleRate: frame.sampleRate,
                startTime: analysedStart + TimeInterval(start) / frame.sampleRate
            )
            emitted += assembler.consume(window, isSpeech: probabilities[index] >= options.speechThreshold)
        }
        return emitted
    }

    public func pending() async -> AudioChunk? { assembler.pending }

    public func flush() async -> AudioChunk? {
        // Whatever is left in `pending` is shorter than one window (<32 ms) and cannot
        // be analysed, so it is dropped rather than guessed at.
        pending.removeAll(keepingCapacity: true)
        hasPendingStart = false
        return assembler.flush()
    }

    public func reset() async {
        pending.removeAll(keepingCapacity: true)
        hasPendingStart = false
        assembler.reset()
        if let context = context?.pointer {
            // Clear the LSTM state so the next session does not inherit this one's.
            whisper_vad_reset_state(context)
        }
    }
}

public enum VoiceActivityDetectorError: Error, Sendable, Equatable {
    case modelUnavailable(String)
}
