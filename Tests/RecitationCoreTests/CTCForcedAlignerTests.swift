import Foundation
import Testing

@testable import RecitationCore

/// Forced alignment is what will let tajweed be judged letter by letter, so its
/// guarantees matter more than its accuracy: the path it returns must spell out the
/// expected sequence exactly, in order, without inventing or dropping anything. Those
/// are properties, and they are what these tests pin down.
@Suite("CTC forced alignment")
struct CTCForcedAlignerTests {

    private let aligner = CTCForcedAligner(blank: 0)

    /// Frames that are certain of one class each.
    private func frames(_ classes: [Int], vocabulary: Int = 5) -> [[Double]] {
        classes.map { certain in
            (0..<vocabulary).map { $0 == certain ? 0.96 : 0.01 }
        }
    }

    @Test("Each symbol lands on the frames that carry it")
    func alignsToTheObviousFrames() throws {
        // blank, blank, A, A, A, blank, B, B, blank
        let probabilities = frames([0, 0, 1, 1, 1, 0, 2, 2, 0])
        let spans = try aligner.align(probabilities: probabilities, target: [1, 2])

        #expect(spans.count == 2)
        #expect(spans[0].symbol == 1)
        #expect(spans[0].frames == 2..<5)
        #expect(spans[1].symbol == 2)
        #expect(spans[1].frames == 6..<8)
    }

    @Test("The path spells out the target exactly, whatever the audio says")
    func pathIsConstrainedToTheTarget() throws {
        // The audio is confidently a third symbol the target does not contain. Forced
        // alignment must still return exactly the expected sequence: it decides *when*
        // each phoneme was said, never *what* was said. Anything else would let the
        // aligner quietly agree with a misrecitation.
        let probabilities = frames([3, 3, 3, 3, 3, 3])
        let spans = try aligner.align(probabilities: probabilities, target: [1, 2])

        #expect(spans.map(\.symbol) == [1, 2])
        // …and it should say it is not confident, which is the signal a caller acts on.
        #expect(spans.allSatisfy { $0.confidence < 0.1 })
    }

    @Test("Spans are ordered, contiguous in index, and never overlap")
    func spansAreMonotonic() throws {
        let probabilities = frames([0, 1, 1, 0, 2, 0, 3, 3, 3, 0, 1, 0])
        let spans = try aligner.align(probabilities: probabilities, target: [1, 2, 3, 1])

        #expect(spans.map(\.index) == [0, 1, 2, 3])
        #expect(spans.map(\.symbol) == [1, 2, 3, 1])
        for (earlier, later) in zip(spans, spans.dropFirst()) {
            #expect(earlier.frames.upperBound <= later.frames.lowerBound, "spans overlap")
        }
    }

    @Test("A repeated phoneme is kept apart by the blank between them")
    func repeatedSymbolsStaySeparate() throws {
        // Doubled letters are everywhere in the Uthmani text — shadda is exactly this —
        // so collapsing a repeat into one span would mislocate every rule after it.
        let probabilities = frames([1, 1, 0, 1, 1])
        let spans = try aligner.align(probabilities: probabilities, target: [1, 1])

        #expect(spans.count == 2)
        #expect(spans[0].frames.upperBound <= spans[1].frames.lowerBound)
    }

    @Test("Audio too short for the sequence is refused, not fudged")
    func refusesImpossibleAlignments() {
        let probabilities = frames([1, 2])
        #expect(throws: CTCForcedAligner.AlignmentError.self) {
            _ = try aligner.align(probabilities: probabilities, target: [1, 2, 3, 4, 5])
        }
    }

    @Test("Every frame is accounted for and every symbol placed")
    func coversTheWholeSequence() throws {
        let probabilities = frames([0, 1, 0, 2, 2, 0, 3, 0])
        let target = [1, 2, 3]
        let spans = try aligner.align(probabilities: probabilities, target: target)

        #expect(spans.count == target.count)
        #expect(spans.allSatisfy { !$0.frames.isEmpty })
    }
}
