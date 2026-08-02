import Foundation

/// Runs every check the app has, and merges what they say.
///
/// The two halves answer different questions and neither can answer the other's. The
/// Muaalem model judges *ṣifāt* — whether a sound was nasalised, echoed, heavy or light —
/// frame by frame, and has no notion of how long anything was held. Madd is entirely a
/// question of length, and is measured against the pace of the reciter's own recitation.
/// Running only one of them leaves a whole class of rule unchecked.
public actor CompositeTajweedAnalyzer: TajweedAnalyzer {
    private let neural: MuaalemTajweedAnalyzer
    private let duration: DSPTajweedAnalyzer
    private var lastCoverage: TajweedCoverage = .none

    public init(neural: MuaalemTajweedAnalyzer, duration: DSPTajweedAnalyzer = DSPTajweedAnalyzer()) {
        self.neural = neural
        self.duration = duration
    }

    public func analyze(
        segments: [AlignedAudioSegment],
        target: RecitationTarget
    ) async -> [TajweedNote] {
        let fromModel = await neural.analyze(segments: segments, target: target)
        let fromDuration = await duration.analyze(segments: segments, target: target)

        // Where both speak about the same word, the model's reading wins: it heard the
        // sound, while the duration check only measures how long the word took.
        let judgedByModel = Set(fromModel.map(\.targetIndex))
        let merged = fromModel + fromDuration.filter { !judgedByModel.contains($0.targetIndex) }

        var coverage = await neural.coverage()
        // Madd rules are judged by duration, so they belong in the counts too.
        let maddRules = TajweedRuleDetector.occurrences(in: target).filter {
            MuaalemTajweedAnalyzer.expectation(for: $0.rule) == nil
        }
        coverage.judgeable += maddRules.count
        coverage.examined += fromDuration.isEmpty ? 0 : maddRules.count
        coverage.questioned = merged.count
        lastCoverage = coverage

        return merged.sorted { $0.targetIndex < $1.targetIndex }
    }

    public func coverage() async -> TajweedCoverage { lastCoverage }
}
