#if canImport(AVFoundation)
import AVFoundation
import Foundation

/// Plays a downloaded reciter's āyah.
///
/// Separate from `AudioChunkPlayer`, which plays raw PCM captured from the microphone.
/// This plays encoded files from disk, so it uses `AVAudioPlayer` rather than an engine.
@MainActor
public final class ReferenceAudioPlayer {
    private var player: AVAudioPlayer?
    public private(set) var playing: VerseReference?

    public init() {}

    public func play(_ url: URL, reference: VerseReference) throws {
        stop()
        let player = try AVAudioPlayer(contentsOf: url)
        player.prepareToPlay()
        player.play()
        self.player = player
        self.playing = reference
    }

    public func stop() {
        player?.stop()
        player = nil
        playing = nil
    }

    public var isPlaying: Bool { player?.isPlaying ?? false }
}
#endif
