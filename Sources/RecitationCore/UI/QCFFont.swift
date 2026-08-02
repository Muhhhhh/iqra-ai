#if canImport(SwiftUI)
import CoreText
import Foundation
import SwiftUI

/// The King Fahd Complex per-page fonts (QCF v1) — Uthman Taha's calligraphy.
///
/// These are not ordinary text fonts. There is one font per muṣḥaf page, and every glyph
/// in it is pre-shaped for its exact position on its line, kashida stretching included.
/// The text rendered is not Unicode Arabic but the page's own glyph codes (`code_v1` in
/// the database), which are only meaningful in that page's font.
///
/// Two consequences follow, and both are why this is worth the 92 MB:
///
/// * The letterforms are the ones in a printed muṣḥaf, not a Naskh approximation.
/// * Lines justify themselves. Measured on full pages, the widths of the fifteen lines
///   span about 1% — the calligrapher already stretched them to the measure, so no
///   inter-word padding is needed to make the page square up.
///
/// Matching still uses the Unicode `text_uthmani`; only display uses these codes.
@MainActor
public enum QCFFont {

    private static var registered: Set<Int> = []
    private static var unavailable: Set<Int> = []

    /// Extra places to look, checked first.
    ///
    /// Needed under `xctest`, where `Bundle.main` is the test runner and walking up from
    /// it never reaches the repository.
    public static var additionalSearchDirectories: [URL] = [] {
        didSet { unavailable.removeAll() }
    }

    /// PostScript name of a page's font, e.g. `QCF_P042`.
    public static func name(forPage page: Int) -> String {
        let padded = String(format: "%03d", max(1, min(page, MushafPage.count)))
        return "QCF_P\(padded)"
    }

    /// Register a page's font, once per process. Returns false when it isn't installed,
    /// in which case the caller should fall back to Unicode text in a Naskh face.
    @discardableResult
    public static func register(page: Int) -> Bool {
        if registered.contains(page) { return true }
        if unavailable.contains(page) { return false }

        guard let url = locate(page: page) else {
            unavailable.insert(page)
            return false
        }
        var error: Unmanaged<CFError>?
        let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        if ok {
            registered.insert(page)
            return true
        }
        // Registering the same file twice is not a failure.
        if let error,
           CFErrorGetCode(error.takeUnretainedValue()) == CTFontManagerError.alreadyRegistered.rawValue {
            registered.insert(page)
            return true
        }
        unavailable.insert(page)
        return false
    }

    /// The font for a page, or nil when its file is missing.
    public static func font(page: Int, size: CGFloat) -> Font? {
        guard register(page: page) else { return nil }
        return .custom(name(forPage: page), fixedSize: size)
    }

    /// True when the calligraphic fonts are installed at all.
    public static var isAvailable: Bool { locate(page: 1) != nil }

    private static func locate(page: Int) -> URL? {
        let file = "\(name(forPage: page)).TTF"
        for directory in additionalSearchDirectories {
            let url = directory.appending(path: file)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        if let url = Bundle.main.url(forResource: "QCF/\(name(forPage: page))", withExtension: "TTF") {
            return url
        }
        if let resources = Bundle.main.resourceURL {
            let url = resources.appending(path: "QCF/\(file)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        // Development: walk up to the repo's Resources/Fonts/QCF.
        var current = URL(fileURLWithPath: Bundle.main.bundlePath).standardized
        for _ in 0..<8 {
            let url = current.appending(path: "Resources/Fonts/QCF/\(file)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
            let parent = current.deletingLastPathComponent()
            if parent == current { break }
            current = parent
        }
        return nil
    }
}
#endif
