import Foundation

/// Where a tajweed rule applies within a word.
public struct TajweedOccurrence: Sendable, Equatable, Identifiable {
    public let rule: TajweedRule
    public let reference: VerseReference
    /// Index into `RecitationTarget.flattenedWords`.
    public let targetIndex: Int
    /// Character offsets within that word's display text.
    public let range: Range<Int>
    /// The letters the rule falls on, for display.
    public let letters: String
    /// Harakāt the elongation should be held for, where the rule prescribes one.
    /// Hafs conventions; nil for rules that are not about duration.
    public let expectedHarakat: Int?

    public var id: String { "\(reference):\(targetIndex):\(range.lowerBound):\(rule.rawValue)" }

    public init(
        rule: TajweedRule,
        reference: VerseReference,
        targetIndex: Int,
        range: Range<Int>,
        letters: String,
        expectedHarakat: Int? = nil
    ) {
        self.rule = rule
        self.reference = reference
        self.targetIndex = targetIndex
        self.range = range
        self.letters = letters
        self.expectedHarakat = expectedHarakat
    }
}

/// Finds tajweed rules in the Uthmani text.
///
/// This half of tajweed is deterministic. Where a rule applies follows from the
/// orthography — a shadda on nūn is ghunnah, a sākin qāf is qalqalah, a madd letter
/// before a hamza in the same word is madd wājib — so it can be derived exactly and
/// tested against known āyāt, with no audio and no calibration involved.
///
/// Judging whether the reciter *executed* the rule is a different problem entirely; see
/// `DSPTajweedAnalyzer`, which is explicitly uncalibrated.
///
/// Rules follow the riwāyah of Hafs 'an 'Asim, which is what the bundled Uthmani text is.
public enum TajweedRuleDetector {

    // MARK: - Arabic constants

    private static let sukun: Unicode.Scalar = "\u{0652}"
    private static let shadda: Unicode.Scalar = "\u{0651}"
    private static let fatha: Unicode.Scalar = "\u{064E}"
    private static let damma: Unicode.Scalar = "\u{064F}"
    private static let kasra: Unicode.Scalar = "\u{0650}"
    private static let fathatan: Unicode.Scalar = "\u{064B}"
    private static let dammatan: Unicode.Scalar = "\u{064C}"
    private static let kasratan: Unicode.Scalar = "\u{064D}"
    private static let daggerAlef: Unicode.Scalar = "\u{0670}"
    private static let maddah: Unicode.Scalar = "\u{0653}"
    private static let smallHighMeem: Unicode.Scalar = "\u{06E2}"
    private static let smallLowMeem: Unicode.Scalar = "\u{06ED}"

    private static let alef: Unicode.Scalar = "\u{0627}"
    /// آ — alef carrying maddah, a single scalar and always a long madd.
    private static let alefMaddah: Unicode.Scalar = "\u{0622}"
    private static let alefWasla: Unicode.Scalar = "\u{0671}"
    private static let waw: Unicode.Scalar = "\u{0648}"
    private static let ya: Unicode.Scalar = "\u{064A}"
    private static let alefMaqsura: Unicode.Scalar = "\u{0649}"

    private static let tanwin: Set<Unicode.Scalar> = [fathatan, dammatan, kasratan]
    private static let harakat: Set<Unicode.Scalar> = [fatha, damma, kasra, fathatan, dammatan, kasratan]

    /// ق ط ب ج د — the letters of qalqalah.
    private static let qalqalahLetters: Set<Unicode.Scalar> = ["\u{0642}", "\u{0637}", "\u{0628}", "\u{062C}", "\u{062F}"]
    /// Throat letters: nūn sākinah before these is pronounced plainly.
    private static let izharLetters: Set<Unicode.Scalar> = [
        "\u{0621}", "\u{0623}", "\u{0625}", "\u{0624}", "\u{0626}", "\u{0622}",
        "\u{0647}", "\u{0639}", "\u{062D}", "\u{063A}", "\u{062E}",
    ]
    /// ي ر م ل و ن — assimilation. Split by whether it carries ghunnah, because that
    /// is the whole difference between the two rules.
    private static let idghamLetters: Set<Unicode.Scalar> = [
        "\u{064A}", "\u{0631}", "\u{0645}", "\u{0644}", "\u{0648}", "\u{0646}",
    ]
    /// ل and ر: assimilation *without* nasalisation.
    private static let idghamBilaGhunnahLetters: Set<Unicode.Scalar> = [
        "\u{0644}", "\u{0631}",
    ]
    /// Every hamza carrier.
    private static let hamzaLetters: Set<Unicode.Scalar> = [
        "\u{0621}", "\u{0622}", "\u{0623}", "\u{0624}", "\u{0625}", "\u{0626}",
    ]

