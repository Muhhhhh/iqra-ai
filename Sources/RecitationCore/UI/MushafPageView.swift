#if canImport(SwiftUI)
import SwiftUI

/// A page of the muṣḥaf, set as printed: fifteen lines, canonical line breaks, each line
/// stretched flush to both margins.
///
/// The page is laid out into a fixed canvas and then scaled to fit, rather than reflowed
/// to the window. That is what keeps the line breaks canonical — the seventh line of page
/// three ends on the same word here as in a printed copy, at any window size. A ḥāfiẓ
/// recalls the shape of the page, so reflowing it would defeat the purpose.
/// Everything about a page that depends only on the page itself: whether it can be set
/// in the calligraphic font, which font that is, and the size at which its widest line
/// fits the measure.
///
/// Computed once per page and cached. Deriving it on demand cost 0.51 ms — it measures
/// every word with Core Text — and SwiftUI reads it once per line *and* once per word,
/// about 153 times per render. That was ~78 ms of measurement per frame against a 16 ms
/// budget, which is what made zooming and live highlighting stutter.
public struct MushafPageLayout {
    public let usesCalligraphy: Bool
    public let fontName: String?
    public let fontSize: CGFloat
    public let spacingRatio: CGFloat

    /// The font for body words on this page.
    public var wordFont: Font {
        if let fontName { return .custom(fontName, fixedSize: fontSize) }
        return QuranFont.mushaf(size: fontSize)
    }
}

@MainActor
public enum MushafPageLayoutCache {
    /// Pages are immutable for a given number, so the entry never goes stale. The
    /// rendering choice is part of the key: the two modes measure differently, and
    /// serving one's layout to the other overflows the page.
    private struct Key: Hashable {
        let page: Int
        let calligraphic: Bool
    }
    private static var entries: [Key: MushafPageLayout] = [:]

    public static func layout(
        for page: MushafPage,
        measure: CGFloat,
        baseFontSize: CGFloat,
        naskhSpacingRatio: CGFloat,
        calligraphicSpacingRatio: CGFloat,
        bookFontSize: CGFloat,
        prefersCalligraphy: Bool = true
    ) -> MushafPageLayout {
        let key = Key(page: page.number, calligraphic: prefersCalligraphy)
        if let cached = entries[key] { return cached }

        let hasCodes = page.lines.contains { line in line.words.contains { !$0.code.isEmpty } }
        let calligraphic = prefersCalligraphy && hasCodes
            && !page.recitedWords.isEmpty && QCFFont.register(page: page.number)

        let layout: MushafPageLayout
        if calligraphic {
            let name = QCFFont.name(forPage: page.number)
            layout = MushafPageLayout(
                usesCalligraphy: true,
                fontName: name,
                fontSize: MushafMetrics.fittedFontSize(
                    lines: page.lines.map { $0.words.map(\.code) },
                    measure: measure,
                    preferred: baseFontSize * 1.5,
                    minimumSpacingRatio: calligraphicSpacingRatio,
                    fontName: name
                ),
                spacingRatio: calligraphicSpacingRatio
            )
        } else {
            let size = page.number <= 2
                ? MushafMetrics.fittedFontSize(
                    lines: page.lines.map { $0.words.map(\.text) },
                    measure: measure,
                    preferred: baseFontSize,
                    minimumSpacingRatio: naskhSpacingRatio
                  )
                : bookFontSize
            layout = MushafPageLayout(
                usesCalligraphy: false,
                fontName: nil,
                fontSize: size,
                spacingRatio: naskhSpacingRatio
            )
        }

        entries[key] = layout
        return layout
    }
}

public struct MushafPageView: View {
    /// Canvas proportions follow a printed muṣḥaf page.
    private static let canvasWidth: CGFloat = 620
    private static let horizontalMargin: CGFloat = 34
    private static let baseFontSize: CGFloat = 33

