#if os(iOS)
import AVFoundation
import Foundation

/// iOS session lifecycle: category/mode setup plus interruption and route-change
/// forwarding. macOS has no equivalent and uses `PassthroughAudioSessionController`.
public final class IOSAudioSessionController: AudioSessionController, @unchecked Sendable {
    private let session = AVAudioSession.sharedInstance()
    private var observers: [NSObjectProtocol] = []

    public init() {}

    public func activate() async throws {
        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard granted else { throw AudioCaptureError.permissionDenied }

        do {
            // `.measurement` disables the processing chain that would otherwise colour
            // the signal — it matters for ASR accuracy and even more for v2 tajweed DSP,
            // where AGC would flatten exactly the energy bursts we want to measure.
            try session.setCategory(.record, mode: .measurement, options: [.allowBluetooth])
            try session.setPreferredSampleRate(AudioChunk.canonicalSampleRate)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw AudioCaptureError.engineFailure(error.localizedDescription)
        }
    }

    public func deactivate() async {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    public func interruptions() -> AsyncStream<AudioInterruption> {
        AsyncStream { continuation in
            let center = NotificationCenter.default

            let interruption = center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: session,
                queue: nil
            ) { notification in
                guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                switch type {
                case .began:
                    continuation.yield(.began)
                case .ended:
                    let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                    continuation.yield(.ended(shouldResume: options.contains(.shouldResume)))
                @unknown default:
                    break
                }
            }

            let route = center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: session,
                queue: nil
            ) { _ in
                continuation.yield(.routeChanged)
            }

            observers = [interruption, route]
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                for observer in self.observers {
                    NotificationCenter.default.removeObserver(observer)
                }
                self.observers = []
            }
        }
    }
}
#endif
