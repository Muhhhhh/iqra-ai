import AVFoundation
import Foundation

/// Decodes an audio file into the pipeline's canonical 16 kHz mono float format.
///
/// Used for the bundled test fixtures and for offline evaluation of the recognizer
/// against reference recordings. Goes through `AVAudioConverter` rather than reading
/// samples directly so that resampling and downmixing match exactly what
/// `EngineAudioCapture` does to live microphone input — otherwise a model verified on
/// files could behave differently on the mic.
public enum AudioFileLoader {

    public enum LoadError: Error, Sendable {
        case unreadable(String)
        case formatUnsupported(String)
        case empty
    }

    /// Load and convert an audio file to a single `AudioChunk` starting at t = 0.
    public static func load(url: URL) throws -> AudioChunk {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw LoadError.unreadable("\(url.lastPathComponent): \(error.localizedDescription)")
        }

        let sourceFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else { throw LoadError.empty }

        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            throw LoadError.formatUnsupported("could not allocate buffer for \(url.lastPathComponent)")
        }
        do {
            try file.read(into: sourceBuffer)
        } catch {
            throw LoadError.unreadable("\(url.lastPathComponent): \(error.localizedDescription)")
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioChunk.canonicalSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw LoadError.formatUnsupported("could not build 16 kHz mono format")
        }

        // Already in canonical format — skip the converter entirely.
        if sourceFormat.sampleRate == targetFormat.sampleRate,
           sourceFormat.channelCount == 1,
           sourceFormat.commonFormat == .pcmFormatFloat32,
           let channel = sourceBuffer.floatChannelData?[0] {
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(sourceBuffer.frameLength)))
            return AudioChunk(samples: samples, startTime: 0)
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw LoadError.formatUnsupported(
                "no converter from \(sourceFormat.sampleRate) Hz / \(sourceFormat.channelCount) ch"
            )
        }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(frameCount) * ratio) + 4096
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw LoadError.formatUnsupported("could not allocate output buffer")
        }

        var supplied = false
        var conversionError: NSError?
        converter.convert(to: outputBuffer, error: &conversionError) { _, status in
            if supplied {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return sourceBuffer
        }
        if let conversionError {
            throw LoadError.formatUnsupported(conversionError.localizedDescription)
        }
        guard outputBuffer.frameLength > 0, let channel = outputBuffer.floatChannelData?[0] else {
            throw LoadError.empty
        }

        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(outputBuffer.frameLength)))
        return AudioChunk(samples: samples, startTime: 0)
    }
}
