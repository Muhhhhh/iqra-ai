import Foundation
import Observation

/// Main-actor view state for a recitation session, shared by both app shells.
///
/// This is the whole surface a UI needs: set a target, call `start`/`stop`, render
/// `words`. Keeping it here (rather than in each shell) is what lets the iOS and
/// macOS apps stay thin and gain features — including v2 tajweed — at the same time.
@MainActor
@Observable
public final class RecitationSessionModel {
    public private(set) var state: PipelineState = .idle
    /// Per-word verdicts for the current target. Drives the highlighting.
    public private(set) var words: [WordEvaluation] = []
    public private(set) var insertions: [InsertedWord] = []
    public private(set) var tajweedNotes: [TajweedNote] = []
    /// How much of the passage's tajweed was actually examined — see `TajweedCoverage`.
    public private(set) var tajweedCoverage: TajweedCoverage = .none
    public private(set) var transcript: String = ""
    public private(set) var level: Float = 0
    /// True when the input has been clipping recently.
    ///
    /// Worth surfacing because it is both invisible and severe: clipping cost more
    /// accuracy in testing than heavy background noise, and the fix — move back from the
    /// mic, or turn the input gain down — is trivial once you know.
    public private(set) var isClipping = false
    private var clippingUntil: Date?
    public private(set) var errorMessage: String?
    public private(set) var target: RecitationTarget?
    /// Retained after a session ends — audio and timestamps for v2 analysis and replay.
    public private(set) var segments: [AlignedAudioSegment] = []

    private var pipeline: RecitationPipeline?
    private var eventTask: Task<Void, Never>?
    /// Tracks an in-flight `stop()`. Starting again must wait for it: the pipeline
    /// finishes asynchronously, and without this a Start pressed during `.finishing`
    /// was silently dropped — which reads as the app refusing to let you try again.
    private var stopTask: Task<Void, Never>?
    private let makePipeline: @MainActor () -> RecitationPipeline

    /// - Parameter makePipeline: called once per session. A fresh pipeline per run keeps
    ///   the scripted recognizer's cursor and the VAD buffer from leaking between takes.
    public init(makePipeline: @escaping @MainActor () -> RecitationPipeline) {
        self.makePipeline = makePipeline
    }

    public var isRunning: Bool {
        switch state {
        case .starting, .listening, .interrupted, .finishing: return true
        case .idle, .stopped: return false
        }
    }

    public var mistakeCount: Int { words.count(where: { $0.status.isMistake }) }
    public var correctCount: Int { words.count(where: { $0.status == .correct }) }

    public func setTarget(_ target: RecitationTarget) {
        guard !isRunning else { return }
        self.target = target
        // Render the text immediately, before any audio arrives.
        words = TokenAligner().align(heard: [], against: target, isFinal: false).words
        insertions = []
        tajweedNotes = []
        tajweedCoverage = .none
        transcript = ""
        segments = []
        errorMessage = nil
    }

    public func start() {
        guard let target else { return }
        // Not `guard !isRunning`: a Start pressed while the previous session is still
        // finishing should queue behind it rather than be discarded.
        guard state != .starting, state != .listening else { return }

        let pendingStop = stopTask
        errorMessage = nil
        insertions = []
        tajweedNotes = []
        tajweedCoverage = .none
        transcript = ""
        segments = []

        eventTask?.cancel()
        eventTask = Task { [weak self] in
            await pendingStop?.value
            guard !Task.isCancelled, let self else { return }

            let pipeline = self.makePipeline()
            self.pipeline = pipeline
            let stream = await pipeline.events()
            await pipeline.start(target: target)
            for await event in stream {
                self.apply(event)
            }
        }
    }

    public func stop() {
        guard isRunning, let pipeline else { return }
        stopTask = Task { await pipeline.stop() }
    }

    /// Discard the current attempt and start listening again from the top.
    ///
    /// Practising means re-reciting the same passage repeatedly, so this is the common
    /// action, not an edge case.
    public func retry() {
        stop()
        clearResults()
        start()
    }

