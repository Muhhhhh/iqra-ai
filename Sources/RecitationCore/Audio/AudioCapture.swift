import Foundation

public enum AudioCaptureError: Error, Sendable, Equatable {
    case permissionDenied
    case noInputDevice
    case engineFailure(String)
    case formatUnsupported(String)
}

/// Source of 16 kHz mono audio frames.
///
/// Abstracted so the pipeline is testable without a microphone, and so the real
/// implementation can vary per platform without leaking into the pipeline.
public protocol AudioCapture: Sendable {
    /// Begin capturing. The returned stream finishes when `stop()` is called or the
    /// source is exhausted.
    func start() async throws -> AsyncStream<AudioChunk>
    func stop() async
}

/// Platform differences in session lifecycle. iOS is far stricter than macOS:
/// it requires an activated `AVAudioSession` with the right category, and it can
/// interrupt capture at any time (phone call, Siri, another app taking the mic).
/// macOS mostly needs to react to default-device changes.
public protocol AudioSessionController: Sendable {
    func activate() async throws
    func deactivate() async
    /// Interruptions the pipeline must react to by pausing/resuming.
    func interruptions() -> AsyncStream<AudioInterruption>
}

public enum AudioInterruption: Sendable, Equatable {
    case began
    /// `shouldResume` reflects the OS hint that it's safe to restart capture.
    case ended(shouldResume: Bool)
    case routeChanged
}

/// macOS and test default: nothing to activate.
public struct PassthroughAudioSessionController: AudioSessionController {
    public init() {}
    public func activate() async throws {}
    public func deactivate() async {}
    public func interruptions() -> AsyncStream<AudioInterruption> {
        AsyncStream { $0.finish() }
    }
}
