import Foundation

/// Keeps a session's audio, and what the app concluded about it.
///
/// **Off unless the reciter turns it on**, and nothing leaves the machine — this writes a
/// WAV and a JSON file into Application Support and stops there. It exists because every
/// threshold in this app is fitted to studio recordings of professional qurrāʾ, who do not
/// make the mistakes it is built to catch. The synthetic negatives that stand in for real
/// errors choose where the error goes, so they can show a check responds to a change but
/// never that it finds a mistake a person actually made.
///
/// One page read normally and one read with deliberate mistakes closes that gap. The WAV
/// is what the microphone heard; the JSON is what the app decided, word by word and note
/// by note, so the two can be compared without needing the session to be reproduced.
///
/// The audio saved is *pre-gain*, exactly as captured. `AutomaticGain` adapts to the
/// recitation as it goes, so saving its output would bake one particular adaptation into
/// the file and a replay would not take the path the live session took.
public actor SessionRecorder {

    /// What the app concluded, in a form that outlives the session.
    ///
    /// Deliberately a flat structure of its own rather than the pipeline's types. A log
    /// that has to be read months later, possibly by a different version of this app,
    /// should not break because a field moved.
    public struct Log: Codable, Sendable {
        public struct Word: Codable, Sendable {
            public var index: Int
            public var surah: Int
            public var ayah: Int
            public var text: String
            public var status: String
            public var start: TimeInterval?
            public var end: TimeInterval?
            public var confidence: Double?
        }

        public struct Note: Codable, Sendable {
            public var rule: String
            public var wordIndex: Int
            public var surah: Int
            public var ayah: Int
            public var start: TimeInterval
            public var end: TimeInterval
            public var confidence: String
            public var message: String
            public var observed: Double?
            public var expected: Double?
            public var unit: String?
        }

        public struct Segment: Codable, Sendable {
            public var start: TimeInterval
            public var end: TimeInterval
            public var transcript: String
        }

        public var recordedAt: Date
        public var sampleRate: Double
        public var duration: TimeInterval
        public var audioFile: String
        public var words: [Word]
        public var notes: [Note]
        public var segments: [Segment]
    }

    /// How a log is written, and how to read one back.
    ///
    /// Paired deliberately. The point of keeping a session is that something else reads it
    /// later — a script, a future version of this app — and a date strategy that has to be
    /// guessed is the sort of detail that makes an archive unreadable a year on.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private let directory: URL
    private var handle: FileHandle?
    private var audioURL: URL?
    private var startedAt: Date?
    private var samplesWritten: Int = 0
    private var segments: [Log.Segment] = []

    public init(directory: URL) {
        self.directory = directory
    }

    /// Where sessions are kept, alongside the app's other private data.
    public static func defaultDirectory() -> URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: "Iqra/Recordings", directoryHint: .isDirectory)
    }

    // MARK: - Recording

    public func begin() {
        guard handle == nil else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let stamp = Self.stamp.string(from: Date())
        let url = directory.appending(path: "\(stamp).wav")
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let opened = try? FileHandle(forWritingTo: url)
        else { return }

        // A header with zeroed lengths, patched in `finish`. Streaming to disk as the
        // session runs rather than buffering it means a crash costs the last frame
        // instead of the whole recitation.
        opened.write(Self.header(sampleCount: 0))
        handle = opened
        audioURL = url
        startedAt = Date()
        samplesWritten = 0
        segments = []
    }

    /// One captured frame, exactly as the microphone delivered it.
    public func append(_ chunk: AudioChunk) {
        guard let handle else { return }
        var pcm = [Int16]()
        pcm.reserveCapacity(chunk.samples.count)
        for sample in chunk.samples {
            // Clamp before scaling: a sample above 1.0 would otherwise wrap to the
            // opposite extreme and put a click in the file exactly where the reciter was
            // loudest.
            let clamped = max(-1, min(1, sample))
            pcm.append(Int16(clamped * 32767))
        }
        pcm.withUnsafeBufferPointer { handle.write(Data(buffer: $0)) }
        samplesWritten += pcm.count
    }

    /// Note a segment the VAD closed, with whatever was transcribed from it.
    public func noteSegment(_ segment: AlignedAudioSegment) {
        segments.append(
            Log.Segment(
                start: segment.audio.startTime,
                end: segment.audio.endTime,
                transcript: segment.transcription.tokens.map(\.text).joined(separator: " ")
            )
        )
    }

    /// Close the file and write the log beside it. Returns the folder, if anything was kept.
    @discardableResult
    public func finish(
        words: [WordEvaluation],
        notes: [TajweedNote]
    ) -> URL? {
        guard let handle, let audioURL, let startedAt else { return nil }
        defer {
            self.handle = nil
            self.audioURL = nil
            self.startedAt = nil
        }

        // Patch the two length fields now that the total is known.
        try? handle.seek(toOffset: 0)
        handle.write(Self.header(sampleCount: samplesWritten))
        try? handle.close()

        // A recording of nothing helps no one, and leaving it behind makes the folder
        // harder to read than it is useful.
        guard samplesWritten > Int(AudioChunk.canonicalSampleRate) else {
            try? FileManager.default.removeItem(at: audioURL)
            return nil
        }

        let log = Log(
            recordedAt: startedAt,
            sampleRate: AudioChunk.canonicalSampleRate,
            duration: Double(samplesWritten) / AudioChunk.canonicalSampleRate,
            audioFile: audioURL.lastPathComponent,
            words: words.map {
                Log.Word(
                    index: $0.targetIndex,
                    surah: $0.reference.surah,
                    ayah: $0.reference.ayah,
                    text: $0.expectedText,
                    status: String(describing: $0.status),
                    start: $0.timeRange?.lowerBound,
                    end: $0.timeRange?.upperBound,
                    confidence: $0.recognizerConfidence
                )
            },
            notes: notes.map {
                Log.Note(
                    rule: $0.rule.rawValue,
                    wordIndex: $0.targetIndex,
                    surah: $0.reference.surah,
                    ayah: $0.reference.ayah,
                    start: $0.timeRange.lowerBound,
                    end: $0.timeRange.upperBound,
                    confidence: String(describing: $0.confidence),
                    message: $0.message,
                    observed: $0.measurement?.observed,
                    expected: $0.measurement?.expected,
                    unit: $0.measurement?.unit
                )
            },
            segments: segments
        )

        if let data = try? Self.encoder().encode(log) {
            try? data.write(to: audioURL.deletingPathExtension().appendingPathExtension("json"))
        }
        return directory
    }

    /// Abandon the recording and delete the partial file.
    public func discard() {
        try? handle?.close()
        if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
        handle = nil
        audioURL = nil
        startedAt = nil
    }

    // MARK: - WAV

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// A 44-byte canonical WAV header: mono, 16-bit, at the pipeline's rate.
    static func header(sampleCount: Int) -> Data {
        let rate = UInt32(AudioChunk.canonicalSampleRate)
        let bytes = UInt32(sampleCount * 2)
        var data = Data()

        func string(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func uint32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func uint16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        string("RIFF")
        uint32(36 + bytes)
        string("WAVE")
        string("fmt ")
        uint32(16)              // PCM chunk size
        uint16(1)               // PCM, uncompressed
        uint16(1)               // mono
        uint32(rate)
        uint32(rate * 2)        // byte rate: one channel, two bytes a sample
        uint16(2)               // block align
        uint16(16)              // bits per sample
        string("data")
        uint32(bytes)
        return data
    }
}
