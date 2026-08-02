import RecitationCore
import SwiftUI

/// ⌘, — matching sensitivity, audio segmentation, and model selection.
struct SettingsView: View {
    var body: some View {
        TabView {
            MatchingSettings()
                .tabItem { Label("Matching", systemImage: "text.magnifyingglass") }
            TextSettings()
                .tabItem { Label("Text", systemImage: "book.closed") }
            TajweedSettings()
                .tabItem { Label("Tajweed", systemImage: "waveform.badge.magnifyingglass") }
            ReciterSettings()
                .tabItem { Label("Reciter", systemImage: "person.wave.2") }
            AudioSettings()
                .tabItem { Label("Audio", systemImage: "waveform") }
            ModelSettings()
                .tabItem { Label("Model", systemImage: "cpu") }
        }
        .frame(width: 520, height: 380)
    }
}

private struct MatchingSettings: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Slider(value: $settings.matchThreshold, in: 0.5...1.0) {
                    Text("Match threshold")
                } minimumValueLabel: {
                    Text("lenient").font(.caption2)
                } maximumValueLabel: {
                    Text("strict").font(.caption2)
                }
                Text("Similarity at or above \(settings.matchThreshold, format: .percent.precision(.fractionLength(0))) counts as the same word. Raising this reports more mistakes, including false ones.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Word matching")
            }

            Section {
                Slider(value: $settings.uncertainThreshold, in: 0.2...settings.matchThreshold)
                Text("Between \(settings.uncertainThreshold, format: .percent.precision(.fractionLength(0))) and \(settings.matchThreshold, format: .percent.precision(.fractionLength(0))) similarity, a word is flagged “check this” rather than wrong. Widening this band makes the app more cautious.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Slider(value: $settings.confidenceFloor, in: 0.0...0.9)
                Text("If the recognizer's own confidence is below \(settings.confidenceFloor, format: .percent.precision(.fractionLength(0))), a mismatch is never escalated to a mistake.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Caution band")
            } footer: {
                Label(
                    "Defaults are tuned to under-report. A false “you made a mistake” costs more than a missed one.",
                    systemImage: "hand.raised.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            }

            Section {
                Button("Restore Defaults") { settings.resetTuningToDefaults() }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AudioSettings: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Picker("Detector", selection: $settings.vadKind) {
                    ForEach(VADKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .disabled(settings.locatedVADModel == nil)

                if settings.vadKind == .silero {
                    Slider(value: $settings.sileroThreshold, in: 0.1...0.9)
                    Text("Speech probability above \(settings.sileroThreshold, format: .percent.precision(.fractionLength(0))) opens a segment. Lower is safer here: clipping a word's quiet onset truncates it, and a truncated word reads as a wrong word.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Slider(value: $settings.energyThreshold, in: 0.001...0.08)
                    Text("RMS above \(settings.energyThreshold, format: .number.precision(.fractionLength(3))) counts as speech.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Slider(value: $settings.vadTrailingSilence, in: 0.2...3.0)
                Text("A segment closes after \(settings.vadTrailingSilence, format: .number.precision(.fractionLength(2)))s of silence. Shorter means quicker feedback; measured on real recitation, it also means markedly more words falsely flagged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Slider(value: $settings.vadPreRoll, in: 0.0...1.0)
                Text("Segments open with \(settings.vadPreRoll, format: .number.precision(.fractionLength(2)))s of preceding audio, so word onsets are not clipped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Voice activity detection")
            } footer: {
                if settings.locatedVADModel == nil {
                    Label(
                        "No Silero model installed — falling back to the energy gate, which cannot tell speech from noise. Run scripts/fetch-vad-model.sh.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 4)
                } else if settings.vadKind == .energy {
                    Label(
                        "The energy gate cannot distinguish a held vowel from a quiet passage, nor speech from noise. Kept only as a baseline.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 4)
                }
            }

            Section {
                Toggle("Turn the page automatically", isOn: $settings.autoTurnPage)
                Text("When you reach the end of a page while reciting, the muṣḥaf turns and the previous page's recording is discarded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Reciting")
            }

            Section {
                LabeledContent("Typeface", value: QuranFont.activeName)
                    .font(.caption)
                Text("The page sets itself: the size comes from the calligraphy's own metrics so every line fits its measure. Use ⌘+ / ⌘− to zoom the page instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Display")
            } footer: {
                if QuranFont.isBundledFontAvailable {
                    Text("Amiri Quran (SIL OFL) covers all 29 Quranic marks used in the Uthmani text. Most Arabic faces do not — Mishafi covers 25% and drops every waqf sign silently.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                } else {
                    Label(
                        "Falling back to Geeza Pro — complete, but not a muṣḥaf face. The bundled Amiri Quran could not be loaded.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 4)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Provenance of the bundled Quran text. Shown so the shipped scripture can be
/// audited rather than taken on trust.
private struct TextSettings: View {
    @State private var library = QuranLibrary.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Surahs", value: "\(library.surahs.count)")
                LabeledContent("Āyāt", value: library.databaseMetadata["ayah_count"] ?? "—")
                LabeledContent("Words", value: library.databaseMetadata["word_count"] ?? "—")
                LabeledContent("Script", value: library.databaseMetadata["script"] ?? "—")
            } header: {
                Text("Bundled text")
            }

            Section {
                Text(library.databaseMetadata["source"] ?? "unknown")
                    .font(.caption)
                LabeledContent("Built", value: library.databaseMetadata["generated_utc"] ?? "—")
                    .font(.caption)
                if let checksum = library.databaseMetadata["corpus_sha256"] {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Corpus SHA-256")
                            .font(.caption)
                        Text(checksum)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text("Provenance")
            } footer: {
                Text("scripts/build-quran-db.py rebuilds this database and refuses to emit one that fails its structural checks — 114 surahs, 6,236 āyāt, per-surah counts, and words that rejoin to exactly the verse text. Run it with --verify to re-check the shipped file.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .formStyle(.grouped)
    }
}

/// Tajweed has two halves with very different reliability, and the settings say so.
private struct TajweedSettings: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("Colour tajweed letters", isOn: $settings.showsTajweed)
                Text("Where a rule applies follows from the Uthmani text, so this is exact and does not depend on your recitation. Only the letters the rule falls on are coloured — the nūn that carries a ghunnah, the qāf that is echoed in qalqalah — not the whole word around them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Page is set in", selection: $settings.prefersCalligraphicPage) {
                    Text("Uthman Taha's calligraphy").tag(true)
                    Text("Unicode text").tag(false)
                }
                .pickerStyle(.inline)

                if settings.showsTajweed && settings.prefersCalligraphicPage {
                    Label(
                        "The calligraphic fonts draw a whole word as one glyph — رَّسُولٍ is the single character ﮙ — so there are no letters to colour, and the page shows no tajweed colour. Switch to Unicode text to see it. Colouring the entire word instead would claim the rule applies to letters that do not carry it.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                TajweedLegend()
                    .padding(.top, 4)
            } header: {
                Text("On the page")
            }

            Section {
                Toggle("Check tajweed against my recitation", isOn: $settings.analysesTajweedAudio)
                LabeledContent(
                    "Method",
                    value: settings.hasNeuralTajweed ? "Muaalem model" : "Duration only"
                )
                .font(.caption)
                if settings.hasNeuralTajweed {
                    Text("The Muaalem model (obadx, MIT) reports, frame by frame, whether what it heard was nasalised, echoed, heavy or light. Ghunnah, qalqalah and the four nūn-sākinah rules are checked against it; madd is still checked by duration.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("No model installed, so only elongation is checked — against the pace of your own recitation. Run scripts/convert-tajweed-model.py to enable the rest.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("From your recitation")
            } footer: {
                Label(
                    "Experimental, and off by default. Nothing here has been calibrated against expert reciters or reviewed by a qārī. The app only asks whether the attribute the text requires was actually present — it does not grade recitation — and it stays silent unless the model is confidently against the rule. Treat anything it says as a prompt to listen again, never as a correction.",
                    systemImage: "hand.raised.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.top, 4)
            }
        }
        .formStyle(.grouped)
    }
}

private struct TajweedLegend: View {
    private let shown: [TajweedRule] = [
        .maddLazim, .maddWajibMuttasil, .maddJaizMunfasil,
        .ghunnah, .qalqalah, .iqlab, .idgham, .ikhfa, .izhar, .maddAsli,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(shown, id: \.self) { rule in
                HStack(spacing: 8) {
                    Circle()
                        .fill(TajweedStyle.colour(for: rule))
                        .frame(width: 9, height: 9)
                    Text(rule.title).font(.caption)
                    Text(rule.arabicTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .environment(\.layoutDirection, .rightToLeft)
                    Spacer()
                }
            }
        }
    }
}

/// Reference recitation. The only feature in the app that uses the network.
private struct ReciterSettings: View {
    @State private var settings = AppSettings.shared
    @State private var reciters = ReciterModel.shared
    @State private var library = QuranLibrary.shared
    @State private var confirmingFullDownload = false

    var body: some View {
        Form {
            Section {
                Picker("Reciter", selection: $settings.reciterID) {
                    ForEach(Reciter.catalogue) { reciter in
                        Text("\(reciter.name) · \(reciter.style)").tag(reciter.id)
                    }
                }
                Text(settings.reciter.arabicName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .environment(\.layoutDirection, .rightToLeft)
                Toggle("Offer the reciter when an āyah is flagged", isOn: $settings.offersReciterOnMistake)
            } header: {
                Text("Reference recitation")
            }

            Section {
                if let progress = reciters.downloadProgress {
                    ProgressView(value: Double(progress.done), total: Double(progress.total)) {
                        Text("Downloading \(progress.done) of \(progress.total)")
                            .font(.caption)
                    }
                } else {
                    Button("Download this page") {
                        guard let page = library.page else { return }
                        reciters.download(page.verses, reciter: settings.reciter)
                    }
                    .disabled(library.page == nil)
                }

                LabeledContent(
                    "Cached",
                    value: reciters.cachedBytes > 0
                        ? ByteCountFormatter.string(fromByteCount: reciters.cachedBytes, countStyle: .file)
                        : "nothing yet"
                )
                .font(.caption)

                Button("Remove downloaded audio", role: .destructive) {
                    reciters.clearCache(for: settings.reciter)
                }
                .disabled(reciters.cachedBytes == 0)
            }

            Section {
                Button("Download the entire Quran") {
                    confirmingFullDownload = true
                }
                .disabled(reciters.isDownloading)
                .confirmationDialog(
                    "Download all 6,236 āyāt from \(settings.reciter.name)?",
                    isPresented: $confirmingFullDownload,
                    titleVisibility: .visible
                ) {
                    Button("Download about \(settings.reciter.approximateMegabytes) MB") {
                        Task { @MainActor in
                            guard let store = library.store else { return }
                            var all: [VerseReference] = []
                            for surah in 1...114 {
                                guard let target = try? await store.target(surah: surah) else { continue }
                                all.append(contentsOf: target.verses.map(\.reference))
                            }
                            reciters.download(all, reciter: settings.reciter)
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This fetches every āyah one at a time and keeps them, so the whole muṣḥaf works offline afterwards. It takes a while and cannot be resumed mid-āyah — though anything already downloaded is skipped if you run it again.")
                }

                Label(
                    "About \(settings.reciter.approximateMegabytes) MB for \(settings.reciter.name). Downloading a single page instead is enough for practising, and far quicker.",
                    systemImage: "internaldrive"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Downloads")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Āyāt are fetched one at a time, only when you play them or download a page, and kept afterwards — a page you have fetched once works offline.")
                    Text("This is the only part of the app that uses the network. Nothing that judges your recitation does: the model, the voice detection and the muṣḥaf are all bundled and run on-device.")
                        .foregroundStyle(.secondary)
                    Text("Audio from everyayah.com. A full reciter is roughly \(settings.reciter.approximateMegabytes) MB if you download everything.")
                        .foregroundStyle(.secondary)
                }
                .font(.caption2)
                .padding(.top, 4)
            }

            if let error = reciters.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .task(id: settings.reciterID) {
            await reciters.refreshCacheSize(for: settings.reciter)
        }
    }
}

private struct ModelSettings: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                if settings.availableModelSizes.isEmpty {
                    Label(
                        "No speech model installed. Transcription falls back to a canned reading, so the highlighting will not reflect what you recited. Run scripts/convert-model.sh.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    // Only installed sizes are offered. Choosing one without weights makes
                    // the locator return nil, and the pipeline then quietly swaps in the
                    // scripted recogniser — the app would look like it was working while
                    // reporting a canned reading as your recitation.
                    Picker("Size", selection: $settings.modelSize) {
                        ForEach(settings.availableModelSizes, id: \.self) { size in
                            Text(size.rawValue.capitalized).tag(size)
                        }
                    }
                }

                let missing = SpeechModelConfiguration.Size.allCases
                    .filter { !settings.availableModelSizes.contains($0) }
                if !missing.isEmpty {
                    LabeledContent("Not installed", value: missing.map(\.rawValue).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Speech recognition")
            } footer: {
                if let located = settings.locatedModel {
                    VStack(alignment: .leading, spacing: 3) {
                        LabeledContent("File", value: located.url.lastPathComponent)
                        LabeledContent(
                            "Encoder",
                            value: located.hasCoreMLEncoder ? "Core ML, Neural Engine" : "Metal / CPU"
                        )
                        if !located.hasCoreMLEncoder {
                            Text("No Core ML encoder beside these weights — scripts/convert-model.sh builds one.")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.caption2)
                    .padding(.top, 4)
                }
            }

            Section {
                Text("Only the Quran-tuned base model is built here. The other sizes exist because whisper publishes them, but there is no Quran-tuned conversion of them — building one means pointing scripts/convert-model.sh at a different checkpoint.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Adding a size")
            }

            Section {
                LabeledContent(
                    "Analyzer",
                    value: !settings.analysesTajweedAudio
                        ? "off"
                        : (settings.hasNeuralTajweed ? "Muaalem model" : "duration only")
                )
                Text("Configured in the Tajweed tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Tajweed")
            }
        }
        .formStyle(.grouped)
        .task { settings.clampModelSizeToInstalled() }
        .onChange(of: settings.modelSize) { _, _ in settings.invalidateComponents() }
    }
}
