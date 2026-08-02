import AVFoundation
import Foundation

/// Plays back a retained `AudioChunk`.
///
/// This exists to make the "audio is preserved, not discarded" guarantee visible and
/// useful: the reviewer can hear exactly the audio the matcher judged. The same slices
/// are what v2 tajweed rules will measure, so being able to listen to a slice is also
/// the fastest way to sanity-check those thresholds later.
public actor AudioChunkPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var isConfigured = false

    public init() {}

    public enum PlaybackError: Error, Sendable {
        case emptyChunk
        case formatUnsupported
        case engineFailure(String)
    }

    /// Play a chunk. Returns as soon as playback is scheduled, not when it finishes.
    public func play(_ chunk: AudioChunk) throws {
        guard !chunk.isEmpty else { throw PlaybackError.emptyChunk }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: chunk.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw PlaybackError.formatUnsupported
        }

        try configureIfNeeded(format: format)

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(chunk.samples.count)
        ) else {
            throw PlaybackError.formatUnsupported
        }
        buffer.frameLength = AVAudioFrameCount(chunk.samples.count)
        guard let channel = buffer.floatChannelData?[0] else {
            throw PlaybackError.formatUnsupported
        }
        chunk.samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: source.count)
        }

        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: [])
        player.play()
    }

    public func stop() {
        guard isConfigured else { return }
        player.stop()
    }

    private func configureIfNeeded(format: AVAudioFormat) throws {
        // The engine is rebuilt if the format changes, but in practice every chunk in
        // the pipeline is 16 kHz mono, so this runs once.
        if isConfigured, player.outputFormat(forBus: 0).sampleRate == format.sampleRate {
            if !engine.isRunning {
                do { try engine.start() } catch { throw PlaybackError.engineFailure(error.localizedDescription) }
            }
            return
        }

        if isConfigured {
            engine.stop()
            engine.disconnectNodeOutput(player)
            engine.detach(player)
            isConfigured = false
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw PlaybackError.engineFailure(error.localizedDescription)
        }
        isConfigured = true
    }
}
