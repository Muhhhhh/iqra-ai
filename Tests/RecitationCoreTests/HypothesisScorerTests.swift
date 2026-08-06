import Foundation
import Testing
@testable import RecitationCore

/// The edits that stand for a mistake.
///
/// These are the whole method: a rule is testable only when breaking it changes which
/// sounds are made, and each case here is a claim about what that change is. Getting one
/// wrong would not crash anything — it would quietly compare the audio against a reading
/// nobody would ever produce, and report the result as a verdict about the reciter.
@Suite("Hypothesis edits")
struct HypothesisScorerTests {

    private let echo = AlignedTajweedAnalyzer.qalqalaEcho   // 38
    private let ikhfa = HypothesisScorer.ikhfaNun           // 39
    private let iqlab = HypothesisScorer.iqlabNun           // 40
    private let nun = HypothesisScorer.plainNun             // 25

    @Test("A swallowed qalqalah is the echo simply absent")
    func qalqalahRemovesTheEcho() throws {
        // د + echo + a  →  the stop released straight into what follows.
        let symbols = [8, echo, 32]
        let broken = try #require(HypothesisScorer.violate(symbols, at: 1, rule: .qalqalah))
        #expect(broken == [8, 32])
    }

    @Test("Ikhfāʾ broken is the whole hidden run replaced by one plain nūn")
    func ikhfaBecomesAPlainNun() throws {
        // The rule is written two or three times over for its ghunnah's length. Reciting
        // it wrongly does not shorten that sound, it replaces it — so the run goes, not
        // part of it.
        let symbols = [32, ikhfa, ikhfa, ikhfa, 3]
        for position in 1...3 {
            let broken = try #require(HypothesisScorer.violate(symbols, at: position, rule: .ikhfa))
            #expect(broken == [32, nun, 3], "position \(position) gave a different reading")
        }
    }

    @Test("Iqlāb broken is the same edit")
    func iqlabBecomesAPlainNun() throws {
        let symbols = [32, iqlab, iqlab, iqlab, 2]
        let broken = try #require(HypothesisScorer.violate(symbols, at: 2, rule: .iqlab))
        #expect(broken == [32, nun, 2])
    }

    @Test("Idghām broken says the nūn and then the letter once")
    func idghamSeparatesTheNun() throws {
        // مِن رَّبِّهِمْ writes the assimilated nūn as a doubled rāʾ. A reciter who fails to
        // merge says two sounds where the text asks for one held.
        let symbols = [34, 10, 10, 32]
        let broken = try #require(HypothesisScorer.violate(symbols, at: 1, rule: .idgham))
        #expect(broken == [34, nun, 10, 32])
    }

    @Test("A rushed madd is the elongation cut to a single count")
    func maddShortensToOne() throws {
        let symbols = [24, 29, 29, 29, 29, 12]
        let broken = try #require(HypothesisScorer.violate(symbols, at: 2, rule: .maddWajibMuttasil))
        #expect(broken == [24, 29, 12])
    }

    @Test("A rule with nothing to change refuses rather than inventing an edit")
    func unwritableRulesReturnNothing() {
        let symbols = [32, 25, 3]
        // Tafkhīm and hams sound different without changing which symbols are spoken, so
        // there is no second reading to compare against and none is fabricated.
        #expect(HypothesisScorer.violate(symbols, at: 1, rule: .tafkhimTarqiq) == nil)
        #expect(HypothesisScorer.violate(symbols, at: 1, rule: .izhar) == nil)
        // Nor is a qalqalah edit made where there is no echo.
        #expect(HypothesisScorer.violate(symbols, at: 1, rule: .qalqalah) == nil)
        // Nor a madd out of a vowel written once.
        #expect(HypothesisScorer.violate([24, 29, 12], at: 1, rule: .maddAsli) == nil)
    }

    @Test("Each run is one place to ask, however many symbols it spans")
    func positionsAreOnePerRun() {
        // A three-symbol ikhfāʾ is one occasion the reciter either applied the rule or did
        // not, not three. Counting symbols would triple every rate this method reports.
        let symbols = [32, ikhfa, ikhfa, ikhfa, 3, 32, ikhfa, ikhfa, 12]
        #expect(HypothesisScorer.positions(in: symbols, rule: .ikhfa) == [1, 6])
    }

    @Test("Qalqalah is found at every echo")
    func positionsFindEveryEcho() {
        let symbols = [8, echo, 32, 2, echo, 12]
        #expect(HypothesisScorer.positions(in: symbols, rule: .qalqalah) == [1, 4])
    }

    @Test("Idghām is read from its own plane, since the symbols cannot say")
    func idghamPositionsComeFromThePlane() {
        // A doubled mīm is the same whether it came from أُمَّة or from مِن مَّاء, so the
        // positions are carried from the text rather than inferred.
        let plane: [UInt8] = [0, 0, 1, 1, 0, 2, 2, 2, 0]
        #expect(HypothesisScorer.idghamPositions(in: plane) == [2, 5])
    }

    @Test("An edit describes only what it replaces")
    func editIsLocal() throws {
        // The comparison re-aligns just the neighbourhood of the edit, which is only sound
        // if the edit knows its own extent.
        let symbols = [32, ikhfa, ikhfa, 3]
        let edit = try #require(HypothesisScorer.edit(symbols, at: 1, rule: .ikhfa))
        #expect(edit.range == 1..<3)
        #expect(edit.replacement == [nun])
    }
}
