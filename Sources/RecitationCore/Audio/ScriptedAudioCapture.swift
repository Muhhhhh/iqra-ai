import Foundation

/// Replays a fixed sequence of chunks instead of opening the microphone.
///
/// Two uses: deterministic pipeline tests, and a "demo mode" toggle in the app shells
/// so the UI can be exercised on a machine with no mic permission granted.
public actor ScriptedAudioCapture: AudioCapture {
    private let chunks: [AudioChunk]
    /// Wall-clock delay between chunks, so the UI updates at a lifelike pace.
    private let pacing: Duration
    private var task: Task<Void, Never>?

    public init(chunks: [AudioChunk], pacing: Duration = .milliseconds(400)) {
        self.chunks = chunks
        self.pacing = pacing
    }

    /// Generates silence-shaped chunks of a given length — enough to drive the pipeline
    /// when paired with a scripted recognizer that ignores the samples.
    public static func silence(
        chunkCount: Int,
        chunkDuration: TimeInterval = 1.5,
        pacing: Duration = .milliseconds(400)
    ) -> ScriptedAudioCapture {
        let sampleCount = Int(chunkDuration * AudioChunk.canonicalSampleRate)
        let chunks = (0..<chunkCount).map { index in
            AudioChunk(
                samples: [Float](repeating: 0, count: sampleCount),
                startTime: TimeInterval(index) * chunkDuration
            )
        }
        return ScriptedAudioCapture(chunks: chunks, pacing: pacing)
    }

    public func start() async throws -> AsyncStream<AudioChunk> {
        // The builder closure runs synchronously in the actor's context, so assigning
        // `task` here is isolated without hopping.
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            self.task = Task { [chunks, pacing] in
                for chunk in chunks {
                    if Task.isCancelled { break }
                    try? await Task.sleep(for: pacing)
                    if Task.isCancelled { break }
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
        }
    }

    public func stop() async {
        task?.cancel()
        task = nil
    }
}
