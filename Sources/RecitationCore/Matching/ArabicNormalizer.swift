import Foundation

/// Folds Arabic orthography down to a form that can be compared across two very
/// different writers: the Uthmani mushaf text in our database, and whatever the ASR
/// model emits (usually modern-standard spelling, no diacritics, no Quranic marks).
///
/// Every rule here is a *deliberate loss of information*. The rule of thumb: fold a
/// distinction only when the ASR model cannot be trusted to reproduce it. Folding too
/// little produces false "you made a mistake" reports, which is the failure mode we
/// care most about avoiding.
public enum ArabicNormalizer {

    /// Harakāt, tanwīn, sukūn, shadda, and the Quranic annotation marks.
    /// Dropped wholesale: Whisper output is effectively undiacritised.
    private static let strippedScalars: Set<Unicode.Scalar> = {
        var set = Set<Unicode.Scalar>()
        func add(_ range: ClosedRange<UInt32>) {
            for value in range {
                if let scalar = Unicode.Scalar(value) { set.insert(scalar) }
            }
        }
        add(0x064B...0x0652)  // fathatan … sukun
        add(0x0653...0x0655)  // maddah above, hamza above/below
        add(0x0656...0x065F)  // subscript alef and friends
        add(0x0670...0x0670)  // superscript (dagger) alef
        add(0x06D6...0x06ED)  // small waqf marks, small high seen, rub el hizb, etc.
        add(0x08D3...0x08FF)  // extended Arabic diacritics
        set.insert(Unicode.Scalar(0x0640)!)   // tatweel / kashida
        set.insert(Unicode.Scalar(0x200C)!)   // ZWNJ
        set.insert(Unicode.Scalar(0x200D)!)   // ZWJ
        set.insert(Unicode.Scalar(0x200E)!)   // LRM
        set.insert(Unicode.Scalar(0x200F)!)   // RLM
        return set
    }()

    /// Letter-shape folds. These are the forms ASR routinely gets "wrong" in a way that
    /// is purely orthographic, not a recitation mistake.
    private static let letterFolds: [Character: Character] = [
        "\u{0622}": "\u{0627}",  // آ → ا
        "\u{0623}": "\u{0627}",  // أ → ا
        "\u{0625}": "\u{0627}",  // إ → ا
        "\u{0671}": "\u{0627}",  // ٱ (wasla) → ا
        "\u{0649}": "\u{064A}",  // ى → ي
        "\u{0624}": "\u{0648}",  // ؤ → و
        "\u{0626}": "\u{064A}",  // ئ → ي
        "\u{06A9}": "\u{0643}",  // Persian ک → ك
        "\u{06CC}": "\u{064A}",  // Persian ی → ي
        "\u{0629}": "\u{0647}",  // ة → ه  (pausal form; ASR is inconsistent here)
    ]

    /// Strip marks, fold letter shapes, and drop anything that isn't an Arabic letter.
    public static func normalize(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !strippedScalars.contains(scalar) {
            scalars.append(scalar)
        }
        var result = ""
        result.reserveCapacity(scalars.count)
        for character in String(scalars) {
            let folded = letterFolds[character] ?? character
            if folded.isArabicLetter {
                result.append(folded)
            } else if folded.isWhitespace, result.last != " " {
                // Collapse runs: dropping punctuation and Latin text between two words
                // would otherwise leave a gap of several spaces behind.
                result.append(" ")
            }
            // Punctuation, Latin text, and digits are dropped entirely.
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// The superscript (dagger) alef: a long ā the Uthmani text marks rather than writes.
    static let daggerAlef = Unicode.Scalar(0x0670)!
    private static let fullAlef = Unicode.Scalar(0x0627)!

    /// Every spelling of a word that should be accepted as the same word.
    ///
    /// Only the dagger alef produces more than one, and it produces exactly two, because
    /// modern orthography is genuinely inconsistent about it. The same mark is written
    /// out as a full alef in some words and left out in others:
    ///
    ///     ءَايَٰت  → آيات      (written)
    ///     سَمَٰوَٰت → سماوات    (written)
    ///     هَٰذَا   → هذا       (not written)
    ///     ذَٰلِكَ  → ذلك       (not written)
    ///     ٱلرَّحْمَٰن → الرحمن   (usually not written, sometimes الرحمان)
    ///
    /// So there is no single fold that is right. Dropping the mark — which is what this
    /// normaliser did — turns آيات into a mismatch; folding it to an alef turns هذا into
    /// one. Either way the reciter is told they misread a word they read correctly.
    ///
    /// Both readings are therefore offered, and the matcher takes whichever fits what was
    /// heard. The ambiguity is confined to words that actually carry the mark, so pairs
    /// that differ by a *written* alef — قَالَ against قُل, which is a real difference
    /// worth reporting — are untouched.
    public static func matchingVariants(of text: String) -> [String] {
        let canonical = normalize(text)
        guard text.unicodeScalars.contains(daggerAlef) else { return [canonical] }

        var realised = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            realised.append(scalar == daggerAlef ? fullAlef : scalar)
        }
        let spelled = normalize(String(realised))
        return spelled == canonical ? [canonical] : [canonical, spelled]
    }

    /// Normalize and split into word tokens, discarding empties.
    public static func tokenize(_ text: String) -> [String] {
        normalize(text)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}

extension Character {
    /// True for the Arabic letter blocks (excludes the diacritic ranges stripped above).
    var isArabicLetter: Bool {
        guard let scalar = unicodeScalars.first, unicodeScalars.count == 1 else { return false }
        switch scalar.value {
        case 0x0621...0x063F, 0x0641...0x064A, 0x066E...0x066F, 0x0671...0x06D5:
            return true
        default:
            return false
        }
    }
}
