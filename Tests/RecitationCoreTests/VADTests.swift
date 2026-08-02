import Foundation
import Testing

@testable import RecitationCore

@Suite("Energy voice activity detection")
struct VADTests {

    /// One 20 ms frame at a given amplitude.
    private func frame(amplitude: Float, at index: Int, duration: TimeInterval = 0.02) -> AudioChunk {
        let count = Int(duration * AudioChunk.canonicalSampleRate)
        // Alternating sign gives a predictable RMS equal to the amplitude.
        let samples = (0..<count).map { $0.isMultiple(of: 2) ? amplitude : -amplitude }
        return AudioChunk(samples: samples, startTime: TimeInterval(index) * duration)
    }

    @Test("A segment opens with the audio that preceded detection")
    func preRollIsPrepended() async {
        // Speech onsets ramp up through the threshold. Without a pre-roll the quiet
        // start of a word is discarded and the recognizer hears it truncated — that is
        // how بِسْمِ became من in the app.
        let vad = EnergyVoiceActivityDetector(
            options: .init(
                speechThreshold: 0.015,
                segmentation: .init(trailingSilence: 0.1, minimumSegmentDuration: 0.05, preRoll: 0.2)
            )
        )

        var index = 0
        // Quiet onset, below the threshold — must be retained, not dropped.
        for _ in 0..<5 {
            _ = await vad.process(frame(amplitude: 0.004, at: index)); index += 1
        }
        // Loud speech.
        for _ in 0..<10 {
            _ = await vad.process(frame(amplitude: 0.2, at: index)); index += 1
        }
        // Silence closes the segment.
        var emitted: [AudioChunk] = []
        for _ in 0..<10 {
            emitted += await vad.process(frame(amplitude: 0.0, at: index)); index += 1
        }

        let segment = try? #require(emitted.first)
        guard let segment else { return }

        // The segment must begin before the threshold crossing at t = 0.10 s.
        #expect(segment.startTime < 0.10, "segment started at the threshold crossing, losing the onset")
        #expect(segment.startTime >= 0.0)
    }

    @Test("Pre-roll is bounded and does not accumulate during long silence")
    func preRollIsBounded() async {
        let vad = EnergyVoiceActivityDetector(
            options: .init(
                speechThreshold: 0.015,
                segmentation: .init(trailingSilence: 0.1, minimumSegmentDuration: 0.05, preRoll: 0.2)
            )
        )

        var index = 0
        // Five seconds of quiet before anything is said.
        for _ in 0..<250 {
            _ = await vad.process(frame(amplitude: 0.004, at: index)); index += 1
        }
        for _ in 0..<10 {
            _ = await vad.process(frame(amplitude: 0.2, at: index)); index += 1
        }
        var emitted: [AudioChunk] = []
        for _ in 0..<10 {
            emitted += await vad.process(frame(amplitude: 0.0, at: index)); index += 1
        }

        let segment = try? #require(emitted.first)
        guard let segment else { return }

        let speechStart = TimeInterval(250) * 0.02
        // At most `preRoll` of lead-in, plus one frame of rounding.
        #expect(segment.startTime >= speechStart - 0.2 - 0.02, "pre-roll grew beyond its bound")
    }

    @Test("Silence alone never produces a segment")
    func silenceProducesNoSegments() async {
        let vad = EnergyVoiceActivityDetector()
        var emitted: [AudioChunk] = []
        for index in 0..<200 {
            emitted += await vad.process(frame(amplitude: 0.0, at: index))
        }
        #expect(emitted.isEmpty)
        #expect(await vad.flush() == nil)
    }

    @Test("A pause closes the segment and speech after it opens a new one")
    func pauseSplitsSegments() async {
        let vad = EnergyVoiceActivityDetector(
            options: .init(
                speechThreshold: 0.015,
                segmentation: .init(trailingSilence: 0.1, minimumSegmentDuration: 0.05, preRoll: 0.05)
            )
        )

        var index = 0
        var emitted: [AudioChunk] = []
        for _ in 0..<10 { emitted += await vad.process(frame(amplitude: 0.2, at: index)); index += 1 }
        for _ in 0..<10 { emitted += await vad.process(frame(amplitude: 0.0, at: index)); index += 1 }
        for _ in 0..<10 { emitted += await vad.process(frame(amplitude: 0.2, at: index)); index += 1 }
        for _ in 0..<10 { emitted += await vad.process(frame(amplitude: 0.0, at: index)); index += 1 }

        #expect(emitted.count == 2)
        #expect(emitted[0].endTime <= emitted[1].startTime + 0.05)
    }

    @Test("Reset clears both the segment buffer and the pre-roll")
    func resetClearsState() async {
        let vad = EnergyVoiceActivityDetector()
        for index in 0..<10 { _ = await vad.process(frame(amplitude: 0.004, at: index)) }
        await vad.reset()

        // After a reset the next speech must not drag in audio from before it.
        var emitted: [AudioChunk] = []
        var index = 100
        for _ in 0..<10 { emitted += await vad.process(frame(amplitude: 0.2, at: index)); index += 1 }
        for _ in 0..<40 { emitted += await vad.process(frame(amplitude: 0.0, at: index)); index += 1 }

        let segment = try? #require(emitted.first)
        guard let segment else { return }
        #expect(segment.startTime >= 100 * 0.02 - 0.05)
    }
}