    private let page: MushafPage
    private let evaluations: [Int: WordEvaluation]
    private let surahNames: [Int: String]
    @Binding private var selection: Int?
    private let onSelectWord: (MushafWord) -> Void
    /// Where each tajweed rule falls, per target word, when the overlay is on.
    ///
    /// Positions, not one rule per word: a rule applies to particular letters — the
    /// nūn of a ghunnah, the qāf of a qalqalah — and tinting the whole word says
    /// something about the other letters that is not true.
    private let tajweed: [Int: [TajweedOccurrence]]
    /// Set the page in Uthman Taha's calligraphy when it is available.
    ///
    /// Turning this off falls back to Unicode text, which is the only way to colour
    /// tajweed letter by letter — see `MushafWordView`.
    private let prefersCalligraphy: Bool
    /// Words carrying a tajweed finding, and which rule was questioned.
    ///
    /// Marked with an underline rather than a colour: the tajweed *colouring* says which
    /// rule a word carries, which is derived from the text and always true. A finding is
    /// a judgement about how it was recited, which is a much weaker claim, and the two
    /// must not look like the same kind of statement.
    private let tajweedFindings: [Int: TajweedRule]
    /// Multiplier on the fit-to-window size. 1 fills the available area; above that the
    /// page overflows and the view scrolls.
    @Binding private var zoom: CGFloat
    @State private var zoomAtGestureStart: CGFloat?

    /// Bounds for `zoom`. Below the lower bound the calligraphy is illegible; above the
    /// upper bound a single page is larger than any display.
    public static let zoomRange: ClosedRange<CGFloat> = 0.5...5.0

