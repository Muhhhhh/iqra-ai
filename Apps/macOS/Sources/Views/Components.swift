import RecitationCore
import SwiftUI

/// Input level indicator: a scrolling waveform of the last couple of seconds.
///
/// Every bar is a level the microphone actually reported — nothing here animates on its
/// own. That matters: a meter that wobbles decoratively would suggest the app is hearing
/// you when it is not, and "is the microphone actually working" is the main question this
/// control has to answer. Silence therefore reads as a flat line, which is the truth.
struct LevelMeter: View {
    let level: Float
    let isActive: Bool
    /// Clipping is shown in red because it is the single most damaging thing that can
    /// happen to the audio, and it is otherwise invisible.
    var isClipping: Bool = false

    /// Newest last, kept generously so a wide window has enough to fill.
    @State private var history: [Float] = []

    /// Points per bar.
    ///
    /// The count follows from the width rather than the other way round, so the trace
    /// keeps its density at any size. A fixed count stretched each bar as the window grew,
    /// turning a fine waveform into a row of slabs. 11.7 is the spacing the meter had at
    /// the width it was tuned on; lower is denser.
    private static let barPitch: CGFloat = 11.7
    /// Enough history for a very wide window; the display takes the last `count` of it.
    private static let historyLimit = 400

    private var tint: Color {
        if isClipping { return .red }
        return isActive ? .accentColor : .secondary
    }

    var body: some View {
        GeometryReader { geometry in
            let count = max(8, Int(geometry.size.width / Self.barPitch))
            let spacing = max(1, geometry.size.width / CGFloat(count) * 0.34)
            let barWidth = max(1, (geometry.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            let shown = Array(history.suffix(count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<count, id: \.self) { index in
                    // Left-pad with silence until enough has been heard to fill the view,
                    // so the trace grows in from the right rather than stretching.
                    let padding = count - shown.count
                    let value = index < padding ? 0 : shown[index - padding]
                    Capsule()
                        .fill(tint.opacity(value > 0.001 ? 1 : 0.35))
                        .frame(
                            width: barWidth,
                            // Never fully vanish: a row of dots reads as "connected and
                            // quiet", an empty rectangle reads as "broken".
                            height: max(barWidth, geometry.size.height * CGFloat(shaped(value)))
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .onChange(of: level, initial: true) { _, value in
            history.append(min(max(value, 0), 1))
            if history.count > Self.historyLimit {
                history.removeFirst(history.count - Self.historyLimit)
            }
        }
        .onChange(of: isActive) { _, running in
            if !running { history.removeAll() }
        }
        .animation(.linear(duration: 0.06), value: history)
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }

    /// Speech sits low in a linear scale, so a straight mapping barely moves. The cube
    /// root spreads quiet-but-real speech across the meter without exaggerating silence.
    private func shaped(_ value: Float) -> Float {
        value <= 0 ? 0 : pow(value, 1.0 / 3.0)
    }
}

/// Colour key for the mushaf highlighting.
struct StatusLegend: View {
    private let entries: [(status: WordStatus, title: String)] = [
        (.correct, "Correct"),
        (.uncertain(heard: ""), "Check"),
        (.wrong(heard: ""), "Wrong"),
        (.skipped, "Skipped"),
    ]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(WordStatusStyle.background(for: entry.status))
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.separator))
                        .frame(width: 13, height: 13)
                    Text(entry.title).foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
    }
}
