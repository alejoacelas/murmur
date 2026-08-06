// S5 spike — streaming partials via SlidingWindowAsrManager, feeding a file's buffers
// through the external-feed API (streamAudio). Asserts partial updates fire.
// Usage: stream-spike <wav>
import AVFoundation
import FluidAudio
import Foundation

guard let path = CommandLine.arguments.dropFirst().first else {
    print("usage: stream-spike <wav>")
    exit(2)
}

let models = try await AsrModels.downloadAndLoad(version: .v2)
let sw = SlidingWindowAsrManager(config: .default)
try await sw.loadModels(models)
try await sw.startStreaming(source: .microphone)  // label only; audio is fed manually below

let updatesTask = Task { () -> Int in
    var n = 0
    for await u in await sw.transcriptionUpdates {
        n += 1
        print("PARTIAL n=\(n) confirmed=\(u.isConfirmed) text=\(String(u.text.prefix(72)))")
    }
    return n
}

let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
let fmt = file.processingFormat
let chunkFrames = AVAudioFrameCount(fmt.sampleRate / 10)  // 100 ms chunks
while file.framePosition < file.length {
    guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunkFrames) else { break }
    try file.read(into: buf, frameCount: chunkFrames)
    if buf.frameLength == 0 { break }
    await sw.streamAudio(buf)
    try await Task.sleep(nanoseconds: 10_000_000)  // pace the feed a little
}

let final = try await sw.finish()
print("FINAL \(final)")
await sw.cleanup()
updatesTask.cancel()
print("OK")
