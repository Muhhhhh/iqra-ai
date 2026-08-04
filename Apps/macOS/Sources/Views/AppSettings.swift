import Foundation
import Observation
import RecitationCore

/// Where audio comes from while the recognizer is still stubbed.
enum InputSource: String, CaseIterable, Identifiable {
    /// Real `AVAudioEngine` capture. Needs microphone permission, which macOS only
    /// grants to a signed bundle — run via `scripts/run-macos.sh`, not `swift run`.
    case microphone
    /// Deterministic, no mic, no permission prompt. Exercises the UI on any machine.
    case scripted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .scripted: return "Scripted (no mic)"
        }
    }

    var help: String {
        switch self {
        case .microphone:
            return "Captures real audio and segments it with the VAD. Transcription is still scripted."
        case .scripted:
            return "Feeds synthetic silence through the pipeline on a fixed schedule."
        }
    }
}

/// Which voice activity detector splits the audio into segments.
enum VADKind: String, CaseIterable, Identifiable {
    /// Silero neural VAD via whisper.cpp.
    case silero
    /// RMS threshold fallback.
    case energy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .silero: return "Silero (neural)"
        case .energy: return "Energy (fallback)"
        }
    }
}

/// Which speech recognizer the pipeline runs.
enum RecognizerKind: String, CaseIterable, Identifiable {
    /// whisper.cpp with the GGML weights in `Models/`.
    case whisper
    /// Replays a canned transcript; ignores the audio entirely.
    case scripted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .whisper: return "Whisper (real)"
        case .scripted: return "Scripted (stub)"
        }
    }
}

/// What the stubbed recognizer "hears", so every verdict path is reachable in the UI.
enum MistakeStyle: String, CaseIterable, Identifiable {
    case clean
    case wrongWord
    case addedWord
    case skippedWord
    case skippedVerse

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clean: return "Perfect recitation"
        case .wrongWord: return "Wrong word"
        case .addedWord: return "Added word"
        case .skippedWord: return "Skipped word"
        case .skippedVerse: return "Skipped verse"
        }
    }

    var explanation: String {
        switch self {
        case .clean:
            return "Every word matches. The whole passage should end up green."
        case .wrongWord:
            return "One word replaced with an unrelated one — exactly that word should turn red."
        case .addedWord:
            return "An extra word inserted mid-passage. All expected words stay correct."
        case .skippedWord:
            return "One word omitted — its neighbours must stay correct."
        case .skippedVerse:
            return "A whole verse omitted. Reported as one skipped verse, not N skipped words."
        }
    }
}