    /// Diacritics, Quranic annotation marks, and tatweel.
    ///
    /// Everything here works on Unicode *scalars*, not Characters. Swift's Character is a
    /// grapheme cluster, so a letter and its diacritics are a single element — نَّ is one
    /// Character — and every rule below, which is precisely about which mark sits on
    /// which letter, would find nothing at all.
    private static func isMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x064B...0x065F, 0x0670, 0x06D6...0x06ED, 0x0640:
            return true
        default:
            return false
        }
    }

    // MARK: - Detection

    /// Every rule occurrence in a passage, in reading order.
    ///
    /// Cross-word rules — nūn sākinah at the end of one word meeting the first letter of
    /// the next — need the following word, which is why this walks the whole target
    /// rather than working verse by verse.
    public static func occurrences(in target: RecitationTarget) -> [TajweedOccurrence] {
        let words = target.flattenedWords
        var result: [TajweedOccurrence] = []

        for (index, word) in words.enumerated() {
            let next = index + 1 < words.count ? words[index + 1] : nil
            result.append(contentsOf: occurrences(in: word, followedBy: next))
        }
        return result
    }

    /// Rules within one word, using the next word only where a rule crosses the boundary.
    static func occurrences(in word: TargetWord, followedBy next: TargetWord?) -> [TajweedOccurrence] {
        let characters = Array(word.text.unicodeScalars)
        var result: [TajweedOccurrence] = []

        func make(_ rule: TajweedRule, _ range: Range<Int>, _ harakat: Int? = nil) {
            let clamped = max(0, range.lowerBound)..<min(characters.count, range.upperBound)
            guard clamped.lowerBound < clamped.upperBound else { return }
            result.append(
                TajweedOccurrence(
                    rule: rule,
                    reference: word.reference,
                    targetIndex: word.globalIndex,
                    range: clamped,
                    letters: String(String.UnicodeScalarView(characters[clamped])),
                    expectedHarakat: harakat
                )
            )
        }

        /// First letter (not mark) at or after `index`.
        func nextLetter(after index: Int) -> (offset: Int, character: Unicode.Scalar)? {
            var cursor = index + 1
            while cursor < characters.count {
                if !isMark(characters[cursor]) { return (cursor, characters[cursor]) }
                cursor += 1
            }
            return nil
        }

        /// Marks attached to the letter at `index`.
        func marks(at index: Int) -> [Unicode.Scalar] {
            var cursor = index + 1
            var found: [Unicode.Scalar] = []
            while cursor < characters.count, isMark(characters[cursor]) {
                found.append(characters[cursor])
                cursor += 1
            }
            return found
        }

        let firstLetterOfNextWord = next.flatMap { word -> Unicode.Scalar? in
            word.text.unicodeScalars.first { !isMark($0) }
        }

        for (index, character) in characters.enumerated() where !isMark(character) {
            let attached = marks(at: index)
            let hasSukun = attached.contains(sukun)
            let hasShadda = attached.contains(shadda)
            let attachedTanwin = attached.first { tanwin.contains($0) }

            // --- Ghunnah: shadda on nūn or mīm --------------------------------------
            if hasShadda, character == "\u{0646}" || character == "\u{0645}" {
                make(.ghunnah, index..<(index + attached.count + 1), 2)
            }

            // --- Qalqalah: ق ط ب ج د carrying sukun ---------------------------------
            if hasSukun, qalqalahLetters.contains(character) {
                make(.qalqalah, index..<(index + attached.count + 1))
            }

            // --- Nūn sākinah and tanwīn ---------------------------------------------
            // The Uthmani text usually leaves the sukun off a sākin nūn — مَن, مِن — so a
            // bare nūn carrying no vowel is sākinah too. Requiring an explicit sukun
            // would miss most occurrences in the muṣḥaf.
            let hasHaraka = attached.contains { harakat.contains($0) }
            let isNunSakinah = character == "\u{0646}" && !hasShadda && (hasSukun || !hasHaraka)
            if isNunSakinah || attachedTanwin != nil {
                // Tanwīn only ever falls at the end of a word, so what follows it is the
                // next word's first letter — never a letter inside this one, which may
                // just be a silent alef or yāʾ carrying the tanwīn.
                let following: Unicode.Scalar? = attachedTanwin != nil
                    ? firstLetterOfNextWord
                    : (nextLetter(after: index)?.character ?? firstLetterOfNextWord)
                if let following {
                    let span = index..<(index + attached.count + 1)
                    if following == "\u{0628}" || attached.contains(smallHighMeem) {
                        // Iqlāb. The muṣḥaf marks it with a small high mīm over the nūn.
                        make(.iqlab, span, 2)
                    } else if izharLetters.contains(following) {
                        make(.izhar, span)
                    } else if idghamLetters.contains(following) {
                        make(
                            idghamBilaGhunnahLetters.contains(following) ? .idghamBilaGhunnah : .idgham,
                            span,
                            idghamLetters.contains(following)
                             && (following == "\u{0644}" || following == "\u{0631}") ? nil : 2)
                    } else {
                        make(.ikhfa, span, 2)
                    }
                }
            }

            // --- Madd ---------------------------------------------------------------
            if let madd = maddLength(
                at: index,
                characters: characters,
                attached: attached,
                nextWordFirstLetter: firstLetterOfNextWord,
                nextLetter: nextLetter
            ) {
                make(madd.rule, index..<(index + attached.count + 1 + madd.extraLength), madd.harakat)
            }
        }

        return result
    }

    // MARK: - Madd

    private struct MaddClassification {
        let rule: TajweedRule
        let harakat: Int
        /// Extra characters the madd spans beyond the carrier's own marks.
        let extraLength: Int
    }

    /// Classify a madd starting at `index`, if there is one.
    ///
    /// A madd letter is a bare alef after fatha, a wāw after damma, or a yāʾ after kasra —
    /// plus the dagger alef, which is always one. What follows decides its length:
    /// a hamza in the same word makes it wājib muttasil, a hamza opening the next word
    /// makes it jāʾiz munfasil, and a shadda or sukun makes it lāzim.
    private static func maddLength(
        at index: Int,
        characters: [Unicode.Scalar],
        attached: [Unicode.Scalar],
        nextWordFirstLetter: Unicode.Scalar?,
        nextLetter: (Int) -> (offset: Int, character: Unicode.Scalar)?
    ) -> MaddClassification? {
        let character = characters[index]

        // The dagger alef is itself a mark on the preceding letter, handled below.
        let carriesDaggerAlef = attached.contains(daggerAlef)

        var isMadd = false
        var span = 0

        if carriesDaggerAlef {
            isMadd = true
        } else if character == alefMaddah {
            // آ is alef plus maddah in one scalar; it is always a long madd.
            isMadd = true
        } else if character == alef || character == alefWasla || character == alefMaqsura {
            // Alef is a madd when the letter before it carries a fatha.
            if precedingHaraka(before: index, in: characters) == fatha { isMadd = true }
        } else if character == waw, !attached.contains(where: { harakat.contains($0) }) {
            if precedingHaraka(before: index, in: characters) == damma { isMadd = true }
        } else if character == ya, !attached.contains(where: { harakat.contains($0) }) {
            if precedingHaraka(before: index, in: characters) == kasra { isMadd = true }
        }

        guard isMadd else { return nil }

        // A maddah — written over the carrier, or built into آ — is the scribe's own
        // signal that this is a long madd rather than the natural two harakāt.
        let explicitlyMarked = attached.contains(maddah) || character == alefMaddah

        if let following = nextLetter(index) {
            let followingMarks: [Unicode.Scalar] = {

                var cursor = following.offset + 1
                var found: [Unicode.Scalar] = []
                while cursor < characters.count, isMark(characters[cursor]) {
                    found.append(characters[cursor])
                    cursor += 1
                }
                return found
            }()

            if hamzaLetters.contains(following.character) {
                return MaddClassification(rule: .maddWajibMuttasil, harakat: 4, extraLength: span)
            }
            if followingMarks.contains(shadda) || followingMarks.contains(sukun) {
                return MaddClassification(rule: .maddLazim, harakat: 6, extraLength: span)
            }
        } else if let first = nextWordFirstLetter, hamzaLetters.contains(first) || first == alef {
            return MaddClassification(rule: .maddJaizMunfasil, harakat: 4, extraLength: span)
        }

        span = 0
        return MaddClassification(
            rule: .maddAsli,
            harakat: explicitlyMarked ? 4 : 2,
            extraLength: span
        )
    }

    /// The haraka on the letter before `index`, skipping other marks.
    private static func precedingHaraka(before index: Int, in characters: [Unicode.Scalar]) -> Unicode.Scalar? {
        var cursor = index - 1
        while cursor >= 0 {
            let character = characters[cursor]
            if harakat.contains(character) { return character }
            if !isMark(character) { return nil }
            cursor -= 1
        }
        return nil
    }
}
