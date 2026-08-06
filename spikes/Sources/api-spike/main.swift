// S2/S3/S4 spike — batch transcribe fixtures with the REAL FluidAudio 0.15.4 API.
// Usage: api-spike [--cache <dir>] <wav> [<wav> ...]
import AVFoundation
import FluidAudio
import Foundation

var files: [String] = []
var cacheDir: URL?
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    if a == "--cache", let d = it.next() {
        cacheDir = URL(fileURLWithPath: d)
    } else {
        files.append(a)
    }
}
guard !files.isEmpty else {
    print("usage: api-spike [--cache <dir>] <wav...>")
    exit(2)
}

let t0 = Date()
let models = try await AsrModels.downloadAndLoad(to: cacheDir, version: .v2)
print("LOAD_MS \(Int(Date().timeIntervalSince(t0) * 1000)) cache=\(cacheDir?.path ?? "default")")

let asr = AsrManager(config: .default)
try await asr.loadModels(models)

for f in files {
    var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
    let t = Date()
    let r = try await asr.transcribe(URL(fileURLWithPath: f), decoderState: &state)
    print("FILE \(f)")
    print("TEXT \(r.text)")
    print("MS \(Int(Date().timeIntervalSince(t) * 1000)) confidence=\(r.confidence) durationSec=\(r.duration)")
}
print("OK")
