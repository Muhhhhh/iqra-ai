import RecitationCore
import SwiftUI

/// Desktop shell: passage list on the left, mushaf in the middle, review on the right.
///
/// Everything here is presentation. Session logic lives in `RecitationSessionModel`
/// inside `RecitationCore`, so this file has no idea how VAD, ASR, or alignment work.
struct ContentView: View {
    @State private var settings = AppSettings.shared
    @State private var model = RecitationSessionModel { AppSettings.shared.makePipeline() }
    @State private var library = QuranLibrary.shared
    @State private var pins = PinStore.shared
    @State private var selectedWord: Int?
    /// Furthest word revealed by asking for a hint, in fog modes. -1 is none.
    @State private var revealedThrough = -1
    @State private var showsReviewPanel = true
    @State private var inspectedWord: InspectedWord?
    /// Guards against turning twice off one burst of alignment updates.
    @State private var isTurningPage = false
    /// When the last automatic turn happened, so a burst cannot cascade through pages.
    @State private var lastAutoTurn: Date?
    /// The page currently loaded into the session, so the one being left can be named.
    @State private var loadedPage: Int?
    /// Marks from pages recently left, newest last.
    ///
    /// A single slot was not enough once the page turns by itself: reciting page N,
    /// turning to N+1, then reciting anything at all on N+1 put N+1 in the only slot and
    /// evicted N — so going back to the page you had just recited showed nothing, which
    /// is precisely when you want it. A few pages are kept instead. Only the marks: the
    /// audio is released on every turn, so this stays small.
    @State private var heldPages: [(page: Int, results: RecitationSessionModel.SessionResults)] = []
    private static let heldPageLimit = 6
    /// True while the page shows marks recalled from before rather than a live session.
    @State private var isShowingHeldMarks = false
    @State private var pageTurnTask: Task<Void, Never>?

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 360)
        } detail: {
            HStack(spacing: 0) {
                mushaf
                if showsReviewPanel {
                    Divider()
                    ReviewPanel(
                        model: model,
                        selectedWord: $selectedWord,
                        reportsMistakes: settings.practiceMode.reportsMistakes
                    )
                        .frame(width: 320)
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .toolbar { toolbar }
        .task { await load() }
        .onChange(of: library.currentPage) { _, _ in Task { await load() } }
        .onChange(of: model.words) { _, _ in autoTurnIfFinished() }
        .onChange(of: settings.inputSource) { _, _ in resetSession() }
        .onChange(of: settings.mistakeStyle) { _, _ in resetSession() }
        .onChange(of: settings.recognizerKind) { _, _ in resetSession() }
        .onReceive(NotificationCenter.default.publisher(for: .toggleRecitation)) { _ in toggle() }
        .onReceive(NotificationCenter.default.publisher(for: .resetRecitation)) { _ in retry() }
        .onReceive(NotificationCenter.default.publisher(for: .revealNextWord)) { _ in revealNextWord() }
        .onChange(of: settings.practiceMode) { _, _ in revealedThrough = -1 }
        .onReceive(NotificationCenter.default.publisher(for: .selectNextMistake)) { _ in step(by: 1) }
        .onReceive(NotificationCenter.default.publisher(for: .selectPreviousMistake)) { _ in step(by: -1) }
    }

    // MARK: - Mushaf

    private var mushaf: some View {
        VStack(spacing: 0) {
            StubBanner(settings: settings)
            pageArea
            Divider()
            PageNavigator(library: library, settings: settings)
            Divider()
            StatusBar(
                model: model,
                settings: settings,
                isRecalled: isShowingHeldMarks,
                reportsMistakes: settings.practiceMode.reportsMistakes
            )
        }
        .frame(minWidth: 520)
    }

    @ViewBuilder
    private var pageArea: some View {
        if let page = library.page {
            MushafPageView(
                page: page,
                words: model.words,
                surahNames: library.surahArabicNames,
                selection: $selectedWord,
                zoom: Binding(
                    get: { CGFloat(settings.pageZoom) },
                    set: { settings.pageZoom = Double($0) }
                ),
                tajweed: settings.showsTajweed ? library.tajweedSpansByWord : [:],
                prefersCalligraphy: settings.prefersCalligraphicPage,
                tajweedFindings: settings.practiceMode.reportsMistakes
                    ? Dictionary(
                        model.tajweedNotes.map { ($0.targetIndex, $0.rule) },
                        uniquingKeysWith: { first, _ in first }
                      )
                    : [:],
                mode: settings.practiceMode,
                revealedThrough: revealedThrough,
                onSelectWord: { word in
                    Task { await showTranslation(for: word) }
                }
            )
            .padding(20)
            .popover(item: $inspectedWord) { inspected in
                WordTranslationPopover(word: inspected)
            }
        } else {
            ContentUnavailableView(
                "No page loaded",
                systemImage: "book.closed",
                description: Text("Run scripts/build-quran-db.py to build the muṣḥaf database.")
            )
        }
    }

    // MARK: - Toolbar
    //
    // Three groups, each answering one question: what do I do now (left), what is the app
    // hearing (centre), what do I want on screen (right). The transport buttons stay
    // together rather than being split around the meter.

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button(action: toggle) {
                Label(
                    model.isRunning ? "Stop" : "Start",
                    systemImage: model.isRunning ? "stop.fill" : "mic.fill"
                )
            }
            .help(model.isRunning ? "Stop reciting (⌘R)" : "Start reciting (⌘R)")
            .disabled(model.target == nil)

            Button(action: retry) {
                Label("Retry", systemImage: "arrow.counterclockwise")
            }
            .help("Discard this attempt and recite the passage again (⌘⇧R)")
            .disabled(model.target == nil)
        }

        ToolbarItem(placement: .principal) {
            ListeningIndicator(model: model, label: stateLabel)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Mode", selection: $settings.practiceMode) {
                ForEach(PracticeMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 210)
            .help(settings.practiceMode.explanation)

            if settings.practiceMode.hidesUnrecitedText {
                Button {
                    revealNextWord()
                } label: {
                    Label("Reveal next word", systemImage: "eye")
                }
                .help("Show the next word without reciting it (⌘H)")
            }

            PinMenu(
                library: library,
                pins: pins,
                currentReference: currentReference
            )

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showsReviewPanel.toggle() }
            } label: {
                Label("Review", systemImage: showsReviewPanel ? "sidebar.right" : "sidebar.leading")
            }
            .help("Toggle the review panel")

            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Settings (⌘,)")
        }
    }

    private var stateLabel: String {
        switch model.state {
        case .idle: return "Ready"
        case .starting: return "Starting…"
        case .listening: return "Listening"
        case .interrupted: return "Interrupted"
        case .finishing: return "Finishing…"
        case .stopped: return model.words.contains { $0.status != .notYetRecited } ? "Done" : "Ready"
        }
    }

    /// The āyah the reader is looking at: the selected word's, or the page's first.
    private var currentReference: VerseReference? {
        guard let page = library.page else { return nil }
        if let selectedWord,
           let word = page.recitedWords.first(where: { $0.targetIndex == selectedWord }) {
            return word.reference
        }
        return page.verses.first
    }

    // MARK: - Actions

    private func toggle() {
        if model.isRunning {
            model.stop()
        } else {
            selectedWord = nil
            // Reciting again replaces the recalled marks; keeping the old ones on screen
            // beside new ones would blur which attempt each verdict came from.
            if isShowingHeldMarks {
                model.retry()
                isShowingHeldMarks = false
                return
            }
            model.start()
        }
    }

    /// Show the next word without reciting it.
    ///
    /// The point of fog is to recite from memory, and the point of a hint is that being
    /// stuck should not end the session. It reveals exactly one word past wherever the
    /// reciter has actually reached, so it cannot be held down to uncover the page.
    private func revealNextWord() {
        guard settings.practiceMode.hidesUnrecitedText else { return }
        let reached = model.words.last { $0.status != .notYetRecited }?.targetIndex ?? -1
        revealedThrough = min(max(revealedThrough, reached) + 1, (model.words.last?.targetIndex ?? 0))
    }

    private func resetSession() {
        selectedWord = nil
        model.reset()
    }

    /// Start over on the same passage — the common action when practising.
    private func retry() {
        selectedWord = nil
        pageTurnTask?.cancel()
        isTurningPage = false
        lastAutoTurn = nil
        isShowingHeldMarks = false
        revealedThrough = -1
        model.retry()
    }

    /// Look up the meaning of a tapped word, including its āyah's translation.
    private func showTranslation(for word: MushafWord) async {
        guard word.kind == .word else { return }
        let verse = await library.translation(of: word.reference)
        inspectedWord = InspectedWord(
            text: word.text,
            reference: word.reference,
            translation: word.translation,
            transliteration: word.transliteration,
            verseTranslation: verse
        )
    }

    /// Cycle through mistakes in reading order (⌘↓ / ⌘↑).
    private func step(by offset: Int) {
        let mistakes = model.words.filter { $0.status.isMistake }.map(\.targetIndex)
        guard !mistakes.isEmpty else { return }
        guard let current = selectedWord, let position = mistakes.firstIndex(of: current) else {
            selectedWord = offset > 0 ? mistakes.first : mistakes.last
            return
        }
        let next = (position + offset + mistakes.count) % mistakes.count
        selectedWord = mistakes[next]
    }

    private func load() async {
        guard let target = await library.makeTarget() else { return }
        let page = library.currentPage
        settings.target = target
        selectedWord = nil

        // Hold on to the page being left, so turning back to it shows what you recited
        // rather than a blank page. One page only: the moment you turn onward again the
        // slot is taken by the page you were just on. The audio is not kept — that was
        // already released when the page turned — so this is the marks, not a session
        // you can carry on with.
        if let outgoing = loadedPage, outgoing != page, !model.results.isEmpty {
            heldPages.removeAll { $0.page == outgoing }
            heldPages.append((page: outgoing, results: model.results))
            if heldPages.count > Self.heldPageLimit { heldPages.removeFirst() }
        }
        loadedPage = page
        revealedThrough = -1

        // While reciting, hand the new page to the running session instead of resetting
        // it — that is what makes an auto-turn seamless rather than a stop and restart.
        if model.isRunning {
            model.retarget(target)
        } else if let held = heldPages.last(where: { $0.page == page }) {
            model.restore(held.results, for: target)
            isShowingHeldMarks = true
        } else {
            model.setTarget(target)
            isShowingHeldMarks = false
        }
        isTurningPage = false
    }

    /// Turn to the next page once the reciter reaches the end of this one.
    ///
    /// Only while actually listening: outside a session the page should stay where the
    /// reader put it.
    private func autoTurnIfFinished() {
        guard settings.autoTurnPage,
              model.isRunning,
              !isTurningPage,
              library.canGoForward
        else { return }

        // The verdicts must belong to the page on screen. Turning the page hands the
        // session a new passage, but an alignment for the *old* one can still be in
        // flight and arrive afterwards — and since it ended at the old page's last word,
        // it satisfies "reached the end" immediately and turns again. Each turn then
        // releases the next stale update, and the muṣḥaf runs away several pages from
        // where the reciter actually is.
        guard let page = library.page,
              let lastRecited = model.words.last(where: { $0.status != .notYetRecited }),
              page.verses.contains(lastRecited.reference)
        else { return }

        // A second guard on the same failure, for the case where a stale alignment does
        // happen to fall inside the new page: a reciter cannot finish two pages in a
        // couple of seconds, so a turn that soon is the pipeline talking, not them.
        if let lastAutoTurn, Date().timeIntervalSince(lastAutoTurn) < 3 { return }

        guard model.hasReachedEnd else { return }

        isTurningPage = true
        // Settle before turning. The page should not move the instant the closing word
        // registers — a reciter usually pauses on the last word of a page, and pulling
        // the text away mid-breath is worse than turning a moment late.
        pageTurnTask?.cancel()
        pageTurnTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1400))
            guard !Task.isCancelled, model.isRunning, library.canGoForward else {
                isTurningPage = false
                return
            }
            lastAutoTurn = Date()
            library.goToPage(library.currentPage + 1)
        }
    }
}

