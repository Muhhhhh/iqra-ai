import Foundation

/// Finds the whisper weights at runtime.
///
/// Shipping builds bundle the model inside the app. During development the model lives
/// in the repo's `Models/` directory (it is fetched, not checked in), so the locator
/// falls back to searching upward from the executable. Everything is local either way —
/// there is no download path at runtime, by design.
public enum SpeechModelLocator {

    /// Where a model was found, for display and diagnostics.
    public struct Located: Sendable, Equatable {
        public let url: URL
        public let source: Source
        /// Whether a Core ML encoder sits alongside the weights. When absent, whisper.cpp
        /// falls back to the Metal/CPU encoder (the libraries are built with
        /// ALLOW_FALLBACK), so this is informational rather than fatal.
        public let hasCoreMLEncoder: Bool

        public enum Source: String, Sendable {
            case appBundle
            case developmentDirectory
        }

        public init(url: URL, source: Source, hasCoreMLEncoder: Bool) {
            self.url = url
            self.source = source
            self.hasCoreMLEncoder = hasCoreMLEncoder
        }
    }

    /// Search for the weights described by `configuration`.
    ///
    /// - Parameters:
    ///   - bundle: checked first, so a shipped app never reads outside itself.
    ///   - additionalDirectories: extra places to look after the bundle. Needed under
    ///     `xctest`, where `Bundle.main` is the test runner and the upward walk never
    ///     reaches the package root.
    public static func locate(
        _ configuration: SpeechModelConfiguration,
        in bundle: Bundle = .main,
        additionalDirectories: [URL] = []
    ) -> Located? {
        // Try the exact stem first, then the unquantised name — during development the
        // stock model is used before the Tarteel conversion exists.
        let candidates = [configuration.modelStem, "ggml-\(configuration.size.rawValue)"]

        for stem in candidates {
            if let url = bundle.url(forResource: stem, withExtension: "bin") {
                return Located(url: url, source: .appBundle, hasCoreMLEncoder: encoderExists(besides: url, stem: stem))
            }
        }

        for directory in additionalDirectories + developmentModelDirectories() {
            for stem in candidates {
                let url = directory.appending(path: "\(stem).bin")
                if FileManager.default.fileExists(atPath: url.path) {
                    return Located(
                        url: url,
                        source: .developmentDirectory,
                        hasCoreMLEncoder: encoderExists(besides: url, stem: stem)
                    )
                }
            }
        }

        return nil
    }

    /// Which model sizes are actually installed.
    ///
    /// The settings picker must only offer these. Selecting a size with no weights makes
    /// `locate` return nil, and the pipeline then falls back to the scripted recogniser —
    /// so the app would carry on looking like it worked while reporting a canned reading
    /// as if it were your recitation.
    public static func installedSizes(
        in bundle: Bundle = .main,
        additionalDirectories: [URL] = []
    ) -> [SpeechModelConfiguration.Size] {
        SpeechModelConfiguration.Size.allCases.filter { size in
            locate(
                SpeechModelConfiguration(size: size),
                in: bundle,
                additionalDirectories: additionalDirectories
            ) != nil
        }
    }

    /// whisper.cpp looks for `<stem>-encoder.mlmodelc` next to the weights, first
    /// stripping any `-qX_X` quantisation suffix — the Core ML encoder is fp16 and is
    /// shared by every quantisation of the same weights, so one file serves them all.
    private static func encoderExists(besides url: URL, stem: String) -> Bool {
        let encoder = url.deletingLastPathComponent()
            .appending(path: "\(strippingQuantizationSuffix(stem))-encoder.mlmodelc")
        return FileManager.default.fileExists(atPath: encoder.path)
    }

    /// Mirrors `whisper_get_coreml_path_encoder`: drop a trailing `-q8_0`-style suffix.
    static func strippingQuantizationSuffix(_ stem: String) -> String {
        guard let separator = stem.lastIndex(of: "-") else { return stem }
        let suffix = stem[separator...]
        guard suffix.count == 5 else { return stem }
        let characters = Array(suffix)
        guard characters[1] == "q", characters[3] == "_" else { return stem }
        return String(stem[..<separator])
    }

    /// Walk up from the executable looking for a `Models/` directory. This finds the
    /// repo checkout whether the binary is run from `.build/debug`, from a bundled
    /// `.app`, or from Xcode's DerivedData.
    static func developmentModelDirectories() -> [URL] {
        var directories: [URL] = []
        var current = URL(fileURLWithPath: Bundle.main.bundlePath).standardized

        for _ in 0..<8 {
            directories.append(current.appending(path: "Models"))
            let parent = current.deletingLastPathComponent()
            if parent == current { break }
            current = parent
        }
        return directories
    }
}

extension SpeechModelLocator {
    /// Known filenames for the bundled Silero VAD weights, newest first.
    /// whisper.cpp ships converters for these two revisions.
    static let vadModelStems = ["ggml-silero-v5.1.2", "ggml-silero-v6.2.0"]

    /// Locate the Silero VAD weights, using the same bundle-then-development search.
    public static func locateVAD(
        in bundle: Bundle = .main,
        additionalDirectories: [URL] = []
    ) -> URL? {
        for stem in vadModelStems {
            if let url = bundle.url(forResource: stem, withExtension: "bin") {
                return url
            }
        }
        for directory in additionalDirectories + developmentModelDirectories() {
            for stem in vadModelStems {
                let url = directory.appending(path: "\(stem).bin")
                if FileManager.default.fileExists(atPath: url.path) {
                    return url
                }
            }
        }
        return nil
    }
}
