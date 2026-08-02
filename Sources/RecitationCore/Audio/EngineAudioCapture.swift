import AVFoundation
import Foundation

/// Real microphone capture via `AVAudioEngine`, resampled to 16 kHz mono float.
///
/// Both platforms share this class; the platform-specific parts (session activation,
/// interruption handling) live behind `AudioSessionController`.
public final class EngineAudioCapture: AudioCapture, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let session: AudioSessionController
    private let bufferSize: AVAudioFrameCount
    private let lock = NSLock()
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var samplesEmitted: Int = 0

    public init(session: AudioSessionController, bufferSize: AVAudioFrameCount = 1024) {
        self.session = session
        self.bufferSize = bufferSize
    }

    public func start() async throws -> AsyncStream<AudioChunk> {
        try await session.activate()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioCaptureError.noInputDevice
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioChunk.canonicalSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioCaptureError.formatUnsupported("could not build 16 kHz mono format")
        }

        // Whisper only ever sees 16 kHz mono, so the resampler runs on every session and
        // its artefacts are the one part of "audio quality" this code controls. Asking
        // for the best algorithm costs nothing at this data rate.
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioCaptureError.formatUnsupported(
                "no converter from \(inputFormat.sampleRate) Hz / \(inputFormat.channelCount) ch to 16 kHz mono"
            )
        }

        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering

        lock.withLock { samplesEmitted = 0 }

        let stream = AsyncStream<AudioChunk>(bufferingPolicy: .unbounded) { continuation in
            lock.withLock { self.continuation = continuation }
        }

        input.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            guard let chunk = self.convert(buffer, using: converter, to: targetFormat) else { return }
            self.lock.withLock { self.continuation }?.yield(chunk)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            await session.deactivate()
            throw AudioCaptureError.engineFailure(error.localizedDescription)
        }

        return stream
    }

    public func stop() async {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        let continuation = lock.withLock { () -> AsyncStream<AudioChunk>.Continuation? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.finish()
        await session.deactivate()
    }

    /// Resample/downmix one tap buffer and stamp it with its session-clock offset.
    private func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AudioChunk? {
        let ratio = format.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var supplied = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard conversionError == nil, output.frameLength > 0,
              let channel = output.floatChannelData?[0] else { return nil }

        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        let startTime = lock.withLock { () -> TimeInterval in
            let offset = TimeInterval(samplesEmitted) / format.sampleRate
            samplesEmitted += samples.count
            return offset
        }
        return AudioChunk(samples: samples, sampleRate: format.sampleRate, startTime: startTime)
    }
}