// MARK: - Header pieces

/// Waveform plus state, as one unit rather than two loose toolbar items.
private struct ListeningIndicator: View {
    let model: RecitationSessionModel
    let label: String

    var body: some View {
        HStack(spacing: 10) {
            LevelMeter(level: model.level, isActive: model.isRunning, isClipping: model.isClipping)
                .frame(width: 132, height: 18)
            Text(label)
                .font(.callout.weight(model.isRunning ? .semibold : .regular))
                .foregroundStyle(model.isRunning ? .primary : .secondary)
                .frame(minWidth: 74, alignment: .leading)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: Capsule())
        .help(model.isClipping
              ? "Input is clipping — move back from the mic or lower the input gain"
              : "What the microphone is picking up")
    }
}

/// Pin the place you are in, and jump back to a place you pinned.
private struct PinMenu: View {
    @Bindable var library: QuranLibrary
    @Bindable var pins: PinStore
    let currentReference: VerseReference?

    private var currentSurah: Int? { currentReference?.surah ?? library.page?.surahs.first }

    private var isCurrentPagePinned: Bool {
        guard let reference = currentReference else { return false }
        return pins.contains(surah: reference.surah, ayah: reference.ayah)
            || pins.contains(surah: reference.surah)
    }

    var body: some View {
        Menu {
            if let reference = currentReference, let page = library.page {
                Button {
                    pins.toggle(surah: reference.surah, ayah: reference.ayah, page: page.number)
                } label: {
                    Label(
                        pins.contains(surah: reference.surah, ayah: reference.ayah)
                            ? "Unpin āyah \(reference.description)"
                            : "Pin āyah \(reference.description)",
                        systemImage: "bookmark"
                    )
                }
            }

            if let surah = currentSurah, let page = library.page {
                Button {
                    pins.toggle(surah: surah, page: page.number)
                } label: {
                    Label(
                        pins.contains(surah: surah)
                            ? "Unpin surah \(library.surahNames[surah] ?? "\(surah)")"
                            : "Pin surah \(library.surahNames[surah] ?? "\(surah)")",
                        systemImage: "bookmark.square"
                    )
                }
            }

            if !pins.pins.isEmpty {
                Divider()
                Section("Pinned") {
                    ForEach(pins.pins) { pin in
                        Button(PinLabel.title(pin, names: library.surahNames)) {
                            library.goToPage(pin.page)
                        }
                    }
                }
                Divider()
                Button("Remove all pins", role: .destructive) { pins.removeAll() }
            }
        } label: {
            Label("Pins", systemImage: isCurrentPagePinned ? "bookmark.fill" : "bookmark")
        }
        .help("Pin this āyah or surah, or jump to one you pinned")
    }
}

