#if canImport(CoreML)
import CoreML
import Foundation

/// Verifies tajweed against the Muaalem pronunciation model.
///
/// `obadx/muaalem-model-v3_2` (MIT, arXiv 2509.00094) is a Wav2Vec2-BERT with a CTC head
/// for each ṣifah, so it reports — per 40 ms frame — whether what it heard was nasalised,
/// echoed, heavy or light. That is what makes it possible to check the rules
/// `DSPTajweedAnalyzer` cannot: duration measurement can say a madd was short, but only
/// this can say a ghunnah was missing.
///
/// The rules are still located in the text by `TajweedRuleDetector`. The model is asked
/// only whether the *expected* attribute was actually present where it should have been,
/// which is a far narrower question than "grade this recitation" and keeps every claim
/// anchored to something the orthography demands.
///
/// It stays conservative in the same way as everything else here: a rule is only reported
/// when the model is confidently against it over a sustained stretch, and a note is a
/// prompt to listen again rather than a verdict.
public actor MuaalemTajweedAnalyzer: TajweedAnalyzer {

    public struct Options: Sendable {
        /// Peak probability of the expected attribute below which the rule is questioned.
        ///
        /// **Peak, not mean.** The model is a CTC network: it labels almost every frame
        /// blank and spikes where it has something to say. A ghunnah is one spike on one
        /// nūn inside a word that may run six letters, and the other letters carry the
        /// contrary label perfectly correctly. Averaging across the word therefore
        /// measures how much of the word is *not* a ghunnah — which is most of it, in
        /// every recitation, correct or not.
        ///
        /// Measured through `IqraEval --calibrate-tajweed` over 216 rule occurrences in
        /// Al-Husary's murattal, all of them correct by assumption:
        ///
        ///     rule        mean over word (med)   peak in word (p5 / p25 / med)
        ///     ghunnah     20.0%                  0.0% /  97.2% / 100.0%
        ///     ikhfāʾ      25.0%                  1.8% /  99.8% / 100.0%
        ///     qalqalah    14.3%                  0.0% /  94.1% /  99.9%
        ///     idghām      14.3%                  0.0% /   0.0% /  94.9%
        ///     iqlāb       14.3%                  0.0% /   0.3% / 100.0%
        ///
        /// The mean-based test that shipped before would have questioned **145 of 216**
        /// correct occurrences — 67% of expert recitation. The peak separates instead.
        public var presenceThreshold: Double
        /// The model must spike on the contrary reading this hard before anything is said.
        /// Between the two thresholds it stays silent.
        public var contraryThreshold: Double
        /// Frames of evidence needed. One frame is 40 ms; a ghunnah is two harakāt, so a
        /// genuine one spans several.
        public var minimumFrames: Int
        /// How far past the end of a word to keep looking for its rule's evidence.
        ///
        /// The nūn-sākinah rules are *junction* rules: a tanwīn or sākin nūn takes its
        /// ruling from the first letter of the **next** word, and the nasalisation that
        /// ruling calls for is articulated across the boundary — after the word that
        /// triggered it has ended. Measured on Al-Husary, the 25th percentile of the
        /// ghunnah spike for idghām bi-ghunnah is 22.8% inside the word alone and 82.5%
        /// with 200 ms more; beyond that it stops improving, so 200 ms it is.
        public var junctionWindow: TimeInterval
        /// Seconds of audio per inference window, matching the converted model.
        public var windowSeconds: Double

        public init(
            // Loosened deliberately, and the room to loosen is small: the model's
            // output is bimodal — a spike near 1 or nothing near 0 — so almost nothing
            // sits between the thresholds to be admitted by moving them. Measured over
            // 205 correct occurrences of the rules judged:
            //
            //     peak below   2%     10%    25%    50%    75%    90%
            //     questioned   11.2%  11.8%  12.4%  12.4%  12.4%  12.4%
            //
            //     contrary above  90%    75%    50%    25%    0%
            //     questioned      12.4%  14.0%  14.0%  14.0%  14.0%
            //
            // 11.2% at the tightest, 14.0% at the loosest possible setting. This sits at
            // the loose end: about one correctly recited rule in seven is questioned,
            // against one in nine before.
            //
            // What that buys is unmeasured. Nothing in the calibration set contains a
            // mistake, so there is no detection rate to weigh against it — only the
            // certainty that more correct recitation is questioned.
            presenceThreshold: Double = 0.5,
            contraryThreshold: Double = 0.5,
            minimumFrames: Int = 3,
            junctionWindow: TimeInterval = 0.2,
            windowSeconds: Double = 10
        ) {
            self.junctionWindow = junctionWindow
            self.presenceThreshold = presenceThreshold
            self.contraryThreshold = contraryThreshold
            self.minimumFrames = minimumFrames
            self.windowSeconds = windowSeconds
        }

        public static let `default` = Options()
    }

    /// The heads this analyzer reads, and the class index that means "the attribute is
    /// present". Taken from the model's own vocab.json.
    public enum Head: String, Sendable, CaseIterable {
        case ghonna
        case qalqla
        case tafkheemOrTaqeeq = "tafkheem_or_taqeeq"

        /// Class index meaning the attribute was heard.
        public var presentIndex: Int {
            switch self {
            case .ghonna: return 1        // مغن
            case .qalqla: return 1        // مقلقل
            case .tafkheemOrTaqeeq: return 1  // مفخم
            }
        }

        /// Class index meaning it was heard and the attribute was absent.
        public var absentIndex: Int {
            switch self {
            case .ghonna: return 2        // لا غنة
            case .qalqla: return 2        // لا قلقلة
            case .tafkheemOrTaqeeq: return 2  // مرقق
            }
        }
    }

    private let modelURL: URL
    private let features: MuaalemFeatures
    private let options: Options
    private var model: MLModel?
    private var rows: Int { Int(options.windowSeconds * Double(MuaalemFeatures.stride) * 25) }

    public init(modelURL: URL, features: MuaalemFeatures, options: Options = .default) {
        self.modelURL = modelURL
        self.features = features
        self.options = options
    }

    /// Load and compile the Core ML package if needed.
    public func loadModel() throws {
        guard model == nil else { return }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all

        if modelURL.pathExtension == "mlmodelc" {
            model = try MLModel(contentsOf: modelURL, configuration: configuration)
        } else {
            // Compiling takes a while, so the compiled copy is cached — but *not* beside
            // the package. In a shipped app the package sits inside the bundle, which is
            // read-only under the sandbox, so writing there throws and the whole analyzer
            // fails to load. It then reports nothing about any rule, which is
            // indistinguishable from a recitation with nothing wrong in it. The cache
            // goes somewhere writable instead.
            let compiled = try Self.compiledModelURL(for: modelURL)
            model = try MLModel(contentsOf: compiled, configuration: configuration)
        }
    }

    /// A compiled copy of `modelURL`, built once and cached in Application Support.
    ///
    /// Falls back to compiling into a temporary directory if even that is unavailable, so
    /// a failure to cache never becomes a failure to analyse.
    static func compiledModelURL(for modelURL: URL) throws -> URL {
        let stem = modelURL.deletingPathExtension().lastPathComponent
        let caches = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: "Iqra/CompiledModels", directoryHint: .isDirectory)

        if let caches {
            let cached = caches.appending(path: "\(stem).mlmodelc")
            if FileManager.default.fileExists(atPath: cached.path) { return cached }
            try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
            let temporary = try MLModel.compileModel(at: modelURL)
            if (try? FileManager.default.moveItem(at: temporary, to: cached)) != nil {
                return cached
            }
            return temporary
        }
        return try MLModel.compileModel(at: modelURL)
    }

    public var isLoaded: Bool { model != nil }

    // MARK: - TajweedAnalyzer

    public func analyze(
        segments: [AlignedAudioSegment],
        target: RecitationTarget
    ) async -> [TajweedNote] {
        let occurrences = TajweedRuleDetector.occurrences(in: target)
        let judgeable = occurrences.count { Self.audioVerifiable.contains($0.rule) }
        lastCoverage = TajweedCoverage(required: occurrences.count, judgeable: judgeable)
        guard !occurrences.isEmpty, !segments.isEmpty else { return [] }
        do { try loadModel() } catch { return [] }
        guard model != nil else { return [] }

        var examined = 0
        var notes: [TajweedNote] = []
        for segment in segments {
            guard let observed = try? probabilities(for: segment.audio) else { continue }
            let outcome = verify(
                occurrences: occurrences,
                against: observed,
                segment: segment
            )
            notes += outcome.notes
            examined += outcome.examined
        }
        lastCoverage = TajweedCoverage(
            required: occurrences.count,
            judgeable: judgeable,
            examined: examined,
            skippedWithoutTiming: max(0, judgeable - examined),
            questioned: notes.count
        )
        return notes.sorted { $0.targetIndex < $1.targetIndex }
    }

    private var lastCoverage: TajweedCoverage = .none

    public func coverage() async -> TajweedCoverage { lastCoverage }

    // MARK: - Inference

    /// One-shot diagnostic of how a head's output actually arrives: element type,
    /// layout, and the same values read three ways. Used to settle what `softmaxRows`
    /// must do, rather than assuming.
    public func describeOutput(for audio: AudioChunk, head: String = "ghonna") throws -> String {
        if model == nil { try loadModel() }
        guard let model else { throw TajweedModelError.notLoaded }
        var extracted = features.features(from: audio)
        guard !extracted.isEmpty else { throw TajweedModelError.audioTooShort }
        let rows = self.rows
        if extracted.count < rows {
            extracted += Array(repeating: [Float](repeating: 0, count: 160), count: rows - extracted.count)
        }
        let input = try MLMultiArray(shape: [1, NSNumber(value: rows), 160], dataType: .float32)
        let pointer = input.dataPointer.bindMemory(to: Float.self, capacity: rows * 160)
        for row in 0..<rows {
            for column in 0..<160 { pointer[row * 160 + column] = extracted[row][column] }
        }
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input_features": input]))
        guard let array = output.featureValue(for: head)?.multiArrayValue else { return "no head \(head)" }

        var text = "head \(head): shape \(array.shape), strides \(array.strides), "
        text += "dataType raw \(array.dataType.rawValue), count \(array.count)\n"
        let viaNumber = (0..<min(9, array.count)).map { array[$0].doubleValue }
        text += "  via NSNumber:  \(viaNumber.map { ($0 * 1000).rounded() / 1000 })\n"
        let asFloat = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
        text += "  as Float32:    \((0..<9).map { (Double(asFloat[$0]) * 1000).rounded() / 1000 })\n"
        let asHalf = array.dataPointer.bindMemory(to: Float16.self, capacity: array.count)
        text += "  as Float16:    \((0..<9).map { (Double(asHalf[$0]) * 1000).rounded() / 1000 })"
        return text
    }

    /// Per-frame probability of each head's classes, on the session clock.
    public struct Observation: Sendable {
        /// `[head][frame][class]`.
        public var probabilities: [String: [[Double]]]
        /// Session time of frame 0, and seconds per frame.
        public var startTime: TimeInterval
        public var frameDuration: TimeInterval
    }

    public func probabilities(for audio: AudioChunk) throws -> Observation {
        // Load on first use rather than requiring the caller to remember: a public entry
        // point that silently throws `notLoaded` reads, from the outside, exactly like a
        // model that has no opinion about the audio.
        if model == nil { try loadModel() }
        guard let model else { throw TajweedModelError.notLoaded }
        let rows = self.rows
        var extracted = features.features(from: audio)
        guard !extracted.isEmpty else { throw TajweedModelError.audioTooShort }

        // The converted model takes a fixed window. Longer audio is processed in
        // consecutive windows and the frames concatenated; a short tail is zero-padded,
        // and the padding's frames are dropped afterwards so they cannot be mistaken for
        // silence the reciter produced.
        var merged: [String: [[Double]]] = [:]
        var realFrames = 0
        let usableFramesPerWindow = rows / MuaalemFeatures.stride

        var offset = 0
        while offset < extracted.count {
            let slice = Array(extracted[offset..<min(offset + rows, extracted.count)])
            let padded = slice.count == rows
                ? slice
                : slice + Array(repeating: [Float](repeating: 0, count: 160), count: rows - slice.count)

            let input = try MLMultiArray(shape: [1, NSNumber(value: rows), 160], dataType: .float32)
            let pointer = input.dataPointer.bindMemory(to: Float.self, capacity: rows * 160)
            for row in 0..<rows {
                let values = padded[row]
                for column in 0..<160 { pointer[row * 160 + column] = values[column] }
            }

            let provider = try MLDictionaryFeatureProvider(dictionary: ["input_features": input])
            let output = try model.prediction(from: provider)

            let framesInThisWindow = min(
                usableFramesPerWindow,
                Int(ceil(Double(slice.count) / Double(MuaalemFeatures.stride)))
            )
            for name in output.featureNames {
                guard let array = output.featureValue(for: name)?.multiArrayValue else { continue }
                merged[name, default: []] += softmaxRows(array, limit: framesInThisWindow)
            }
            realFrames += framesInThisWindow
            offset += rows
        }

        return Observation(
            probabilities: merged,
            startTime: audio.startTime,
            frameDuration: 1.0 / Double(MuaalemFeatures.framesPerSecond)
        )
    }

    /// Convert logits `[1, frames, classes]` to per-frame probabilities.
    ///
    /// The element type is read from the array rather than assumed. The converted model
    /// emits **float16**, and reading those bytes as `Float` produces numbers that are not
    /// merely inaccurate but unrelated — every second logit is assembled from halves of
    /// two different values. Softmax then flattens the nonsense into a near-uniform
    /// distribution, and a uniform distribution is indistinguishable, from the outside,
    /// from a model that has no opinion: the analyzer stayed silent about every rule in
    /// every recitation, which reads as "tajweed checking finds nothing wrong".
    ///
    /// Measured through `IqraEval --calibrate-tajweed`: reading as `Float` gave every head
    /// 34.3% for both a rule and its contrary across 251 occurrences. The same model in
    /// Python, on the same features, puts 0.90–0.95 on its chosen class.
    private func softmaxRows(_ array: MLMultiArray, limit: Int) -> [[Double]] {
        let shape = array.shape.map(\.intValue)
        guard shape.count == 3 else { return [] }
        let frames = min(shape[1], limit)
        let classes = shape[2]
        guard frames > 0, classes > 0 else { return [] }

        // Strides rather than assumed contiguity, and they are not a formality here: the
        // real layout is [8000, 32, 1] for a [1, 250, 3] output, because each frame's
        // three logits are padded out to 32 elements for the Neural Engine. Reading this
        // buffer as though it were packed gives frame 0 and then nothing.
        //
        // The bound must come from the strides too. `array.count` is the *logical* number
        // of elements (750), while the buffer holds 8000 — using the logical count as the
        // limit silently truncates everything past frame 23, and softmax of the zeros that
        // follow is a flat third across every class.
        let strides = array.strides.map(\.intValue)
        let frameStride = strides.count == 3 ? strides[1] : classes
        let classStride = strides.count == 3 ? strides[2] : 1
        let count = strides.count == 3 ? max(array.count, shape[0] * strides[0]) : array.count

        let read: (Int) -> Double
        switch array.dataType {
        case .float16:
            let pointer = array.dataPointer.bindMemory(to: Float16.self, capacity: count)
            read = { Double(pointer[$0]) }
        case .double:
            let pointer = array.dataPointer.bindMemory(to: Double.self, capacity: count)
            read = { pointer[$0] }
        case .int32:
            let pointer = array.dataPointer.bindMemory(to: Int32.self, capacity: count)
            read = { Double(pointer[$0]) }
        default:
            let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: count)
            read = { Double(pointer[$0]) }
        }

        var result: [[Double]] = []
        result.reserveCapacity(frames)
        for frame in 0..<frames {
            var logits = [Double](repeating: 0, count: classes)
            for index in 0..<classes {
                let offset = frame * frameStride + index * classStride
                guard offset < count else { continue }
                logits[index] = read(offset)
            }
            let peak = logits.max() ?? 0
            var sum = 0.0
            for index in 0..<classes {
                logits[index] = exp(logits[index] - peak)
                sum += logits[index]
            }
            if sum > 0 { for index in 0..<classes { logits[index] /= sum } }
            result.append(logits)
        }
        return result
    }

    // MARK: - Verification

    /// Rules whose model output on correct recitation separates well enough to judge.
    ///
    /// Deliberately a short list. See `Options.presenceThreshold` for the measurements:
    /// idghām and iqlāb produce no spike in a quarter of occurrences that a qārī recited
    /// correctly, which is a property of the model, not of the recitation.
    public static let audioVerifiable: Set<TajweedRule> = [
        .ghunnah, .ikhfa, .qalqalah, .izhar, .idghamBilaGhunnah,
    ]

    /// Rules whose sound is articulated across the boundary into the next word.
    static let junctionRules: Set<TajweedRule> = [.idgham, .idghamBilaGhunnah, .ikhfa, .iqlab, .izhar]

    /// Which head decides a rule, and whether the attribute should be present.
    ///
    /// The nūn-sākinah rules are all judged by nasalisation: ikhfāʾ, iqlāb and idghām
    /// with ghunnah should show it, and iẓhār — which exists precisely to *not* — should
    /// not. That inversion is what lets one head check four rules.
    public static func expectation(for rule: TajweedRule) -> (head: Head, present: Bool)? {
        switch rule {
        case .ghunnah, .ikhfa, .iqlab: return (.ghonna, true)
        case .idgham: return (.ghonna, true)
        // Defined by the absence of nasalisation, so the head is read the same way round
        // as iẓhār — and iẓhār is the rule this model reads most cleanly of all.
        case .idghamBilaGhunnah: return (.ghonna, false)
        case .izhar: return (.ghonna, false)
        case .qalqalah: return (.qalqla, true)
        case .maddAsli, .maddWajibMuttasil, .maddJaizMunfasil, .maddLazim: return nil
        case .tafkhimTarqiq: return (.tafkheemOrTaqeeq, true)
        case .waqf: return nil
        }
    }

    private func verify(
        occurrences: [TajweedOccurrence],
        against observed: Observation,
        segment: AlignedAudioSegment
    ) -> (notes: [TajweedNote], examined: Int) {
        var timings: [Int: ClosedRange<TimeInterval>] = [:]
        for word in segment.words {
            if let range = word.timeRange { timings[word.targetIndex] = range }
        }

        var notes: [TajweedNote] = []
        var examined = 0
        for occurrence in occurrences {
            guard let expectation = Self.expectation(for: occurrence.rule) else { continue }
            guard let range = timings[occurrence.targetIndex] else { continue }
            guard let series = observed.probabilities[expectation.head.rawValue] else { continue }

            let first = Int(((range.lowerBound - observed.startTime) / observed.frameDuration).rounded(.down))
            // Junction rules are allowed to look a little past the word; the others are
            // not, since their evidence is inside the word by definition.
            let junction = Self.junctionRules.contains(occurrence.rule) ? options.junctionWindow : 0
            let last = Int((
                (range.upperBound + junction - observed.startTime) / observed.frameDuration
            ).rounded(.up))
            let lower = max(0, first)
            let upper = min(series.count, last)
            guard upper - lower >= options.minimumFrames else { continue }

            // Only the rules whose distribution on correct recitation actually separates.
            // Idghām and iqlāb show no spike at all in a quarter of correct occurrences,
            // so any threshold that questions their absence would question a qārī every
            // fourth time. They are detected in the text and coloured on the page; they
            // are simply not judged against audio until that tail is understood.
            guard Self.audioVerifiable.contains(occurrence.rule) else { continue }

            let frames = series[lower..<upper]
            let presentIndex = expectation.head.presentIndex
            let absentIndex = expectation.head.absentIndex

            // The strongest single frame each way, ignoring frames the model marked as
            // padding. CTC spikes; it does not sustain, so the peak is the evidence.
            var presence = 0.0
            var contrary = 0.0
            var counted = 0
            for frame in frames where frame.count > max(presentIndex, absentIndex) {
                let pad = frame[0]
                guard pad < 0.5 else { continue }
                presence = max(presence, frame[presentIndex])
                contrary = max(contrary, frame[absentIndex])
                counted += 1
            }
            guard counted >= options.minimumFrames else { continue }
            examined += 1

            let wanted = expectation.present ? presence : contrary
            let against = expectation.present ? contrary : presence
            guard wanted < options.presenceThreshold, against > options.contraryThreshold else { continue }

            notes.append(
                TajweedNote(
                    rule: occurrence.rule,
                    targetIndex: occurrence.targetIndex,
                    reference: occurrence.reference,
                    timeRange: range,
                    confidence: against > 0.85 ? .moderate : .low,
                    message: Self.message(for: occurrence, expectingPresence: expectation.present),
                    measurement: .init(observed: wanted, expected: options.contraryThreshold, unit: "")
                )
            )
        }
        return (notes, examined)
    }

    private static func message(for occurrence: TajweedOccurrence, expectingPresence: Bool) -> String {
        let letters = occurrence.letters
        switch occurrence.rule {
        case .ghunnah:
            return "“\(letters)” carries ghunnah — the nūn or mīm is held with nasalisation for two harakāt. This did not sound nasalised; worth listening back."
        case .ikhfa:
            return "Ikhfāʾ at “\(letters)”: the nūn is hidden into the next letter with nasalisation. That nasalisation did not come through clearly."
        case .iqlab:
            return "Iqlāb at “\(letters)”: the nūn becomes a mīm sound with ghunnah before the bāʾ. That did not sound nasalised."
        case .idgham:
            return "Idghām at “\(letters)”: the nūn merges into the next letter with ghunnah. The nasalisation did not come through."
        case .izhar:
            return "Iẓhār at “\(letters)”: the nūn should be pronounced plainly, without nasalisation — this sounded nasalised."
        case .qalqalah:
            return "Qalqalah on “\(letters)” — the sākin letter should carry an audible echo. It sounded flat here."
        default:
            return "Check “\(letters)” — \(occurrence.rule.title) did not sound as the text calls for."
        }
    }
}

public enum TajweedModelError: Error, Sendable {
    case notLoaded
    case audioTooShort
    case modelUnavailable(String)
}

extension MuaalemTajweedAnalyzer {
    /// Locate the converted Core ML package, preferring the quantised build.
    public static func locateModel(in bundle: Bundle = .main, additionalDirectories: [URL] = []) -> URL? {
        let names = ["muaalem-v3_2-int8", "muaalem-v3_2"]
        for name in names {
            if let url = bundle.url(forResource: name, withExtension: "mlmodelc") { return url }
            if let url = bundle.url(forResource: name, withExtension: "mlpackage") { return url }
        }
        var directories = additionalDirectories
        var current = URL(fileURLWithPath: bundle.bundlePath).standardized
        for _ in 0..<8 {
            directories.append(current.appending(path: "Models"))
            let parent = current.deletingLastPathComponent()
            if parent == current { break }
            current = parent
        }
        for directory in directories {
            for name in names {
                for ext in ["mlmodelc", "mlpackage"] {
                    let url = directory.appending(path: "\(name).\(ext)")
                    if FileManager.default.fileExists(atPath: url.path) { return url }
                }
            }
        }
        return nil
    }
}
#endif
