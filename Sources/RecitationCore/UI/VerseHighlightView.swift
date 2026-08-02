#if canImport(SwiftUI)
import SwiftUI

/// How a word's verdict is expressed typographically.
///
/// The muṣḥaf is not marked up with boxes. Feedback is carried in the *ink* — weight,
/// colour, and a thin underline where something needs attention — so the page reads as
/// scripture rather than as a corrected exam paper.
///
/// Correct words get no decoration at all. That is deliberate: a screen covered in green
/// would imply the app had certified the recitation, and it has not — it checked which
/// words were said, nothing more. Words not yet reached are dimmed instead, so the page
/// simply illuminates as you recite.
public enum WordStatusStyle {

    public static func foreground(for status: WordStatus) -> Color {
        switch status {
        case .correct: return .primary
        case .uncertain: return .primary
        case .wrong: return .red
        case .skipped: return .orange
        case .notYetRecited: return .secondary
        }
    }

    /// Opacity is what carries progress: unrecited text sits back, recited text comes
    /// forward.
    public static func opacity(for status: WordStatus) -> Double {
        switch status {
        case .correct: return 1.0
        case .uncertain: return 1.0
        case .wrong: return 1.0
        case .skipped: return 0.9
        case .notYetRecited: return 0.32
        }
    }

    /// A thin rule under words that need a second look. Nothing else is decorated.
    public static func underline(for status: WordStatus) -> Color? {
        switch status {
        case .wrong: return .red.opacity(0.55)
        case .skipped: return .orange.opacity(0.5)
        case .uncertain: return .yellow.opacity(0.7)
        case .correct, .notYetRecited: return nil
        }
    }

    /// Retained for the review panel's swatches, where a legend key does need a fill.
    public static func background(for status: WordStatus) -> Color {
        switch status {
        case .correct: return .green.opacity(0.16)
        case .uncertain: return .yellow.opacity(0.22)
        case .wrong: return .red.opacity(0.18)
        case .skipped: return .orange.opacity(0.18)
        case .notYetRecited: return .clear
        }
    }

    public static func label(for status: WordStatus) -> String {
        switch status {
        case .correct: return "Correct"
        case .uncertain(let heard): return "Check this — heard “\(heard)”"
        case .wrong(let heard): return "Heard “\(heard)”"
        case .skipped: return "Skipped"
        case .notYetRecited: return "Not yet recited"
        }
    }
}

/// Colours for tajweed rules, following the convention of printed tajweed muṣḥafs
/// closely enough to be familiar without claiming to be any particular edition.
public enum TajweedStyle {

    public static func colour(for rule: TajweedRule) -> Color {
        switch rule {
        case .maddLazim: return Color(red: 0.78, green: 0.15, blue: 0.15)
        case .maddWajibMuttasil: return Color(red: 0.85, green: 0.42, blue: 0.10)
        case .maddJaizMunfasil: return Color(red: 0.80, green: 0.60, blue: 0.10)
        case .maddAsli: return Color(red: 0.45, green: 0.50, blue: 0.55)
        case .ghunnah: return Color(red: 0.20, green: 0.55, blue: 0.35)
        case .qalqalah: return Color(red: 0.25, green: 0.45, blue: 0.80)
        case .idgham: return Color(red: 0.45, green: 0.35, blue: 0.70)
        case .idghamBilaGhunnah: return Color(red: 0.55, green: 0.42, blue: 0.78)
        case .ikhfa: return Color(red: 0.55, green: 0.40, blue: 0.60)
        case .iqlab: return Color(red: 0.30, green: 0.55, blue: 0.65)
        case .izhar: return Color(red: 0.40, green: 0.45, blue: 0.45)
        case .tafkhimTarqiq, .waqf: return .secondary
        }
    }

    /// Which rule wins when a word carries several. The longer the obligation, the more
    /// a learner needs to see it.
    public static func priority(of rule: TajweedRule) -> Int {
        switch rule {
        case .maddLazim: return 100
        case .maddWajibMuttasil: return 90
        case .maddJaizMunfasil: return 80
        case .ghunnah: return 70
        case .qalqalah: return 60
        case .iqlab: return 50
        case .idgham: return 45
        case .idghamBilaGhunnah: return 44
        case .ikhfa: return 40
        case .izhar: return 30
        case .maddAsli: return 20
        case .tafkhimTarqiq, .waqf: return 10
        }
    }

