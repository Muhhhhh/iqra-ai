import Foundation

/// A tajweed rule the analyzer knows how to look for.
///
/// v1 ships none of these; the cases exist so the note type, the UI, and the
/// persistence format are all shaped correctly before the DSP lands.
public enum TajweedRule: String, Sendable, Codable, CaseIterable {
    /// Natural elongation, two harakāt.
    case maddAsli
    /// Madd letter meeting a hamza in the same word — four or five harakāt.
    case maddWajibMuttasil
    /// Madd letter at the end of a word, next word opening with hamza — four or five.
    case maddJaizMunfasil
    /// Madd letter before a shadda or sukun — six harakāt.
    case maddLazim
    /// Echo on ق ط ب ج د when sākin.
    case qalqalah
    /// Nasalisation, two harakāt, on ن and م carrying shadda.
    case ghunnah
    /// Assimilation of nūn sākinah / tanwīn into ي ن م و, carrying nasalisation.
    case idgham
    /// Assimilation into ل or ر, which carries **no** nasalisation.
    ///
    /// A separate rule because it is one: idghām bilā ghunnah is defined by the absence
    /// of the very thing idghām bi-ghunnah requires. Treating the six letters as one rule
    /// meant expecting nasalisation on ل and ر, so a reciter who correctly gave none was
    /// measured as having failed — and the model, correctly reporting no nasal, supplied
    /// the evidence against them.
    case idghamBilaGhunnah
    /// Nūn sākinah / tanwīn converted to a mīm sound before ب.
    case iqlab
    /// Nūn sākinah / tanwīn held lightly before the fifteen letters.
    case ikhfa
    /// Nūn sākinah / tanwīn pronounced plainly before a throat letter.
    case izhar
    /// Heavy vs. light articulation. Not yet detected.
    case tafkhimTarqiq
    /// Stopping in a place that changes the meaning. Not yet detected.
    case waqf

    /// Every madd rule, which are the ones that prescribe a duration.
    public static let maddRules: Set<TajweedRule> = [
        .maddAsli, .maddWajibMuttasil, .maddJaizMunfasil, .maddLazim,
    ]

    public var isMadd: Bool { Self.maddRules.contains(self) }

    /// Short name for display.
    public var title: String {
        switch self {
        case .maddAsli: return "Madd asli"
        case .maddWajibMuttasil: return "Madd wajib muttasil"
        case .maddJaizMunfasil: return "Madd jaiz munfasil"
        case .maddLazim: return "Madd lazim"
        case .qalqalah: return "Qalqalah"
        case .ghunnah: return "Ghunnah"
        case .idgham: return "Idgham (with ghunnah)"
        case .idghamBilaGhunnah: return "Idgham (without ghunnah)"
        case .iqlab: return "Iqlab"
        case .ikhfa: return "Ikhfa"
        case .izhar: return "Izhar"
        case .tafkhimTarqiq: return "Tafkhim / tarqiq"
        case .waqf: return "Waqf"
        }
    }

    /// Arabic name, as a learner would meet it.
    public var arabicTitle: String {
        switch self {
        case .maddAsli: return "مد أصلي"
        case .maddWajibMuttasil: return "مد واجب متصل"
        case .maddJaizMunfasil: return "مد جائز منفصل"
        case .maddLazim: return "مد لازم"
        case .qalqalah: return "قلقلة"
        case .ghunnah: return "غنة"
        case .idgham: return "إدغام بغنة"
        case .idghamBilaGhunnah: return "إدغام بلا غنة"
        case .iqlab: return "إقلاب"
        case .ikhfa: return "إخفاء"
        case .izhar: return "إظهار"
        case .tafkhimTarqiq: return "تفخيم وترقيق"
        case .waqf: return "وقف"
        }
    }
}

/// How strongly the analyzer believes something is off.
///
/// Everything the analyzer emits is advisory. There is no "error" level by design:
/// a machine-measured tajweed deviation is a prompt to check with a teacher, not a
/// verdict on someone's recitation.
public enum TajweedConfidence: String, Sendable, Codable, Comparable {
    /// Worth mentioning only if the user asked for detailed feedback.
    case low
    /// Show as a hint.
    case moderate
    /// Show prominently — still phrased as a hint.
    case high

    private var rank: Int {
        switch self {
        case .low: return 0
        case .moderate: return 1
        case .high: return 2
        }
    }