enum PinLabel {
    static func title(_ pin: Pin, names: [Int: String]) -> String {
        let name = names[pin.surah] ?? "Surah \(pin.surah)"
        return pin.isSurah ? name : "\(name) \(pin.surah):\(pin.ayah ?? 0)"
    }
}

// MARK: - Sidebar

private struct SidebarView: View {
    @State private var settings = AppSettings.shared
    @State private var library = QuranLibrary.shared
    @State private var pins = PinStore.shared

    private var vadLabel: String {
        guard settings.inputSource == .microphone else { return "Passthrough" }
        return settings.vadKind == .silero && settings.locatedVADModel != nil ? "Silero" : "Energy"
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = library.loadError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }

            List(selection: $library.selectedSurah) {
                if !pins.pins.isEmpty {
                    Section("Pinned") {
                        ForEach(pins.pins) { pin in
                            PinRow(pin: pin, names: library.surahNames, arabic: library.surahArabicNames)
                                .contentShape(Rectangle())
                                .onTapGesture { library.goToPage(pin.page) }
                                .contextMenu {
                                    Button("Remove pin", role: .destructive) { pins.remove(pin) }
                                }
                        }
                    }
                }

                Section {
                    ForEach(library.filteredSurahs) { surah in
                        SurahRow(surah: surah)
                            .tag(surah.number)
                    }
                } header: {
                    Text("Surah")
                }

                Section("Open page") {
                    PageSummary(library: library)
                }

                Section("Pipeline") {
                    PipelineRow(stage: "Capture", value: settings.inputSource == .microphone ? "AVAudioEngine" : "Scripted", isStub: settings.inputSource == .scripted)
                    PipelineRow(
                        stage: "VAD",
                        value: vadLabel,
                        isStub: settings.inputSource == .microphone
                            && !(settings.vadKind == .silero && settings.locatedVADModel != nil)
                    )
                    PipelineRow(
                        stage: "ASR",
                        value: settings.recognizerKind == .whisper && settings.locatedModel != nil
                            ? "Whisper \(settings.modelSize.rawValue)"
                            : "Scripted",
                        isStub: !(settings.recognizerKind == .whisper && settings.locatedModel != nil)
                    )
                    if let located = settings.locatedModel {
                        PipelineRow(
                            stage: "Encoder",
                            value: located.hasCoreMLEncoder ? "Core ML (ANE)" : "Metal / CPU",
                            isStub: !located.hasCoreMLEncoder
                        )
                    }
                    PipelineRow(stage: "Text", value: library.isAvailable ? "SQLite (6,236)" : "unavailable", isStub: !library.isAvailable)
                    PipelineRow(stage: "Matcher", value: "Token aligner", isStub: false)
                    PipelineRow(
                        stage: "Tajweed",
                        value: !settings.analysesTajweedAudio
                            ? "rules only"
                            : (settings.hasNeuralTajweed ? "Muaalem model" : "duration only"),
                        isStub: settings.analysesTajweedAudio && !settings.hasNeuralTajweed
                    )
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $library.searchText, placement: .sidebar, prompt: "Surah name or number")
        }
    }
}