/// App-wide configuration: passage choice, stub controls, and the real tuning knobs
/// that survive into v1 proper (alignment thresholds, VAD sensitivity, model size).
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    // Stub controls — these disappear once whisper.cpp lands.
    /// Defaults to the microphone: with `.scripted` the app marches through the whole
    /// passage on a timer without listening at all, which reads as "it heard me and I
    /// was perfect". That impression is exactly what this app must never give.
    var inputSource: InputSource = .microphone
    var mistakeStyle: MistakeStyle = .wrongWord

    /// Defaults to whisper when weights are present, so the app does real work out of
    /// the box and only falls back to the stub when there is no model to run.
    var recognizerKind: RecognizerKind = SpeechModelLocator.locate(.default) == nil ? .scripted : .whisper

    /// Where the weights were found, for display. Nil means none are installed.
    var locatedModel: SpeechModelLocator.Located? {
        SpeechModelLocator.locate(speechModel)
    }

    /// Silero VAD weights, if installed.
    var locatedVADModel: URL? { SpeechModelLocator.locateVAD() }

    /// True when the pipeline is actually listening to the user rather than replaying
    /// a script. Drives the warning banner.
    var isDoingRealRecognition: Bool {
        recognizerKind == .whisper && locatedModel != nil && inputSource == .microphone
    }

    // Real tuning, carried forward.
    var matchThreshold: Double = MatchingOptions.default.matchThreshold
    var uncertainThreshold: Double = MatchingOptions.default.uncertainThreshold
    var confidenceFloor: Double = MatchingOptions.default.confidenceFloor
    var vadKind: VADKind = SpeechModelLocator.locateVAD() == nil ? .energy : .silero
    var sileroThreshold: Double = Double(SileroVoiceActivityDetector.Options.default.speechThreshold)
    var energyThreshold: Double = Double(EnergyVoiceActivityDetector.Options.default.speechThreshold)
    var vadTrailingSilence: Double = SpeechSegmentAssembler.Options.default.trailingSilence
    var vadPreRoll: Double = SpeechSegmentAssembler.Options.default.preRoll
    /// Only ever set to a size that is actually installed — see `availableModelSizes`.
    var modelSize: SpeechModelConfiguration.Size = .base
    /// 1 is greedy decoding. Measured on the bundled fixture, beam search did not
    /// improve accuracy (11/15 at beam 1, 5 and 8; beam 3 was worse) and cost 60–110%
    /// more time — so greedy is the default. Exposed because that was measured on
    /// synthetic speech, and real recitation may behave differently.
    var beamSize: Int = 1

    /// How the page behaves while reciting: visible throughout, or filling in as you go.
    var practiceMode: PracticeMode = .review {
        didSet { if practiceMode != oldValue { invalidateComponents() } }
    }

    /// Silence that closes a segment, which is what sets how quickly words appear.
    ///
    /// Fog is the one mode where speed can be bought cheaply. Nothing is judged in it, so
    /// the accuracy that a long segment buys — whisper decodes a short fragment markedly
    /// worse, which is why the default is 1.6 s — is worth very little there. What matters
    /// instead is that the word appears while you are still on it. A quarter of a second
    /// of silence closes the segment, so the page keeps up with the reciter rather than
    /// trailing a breath behind.
    ///
    /// Fog Pro keeps the accurate setting: it reports skipped and misread words, and those
    /// verdicts are only worth having if the transcription behind them is.
    var segmentationTrailingSilence: Double {
        practiceMode == .fog ? min(0.25, vadTrailingSilence) : vadTrailingSilence
    }

    /// Cap on a segment's length, likewise shortened for Fog so a long phrase still
    /// reveals as it goes rather than all at once at the end.
    var segmentationMaximum: Double {
        practiceMode == .fog ? 3.0 : SpeechSegmentAssembler.Options.default.maximumSegmentDuration
    }

    /// Muṣḥaf page zoom. 1 fits the page to the window; above that the page view scrolls.
    var pageZoom: Double = 1.0
    /// Turn to the next page automatically when the reciter reaches the end of this one,
    /// so a long recitation does not have to be interrupted to click.
    var autoTurnPage: Bool = true
    /// Colour the letters each tajweed rule applies to. Derived from the text, so this
    /// is reliable regardless of what was recited.
    var showsTajweed: Bool = true
    /// Set the page in Uthman Taha's calligraphy.
    ///
    /// The trade is not cosmetic. In the QCF fonts a whole word is a single glyph, so
    /// there is no letter to colour — tajweed colouring is only possible on the Unicode
    /// setting. Colouring the entire word instead would say the rule applies to letters
    /// that do not carry it, which is the inaccuracy the per-letter colouring exists to
    /// remove.
    var prefersCalligraphicPage: Bool = true
    /// Check the length of elongations against the recitation.
    ///
    /// Judge madd and qalqalah from the recitation.
    ///
    /// Persisted, like every other tajweed setting here. They were not, and only
    /// `keepsSessionAudio` survived a relaunch, so a reciter who turned checking on found
    /// it silently off next time they opened the app — and a session recorded in between
    /// carried no tajweed verdicts at all with no indication why.
    var analysesTajweedAudio: Bool = false {
        didSet { UserDefaults.standard.set(analysesTajweedAudio, forKey: "analysesTajweedAudio") }
    }
    /// Also report vowels held longer than the text asks for.
    ///
    /// Off by default: measured, it is wrong about four and a half times for every time
    /// it is right, and reciters stretch vowels for reasons the text does not record.
    var flagsOverlongVowels: Bool = false {
        didSet {
            cachedTajweedAnalyzer = nil
            UserDefaults.standard.set(flagsOverlongVowels, forKey: "flagsOverlongVowels")
        }
    }
    /// How far short an elongation must fall before it is questioned.
    ///
    /// Exposed because the right value depends on the voice and the microphone, and every
    /// number behind the default was measured on studio recordings of a qārī. Lower is
    /// quieter.
    var maddShortfall: Double = 0.8 {
        didSet {
            cachedTajweedAnalyzer = nil
            UserDefaults.standard.set(maddShortfall, forKey: "maddShortfall")
        }
    }
    /// Also judge ghunnah and qalqalah from the pronunciation model.
    ///
    /// Off, and measured to be near-useless: with a ghunnah's audio removed entirely the
    /// heads caught 2.7% while questioning 67 correct ones. Exposed rather than hidden
    /// because it is the reciter's call whether to see an unreliable opinion, but the
    /// numbers go on the switch so the call is an informed one.
    var judgesSifatFromAudio: Bool = false {
        didSet {
            cachedTajweedAnalyzer = nil
            UserDefaults.standard.set(judgesSifatFromAudio, forKey: "judgesSifatFromAudio")
        }
    }

    /// Ask the audio about words the matcher doubted, and clear the ones it supports.
    ///
    /// On by default when the model is installed: measured over nine passages it removes
    /// a fifth of the falsely flagged words without costing any detection. It doubles
    /// inference time — still around 25× faster than real time — and keeps the
    /// pronunciation model resident.
    var confirmsWordsWithAudio: Bool = true

    /// Keep this session's audio and verdicts on disk.
    ///
    /// Off, and it stays off until asked for. Nothing is uploaded — a WAV and a JSON land
    /// in Application Support and stay there. It is here because every threshold in this
    /// app is fitted to studio recordings of qurrāʾ who do not make the mistakes it exists
    /// to catch, and no amount of further tuning against those recordings fixes that.
    var keepsSessionAudio: Bool = false {
        didSet { UserDefaults.standard.set(keepsSessionAudio, forKey: Self.keepsAudioKey) }
    }
    static let keepsAudioKey = "keepsSessionAudio"

    var recordingsDirectory: URL? { SessionRecorder.defaultDirectory() }

    /// How many sessions are kept, and how much room they take.
    var savedRecordings: (count: Int, megabytes: Double) {
        guard let directory = recordingsDirectory,
              let files = try? FileManager.default.contentsOfDirectory(
                  at: directory, includingPropertiesForKeys: [.fileSizeKey]
              )
        else { return (0, 0) }
        let audio = files.filter { $0.pathExtension == "wav" }
        let bytes = files.reduce(0) {
            $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return (audio.count, Double(bytes) / 1e6)
    }
    /// The phoneme script the confirmation needs.
    var locatedPhonemeScript: URL? { PhonemeScript.locate() }
    var canConfirmWordsWithAudio: Bool { hasNeuralTajweed && locatedPhonemeScript != nil }

    /// The converted Muaalem package, if present.
    var locatedTajweedModel: URL? { MuaalemTajweedAnalyzer.locateModel() }
    /// The exported feature front-end the model needs.
    var locatedTajweedFrontend: URL? { MuaalemFeatures.locate() }
    /// True when the neural verifier is available rather than the duration fallback.
    var hasNeuralTajweed: Bool { locatedTajweedModel != nil && locatedTajweedFrontend != nil }

    /// Reference reciter. Al-Husary's murattal is the usual standard for learners, so it
    /// is the default.
    var reciterID: String = Reciter.husary.id
    var reciter: Reciter {
        Reciter.catalogue.first { $0.id == reciterID } ?? .husary
    }
    /// Offer the reciter's audio for an āyah that was flagged.
    var offersReciterOnMistake: Bool = true

    /// Set by the view when a passage loads; the scripted transcript is derived from it.
    var target: RecitationTarget?

    private init() {
        let defaults = UserDefaults.standard
        keepsSessionAudio = defaults.bool(forKey: Self.keepsAudioKey)
        analysesTajweedAudio = defaults.bool(forKey: "analysesTajweedAudio")
        flagsOverlongVowels = defaults.bool(forKey: "flagsOverlongVowels")
        judgesSifatFromAudio = defaults.bool(forKey: "judgesSifatFromAudio")
        if let stored = defaults.object(forKey: "maddShortfall") as? Double {
            maddShortfall = stored
        }
    }

    // MARK: - Component reuse
    //
    // The recogniser holds ~78 MB of weights and the Core ML encoder compiles for the
    // Neural Engine on first use. Rebuilding both for every session made "stop, try
    // again" pause for about a second each time, which reads as the app refusing to
    // let you retry. They are reused across sessions instead, and rebuilt only when a
    // setting that actually affects them changes.

    /// Identity of the components currently cached.
    private struct ComponentKey: Equatable {
        var modelURL: URL?
        var vadURL: URL?
        var beamSize: Int
        var sileroThreshold: Double
        var trailingSilence: Double
        var maximumSegment: Double
        var preRoll: Double
        var vadKind: VADKind
    }

    private var cachedKey: ComponentKey?
    private var cachedRecognizer: WhisperSpeechRecognizer?
    /// Reused across sessions so the reciter's own pace survives pressing Stop.
    ///
    /// Madd is judged against the reciter's two-count elongations, and a fresh analyzer
    /// starts with none — so on a short take nothing was ever examined, and the coverage
    /// line said so without explaining why.
    private var cachedTajweedAnalyzer: (any TajweedAnalyzer)?
    private var cachedVAD: SileroVoiceActivityDetector?

    private var currentKey: ComponentKey {
        ComponentKey(
            modelURL: locatedModel?.url,
            vadURL: locatedVADModel,
            beamSize: beamSize,
            sileroThreshold: sileroThreshold,
            trailingSilence: segmentationTrailingSilence,
            maximumSegment: segmentationMaximum,
            preRoll: vadPreRoll,
            vadKind: vadKind
        )
    }

    /// Drop cached components so the next session rebuilds them.
    func invalidateComponents() {
        cachedKey = nil
        cachedRecognizer = nil
        cachedVAD = nil
        cachedTajweedAnalyzer = nil
    }

    /// Release the models and their Metal resources, and wait for it.
    ///
    /// Called before the app terminates. ggml tears down its Metal device from a static
    /// destructor at process exit, and aborts if a context is still alive — which shows
    /// up as a crash report on every quit. Caching the recogniser across sessions (so
    /// retrying is instant) is what made those contexts outlive the app.
    func releaseComponents() async {
        if let recognizer = cachedRecognizer { await recognizer.unloadModel() }
        if let vad = cachedVAD { await vad.unloadModel() }
        invalidateComponents()
    }

    var alignmentOptions: MatchingOptions {
        MatchingOptions(
            matchThreshold: matchThreshold,
            uncertainThreshold: min(uncertainThreshold, matchThreshold),
            confidenceFloor: confidenceFloor
        )
    }

    var speechModel: SpeechModelConfiguration {
        SpeechModelConfiguration(size: modelSize)
    }

    /// Sizes with weights on disk. Anything else would silently degrade to the stub.
    var availableModelSizes: [SpeechModelConfiguration.Size] {
        SpeechModelLocator.installedSizes()
    }

    /// Pull `modelSize` back to something installed.
    ///
    /// Guards the case where weights are removed between launches, or a stale preference
    /// names a size that was never built.
    func clampModelSizeToInstalled() {
        let available = availableModelSizes
        guard !available.isEmpty, !available.contains(modelSize) else { return }
        modelSize = available.contains(.base) ? .base : available[0]
        invalidateComponents()
    }

    func resetTuningToDefaults() {
        let defaults = MatchingOptions.default
        matchThreshold = defaults.matchThreshold
        uncertainThreshold = defaults.uncertainThreshold
        confidenceFloor = defaults.confidenceFloor
        sileroThreshold = Double(SileroVoiceActivityDetector.Options.default.speechThreshold)
        energyThreshold = Double(EnergyVoiceActivityDetector.Options.default.speechThreshold)
        vadTrailingSilence = SpeechSegmentAssembler.Options.default.trailingSilence
        vadPreRoll = SpeechSegmentAssembler.Options.default.preRoll
    }

    // MARK: - Pipeline assembly

    /// Builds a fresh pipeline for one session from the current settings.
    ///
    /// This is the only place the concrete components are named. Steps 2–4 swap the
    /// recognizer and VAD here and nothing else in the app changes.
    func makePipeline() -> RecitationPipeline {
        if cachedKey != currentKey { invalidateComponents() }
        cachedKey = currentKey
        return RecitationPipeline(
            components: PipelineComponents(
                capture: makeCapture(),
                vad: makeVAD(),
                recognizer: makeRecognizer(),
                aligner: TokenAligner(options: alignmentOptions),
                tajweed: makeTajweedAnalyzer(),
                scorer: makePronunciationScorer(),
                recorder: makeRecorder()
            )
        )
    }

    private func makeRecorder() -> SessionRecorder? {
        guard keepsSessionAudio, let directory = recordingsDirectory else { return nil }
        return SessionRecorder(directory: directory)
    }

    private func makePronunciationScorer() -> PronunciationScorer? {
        // Likewise: it exists to suppress false flags, and Fog raises none.
        guard practiceMode.reportsMistakes,
              confirmsWordsWithAudio,
              let model = locatedTajweedModel,
              let frontend = locatedTajweedFrontend,
              let scriptURL = locatedPhonemeScript,
              let features = try? MuaalemFeatures(resourceURL: frontend),
              let script = try? PhonemeScript(contentsOf: scriptURL)
        else { return nil }
        return PronunciationScorer(
            model: MuaalemTajweedAnalyzer(modelURL: model, features: features),
            script: script
        )
    }

    private func makeTajweedAnalyzer() -> any TajweedAnalyzer {
        // Fog reports nothing, so running the pronunciation model over every segment
        // would be latency spent on a result no one sees — and latency is the whole
        // point of that mode.
        guard analysesTajweedAudio, practiceMode.reportsMistakes else { return NoOpTajweedAnalyzer() }
        if let cachedTajweedAnalyzer { return cachedTajweedAnalyzer }
        let built = buildTajweedAnalyzer()
        cachedTajweedAnalyzer = built
        return built
    }

    private func buildTajweedAnalyzer() -> any TajweedAnalyzer {
        // The neural verifier when it is installed; duration measurement otherwise. The
        // fallback can only speak about madd length, which the UI says.
        if let model = locatedTajweedModel,
           let frontend = locatedTajweedFrontend,
           let features = try? MuaalemFeatures(resourceURL: frontend) {
            // Forced alignment, and madd only — see `AlignedTajweedAnalyzer`. The ṣifāt
            // heads were measured not to report what they heard, so nothing is built on
            // them.
            if let scriptURL = locatedPhonemeScript,
               let script = try? PhonemeScript(contentsOf: scriptURL) {
                return AlignedTajweedAnalyzer(
                    model: MuaalemTajweedAnalyzer(modelURL: model, features: features),
                    script: script,
                    options: .init(
                        maddShortfall: maddShortfall,
                        flagsOverlongVowels: flagsOverlongVowels,
                        judgesSifat: judgesSifatFromAudio
                    )
                )
            }
            return DSPTajweedAnalyzer()
        }
        return DSPTajweedAnalyzer()
    }

    private func makeRecognizer() -> any SpeechRecognizer {
        // Falls back to the stub when no weights are installed, rather than failing to
        // start — but `isDoingRealRecognition` reports the truth to the UI either way.
        // The stub is never cached: it holds a cursor into its canned transcript.
        guard recognizerKind == .whisper, let located = locatedModel else {
            return ScriptedSpeechRecognizer(transcript: scriptedTranscript, segmentCount: 3)
        }
        if let cachedRecognizer { return cachedRecognizer }
        let recognizer = WhisperSpeechRecognizer(
            modelURL: located.url,
            options: .init(
                beamSize: beamSize,
                // Must follow the weights, or word timings come out wrong and the
                // degenerate-timing guard throws away whole transcriptions.
                alignmentHeads: .matching(modelSize)
            )
        )
        cachedRecognizer = recognizer
        return recognizer
    }

    private func makeCapture() -> any AudioCapture {
        switch inputSource {
        case .microphone:
            return EngineAudioCapture(session: PassthroughAudioSessionController())
        case .scripted:
            return ScriptedAudioCapture.silence(chunkCount: 3, chunkDuration: 2.0)
        }
    }

    private func makeVAD() -> any VoiceActivityDetector {
        guard inputSource == .microphone else {
            // One segment per synthetic chunk keeps the demo run fully deterministic.
            return PassthroughVoiceActivityDetector()
        }

        let segmentation = SpeechSegmentAssembler.Options(
            trailingSilence: segmentationTrailingSilence,
            maximumSegmentDuration: segmentationMaximum,
            preRoll: vadPreRoll
        )

        if vadKind == .silero, let vadModel = locatedVADModel {
            if let cachedVAD { return cachedVAD }
            // Safe to reuse: the pipeline resets the detector when a session starts,
            // which clears the LSTM state.
            let vad = SileroVoiceActivityDetector(
                modelURL: vadModel,
                options: .init(speechThreshold: Float(sileroThreshold), segmentation: segmentation)
            )
            cachedVAD = vad
            return vad
        }
        return EnergyVoiceActivityDetector(
            options: .init(speechThreshold: Float(energyThreshold), segmentation: segmentation)
        )
    }

    /// Derives the fake transcript from the real target text, mutated per `mistakeStyle`.
    /// Deriving rather than hardcoding means it keeps working when the passage changes.
    private var scriptedTranscript: String {
        guard let target else { return "" }
        var words = target.flattenedWords.map(\.text)
        guard words.count > 4 else { return words.joined(separator: " ") }

        switch mistakeStyle {
        case .clean:
            break
        case .wrongWord:
            words[words.count / 2] = "قَالَ"
        case .addedWord:
            words.insert("ثُمَّ", at: words.count / 2)
        case .skippedWord:
            words.remove(at: words.count / 2)
        case .skippedVerse:
            let verses = target.verses
            guard verses.count > 1 else { break }
            let skipIndex = min(1, verses.count - 1)
            words = verses.enumerated()
                .filter { $0.offset != skipIndex }
                .flatMap { $0.element.words.map(\.text) }
        }
        return words.joined(separator: " ")
    }
}
