import Foundation

/// Everything the pipeline needs, injected. No component is constructed internally,
/// so swapping the stub recognizer for whisper.cpp (step 2/3) or the energy VAD for
/// Silero (step 4) is a call-site change and nothing more.
public struct PipelineComponents: Sendable {
    public var capture: any AudioCapture
    public var vad: any VoiceActivityDetector
    public var recognizer: any SpeechRecognizer
    public var aligner: TokenAligner
    public var tajweed: any TajweedAnalyzer

    public init(
        capture: any AudioCapture,
        vad: any VoiceActivityDetector,
        recognizer: any SpeechRecognizer,
        aligner: TokenAligner = TokenAligner(),
        tajweed: any TajweedAnalyzer = NoOpTajweedAnalyzer()
    ) {
        self.capture = capture
        self.vad = vad
        self.recognizer = recognizer
        self.aligner = aligner
        self.tajweed = tajweed
    }
}

/// Drives capture → VAD → ASR → alignment and publishes events.
///
/// An actor, so all mutable session state is isolated and inference stays off the
/// main thread. The UI shells only touch `events` and `start`/`stop`.
public actor RecitationPipeline {
    private let components: PipelineComponents

    private var target: RecitationTarget?
    private var segments: [AlignedAudioSegment] = []
    /// Every token heard so far, across all segments — alignment is always recomputed
    /// against the full history, not per segment, so a word skipped early can still be
    /// re-explained once more context arrives.
    private var heardTokens: [TranscribedToken] = []
    private var state: PipelineState = .idle
    private var captureTask: Task<Void, Never>?
    private var continuation: AsyncStream<PipelineEvent>.Continuation?

    public init(components: PipelineComponents) {
        self.components = components
    }

    /// Convenience for the v1 demo: real mic, energy VAD, scripted transcript.
    public static func stubbed(
        transcript: String,
        segmentCount: Int = 3,
        capture: (any AudioCapture)? = nil
    ) -> RecitationPipeline {
        RecitationPipeline(
            components: PipelineComponents(
                capture: capture ?? EngineAudioCapture(session: PassthroughAudioSessionController()),
                vad: EnergyVoiceActivityDetector(),
                recognizer: ScriptedSpeechRecognizer(transcript: transcript, segmentCount: segmentCount),
                aligner: TokenAligner(),
                tajweed: NoOpTajweedAnalyzer()
            )
        )
    }

    /// Event stream for the UI. Call before `start()`.
    public func events() -> AsyncStream<PipelineEvent> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            self.continuation = continuation
        }
    }

    public func start(target: RecitationTarget) async {
        guard state == .idle || state == .stopped else { return }

        self.target = target
        segments = []
        heardTokens = []
        await components.vad.reset()
        transition(to: .starting)

        let stream: AsyncStream<AudioChunk>
        do {
            stream = try await components.capture.start()
        } catch {
            emit(.failed(PipelineFailure(stage: .capture, message: String(describing: error))))
            transition(to: .stopped)
            return
        }

        transition(to: .listening)
        // Publish an initial all-`notYetRecited` alignment so the UI can render the
        // target text immediately rather than waiting for the first segment.
        emit(.alignment(components.aligner.align(heard: [], against: target, isFinal: false)))

        captureTask = Task { [weak self] in
            for await frame in stream {
                guard let self else { return }
                await self.handle(frame: frame)
            }
        }
    }

    /// Switch to a new passage without interrupting capture.
    ///
    /// Used when the muṣḥaf turns to the next page mid-recitation.
    ///
    /// Everything belonging to the finished page is discarded: the heard tokens, because
    /// carrying them over would have the aligner trying to explain the old page's words
    /// with the new page's text, and the retained audio, which is both meaningless to the
    /// new page and unbounded — 16 kHz mono float is about 3.8 MB a minute, so a long
    /// session that never cleared would grow without limit.
    public func retarget(_ newTarget: RecitationTarget) async {
        guard state == .listening || state == .starting else { return }
        target = newTarget
        heardTokens = []
        segments = []
        await components.vad.reset()
        emit(.alignment(components.aligner.align(heard: [], against: newTarget, isFinal: false)))
    }

    public func stop() async {
        guard state == .listening || state == .interrupted || state == .starting else { return }
        transition(to: .finishing)

        await components.capture.stop()
        captureTask?.cancel()
        captureTask = nil

        // Don't lose the tail: whatever the VAD still holds is a real segment.
        if let tail = await components.vad.flush() {
            await process(segment: tail)
        }

        guard let target else {
            transition(to: .stopped)
            return
        }

        let alignment = components.aligner.align(heard: heardTokens, against: target, isFinal: true)
        emit(.alignment(alignment))

        // v1: no-op. The seam is live so v2 lands without touching the pipeline.
        let notes = await components.tajweed.analyze(segments: segments, target: target)

        emit(.finished(
            RecitationResult(
                target: target,
                alignment: alignment,
                segments: segments,
                tajweedNotes: notes
            )
        ))
        transition(to: .stopped)
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Frame handling

    private func handle(frame: AudioChunk) async {
        emit(.level(rms: min(1.0, frame.rms * 12), peak: frame.peak))
        for segment in await components.vad.process(frame) {
            await process(segment: segment)
        }
    }

    private func process(segment: AudioChunk) async {
        guard let target else { return }

        let transcription: Transcription
        do {
            transcription = try await components.recognizer.transcribe(segment)
        } catch {
            emit(.failed(PipelineFailure(stage: .recognition, message: String(describing: error))))
            return
        }
        guard !transcription.tokens.isEmpty else { return }

        heardTokens.append(contentsOf: transcription.tokens)
        let alignment = components.aligner.align(heard: heardTokens, against: target, isFinal: false)

        // Attribute the verdicts whose audio falls inside this segment, so the segment
        // carries its own word list — that pairing is what v2 tajweed consumes.
        let words = alignment.words.filter { evaluation in
            guard let range = evaluation.timeRange else { return false }
            return range.lowerBound < segment.endTime && range.upperBound > segment.startTime
        }

        let aligned = AlignedAudioSegment(
            audio: segment,
            transcription: transcription,
            words: words
        )
        segments.append(aligned)

        emit(.segment(aligned))
        emit(.alignment(alignment))
    }

    // MARK: - Plumbing

    private func transition(to newState: PipelineState) {
        guard state != newState else { return }
        state = newState
        emit(.stateChanged(newState))
    }

    private func emit(_ event: PipelineEvent) {
        continuation?.yield(event)
    }
}