    private func clearResults() {
        insertions = []
        tajweedNotes = []
        tajweedCoverage = .none
        transcript = ""
        segments = []
        level = 0
        if let target {
            words = TokenAligner().align(heard: [], against: target, isFinal: false).words
        }
    }

    /// Continue the session against a new passage — the next muṣḥaf page.
    ///
    /// The finished page's recording is discarded along with its verdicts: it belongs to
    /// a passage no longer on screen, and keeping it would grow without bound across a
    /// long recitation.
    public func retarget(_ newTarget: RecitationTarget) {
        target = newTarget
        insertions = []
        segments = []
        transcript = ""
        tajweedNotes = []
        words = TokenAligner().align(heard: [], against: newTarget, isFinal: false).words
        guard let pipeline, isRunning else { return }
        Task { await pipeline.retarget(newTarget) }
    }

    /// What a passage was marked as, without the audio behind it.
    ///
    /// Enough to put the highlighting back on a page you turned away from, and small
    /// enough to keep: the recording itself — the segments, which are by far the bulk —
    /// is deliberately not part of this.
    public struct SessionResults: Sendable {
        public var words: [WordEvaluation]
        public var insertions: [InsertedWord]
        public var tajweedNotes: [TajweedNote]
        public var transcript: String

        /// False when nothing was recited, so there is nothing worth putting back.
        public var isEmpty: Bool {
            words.allSatisfy { $0.status == .notYetRecited } && insertions.isEmpty
        }
    }

    public var results: SessionResults {
        SessionResults(
            words: words,
            insertions: insertions,
            tajweedNotes: tajweedNotes,
            transcript: transcript
        )
    }

    /// Put a previous passage's marks back on screen.
    ///
    /// Only valid between sessions: while the pipeline is running the verdicts belong to
    /// the passage being recited, and overwriting them would show one page's marks
    /// against another's text.
    public func restore(_ results: SessionResults, for target: RecitationTarget) {
        guard !isRunning else { return }
        self.target = target
        words = results.words
        insertions = results.insertions
        tajweedNotes = results.tajweedNotes
        transcript = results.transcript
        // The audio is gone — it was discarded when the page turned — so nothing here
        // can be replayed or re-analysed. The marks are a record, not a live session.
        segments = []
        errorMessage = nil
    }

    /// True once the reciter has reached the end of the current passage.
    public var hasReachedEnd: Bool {
        AlignmentResult(words: words, insertions: insertions, isFinal: false).hasReachedEnd()
    }

    public func reset() {
        eventTask?.cancel()
        eventTask = nil
        stopTask = nil
        pipeline = nil
        state = .idle
        level = 0
        if let target { setTarget(target) }
    }

    private func apply(_ event: PipelineEvent) {
        switch event {
        case .stateChanged(let newState):
            state = newState
            if newState == .stopped {
                level = 0
                isClipping = false
                clippingUntil = nil
            }

        case .level(let rms, let peak):
            level = rms
            // Hold the warning briefly so a momentary peak is actually visible.
            if peak >= 0.98 { clippingUntil = Date().addingTimeInterval(1.5) }
            isClipping = (clippingUntil.map { $0 > Date() }) ?? false

        case .segment(let segment):
            segments.append(segment)
            let text = segment.transcription.text
            guard !text.isEmpty else { return }
            transcript = transcript.isEmpty ? text : transcript + " " + text

        case .alignment(let alignment):
            words = alignment.words
            insertions = alignment.insertions

        case .tajweed(let notes, let coverage):
            tajweedNotes = notes
            tajweedCoverage = coverage

        case .finished(let result):
            words = result.alignment.words
            insertions = result.alignment.insertions
            segments = result.segments
            tajweedNotes = result.tajweedNotes
            tajweedCoverage = result.tajweedCoverage

        case .failed(let failure):
            errorMessage = "\(failure.stage.rawValue): \(failure.message)"
        }
    }
}
