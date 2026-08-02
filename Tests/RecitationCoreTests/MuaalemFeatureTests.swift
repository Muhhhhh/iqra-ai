import Foundation
import Testing

@testable import RecitationCore

extension WhisperTestSupport {
    static var frontendURL: URL { packageRoot.appending(path: "Resources/muaalem-frontend.bin") }
    static var frontendExists: Bool { FileManager.default.fileExists(atPath: frontendURL.path) }
}

/// The model's input has to be built exactly as its own extractor builds it. Fed the
/// wrong features it does not fail — it returns confident nonsense — so this compares
/// the Swift implementation against reference features produced by the Python extractor.
@Suite(
    "Muaalem feature front-end",
    .enabled(if: WhisperTestSupport.frontendExists, "run scripts/export-tajweed-frontend.py"),
    .serialized
)
struct MuaalemFeatureTests {

    private func extractor() throws -> MuaalemFeatures {
        try MuaalemFeatures(resourceURL: WhisperTestSupport.frontendURL)
    }

    /// Reference features written by scripts/export-tajweed-frontend.py.
    private func reference() throws -> [[Float]] {
        let url = try WhisperTestSupport.fixture("ikhlas-features.bin")
        let data = try Data(contentsOf: url)
        try #require(data.prefix(4) == Data("MUFR".utf8))
        let rows = Int(data.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: Int32.self) })
        let dim = Int(data.subdata(in: 8..<12).withUnsafeBytes { $0.load(as: Int32.self) })
        let values: [Float] = data.subdata(in: 12..<data.count).withUnsafeBytes {
            Array($0.bindMemory(to: Float.self))
        }
        try #require(values.count == rows * dim)
        return (0..<rows).map { Array(values[($0 * dim)..<(($0 + 1) * dim)]) }
    }

    @Test("The exported window and filterbank load with the expected shapes")
    func loads() throws {
        _ = try extractor()
    }

    @Test("A malformed front-end file is rejected rather than half-read")
    func rejectsGarbage() throws {
        let bogus = FileManager.default.temporaryDirectory.appending(path: "fe-\(UUID()).bin")
        try Data("not a front end at all".utf8).write(to: bogus)
        defer { try? FileManager.default.removeItem(at: bogus) }
        #expect(throws: MuaalemFeatures.LoadError.self) {
            _ = try MuaalemFeatures(resourceURL: bogus)
        }
    }

    @Test("Feature shape matches the reference exactly")
    func shapeMatches() async throws {
        let chunk = try AudioFileLoader.load(url: try WhisperTestSupport.fixture("ikhlas-tts.wav"))
        let mine = try extractor().features(from: chunk)
        let theirs = try reference()

        #expect(mine.count == theirs.count, "\(mine.count) rows vs \(theirs.count)")
        #expect(mine.first?.count == 160)
        #expect(theirs.first?.count == 160)
    }

    @Test("Feature values match the Python extractor")
    func valuesMatch() async throws {
        // This is the test that matters. Everything downstream — the ṣifāt predictions,
        // and therefore every tajweed verdict — is built on these numbers being right.
        let chunk = try AudioFileLoader.load(url: try WhisperTestSupport.fixture("ikhlas-tts.wav"))
        let mine = try extractor().features(from: chunk)
        let theirs = try reference()
        try #require(mine.count == theirs.count)

        var worst: Float = 0
        var worstAt = (row: 0, column: 0)
        var total: Float = 0
        var count = 0
        for row in 0..<mine.count {
            for column in 0..<min(mine[row].count, theirs[row].count) {
                let delta = abs(mine[row][column] - theirs[row][column])
                total += delta
                count += 1
                if delta > worst {
                    worst = delta
                    worstAt = (row, column)
                }
            }
        }
        let mean = total / Float(max(count, 1))
        // Features are normalised to roughly ±4, so this is a tight bound in context.
        #expect(worst < 0.02, "largest difference \(worst) at row \(worstAt.row), column \(worstAt.column)")
        #expect(mean < 0.002, "mean difference \(mean)")
    }

    @Test("Silence and very short audio are handled without crashing")
    func degenerateInput() throws {
        let extractor = try extractor()
        #expect(extractor.features(from: AudioChunk(samples: [], startTime: 0)).isEmpty)
        // Shorter than a single 25 ms frame.
        #expect(extractor.features(from: AudioChunk(samples: [Float](repeating: 0, count: 100), startTime: 0)).isEmpty)
        // Exactly one frame stacks to nothing, since rows come in pairs.
        let single = AudioChunk(samples: [Float](repeating: 0, count: 400), startTime: 0)
        #expect(extractor.features(from: single).isEmpty)
    }

    @Test("Row count follows the 20 ms stride")
    func rowRate() throws {
        // 2 s of audio -> ~200 mel frames -> ~100 stacked rows.
        let extractor = try extractor()
        let chunk = AudioChunk(
            samples: (0..<32_000).map { sin(Float($0) * 0.05) * 0.2 },
            startTime: 0
        )
        let rows = extractor.features(from: chunk)
        #expect(abs(rows.count - 100) <= 2, "got \(rows.count) rows for 2 s")
    }
}
