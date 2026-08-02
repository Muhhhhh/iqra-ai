import RecitationCore
import SwiftUI

/// Right-hand panel: what to look at again, and the audio behind each call.
///
/// The wording throughout is deliberately non-accusatory — "to review", "heard", "check
/// this" — rather than "error"/"mistake". A machine judgement about someone's recitation
/// should read as an invitation to listen again, not a verdict.
struct ReviewPanel: View {
    let model: RecitationSessionModel
    @Binding var selectedWord: Int?

    @State private var player = AudioChunkPlayer()
    @State private var playbackError: String?
    @State private var reciters = ReciterModel.shared
    @State private var settings = AppSettings.shared

    private var reviewItems: [WordEvaluation] {
        model.words.filter { $0.status.isMistake || $0.status.heardText != nil }
    }

    private var hasAnythingToShow: Bool {
        !reviewItems.isEmpty || model.insertions.contains { $0.kind == .addition }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if !hasAnythingToShow && model.insertions.isEmpty {
                emptyState
            } else {
                List {
                    if !reviewItems.isEmpty {
                        Section("Words to review") {
                            ForEach(reviewItems) { item in
                                ReviewRow(
                                    evaluation: item,
                                    isSelected: selectedWord == item.targetIndex,
                                    canPlay: audioSegment(for: item) != nil,
                                    reciterState: settings.offersReciterOnMistake
                                        ? reciterState(for: item.reference) : nil,
                                    onSelect: { selectedWord = item.targetIndex },
                                    onPlay: { play(item) },
                                    onPlayReciter: {
                                        reciters.play(item.reference, reciter: settings.reciter)
                                    }
                                )
                            }
                        }
                    }

                    // Presented as something the recogniser heard, not as something the
                    // reciter did. Measured on correct recitation, twelve of these appear
                    // per 360 words, and inspecting them showed what they are: strings
                    // like ٱلصُّحُّمِ and مهص, which are not words. For someone reciting a
                    // known page, a genuinely inserted word almost always also occurs on
                    // that page and is classified as going back over it — which leaves
                    // this list holding mostly mis-hearings. There is no measured rate at
                    // which it catches a real insertion, so it does not claim to.
                    let additions = model.insertions.filter { $0.kind == .addition }
                    if !additions.isEmpty {
                        Section {
                            ForEach(Array(additions.enumerated()), id: \.offset) { _, insertion in
                                InsertionRow(insertion: insertion, words: model.words)
                            }
                        } header: {
                            Text("Sounds the recogniser could not place")
                        } footer: {
                            Text("Usually the recogniser mishearing rather than anything you added — it is right about roughly three words in five. Not counted as mistakes.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    let repetitions = model.insertions.filter { $0.kind == .repetition }
                    if !repetitions.isEmpty {
                        Section {
                            ForEach(Array(repetitions.enumerated()), id: \.offset) { _, insertion in
                                InsertionRow(insertion: insertion, words: model.words)
                            }
                        } header: {
                            Text("Went back over")
                        } footer: {
                            Text("Words you repeated while correcting yourself. Not mistakes.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Always present, even with nothing to say. Silence from a checker
                    // that is switched off looks exactly like silence from one that
                    // found nothing wrong — and for a long time it was in fact silence
                    // from one whose model output was unreadable. The reciter should be
                    // able to tell those three apart without reading the source.
                    Section {
                        ForEach(model.tajweedNotes) { note in
                            TajweedRow(note: note)
                        }
                        TajweedStatusRow(model: model)
                    } header: {
                        Text(model.tajweedNotes.isEmpty ? "Tajweed" : "Tajweed — listen again")
                    } footer: {
                        if !model.tajweedNotes.isEmpty {
                            Text("A prompt to listen back, not a correction. About one in nine correctly recited rules is still questioned, and none of this has been reviewed by a qārī.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.inset)
            }

            if let error = reciters.lastError {
                Divider()
                Label(error, systemImage: "icloud.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(10)
            }

            if let playbackError {
                Divider()
                Label(playbackError, systemImage: "speaker.slash.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(10)
            }

            Divider()
            footer
        }
        .background(.background)
    }

    private var header: some View {
        HStack {
            Text("Review")
                .font(.headline)
            Spacer()
            if !reviewItems.isEmpty {
                Text("\(reviewItems.count)")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: model.state == .stopped ? "checkmark.seal.fill" : "waveform")
                .font(.system(size: 34))
                .foregroundStyle(model.state == .stopped ? Color.green : Color.secondary.opacity(0.5))
            Text(model.state == .stopped ? "Nothing flagged" : "Nothing to review yet")
                .font(.callout)
                .foregroundStyle(.secondary)
            if model.state == .stopped {
                Text("This is not a certification of correctness — it means the matcher found nothing it was confident about.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Word-level matching only", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Pronunciation and tajweed are not assessed. Check with a teacher.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Whether the reference recitation for this āyah is playing or being fetched.
    private func reciterState(for reference: VerseReference) -> ReciterRowState {
        if reciters.playing == reference { return .playing }
        if reciters.busy.contains(reference) { return .loading }
        return .idle
    }

    // MARK: - Playback

    /// Finds the retained segment whose audio covers this word.
    private func audioSegment(for evaluation: WordEvaluation) -> (AlignedAudioSegment, AudioChunk)? {
        guard let range = evaluation.timeRange else { return nil }
        for segment in model.segments where segment.startTime <= range.lowerBound && segment.endTime >= range.upperBound {
            if let audio = segment.audio(for: evaluation) {
                return (segment, audio)
            }
        }
        return nil
    }

    private func play(_ evaluation: WordEvaluation) {
        guard let (_, audio) = audioSegment(for: evaluation) else {
            playbackError = "No audio retained for this word."
            return
        }
        playbackError = nil
        Task {
            do {
                try await player.play(audio)
            } catch {
                playbackError = "Playback failed: \(error)"
            }
        }
    }
}

// MARK: - Rows

enum ReciterRowState { case idle, loading, playing }

private struct ReviewRow: View {
    let evaluation: WordEvaluation
    let isSelected: Bool
    let canPlay: Bool
    /// Nil when the reference-recitation offer is switched off.
    let reciterState: ReciterRowState?
    let onSelect: () -> Void
    let onPlay: () -> Void
    let onPlayReciter: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(WordStatusStyle.foreground(for: evaluation.status))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(evaluation.expectedText)
                        .font(.system(size: 19))
                        .environment(\.layoutDirection, .rightToLeft)
                    Text(evaluation.reference.description)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Text(WordStatusStyle.label(for: evaluation.status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let confidence = evaluation.recognizerConfidence {
                    Text("recognizer confidence \(confidence, format: .percent.precision(.fractionLength(0)))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)

            if canPlay {
                Button(action: onPlay) {
                    Image(systemName: "play.circle")
                }
                .buttonStyle(.borderless)
                .help("Play the audio the matcher judged")
            }

            // Hearing it recited correctly is the thing that actually helps, so it sits
            // beside the flag rather than somewhere in a menu.
            if let reciterState {
                Button(action: onPlayReciter) {
                    switch reciterState {
                    case .idle: Image(systemName: "person.wave.2")
                    case .loading: ProgressView().controlSize(.small)
                    case .playing: Image(systemName: "stop.circle.fill")
                    }
                }
                .buttonStyle(.borderless)
                .help("Hear this āyah from the reciter")
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
    }

    private var icon: String {
        switch evaluation.status {
        case .wrong: return "xmark.circle.fill"
        case .skipped: return "arrow.uturn.forward.circle.fill"
        case .uncertain: return "questionmark.circle.fill"
        case .correct: return "checkmark.circle.fill"
        case .notYetRecited: return "circle.dashed"
        }
    }
}

private struct InsertionRow: View {
    let insertion: InsertedWord
    let words: [WordEvaluation]

    private var isRepetition: Bool { insertion.kind == .repetition }

    private var anchorText: String {
        guard let index = insertion.afterTargetIndex,
              let word = words.first(where: { $0.targetIndex == index }) else {
            return "before the passage"
        }
        return "after “\(word.expectedText)”"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isRepetition ? "arrow.uturn.left.circle.fill" : "plus.circle.fill")
                .foregroundStyle(isRepetition ? Color.secondary : Color.purple)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(insertion.text)
                    .font(.system(size: 19))
                    .environment(\.layoutDirection, .rightToLeft)
                Text(isRepetition ? "Repeated \(anchorText)" : "Heard \(anchorText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }
}

/// What the tajweed checker is doing right now, in one line.
private struct TajweedStatusRow: View {
    let model: RecitationSessionModel
    @State private var settings = AppSettings.shared
    @State private var library = QuranLibrary.shared

    /// Rules on this page the audio checker could judge if every word were recognised.
    private var judgeable: Int {
        library.tajweedSpansByWord.values.reduce(0) { total, spans in
            total + spans.count { MuaalemTajweedAnalyzer.audioVerifiable.contains($0.rule) }
        }
    }

    var body: some View {
        Group {
            if !settings.analysesTajweedAudio {
                row("Not checking your recitation", detail: "Turn it on in Settings → Tajweed.", symbol: "circle.slash")
            } else if !settings.hasNeuralTajweed {
                row("Duration only", detail: "No Muaalem model installed, so only madd length is checked.", symbol: "exclamationmark.triangle")
            } else if model.segments.isEmpty && model.tajweedNotes.isEmpty {
                row(
                    "Ready",
                    detail: "\(judgeable) rules on this page can be checked, as you recite.",
                    symbol: "waveform.badge.magnifyingglass"
                )
            } else if model.isRunning && model.tajweedCoverage.examined == 0 && model.tajweedNotes.isEmpty {
                // Mid-recitation with nothing examined yet is not a finding. Saying
                // "nothing was examined" here would present a check that has not run as
                // one that ran and found nothing.
                row(
                    "Listening",
                    detail: "Rules are checked as each phrase is recognised.",
                    symbol: "waveform"
                )
            } else {
                // The count that matters is how many rules were actually looked at. A
                // rule is only examined when its word was recognised well enough to know
                // when it was recited, and most are not — reporting "nothing questioned"
                // against the page's total would credit the checker with inspecting text
                // it never heard.
                let coverage = model.tajweedCoverage
                let inspected = "\(coverage.examined) of \(max(coverage.judgeable, judgeable)) checkable rules were actually examined"
                let why = coverage.skippedWithoutTiming > 0
                    ? " — the rest sat on words the recogniser did not place, so there was no stretch of audio to read."
                    : "."
                if coverage.examined == 0 {
                    row(
                        "Nothing was examined",
                        detail: "No rule sat on a word confidently enough recognised to time. This says nothing about your tajweed.",
                        symbol: "questionmark.circle"
                    )
                } else if model.tajweedNotes.isEmpty {
                    row("Nothing questioned", detail: inspected + why, symbol: "checkmark.circle")
                } else {
                    row(
                        "\(model.tajweedNotes.count) to listen back to",
                        detail: inspected + why,
                        symbol: "waveform.badge.magnifyingglass"
                    )
                }
            }
        }
    }

    private func row(_ title: String, detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.weight(.medium))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct TajweedRow: View {
    let note: TajweedNote

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lightbulb.fill")
                .foregroundStyle(TajweedStyle.colour(for: note.rule))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(note.rule.title)
                        .font(.callout.weight(.medium))
                    Text(note.rule.arabicTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .environment(\.layoutDirection, .rightToLeft)
                }
                Text(note.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let measurement = note.measurement {
                    Text("heard \(measurement.observed, format: .number.precision(.fractionLength(2)))\(measurement.unit), your pace suggests \(measurement.expected, format: .number.precision(.fractionLength(2)))\(measurement.unit)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }
}
