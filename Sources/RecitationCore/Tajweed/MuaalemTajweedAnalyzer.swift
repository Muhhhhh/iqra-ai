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
        /// Mean probability of the expected attribute below which the rule is questioned.
        public var presenceThreshold: Double
        /// The model must be at least this sure of the contrary reading before anything
        /// is said. Between the two thresholds it stays silent.
        public var contraryThreshold: Double
        /// Frames of evidence needed. One frame is 40 ms; a ghunnah is two harakāt, so a
        /// genuine one spans several.
        public var minimumFrames: Int
        /// Seconds of audio per inference window, matching the converted model.
        public var windowSeconds: Double

        public init(
            presenceThreshold: Double = 0.35,
            contraryThreshold: Double = 0.65,
            minimumFrames: Int = 3,
            windowSeconds: Double = 10
        ) {
            self.presenceThreshold = presenceThreshold
            self.contraryThreshold = contraryThreshold
            self.minimumFrames = minimumFrames
            self.windowSeconds = windowSeconds
        }

        public static let `default` = Options()
    }

    /// The heads this analyzer reads, and the class index that means "the attribute is
    /// present". Taken from the model's own vocab.json.
    enum Head: String {
        case ghonna
        case qalqla
        case tafkheemOrTaqeeq = "tafkheem_or_taqeeq"

        /// Class index meaning the attribute was heard.
        var presentIndex: Int {
            switch self {
            case .ghonna: return 1        // مغن
            case .qalqla: return 1        // مقلقل
            case .tafkheemOrTaqeeq: return 1  // مفخم
            }
        }

        /// Class index meaning it was heard and the attribute was absent.
        var absentIndex: Int {
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
            // Compiling takes a while, so a compiled copy is cached beside the package
            // rather than rebuilt on every launch.
            let compiled = modelURL.deletingPathExtension().appendingPathExtension("mlmodelc")
            if !FileManager.default.fileExists(atPath: compiled.path) {
                let temporary = try MLModel.compileModel(at: modelURL)
                try? FileManager.default.removeItem(at: compiled)
                try FileManager.default.moveItem(at: temporary, to: compiled)
            }
            model = try MLModel(contentsOf: compiled, configuration: configuration)
        }
    }

    public var isLoaded: Bool { model != nil }

    // MARK: - TajweedAnalyzer

    public func analyze(
        segments: [AlignedAudioSegment],
        target: RecitationTarget
    ) async -> [TajweedNote] {
        let occurrences = TajweedRuleDetector.occurrences(in: target)
        guard !occurrences.isEmpty, !segments.isEmpty else { return [] }
        do { try loadModel() } catch { return [] }
        guard model != nil else { return [] }

        var notes: [TajweedNote] = []
        for segment in segments {
            guard let observed = try? probabilities(for: segment.audio) else { continue }
            notes += verify(
                occurrences: occurrences,
                against: observed,
                segment: segment
            )
        }
        return notes.sorted { $0.targetIndex < $1.targetIndex }
    }

    // MARK: - Inference

    /// Per-frame probability of each head's classes, on the session clock.
    public struct Observation: Sendable {
        /// `[head][frame][class]`.
        public var probabilities: [String: [[Double]]]
        /// Session time of frame 0, and seconds per frame.
        public var startTime: TimeInterval
        public var frameDuration: TimeInterval
    }

    public func probabilities(for audio: AudioChunk) throws -> Observation {
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
    private func softmaxRows(_ array: MLMultiArray, limit: Int) -> [[Double]] {
        let shape = array.shape.map(\.intValue)
        guard shape.count == 3 else { return [] }
        let frames = min(shape[1], limit)
        let classes = shape[2]
        guard frames > 0, classes > 0 else { return [] }

        let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: shape[1] * classes)
        var result: [[Double]] = []
        result.reserveCapacity(frames)
        for frame in 0..<frames {
            var logits = [Double](repeating: 0, count: classes)
            for index in 0..<classes {
                logits[index] = Double(pointer[frame * classes + index])
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

    /// Which head decides a rule, and whether the attribute should be present.
    ///
    /// The nūn-sākinah rules are all judged by nasalisation: ikhfāʾ, iqlāb and idghām
    /// with ghunnah should show it, and iẓhār — which exists precisely to *not* — should
    /// not. That inversion is what lets one head check four rules.
    static func expectation(for rule: TajweedRule) -> (head: Head, present: Bool)? {
        switch rule {
        case .ghunnah, .ikhfa, .iqlab: return (.ghonna, true)
        case .idgham: return (.ghonna, true)
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
    ) -> [TajweedNote] {
        var timings: [Int: ClosedRange<TimeInterval>] = [:]
        for word in segment.words {
            if let range = word.timeRange { timings[word.targetIndex] = range }
        }

        var notes: [TajweedNote] = []
        for occurrence in occurrences {
            guard let expectation = Self.expectation(for: occurrence.rule) else { continue }
            guard let range = timings[occurrence.targetIndex] else { continue }
            guard let series = observed.probabilities[expectation.head.rawValue] else { continue }

            let first = Int(((range.lowerBound - observed.startTime) / observed.frameDuration).rounded(.down))
            let last = Int(((range.upperBound - observed.startTime) / observed.frameDuration).rounded(.up))
            let lower = max(0, first)
            let upper = min(series.count, last)
            guard upper - lower >= options.minimumFrames else { continue }

            let frames = series[lower..<upper]
            let presentIndex = expectation.head.presentIndex
            let absentIndex = expectation.head.absentIndex

            // Average over the word, ignoring frames the model marked as padding — those
            // carry no opinion either way.
            var presence: [Double] = []
            var contrary: [Double] = []
            for frame in frames where frame.count > max(presentIndex, absentIndex) {
                let pad = frame[0]
                guard pad < 0.5 else { continue }
                presence.append(frame[presentIndex])
                contrary.append(frame[absentIndex])
            }
            guard presence.count >= options.minimumFrames else { continue }

            let meanPresence = presence.reduce(0, +) / Double(presence.count)
            let meanContrary = contrary.reduce(0, +) / Double(contrary.count)

            let wanted = expectation.present ? meanPresence : meanContrary
            let against = expectation.present ? meanContrary : meanPresence
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
        return notes
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