    /// The rule to colour a word by, given everything found on it.
    public static func dominant(_ rules: [TajweedRule]) -> TajweedRule? {
        rules.max { priority(of: $0) < priority(of: $1) }
    }
}

/// Sets the target passage as continuous right-to-left muṣḥaf text.
///
/// Verses run on into each other separated by the ornate āyah marker, the way a printed
/// page reads, rather than being broken into labelled blocks. Words remain individually
/// selectable so the review panel and the page stay in sync — Arabic words are shaped
/// independently of their neighbours, so laying them out as separate runs costs nothing
/// typographically.
public struct VerseHighlightView: View {
    private let words: [WordEvaluation]
    private let fontSize: CGFloat
    private let showsVerseNumbers: Bool
    @Binding private var selection: Int?

    public init(
        words: [WordEvaluation],
        fontSize: CGFloat = 34,
        showsVerseNumbers: Bool = true,
        selection: Binding<Int?> = .constant(nil)
    ) {
        self.words = words
        self.fontSize = fontSize
        self.showsVerseNumbers = showsVerseNumbers
        self._selection = selection
    }

    /// The page as a flat run of words, with an āyah marker closing each verse.
    private enum Element: Identifiable {
        case word(WordEvaluation)
        case ayahMarker(VerseReference)

        var id: String {
            switch self {
            case .word(let evaluation): return "w\(evaluation.targetIndex)"
            case .ayahMarker(let reference): return "a\(reference)"
            }
        }
    }

    private var elements: [Element] {
        var result: [Element] = []
        result.reserveCapacity(words.count + 16)
        for (index, word) in words.enumerated() {
            result.append(.word(word))
            let isVerseEnd = index == words.count - 1 || words[index + 1].reference != word.reference
            if isVerseEnd, showsVerseNumbers {
                result.append(.ayahMarker(word.reference))
            }
        }
        return result
    }

    public var body: some View {
        FlowLayout(
            spacing: fontSize * 0.30,
            lineSpacing: QuranFont.lineSpacing(for: fontSize)
        ) {
            ForEach(elements) { element in
                switch element {
                case .word(let evaluation):
                    WordView(
                        evaluation: evaluation,
                        fontSize: fontSize,
                        isSelected: selection == evaluation.targetIndex
                    ) {
                        selection = (selection == evaluation.targetIndex) ? nil : evaluation.targetIndex
                    }
                    .id(evaluation.targetIndex)
                case .ayahMarker(let reference):
                    Text(AyahMarker.text(for: reference.ayah))
                        .font(QuranFont.mushaf(size: fontSize * 0.92))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("End of āyah \(reference.ayah)")
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct WordView: View {
    let evaluation: WordEvaluation
    let fontSize: CGFloat
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Text(evaluation.expectedText)
            .font(QuranFont.mushaf(size: fontSize))
            .foregroundStyle(
                WordStatusStyle.foreground(for: evaluation.status)
                    .opacity(WordStatusStyle.opacity(for: evaluation.status))
            )
            // Underline sits below the descenders rather than through the marks.
            .overlay(alignment: .bottom) {
                if let colour = WordStatusStyle.underline(for: evaluation.status) {
                    Capsule()
                        .fill(colour)
                        .frame(height: max(1.5, fontSize * 0.045))
                        .offset(y: fontSize * 0.10)
                }
            }
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: fontSize * 0.18, style: .continuous)
                        .fill(Color.accentColor.opacity(0.15))
                        .padding(.horizontal, -fontSize * 0.10)
                        .padding(.vertical, -fontSize * 0.04)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .help(WordStatusStyle.label(for: evaluation.status))
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("\(evaluation.expectedText). \(WordStatusStyle.label(for: evaluation.status))")
            .animation(.easeOut(duration: 0.22), value: evaluation.status)
            .animation(.easeOut(duration: 0.12), value: isSelected)
    }
}

/// Minimal wrapping layout. `Text` concatenation cannot carry per-word tap targets and
/// tooltips, so words are laid out as individual views.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = layout(subviews: subviews, maxWidth: maxWidth)
        let height = rows.reduce(CGFloat(0)) { $0 + $1.height } +
            lineSpacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: min(width, maxWidth == .infinity ? width : maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = layout(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func layout(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let projected = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if projected > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
                current.indices = [index]
                current.width = size.width
                current.height = size.height
            } else {
                current.indices.append(index)
                current.width = projected
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
#endif
