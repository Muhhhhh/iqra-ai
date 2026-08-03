import Accelerate
import Foundation

/// Measures nasalisation from the signal itself, without asking a model.
///
/// Every model-based attempt at ghunnah in this project has failed the same way: the
/// Muaalem heads report what the ṣifah *should* be given the surrounding phonemes rather
/// than what was heard, so removing a ghunnah's audio entirely changed the verdict 2.7% of
/// the time. That is not a tuning problem and it is not surprising either — the model was
/// trained on recitation that is correct throughout, so every nūn it ever saw was
/// nasalised. It has no representation of the mistake.
///
/// Nasalisation, though, has a signature that can be measured directly. Opening the velum
/// couples the nasal cavity to the vocal tract, which:
///
/// * adds a low-frequency **murmur** around 250–300 Hz, and
/// * introduces an **anti-formant** — a zero — that drains energy around 800–1500 Hz.
///
/// So the ratio of low-band to mid-band energy rises sharply during a nasal and falls
/// again after it. That ratio is what this computes.
///
/// It is measured **relative to the reciter's own voice** in the same breath, never
/// absolutely: a low voice, a distant microphone or a bright room all shift the bands
/// together, and only the contrast between a nasal stretch and the oral speech around it
/// is stable across those. The comparison is against the reciter's own vowels, so they
/// are their own control.
///
/// ## It does not separate, and is not wired into the app
///
/// Measured over 327 ghunnahs of Al-Husary against the same ghunnahs with their audio
/// replaced by his own vowel sound:
///
///     ghunnah intact    median  0.5 dB   p10 -13.2   p90 13.6
///     ghunnah removed   median -3.9 dB   p10 -13.1   p90 18.6
///
/// The medians differ in the right direction and the distributions overlap almost
/// entirely. Any threshold between them questions about half of correct ghunnahs to catch
/// two thirds of missing ones, which is close enough to chance to be useless.
///
/// Three variants were tried: control taken from the adjacent non-nasal phoneme, from the
/// reciter's pooled vowels, and measuring the murmur between alignment spikes rather than
/// the spike itself — the last being the fix that made madd work. None separated.
///
/// The likely reason is that a band ratio is too blunt for this. A male reciter's F0 sits
/// near 100–150 Hz, so the 200–450 Hz band carries the first formant of ordinary vowels
/// too, and the contrast that nasalisation adds is small beside the variation between one
/// vowel and the next. The measures phoneticians actually use for nasality — A1–P0, which
/// compares the first formant's amplitude against the nasal peak — need formant tracking,
/// not band energies.
///
/// Kept because the measurement is worth being able to repeat: `IqraEval --nasality`.
public struct NasalityMeasure: Sendable {

    public struct Bands: Sendable {
        /// The nasal murmur.
        public var lowRange: ClosedRange<Double>
        /// Where the anti-formant drains energy.
        public var midRange: ClosedRange<Double>

        public init(
            lowRange: ClosedRange<Double> = 200...450,
            midRange: ClosedRange<Double> = 800...1500
        ) {
            self.lowRange = lowRange
            self.midRange = midRange
        }

        public static let `default` = Bands()
    }

    private let bands: Bands
    private static let windowLength = 400      // 25 ms at 16 kHz
    private static let hopLength = 160         // 10 ms
    private static let fftLength = 512

    public init(bands: Bands = .default) {
        self.bands = bands
    }

    /// Low-band to mid-band energy ratio, in decibels, for every 10 ms of a stretch.
    ///
    /// Higher means more nasal. Frames with too little energy to judge are dropped rather
    /// than reported as zero — silence is not oral, it is nothing.
    public func ratios(of samples: [Float]) -> [Double] {
        guard samples.count >= Self.windowLength else { return [] }
        let log2n = vDSP_Length(log2(Float(Self.fftLength)).rounded())
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }

        let binWidth = AudioChunk.canonicalSampleRate / Double(Self.fftLength)
        let lowBins = binRange(bands.lowRange, binWidth: binWidth)
        let midBins = binRange(bands.midRange, binWidth: binWidth)

        var window = [Float](repeating: 0, count: Self.windowLength)
        vDSP_hann_window(&window, vDSP_Length(Self.windowLength), Int32(vDSP_HANN_DENORM))

        var real = [Float](repeating: 0, count: Self.fftLength / 2)
        var imaginary = [Float](repeating: 0, count: Self.fftLength / 2)
        var padded = [Float](repeating: 0, count: Self.fftLength)

        var result: [Double] = []
        var offset = 0
        while offset + Self.windowLength <= samples.count {
            var frame = Array(samples[offset..<(offset + Self.windowLength)])
            vDSP.multiply(frame, window, result: &frame)
            for index in 0..<Self.fftLength {
                padded[index] = index < Self.windowLength ? frame[index] : 0
            }

            var split = DSPSplitComplex(realp: &real, imagp: &imaginary)
            padded.withUnsafeBufferPointer { pointer in
                pointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Self.fftLength / 2) {
                    vDSP_ctoz($0, 2, &split, 1, vDSP_Length(Self.fftLength / 2))
                }
            }
            vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

            func energy(_ range: Range<Int>) -> Double {
                var total = 0.0
                for bin in range where bin > 0 && bin < Self.fftLength / 2 {
                    let re = Double(real[bin]) / 2
                    let im = Double(imaginary[bin]) / 2
                    total += re * re + im * im
                }
                return total
            }

            let low = energy(lowBins)
            let mid = energy(midBins)
            // Below this there is not enough voicing to say anything.
            if low + mid > 1e-9 {
                result.append(10 * log10((low + 1e-12) / (mid + 1e-12)))
            }
            offset += Self.hopLength
        }
        return result
    }

    /// How much more nasal one stretch is than another, in decibels.
    ///
    /// The second stretch is the control — neighbouring voiced audio from the same word,
    /// so the reciter's own voice and the room cancel out. A ghunnah correctly given
    /// should sit clearly above its surroundings; one omitted should not.
    public func contrast(nasal: [Float], against oral: [Float]) -> Double? {
        let nasalRatios = ratios(of: nasal)
        let oralRatios = ratios(of: oral)
        guard !nasalRatios.isEmpty, !oralRatios.isEmpty else { return nil }
        // Medians, because a single frame at the boundary between two sounds carries both.
        let nasalMedian = nasalRatios.sorted()[nasalRatios.count / 2]
        let oralMedian = oralRatios.sorted()[oralRatios.count / 2]
        return nasalMedian - oralMedian
    }

    private func binRange(_ hertz: ClosedRange<Double>, binWidth: Double) -> Range<Int> {
        let lower = max(1, Int((hertz.lowerBound / binWidth).rounded(.down)))
        let upper = max(lower + 1, Int((hertz.upperBound / binWidth).rounded(.up)))
        return lower..<upper
    }
}