    public static func < (lhs: TajweedConfidence, rhs: TajweedConfidence) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// One advisory observation about pronunciation.
public struct TajweedNote: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let rule: TajweedRule
    /// Which target word this concerns.
    public let targetIndex: Int
    public let reference: VerseReference
    /// Where in the session audio the observation was made.
    public let timeRange: ClosedRange<TimeInterval>
    public let confidence: TajweedConfidence
    /// Human-readable hint, phrased as a suggestion. Never as a verdict.
    public let message: String
    /// What was measured vs. expected, for debugging and threshold calibration.
    public let measurement: Measurement?
    /// Which occurrence within the word this is, 1-based, and how many the word holds.
    ///
    /// A word is not one elongation. 22.4% of the words in the muṣḥaf that carry any madd
    /// carry more than one — 5,102 hold two natural madds alone — so naming the word
    /// leaves the reciter to guess which of two or three sounds is being questioned.
    /// `nil` when the word holds only one, since there is nothing to disambiguate.
    public let occurrence: (index: Int, of: Int)?

    public struct Measurement: Sendable, Equatable {
        public let observed: Double
        public let expected: Double
        public let unit: String

        public init(observed: Double, expected: Double, unit: String) {
            self.observed = observed
            self.expected = expected
            self.unit = unit
        }
    }

    public init(
        id: UUID = UUID(),
        rule: TajweedRule,
        targetIndex: Int,
        reference: VerseReference,
        timeRange: ClosedRange<TimeInterval>,
        confidence: TajweedConfidence,
        message: String,
        measurement: Measurement? = nil,
        occurrence: (index: Int, of: Int)? = nil
    ) {
        self.id = id
        self.rule = rule
        self.targetIndex = targetIndex
        self.reference = reference
        self.timeRange = timeRange
        self.confidence = confidence
        self.message = message
        self.measurement = measurement
        self.occurrence = occurrence
    }

    public static func == (lhs: TajweedNote, rhs: TajweedNote) -> Bool {
        lhs.id == rhs.id && lhs.rule == rhs.rule && lhs.targetIndex == rhs.targetIndex
            && lhs.reference == rhs.reference && lhs.timeRange == rhs.timeRange
            && lhs.confidence == rhs.confidence && lhs.message == rhs.message
            && lhs.measurement == rhs.measurement
            && lhs.occurrence?.index == rhs.occurrence?.index
            && lhs.occurrence?.of == rhs.occurrence?.of
    }
}

/// v2 seam. Given the aligned audio segments — raw signal plus word timestamps plus
/// what was expected — return advisory notes.
///
/// Two implementations are planned:
///  1. `DSPTajweedAnalyzer` — on-device signal rules, starting with madd duration
///     (vowel-segment length vs. expected harakāt count) and qalqalah (energy-burst
///     detection on ق ب ج د ط).
///  2. `NeuralTajweedAnalyzer` — the obadx phonetic model (arXiv 2509.00094, MIT)
///     on the Neural Engine, for full QPS-based phonetic scoring.
///
/// Implementations must be conservative: when in doubt, say nothing. Thresholds are
/// to be calibrated against expert reciters and reviewed by a qārī before shipping.
/// How much of the passage's tajweed was actually examined.
///
/// Reported because "nothing questioned" is not the same claim as "everything was
/// checked and passed", and only one of those is usually true. A rule is only examined
/// when its word was recognised well enough to know *when* it was recited; at the word
/// error rates this pipeline achieves, most rules on a page are never looked at. Saying
/// "nothing questioned" without saying how little was inspected would be the same class
/// of false reassurance as a screen of unmarked text implying an approved recitation.
public struct TajweedCoverage: Sendable, Equatable {
    /// Rules the text requires in this passage.
    public var required: Int
    /// Rules this analyzer is capable of judging from audio at all.
    public var judgeable: Int
    /// Rules actually measured — word recognised, timing known, enough audio.
    public var examined: Int
    /// Judgeable rules skipped because the word was not recognised, so there is no
    /// trustworthy stretch of audio to read.
    public var skippedWithoutTiming: Int
    public var questioned: Int

    public init(
        required: Int = 0,
        judgeable: Int = 0,
        examined: Int = 0,
        skippedWithoutTiming: Int = 0,
        questioned: Int = 0
    ) {
        self.required = required
        self.judgeable = judgeable
        self.examined = examined
        self.skippedWithoutTiming = skippedWithoutTiming
        self.questioned = questioned
    }

    public static let none = TajweedCoverage()
}

public protocol TajweedAnalyzer: Sendable {
    func analyze(
        segments: [AlignedAudioSegment],
        target: RecitationTarget
    ) async -> [TajweedNote]

    /// What the last `analyze` was able to look at.
    func coverage() async -> TajweedCoverage
}

extension TajweedAnalyzer {
    public func coverage() async -> TajweedCoverage { .none }
}

/// v1 default: analyses nothing.
public struct NoOpTajweedAnalyzer: TajweedAnalyzer {
    public init() {}

    public func analyze(
        segments: [AlignedAudioSegment],
        target: RecitationTarget
    ) async -> [TajweedNote] {
        []
    }
}
