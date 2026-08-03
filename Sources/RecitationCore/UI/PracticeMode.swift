import Foundation

/// How the muṣḥaf behaves while you recite.
public enum PracticeMode: String, Sendable, CaseIterable, Identifiable {
    /// The text is there throughout and every verdict is shown. The default.
    case review
    /// The page starts empty and fills in as you recite, and nothing is judged.
    ///
    /// For reciting from memory. The text is the answer sheet, so it stays out of sight
    /// until you have said the word — and because the point is to remember rather than to
    /// be corrected, no mistake is reported at all while you are in it.
    case fog
    /// The same reveal, with mistakes and tajweed still reported.
    case fogPro

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .review: return "Review"
        case .fog: return "Fog"
        case .fogPro: return "Fog Pro"
        }
    }

    public var explanation: String {
        switch self {
        case .review:
            return "The whole page is visible and words are marked as you recite."
        case .fog:
            return "The page is blank and fills in word by word as you recite it. Nothing is checked or marked — recite from memory and watch it appear."
        case .fogPro:
            return "The page fills in as you recite, and skipped or misread words are still marked when they appear. Elongations are checked too, if that is switched on."
        }
    }

    /// Whether the page hides text the reciter has not reached.
    public var hidesUnrecitedText: Bool { self != .review }
    /// Whether verdicts are shown at all.
    public var reportsMistakes: Bool { self != .fog }
}
