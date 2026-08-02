import Accelerate
import Foundation

/// Builds the input the Muaalem model expects: 80-bin Kaldi-style mel filterbanks,
/// stacked in pairs, normalised per mel bin.
///
/// This has to match the model's own feature extractor exactly. A network handed the
/// wrong features does not fail — it returns confident nonsense, which for a tool that
/// judges someone's recitation is the worst possible failure mode. So the window and the
/// filterbank are not re-derived here: they are exported verbatim from the Python
/// extractor by `scripts/export-tajweed-frontend.py`, and
/// `MuaalemFeatureTests` checks the output against reference features produced by that
/// same extractor.
///
/// The chain, in order, is: scale to 16-bit, remove DC offset, pre-emphasise, apply the
/// Povey window, take the power spectrum, project onto the mel filterbank, take logs,
/// normalise each mel bin across the utterance, then stack consecutive frames in pairs.
public struct MuaalemFeatures: Sendable {

    /// 25 ms at 16 kHz.
    public static let frameLength = 400
    /// 10 ms hop.
    public static let hopLength = 160
    public static let fftLength = 512
    public static let melBins = 80
    /// Two frames are concatenated per row, so the model sees 160 values per 20 ms.
    public static let stride = 2
    /// Model output rate after its own downsampling.
    public static let framesPerSecond = 25

    private static let preemphasis: Float = 0.97
    private static let melFloor: Float = 1.192092955078125e-07

    /// Povey window, 400 samples.
    private let window: [Float]
    /// Mel filterbank, [frequencyBins][melBins] = [257][80].
    private let melFilters: [[Float]]

    public enum LoadError: Error, Sendable {
        case missing(String)
        case malformed(String)
    }

    /// Load the exported window and filterbank.
    public init(resourceURL: URL) throws {
        guard let data = try? Data(contentsOf: resourceURL) else {
            throw LoadError.missing(resourceURL.path)
        }
        guard data.count > 20, data.prefix(4) == Data("MUFE".utf8) else {
            throw LoadError.malformed("not a Muaalem front-end file")
        }

        func int32(at offset: Int) -> Int {
            Int(data.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.load(as: Int32.self) })
        }

        let version = int32(at: 4)
        guard version == 1 else { throw LoadError.malformed("front-end version \(version)") }
        let frequencyBins = int32(at: 8)
        let mels = int32(at: 12)
        let windowLength = int32(at: 16)
        guard mels == Self.melBins,
              frequencyBins == Self.fftLength / 2 + 1,
              windowLength == Self.frameLength else {
            throw LoadError.malformed("unexpected shapes \(frequencyBins)x\(mels), window \(windowLength)")
        }

        var offset = 20
        let windowBytes = windowLength * MemoryLayout<Float>.size
        guard data.count >= offset + windowBytes else { throw LoadError.malformed("truncated window") }
        window = data.subdata(in: offset..<(offset + windowBytes)).withUnsafeBytes {
            Array($0.bindMemory(to: Float.self))
        }
        offset += windowBytes