private struct PinRow: View {
    let pin: Pin
    let names: [Int: String]
    let arabic: [Int: String]

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: pin.isSurah ? "bookmark.square.fill" : "bookmark.fill")
                .font(.caption)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(names[pin.surah] ?? "Surah \(pin.surah)")
                Text(pin.isSurah ? "whole surah · page \(pin.page)" : "āyah \(pin.surah):\(pin.ayah ?? 0) · page \(pin.page)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if let name = arabic[pin.surah] {
                Text(name)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .environment(\.layoutDirection, .rightToLeft)
            }
        }
        .padding(.vertical, 1)
    }
}

private struct SurahRow: View {
    let surah: SurahInfo

    var body: some View {
        HStack(spacing: 10) {
            Text("\(surah.number)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(surah.nameSimple)
                Text("\(surah.nameEnglish) · \(surah.ayahCount) āyāt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(surah.nameArabic)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .environment(\.layoutDirection, .rightToLeft)
        }
        .padding(.vertical, 1)
    }
}

/// What the open page contains, and how much of it there is to recite.
private struct PageSummary: View {
    @Bindable var library: QuranLibrary
    @State private var wordCount: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let page = library.page {
                Text("Page \(page.number) · Juz’ \(page.juz)")
                    .font(.callout.monospacedDigit())
                Text(page.surahs.compactMap { library.surahNames[$0] }.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let first = page.verses.first, let last = page.verses.last {
                    Text("\(first.description)–\(last.description)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let wordCount {
                Text("\(wordCount) words to recite")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .task(id: library.currentPage) {
            wordCount = await library.makeTarget()?.flattenedWords.count
        }
    }
}


private struct PipelineRow: View {
    let stage: String
    let value: String
    let isStub: Bool

    var body: some View {
        HStack {
            Text(stage).font(.caption)
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundStyle(isStub ? Color.orange : Color.secondary)
        }
        .help(isStub ? "Placeholder — replaced in a later build step" : "Production implementation")
    }
}

/// States plainly whether the highlighting reflects what the user actually recited.
///
/// The app must never let a screen of unmarked text imply an approved recitation when it
/// is replaying a script or not listening at all.
private struct StubBanner: View {
    let settings: AppSettings

    private enum Level {
        case notListening
        case fakeTranscript
        case realButLimited
    }

    private var level: Level {
        if settings.inputSource == .scripted { return .notListening }
        if settings.recognizerKind == .scripted || settings.locatedModel == nil { return .fakeTranscript }
        return .realButLimited
    }

    private var isWarning: Bool { level != .realButLimited }

    /// Expanded on first sight, then collapsed to a single line. The warning cases are
    /// never collapsible: if the app is not listening, that has to stay legible.
    @State private var isExpanded = true

    var body: some View {
        HStack(alignment: isExpanded ? .top : .firstTextBaseline, spacing: 8) {
            Image(systemName: isWarning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.caption)
                .foregroundStyle(isWarning ? Color.orange : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                if isExpanded || isWarning {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if !isWarning {
                Button(isExpanded ? "Less" : "Why") {
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isWarning ? Color.orange.opacity(0.12) : Color.secondary.opacity(0.06))
        .overlay(alignment: .bottom) { Divider() }
        .onAppear { isExpanded = isWarning }
    }

    private var title: String {
        switch level {
        case .notListening: return "Not listening to your microphone"
        case .fakeTranscript: return "Speech recognition is stubbed"
        case .realButLimited: return "Word matching only — tajweed is not assessed"
        }
    }

    private var detail: String {
        switch level {
        case .notListening:
            return "Input is set to “Scripted (no mic)”, so the app runs through the passage on a timer without hearing you. Switch Input to “Microphone” in the sidebar."
        case .fakeTranscript:
            return settings.locatedModel == nil
                ? "No Whisper model is installed, so transcription replays a canned reading. Run scripts/convert-model.sh."
                : "The recognizer is set to the scripted stub, so the highlighting reflects a canned reading rather than your recitation."
        case .realButLimited:
            return "Whisper is transcribing your recitation on-device. It checks which words were said, not how they were pronounced — and it can misrecognise. Treat flags as prompts to listen again, not as verdicts."
        }
    }
}

// MARK: - Status bar

private struct StatusBar: View {
    let model: RecitationSessionModel
    let settings: AppSettings
    /// Marks brought back from the last time this page was open, not a live session.
    var isRecalled: Bool = false
    /// False in fog, where nothing is judged and so nothing is counted.
    var reportsMistakes: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 18) {
                Label("\(model.correctCount) recited", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if reportsMistakes {
                    Label("\(model.mistakeCount) to review", systemImage: "questionmark.circle.fill")
                        .foregroundStyle(model.mistakeCount > 0 ? .orange : .secondary)
                }
                let additions = model.insertions.count { $0.kind == .addition }
                if additions > 0 {
                    Label("\(additions) unplaced", systemImage: "questionmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .help("Sounds the recogniser could not match to the text. Usually its own mishearing rather than words you added — not counted as mistakes.")
                }
                let repetitions = model.insertions.count { $0.kind == .repetition }
                if repetitions > 0 {
                    Label("\(repetitions) repeated", systemImage: "arrow.uturn.left.circle.fill")
                        .foregroundStyle(.secondary)
                        .help("Words you went back over while correcting yourself — not counted as mistakes")
                }
                if isRecalled {
                    Label("From your last attempt on this page", systemImage: "clock.arrow.circlepath")
                        .foregroundStyle(.secondary)
                        .help("These marks were kept when you turned away from this page. The audio was released, so nothing here can be replayed — press Start to recite it again.")
                }
                if model.isClipping {
                    Label("Input clipping", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .help("Clipping costs more accuracy than background noise. Move back from the microphone, or lower the input gain in System Settings → Sound.")
                }
                Spacer()
                Label(
                    "\(model.segments.count) segment\(model.segments.count == 1 ? "" : "s") retained",
                    systemImage: "waveform"
                )
                .foregroundStyle(.secondary)
                .help("Audio and timestamps kept for tajweed analysis in v2")
            }
            .font(.callout)

            if !model.transcript.isEmpty {
                Text(model.transcript)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .environment(\.layoutDirection, .rightToLeft)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .lineLimit(2)
                    .help("What the recognizer heard")
            }

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

// MARK: - Word translation

/// A word the user tapped, with everything needed to explain it.
struct InspectedWord: Identifiable {
    let text: String
    let reference: VerseReference
    let translation: String
    let transliteration: String
    let verseTranslation: String

    var id: String { "\(reference):\(text)" }
}

private struct WordTranslationPopover: View {
    let word: InspectedWord
    @State private var pins = PinStore.shared
    @State private var library = QuranLibrary.shared

    private var isPinned: Bool {
        pins.contains(surah: word.reference.surah, ayah: word.reference.ayah)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(word.text)
                    .font(QuranFont.mushaf(size: 34))
                    .environment(\.layoutDirection, .rightToLeft)
                Spacer(minLength: 16)
                Text(word.reference.description)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    pins.toggle(
                        surah: word.reference.surah,
                        ayah: word.reference.ayah,
                        page: library.currentPage
                    )
                } label: {
                    Image(systemName: isPinned ? "bookmark.fill" : "bookmark")
                }
                .buttonStyle(.borderless)
                .help(isPinned ? "Unpin this āyah" : "Pin this āyah")
            }

            if !word.transliteration.isEmpty {
                Text(word.transliteration)
                    .font(.callout.italic())
                    .foregroundStyle(.secondary)
            }

            if !word.translation.isEmpty {
                Text(word.translation)
                    .font(.title3)
            }

            if !word.verseTranslation.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Āyah \(word.reference.ayah)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(word.verseTranslation)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("Translations are an interpretation of the meaning, not the Quran itself.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }
}

/// Page-by-page navigation across the 604 pages of the muṣḥaf.
private struct PageNavigator: View {
    @Bindable var library: QuranLibrary
    @Bindable var settings: AppSettings
    @State private var pageField: String = ""

    var body: some View {
        // The muṣḥaf reads right to left, so it also *turns* right to left: the next page
        // lies to the left of the one you are on. Latin-book arrows would send you
        // backwards through the book.
        HStack(spacing: 14) {
            Button { library.goToPage(library.currentPage + 1) } label: {
                Label("Next page", systemImage: "chevron.left")
            }
            .disabled(!library.canGoForward)
            .keyboardShortcut(.leftArrow, modifiers: [.command])
            .help("Next page (⌘←)")

            Spacer()

            HStack(spacing: 6) {
                Text("Page")
                    .foregroundStyle(.secondary)
                TextField("", text: $pageField)
                    .frame(width: 46)
                    .multilineTextAlignment(.center)
                    .onSubmit {
                        if let value = Int(pageField) { library.goToPage(value) }
                        pageField = "\(library.currentPage)"
                    }
                Text("of \(MushafPage.count)")
                    .foregroundStyle(.secondary)
            }
            .font(.callout.monospacedDigit())

            Spacer()

            ZoomControl(settings: settings)

            Button { library.goToPage(library.currentPage - 1) } label: {
                Label("Previous page", systemImage: "chevron.right")
            }
            .disabled(!library.canGoBack)
            .keyboardShortcut(.rightArrow, modifiers: [.command])
            .help("Previous page (⌘→)")
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .onAppear { pageField = "\(library.currentPage)" }
        .onChange(of: library.currentPage) { _, value in pageField = "\(value)" }
    }
}

/// Page zoom. 1× fits the page to the window; beyond that the page scrolls.
private struct ZoomControl: View {
    @Bindable var settings: AppSettings

    var body: some View {
        HStack(spacing: 6) {
            Button { settings.pageZoom = max(settings.pageZoom / 1.25, 0.5) } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .disabled(settings.pageZoom <= 0.5001)
            .help("Zoom out (⌘−)")

            Button {
                settings.pageZoom = 1.0
            } label: {
                Text(settings.pageZoom == 1.0 ? "Fit" : "\(Int(settings.pageZoom * 100))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 42)
            }
            .buttonStyle(.plain)
            .help("Fit the page to the window (⌘0)")

            Button { settings.pageZoom = min(settings.pageZoom * 1.25, 5.0) } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .disabled(settings.pageZoom >= 4.999)
            .help("Zoom in (⌘+)")
        }
        .labelStyle(.iconOnly)
    }
}
