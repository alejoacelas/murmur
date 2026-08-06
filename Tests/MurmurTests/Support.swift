import AVFoundation
import Foundation
import XCTest

/// Shared test plumbing: fixture paths, expected transcripts, WAV loading, one warm backend.
enum Fixtures {
    static let dir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // MurmurTests/
        .deletingLastPathComponent()  // Tests/
        .appendingPathComponent("Fixtures", isDirectory: true)

    static func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    static let expected: [String: String] = {
        let data = try! Data(contentsOf: dir.appendingPathComponent("expected.json"))
        return try! JSONDecoder().decode([String: String].self, from: data)
    }()

    /// Load a fixture as canonical 16 kHz mono Float32 samples (fixtures are authored 16 kHz mono).
    static func samples(_ name: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: url(name))
        let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: file.processingFormat.sampleRate,
            channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buf)
        return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
    }
}
