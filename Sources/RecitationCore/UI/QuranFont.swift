#if canImport(SwiftUI)
import CoreText
import Foundation
import SwiftUI

/// The typeface used to set the muṣḥaf.
///
/// Choosing this is not cosmetic. The Uthmani text uses 29 combining and special marks —
/// dagger alef, alef wasla, the small high waqf signs — and most Arabic faces silently
/// drop the ones they lack rather than showing anything. Measured glyph coverage of
/// those marks across the fonts macOS ships:
///
/// | Font | Coverage |
/// |---|---|
/// | Geeza Pro, Damascus | 100% |
/// | Arial Unicode | 93% |
/// | Mishafi Gold | 84% |
/// | DecoType Naskh, Baghdad, Al Bayan, Nadeem | 31% |
/// | **Mishafi** | **25%** |
///
/// Mishafi is the trap: the name suggests it is meant for the muṣḥaf, and it would lose
/// every waqf mark and dagger alef without a single missing-glyph box to warn you.
///
/// So the app bundles **Amiri Quran** (SIL OFL 1.1), which is designed for Quranic
/// typesetting and covers all 29. Geeza Pro is the fallback — plain, but complete.
public enum QuranFont {

    /// PostScript name of the bundled face.
    public static let bundledName = "AmiriQuran-Regular"
    /// Complete coverage, always present on Apple platforms.
    public static let fallbackName = "Geeza Pro"

    /// Registers the bundled font with Core Text on first use.
    ///
    /// The font ships inside the app rather than being installed system-wide, so it has
    /// to be registered into the process before SwiftUI can resolve it by name.
    private static let registration: Bool = {
        guard let url = locateFont() else { return false }
        var error: Unmanaged<CFError>?
        let registered = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        if !registered, let error {
            // Already registered is not a failure worth reporting.
            let code = CFErrorGetCode(error.takeUnretainedValue())
            return code == CTFontManagerError.alreadyRegistered.rawValue
        }
        return registered
    }()

    /// True when the muṣḥaf face is available; false means the fallback is in use.
    public static var isBundledFontAvailable: Bool { registration }

    /// The font to set the muṣḥaf in.
    public static func mushaf(size: CGFloat) -> Font {
        registration ? .custom(bundledName, fixedSize: size) : .custom(fallbackName, fixedSize: size)
    }

    /// Amiri Quran carries tall marks above and below the baseline; the default line
    /// height collides them between lines.
    public static func lineSpacing(for size: CGFloat) -> CGFloat {
        size * (registration ? 0.85 : 0.55)
    }

    /// The name in use, for display in settings.
    public static var activeName: String { registration ? "Amiri Quran" : fallbackName }

    private static func locateFont() -> URL? {
        let candidates = ["AmiriQuran", bundledName]
        for name in candidates {
            if let url = Bundle.main.url(forResource: name, withExtension: "ttf") {
                return url
            }
            if let url = Bundle.main.url(forResource: "Fonts/\(name)", withExtension: "ttf") {
                return url
            }
        }
        // Development: walk up from the executable to the repo's Resources/Fonts.
        var current = URL(fileURLWithPath: Bundle.main.bundlePath).standardized
        for _ in 0..<8 {
            let url = current.appending(path: "Resources/Fonts/AmiriQuran.ttf")
            if FileManager.default.fileExists(atPath: url.path) { return url }
            let parent = current.deletingLastPathComponent()
            if parent == current { break }
            current = parent
        }
        return nil
    }
}

/// Renders an āyah number in the ornate end-of-āyah marker.
///
/// U+06DD consumes the digits that follow it, so `۝` plus Arabic-Indic numerals is one
/// glyph in a Quranic face — the circular ornament seen in a printed muṣḥaf.
public enum AyahMarker {
    public static func text(for ayah: Int) -> String {
        "\u{06DD}" + arabicIndicDigits(ayah)
    }

    public static func arabicIndicDigits(_ value: Int) -> String {
        let digits: [Character] = ["٠", "١", "٢", "٣", "٤", "٥", "٦", "٧", "٨", "٩"]
        let string = String(max(0, value))
        return String(string.compactMap { character in
            character.wholeNumberValue.map { digits[$0] }
        })
    }
}
#endif

#if canImport(CoreText)
import CoreText

/// Measures muṣḥaf text so a page can be fitted before it is rendered.
///
/// SwiftUI can only tell you a view is too wide *after* laying it out, at which point a
/// line has already overflowed the page frame. Measuring with Core Text up front lets the
/// page pick a size at which its longest line fits, which is what a printed muṣḥaf does
/// by setting the whole page to one size.
public enum MushafMetrics {

    /// Advance width of a run of muṣḥaf text at a given size.
    ///
    /// - Parameter fontName: a specific face, e.g. a QCF page font. Defaults to the
    ///   Naskh face used for Unicode text.
    public static func width(of text: String, fontSize: CGFloat, fontName: String? = nil) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let name = fontName
            ?? (QuranFont.isBundledFontAvailable ? QuranFont.bundledName : QuranFont.fallbackName)
        let font = CTFontCreateWithName(name as CFString, fontSize, nil)
        let attributed = NSAttributedString(
            string: text,
            attributes: [kCTFontAttributeName as NSAttributedString.Key: font]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// The largest font size at which every line fits the measure.
    ///
    /// - Parameters:
    ///   - lines: the text of each line, already broken canonically.
    ///   - measure: the width available between the margins.
    ///   - preferred: the size to use when everything already fits.
    ///   - minimumSpacing: inter-word space that must survive at that size.
    public static func fittedFontSize(
        lines: [[String]],
        measure: CGFloat,
        preferred: CGFloat,
        minimumSpacingRatio: CGFloat,
        fontName: String? = nil
    ) -> CGFloat {
        var required: CGFloat = 1
        for words in lines where !words.isEmpty {
            let natural = words.reduce(CGFloat(0)) { $0 + width(of: $1, fontSize: preferred, fontName: fontName) }
                + preferred * minimumSpacingRatio * CGFloat(words.count - 1)
            guard natural > 0 else { continue }
            required = max(required, natural / measure)
        }
        // Never enlarge past the preferred size: a short page should not be blown up.
        return required <= 1 ? preferred : preferred / required
    }
}
#endif