    public init(
        page: MushafPage,
        words: [WordEvaluation],
        surahNames: [Int: String] = [:],
        selection: Binding<Int?> = .constant(nil),
        zoom: Binding<CGFloat> = .constant(1),
        tajweed: [Int: [TajweedOccurrence]] = [:],
        prefersCalligraphy: Bool = true,
        tajweedFindings: [Int: TajweedRule] = [:],
        onSelectWord: @escaping (MushafWord) -> Void = { _ in }
    ) {
        self._zoom = zoom
        self.tajweed = tajweed
        self.prefersCalligraphy = prefersCalligraphy
        self.tajweedFindings = tajweedFindings
        self.page = page
        self.evaluations = Dictionary(
            words.map { ($0.targetIndex, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        self.surahNames = surahNames
        self._selection = selection
        self.onSelectWord = onSelectWord
    }

    private static var measure: CGFloat { canvasWidth - horizontalMargin * 2 }
    private static let minimumSpacingRatio: CGFloat = 0.20

    /// One size for the whole book, so the text does not change size as pages turn.
    ///
    /// Measured as the largest size at which *every* page from 3 onward fits the measure:
    /// 578 of the 604 pages overflowed at the preferred size, the worst by 220pt, which
    /// is what sent text past the frame. A printed muṣḥaf solves this by setting the
    /// whole book at one size and stretching the letterforms to fill each line; this sets
    /// one size and distributes the slack between words instead, which keeps every glyph
    /// intact. `MushafFittingTests` asserts no page overflows at this value.
    nonisolated public static let bookFontSize: CGFloat = 23.5

    /// Resolved once per page, then cached.
    private var layout: MushafPageLayout {
        MushafPageLayoutCache.layout(
            for: page,
            measure: Self.measure,
            baseFontSize: Self.baseFontSize,
            naskhSpacingRatio: Self.minimumSpacingRatio,
            calligraphicSpacingRatio: Self.calligraphicSpacingRatio,
            bookFontSize: Self.bookFontSize,
            prefersCalligraphy: prefersCalligraphy
        )
    }

    private var usesCalligraphy: Bool { layout.usesCalligraphy }
    private var fontSize: CGFloat { layout.fontSize }

    /// The QCF glyphs already contain the inter-word rhythm; only a hair of space is
    /// needed between them.
    private static let calligraphicSpacingRatio: CGFloat = 0.06

    private var lineHeight: CGFloat { Self.baseFontSize * 1.92 }

    private var canvasHeight: CGFloat {
        lineHeight * CGFloat(page.lines.count) + 96
    }

    public var body: some View {
        GeometryReader { geometry in
            // At zoom 1 the whole page is visible; scaling up overflows the scroll view,
            // which is what makes it scrollable rather than just smaller.
            let fit = min(
                geometry.size.width / Self.canvasWidth,
                geometry.size.height / canvasHeight
            )
            let scale = max(fit * zoom, 0.05)
            let scaled = CGSize(width: Self.canvasWidth * scale, height: canvasHeight * scale)

            ScrollView([.horizontal, .vertical]) {
                canvas
                    .frame(width: Self.canvasWidth, height: canvasHeight)
                    .scaleEffect(scale, anchor: .topLeading)
                    // `scaleEffect` is a visual transform: the layout box stays the
                    // canvas's unscaled size. Without `.topLeading` this frame centres
                    // that unscaled box inside the scaled one, while the visual is
                    // anchored to its top-left — so the page drifts down and right by
                    // half the difference, further the more you zoom in.
                    .frame(width: scaled.width, height: scaled.height, alignment: .topLeading)
                    // Keeps the page centred while it is smaller than the window, and
                    // lets it scroll once it is larger.
                    .frame(
                        minWidth: geometry.size.width,
                        minHeight: geometry.size.height
                    )
            }
            .scrollBounceBehavior(.basedOnSize)
            .gesture(magnification)
        }
    }

    /// Pinch or trackpad zoom, clamped to the same range as the menu commands.
    ///
    /// `magnification` is cumulative from the start of the gesture, so it multiplies the
    /// zoom the gesture *began* with. Multiplying the live value instead would compound
    /// on every callback and shoot to the limit.
    private var magnification: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = zoomAtGestureStart ?? zoom
                if zoomAtGestureStart == nil { zoomAtGestureStart = zoom }
                zoom = Self.clamp(base * value.magnification)
            }
            .onEnded { _ in zoomAtGestureStart = nil }
    }

    /// Keep a proposed zoom inside the supported range.
    public static func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, zoomRange.lowerBound), zoomRange.upperBound)
    }

    private var canvas: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 0) {
                ForEach(page.lines) { line in
                    lineView(line)
                        .frame(height: lineHeight)
                }
            }
            .padding(.horizontal, Self.horizontalMargin)
            Spacer(minLength: 0)
            footer
        }
        .frame(width: Self.canvasWidth, height: canvasHeight)
        .background(PageBackground())
    }

    private var header: some View {
        HStack {
            Text("Juz’ \(page.juz)")
            Spacer()
            Text(page.surahs.compactMap { surahNames[$0] }.joined(separator: " · "))
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, Self.horizontalMargin)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    private var footer: some View {
        Text(AyahMarker.arabicIndicDigits(page.number))
            .font(QuranFont.mushaf(size: 17))
            .foregroundStyle(.secondary)
            .padding(.bottom, 18)
    }

    @ViewBuilder
    private func lineView(_ line: MushafLine) -> some View {
        switch line.kind {
        case .surahHeader(let surah):
            SurahHeaderBand(name: surahNames[surah] ?? "", fontSize: fontSize)
        case .basmala:
            Text("بِسْمِ ٱللَّهِ ٱلرَّحْمَـٰنِ ٱلرَّحِيمِ")
                .font(QuranFont.mushaf(size: fontSize * (usesCalligraphy ? 0.62 : 0.88)))
                .foregroundStyle(.primary.opacity(0.85))
                .frame(maxWidth: .infinity)
        case .words:
            JustifiedLine(
                minimumSpacing: layout.fontSize * layout.spacingRatio,
                // A line that ends a surah is short by nature; stretching it across the
                // page would look broken rather than typeset.
                justifies: !isShort(line)
            ) {
                ForEach(line.words) { word in
                    wordView(word)
                }
            }
            .environment(\.layoutDirection, .rightToLeft)
        }
    }

    /// Lines that fall well short of the measure are left ragged instead of stretched.
    private func isShort(_ line: MushafLine) -> Bool {
        guard let last = page.lines.last(where: { !$0.words.isEmpty }) else { return false }
        return line.number == last.number && line.words.count <= 3
    }

    @ViewBuilder
    private func wordView(_ word: MushafWord) -> some View {
        switch word.kind {
        case .ayahEnd:
            // The QCF fonts carry the āyah ornament as a glyph of their own, already
            // holding the number — so it matches the page rather than being pasted on.
            if layout.usesCalligraphy, !word.code.isEmpty {
                Text(word.code)
                    .font(layout.wordFont)
                    .foregroundStyle(.secondary)
            } else {
                Text(AyahMarker.text(for: word.reference.ayah))
                    .font(QuranFont.mushaf(size: fontSize * 0.95))
                    .foregroundStyle(.secondary)
            }
        case .word:
            let status = word.targetIndex.flatMap { evaluations[$0]?.status } ?? .notYetRecited
            MushafWordView(
                word: word,
                status: status,
                fontSize: fontSize,
                font: layout.wordFont,
                displayText: layout.usesCalligraphy && !word.code.isEmpty ? word.code : word.text,
                sourceText: word.text,
                isCalligraphic: layout.usesCalligraphy && !word.code.isEmpty,
                tajweed: word.targetIndex.flatMap { tajweed[$0] } ?? [],
                tajweedFinding: word.targetIndex.flatMap { tajweedFindings[$0] },
                isSelected: word.targetIndex != nil && selection == word.targetIndex
            ) {
                if let index = word.targetIndex {
                    selection = (selection == index) ? nil : index
                }
                onSelectWord(word)
            }
        }
    }
}