        let melBytes = frequencyBins * mels * MemoryLayout<Float>.size
        guard data.count >= offset + melBytes else { throw LoadError.malformed("truncated filterbank") }
        let flat: [Float] = data.subdata(in: offset..<(offset + melBytes)).withUnsafeBytes {
            Array($0.bindMemory(to: Float.self))
        }
        melFilters = (0..<frequencyBins).map { bin in
            Array(flat[(bin * mels)..<((bin + 1) * mels)])
        }
    }

    /// Locate the exported front-end beside the app's other resources.
    public static func locate(in bundle: Bundle = .main, additionalDirectories: [URL] = []) -> URL? {
        if let url = bundle.url(forResource: "muaalem-frontend", withExtension: "bin") { return url }
        var directories = additionalDirectories
        var current = URL(fileURLWithPath: bundle.bundlePath).standardized
        for _ in 0..<8 {
            directories.append(current.appending(path: "Resources"))
            let parent = current.deletingLastPathComponent()
            if parent == current { break }
            current = parent
        }
        for directory in directories {
            let url = directory.appending(path: "muaalem-frontend.bin")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    // MARK: - Extraction

    /// Feature rows for a chunk of 16 kHz mono audio: `[rows][160]`.
    public func features(from chunk: AudioChunk) -> [[Float]] {
        let mel = melSpectrogram(chunk.samples)
        guard !mel.isEmpty else { return [] }
        let normalised = normalisePerBin(mel)
        return stack(normalised)
    }

    /// Log-mel frames, `[frames][80]`.
    func melSpectrogram(_ samples: [Float]) -> [[Float]] {
        guard samples.count >= Self.frameLength else { return [] }
        // Kaldi works in 16-bit integer units, and the mel floor is calibrated to that
        // scale — feeding ±1.0 floats would put every value under the floor.
        let scaled = vDSP.multiply(32768.0, samples)

        let frameCount = (scaled.count - Self.frameLength) / Self.hopLength + 1
        var result: [[Float]] = []
        result.reserveCapacity(frameCount)

        let log2n = vDSP_Length(log2(Float(Self.fftLength)).rounded())
        guard let fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(fft) }

        var real = [Float](repeating: 0, count: Self.fftLength / 2)
        var imaginary = [Float](repeating: 0, count: Self.fftLength / 2)
        var frame = [Float](repeating: 0, count: Self.fftLength)

        for index in 0..<frameCount {
            let start = index * Self.hopLength
            var raw = Array(scaled[start..<(start + Self.frameLength)])

            // Kaldi removes the mean of each frame before pre-emphasis.
            var mean: Float = 0
            vDSP_meanv(raw, 1, &mean, vDSP_Length(Self.frameLength))
            var negativeMean = -mean
            vDSP_vsadd(raw, 1, &negativeMean, &raw, 1, vDSP_Length(Self.frameLength))

            // Pre-emphasis, first sample against itself as Kaldi does.
            var emphasised = [Float](repeating: 0, count: Self.frameLength)
            emphasised[0] = raw[0] - Self.preemphasis * raw[0]
            for n in 1..<Self.frameLength {
                emphasised[n] = raw[n] - Self.preemphasis * raw[n - 1]
            }

            vDSP.multiply(emphasised, window, result: &emphasised)

            for n in 0..<Self.fftLength {
                frame[n] = n < Self.frameLength ? emphasised[n] : 0
            }

            var split = DSPSplitComplex(realp: &real, imagp: &imaginary)
            frame.withUnsafeBufferPointer { pointer in
                pointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Self.fftLength / 2) {
                    vDSP_ctoz($0, 2, &split, 1, vDSP_Length(Self.fftLength / 2))
                }
            }
            vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))

            // vDSP packs Nyquist into imagp[0] and scales by 2.
            var power = [Float](repeating: 0, count: Self.fftLength / 2 + 1)
            let dc = real[0] / 2
            let nyquist = imaginary[0] / 2
            power[0] = dc * dc
            power[Self.fftLength / 2] = nyquist * nyquist
            for bin in 1..<(Self.fftLength / 2) {
                let re = real[bin] / 2
                let im = imaginary[bin] / 2
                power[bin] = re * re + im * im
            }

            var mel = [Float](repeating: 0, count: Self.melBins)
            for bin in 0..<power.count {
                let magnitude = power[bin]
                if magnitude == 0 { continue }
                let filters = melFilters[bin]
                for m in 0..<Self.melBins where filters[m] != 0 {
                    mel[m] += magnitude * filters[m]
                }
            }
            for m in 0..<Self.melBins {
                mel[m] = log(max(mel[m], Self.melFloor))
            }
            result.append(mel)
        }
        return result
    }

    /// Zero mean, unit variance per mel bin across the utterance.
    ///
    /// The sample variance (ddof = 1) is deliberate: it is what the Python extractor uses,
    /// and on short passages the difference from the population variance is not negligible.
    func normalisePerBin(_ frames: [[Float]]) -> [[Float]] {
        guard frames.count > 1 else { return frames }
        let count = Float(frames.count)
        var output = frames
        for bin in 0..<Self.melBins {
            var sum: Float = 0
            for frame in frames { sum += frame[bin] }
            let mean = sum / count
            var squared: Float = 0
            for frame in frames {
                let delta = frame[bin] - mean
                squared += delta * delta
            }
            let variance = squared / (count - 1)
            let scale = 1 / (variance + 1e-7).squareRoot()
            for index in 0..<frames.count {
                output[index][bin] = (frames[index][bin] - mean) * scale
            }
        }
        return output
    }

    /// Concatenate consecutive frames in pairs, dropping a trailing odd frame.
    func stack(_ frames: [[Float]]) -> [[Float]] {
        let usable = frames.count - (frames.count % Self.stride)
        guard usable > 0 else { return [] }
        // `Swift.stride` explicitly: the static `stride` property shadows the global
        // function inside this type.
        return Swift.stride(from: 0, to: usable, by: Self.stride).map { index in
            frames[index] + frames[index + 1]
        }
    }
}
