import Foundation

/// A block of 16 kHz mono float PCM, tagged with where it sits in the session.
///
/// This is the single audio currency of the pipeline. Everything downstream —
/// VAD, ASR, and (v2) tajweed DSP — consumes `AudioChunk`, so the raw signal
/// survives all the way to the result type instead of being dropped after
/// transcription.
public struct AudioChunk: Sendable, Equatable {
    /// Canonical rate for the whole pipeline. whisper.cpp and Silero VAD both want 16 kHz mono.
    public static let canonicalSampleRate: Double = 16_000

    public let samples: [Float]
    public let sampleRate: Double
    /// Offset of `samples[0]` from the start of the capture session.
    public let startTime: TimeInterval

    public init(samples: [Float], sampleRate: Double = AudioChunk.canonicalSampleRate, startTime: TimeInterval) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.startTime = startTime
    }

    public var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return TimeInterval(samples.count) / sampleRate
    }

    public var endTime: TimeInterval { startTime + duration }

    public var isEmpty: Bool { samples.isEmpty }

    /// Highest absolute sample. Clipping is invisible in RMS but destroys recognition:
    /// measured on the Tarteel model, a clipped recording scored 3/15 words against
    /// 11/15 clean — as bad as 5 dB SNR noise.
    public var peak: Float {
        samples.reduce(Float(0)) { Swift.max($0, Swift.abs($1)) }
    }

    /// Root-mean-square level. Used by the placeholder VAD and by the live level meter.
    public var rms: Float {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sumSquares / Float(samples.count)).squareRoot()
    }

    /// Sub-range of this chunk in seconds relative to the *session* clock, clamped to bounds.
    ///
    /// v2 tajweed rules (madd length, qalqalah bursts) work by slicing the audio for one
    /// aligned word out of its segment — this is that slice.
    public func slice(from: TimeInterval, to: TimeInterval) -> AudioChunk {
        let lowerBound = max(from, startTime)
        let upperBound = min(to, endTime)
        guard upperBound > lowerBound else {
            return AudioChunk(samples: [], sampleRate: sampleRate, startTime: lowerBound)
        }
        let first = Int(((lowerBound - startTime) * sampleRate).rounded())
        let last = Int(((upperBound - startTime) * sampleRate).rounded())
        let clampedFirst = max(0, min(first, samples.count))
        let clampedLast = max(clampedFirst, min(last, samples.count))
        return AudioChunk(
            samples: Array(samples[clampedFirst..<clampedLast]),
            sampleRate: sampleRate,
            startTime: startTime + TimeInterval(clampedFirst) / sampleRate
        )
    }

    public func appending(_ other: AudioChunk) -> AudioChunk {
        AudioChunk(samples: samples + other.samples, sampleRate: sampleRate, startTime: startTime)
    }
}