// MARK: - Word

/// A single horizontal rule, so it can be stroked with a dash pattern.
private struct UnderlineStroke: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

private struct MushafWordView: View {
    let word: MushafWord
    let status: WordStatus
    let fontSize: CGFloat
    let font: Font
    /// The glyph codes when the page is set in the calligraphic font, otherwise the
    /// Unicode text. Matching always uses `word.text`; only display switches.
    let displayText: String
    /// The Unicode text regardless of how the word is drawn — tajweed ranges index
    /// into this.
    let sourceText: String
    /// True when `displayText` is a QCF glyph code rather than readable text.
    let isCalligraphic: Bool
    /// Where each rule falls inside `sourceText`, as scalar ranges.
    ///
    /// A tajweed rule belongs to particular letters — the nūn that carries the ghunnah,
    /// the qāf that is echoed in qalqalah — and colouring the whole word claims the rule
    /// applies to letters it does not. So the letters are coloured, not the word.
    ///
    /// This is only possible when the page is set in Unicode text. In the calligraphic
    /// fonts an entire word is a **single glyph** — رَّسُولٍ is the one character ﮙ — so
    /// there is no letter to address and no sub-glyph position to colour. Rather than
    /// fall back to tinting the whole word, which would be the inaccurate thing this is
    /// meant to stop, the calligraphic page shows no tajweed colour at all; the setting
    /// that chooses between the two says so.
    let tajweed: [TajweedOccurrence]
    /// A rule this word was questioned on, if any.
    let tajweedFinding: TajweedRule?
    let isSelected: Bool
    let onTap: () -> Void

    /// A verdict about what was recited always outranks a tajweed tint: being told a
    /// word was wrong matters more than being shown which rule it carries.
    private var showsTajweed: Bool {
        guard !isCalligraphic, !tajweed.isEmpty else { return false }
        switch status {
        case .wrong, .skipped: return false
        case .correct, .uncertain, .notYetRecited: return true
        }
    }

    private var colour: Color {
        WordStatusStyle.foreground(for: status)
    }

    /// The word with each rule's own letters tinted, everything else left alone.
    private var attributed: AttributedString {
        var result = AttributedString(sourceText)
        let scalars = Array(sourceText.unicodeScalars)
        for occurrence in tajweed {
            let lower = max(0, min(occurrence.range.lowerBound, scalars.count))
            let upper = max(lower, min(occurrence.range.upperBound, scalars.count))
            guard lower < upper else { continue }
            // Scalar offsets from the detector, converted to the string's own indices.
            let start = sourceText.unicodeScalars.index(sourceText.unicodeScalars.startIndex, offsetBy: lower)
            let end = sourceText.unicodeScalars.index(sourceText.unicodeScalars.startIndex, offsetBy: upper)
            guard let from = AttributedString.Index(start, within: result),
                  let to = AttributedString.Index(end, within: result) else { continue }
            result[from..<to].foregroundColor = TajweedStyle.colour(for: occurrence.rule)
        }
        return result
    }

