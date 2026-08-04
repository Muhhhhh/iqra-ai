import Foundation
import Testing
@testable import RecitationCore

@Suite("Session recording")
struct SessionRecorderTests {

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "iqra-recorder-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test("The header declares the length the file actually has")
    func headerLengths() {
        let samples = 8_000
        let header = SessionRecorder.header(sampleCount: samples)
        #expect(header.count == 44)

        func uint32(at offset: Int) -> UInt32 {
            header.subdata(in: offset..<(offset + 4)).withUnsafeBytes {
                UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
            }
        }
        // A wrong RIFF size is the classic way to write a file every player refuses.
        #expect(uint32(at: 4) == UInt32(36 + samples * 2))
        #expect(uint32(at: 40) == UInt32(samples * 2))
        #expect(uint32(at: 24) == UInt32(AudioChunk.canonicalSampleRate))
        #expect(String(decoding: header.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: header.subdata(in: 8..<12), as: UTF8.self) == "WAVE")
    }

    @Test("A session writes audio and a log that agree on the length")
    func writesSession() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = SessionRecorder(directory: directory)

        await recorder.begin()
        // Three seconds, so the recording clears the one-second floor.
        for index in 0..<3 {
            let samples = (0..<16_000).map { sin(Float($0) * 0.05) * 0.5 }
            await recorder.append(AudioChunk(samples: samples, startTime: Double(index)))
        }
        let folder = await recorder.finish(words: [], notes: [])
        #expect(folder != nil)

        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let audio = try #require(files.first { $0.pathExtension == "wav" })
        let json = try #require(files.first { $0.pathExtension == "json" })

        let written = try Data(contentsOf: audio)
        let expectedBytes = 44 + 3 * 16_000 * 2
        #expect(written.count == expectedBytes)

        let log = try SessionRecorder.decoder().decode(SessionRecorder.Log.self, from: Data(contentsOf: json))
        #expect(abs(log.duration - 3) < 0.01)
        #expect(log.audioFile == audio.lastPathComponent)
        #expect(log.sampleRate == AudioChunk.canonicalSampleRate)
    }

    @Test("A session with almost nothing in it is not kept")
    func discardsSilence() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = SessionRecorder(directory: directory)

        await recorder.begin()
        await recorder.append(AudioChunk(samples: [Float](repeating: 0, count: 800), startTime: 0))
        let folder = await recorder.finish(words: [], notes: [])

        #expect(folder == nil)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.filter { $0.pathExtension == "wav" }.isEmpty)
    }

    @Test("Samples beyond full scale clamp instead of wrapping")
    func clampsLoudAudio() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = SessionRecorder(directory: directory)

        await recorder.begin()
        // Without clamping, +1.5 wraps to a large negative and puts a click in the file
        // exactly where the reciter was loudest.
        await recorder.append(
            AudioChunk(samples: [Float](repeating: 1.5, count: 20_000), startTime: 0)
        )
        _ = await recorder.finish(words: [], notes: [])

        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let audio = try #require(files.first { $0.pathExtension == "wav" })
        let written = try Data(contentsOf: audio).dropFirst(44)
        let values = written.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        #expect(values.allSatisfy { $0 > 32_000 })
    }
}