    var body: some View {
        Group {
            if showsTajweed {
                Text(attributed)
            } else {
                Text(displayText)
            }
        }
            .font(font)
            .foregroundStyle(colour.opacity(WordStatusStyle.opacity(for: status)))
            .overlay(alignment: .bottom) {
                if let colour = WordStatusStyle.underline(for: status) {
                    Capsule()
                        .fill(colour)
                        .frame(height: max(1.5, fontSize * 0.04))
                        // Close under the word: the Uthmani text hangs marks well below
                        // the baseline, and a rule sitting under those reads as
                        // belonging to the line beneath rather than to this word.
                        .offset(y: fontSize * 0.02)
                }
            }
            .overlay(alignment: .bottom) {
                if let tajweedFinding {
                    // Dashed, and in the rule's own colour, so it reads as a different
                    // kind of remark from the solid line that marks a word verdict — and
                    // sits below it, so a word can carry both without them merging.
                    UnderlineStroke()
                        .stroke(
                            TajweedStyle.colour(for: tajweedFinding),
                            style: StrokeStyle(
                                lineWidth: max(1.2, fontSize * 0.035),
                                lineCap: .round,
                                dash: [fontSize * 0.11, fontSize * 0.09]
                            )
                        )
                        .frame(height: max(1.2, fontSize * 0.035))
                        .offset(y: fontSize * 0.12)
                        .allowsHitTesting(false)
                }
            }
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: fontSize * 0.2, style: .continuous)
                        .fill(Color.accentColor.opacity(0.16))
                        .padding(.horizontal, -fontSize * 0.09)
                        .padding(.vertical, -fontSize * 0.02)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(
                "\(word.text). \(word.translation). \(WordStatusStyle.label(for: status))"
            )
            .animation(.easeOut(duration: 0.22), value: status)
    }
}

// MARK: - Surah header

/// The band that names a surah beginning on this page.
private struct SurahHeaderBand: View {
    let name: String
    let fontSize: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.28), lineWidth: 1)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
            HStack(spacing: 10) {
                ornament
                Text(name)
                    .font(.system(size: fontSize * 0.62, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.85))
                ornament
            }
        }
        .frame(height: fontSize * 1.28)
        .padding(.horizontal, 40)
    }

    private var ornament: some View {
        Text("﴾﴿")
            .font(.system(size: fontSize * 0.5))
            .foregroundStyle(.secondary.opacity(0.6))
    }
}

// MARK: - Page background

/// A warm page with a double rule, the way a printed muṣḥaf is framed. Kept subtle in
/// dark mode rather than inverted to a glowing white sheet.
private struct PageBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Rectangle()
                .fill(
                    colorScheme == .dark
                        ? Color(white: 0.13)
                        : Color(red: 0.99, green: 0.975, blue: 0.94)
                )
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.25), lineWidth: 2)
                .padding(10)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.15), lineWidth: 0.75)
                .padding(15)
        }
    }
}

// MARK: - Justified line layout

/// Lays out one line right-to-left, distributing slack between words so the line reaches
/// both margins — what a printed muṣḥaf achieves by stretching the letterforms.
struct JustifiedLine: Layout {
    var minimumSpacing: CGFloat = 8
    var justifies: Bool = true

    /// Measuring text is the expensive part, and SwiftUI asks for a size and then a
    /// placement — so without a cache every line is measured twice per pass.
    struct Cache {
        var sizes: [CGSize]
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(sizes: subviews.map { $0.sizeThatFits(.unspecified) })
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache.sizes = subviews.map { $0.sizeThatFits(.unspecified) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let sizes = cache.sizes
        let natural = sizes.reduce(0) { $0 + $1.width }
            + minimumSpacing * CGFloat(max(0, sizes.count - 1))
        return CGSize(
            width: proposal.width ?? natural,
            height: sizes.map(\.height).max() ?? 0
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let sizes = cache.sizes
        guard !sizes.isEmpty else { return }

        let content = sizes.reduce(0) { $0 + $1.width }
        let gaps = CGFloat(max(1, sizes.count - 1))
        let available = bounds.width - content
        // Only ever add space, never remove it: squeezing words together to force a fit
        // would collide the diacritics.
        let spacing = (justifies && sizes.count > 1)
            ? max(minimumSpacing, available / gaps)
            : minimumSpacing

        var x = bounds.minX
        for (index, size) in sizes.enumerated() {
            subviews[index].place(
                at: CGPoint(x: x, y: bounds.midY - size.height / 2),
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
        }
    }
}
#endif
