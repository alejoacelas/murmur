// murmur-smoke — headless fixture transcribe, the earliest milestone (SPEC §10.2, §12 M1).
// No GUI, no permissions, no session dir. Usage:
//   murmur-smoke <wav> [<wav> ...] [--expect <normalized-text>]
// With --expect (single file only): exit 0 iff the normalized transcript matches exactly.
import Foundation
import MurmurKit

var files: [String] = []
var expect: String?
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    if a == "--expect", let e = it.next() {
        expect = e
    } else {
        files.append(a)
    }
}
guard !files.isEmpty else {
    FileHandle.standardError.write(Data("usage: murmur-smoke <wav> [...] [--expect <text>]\n".utf8))
    exit(2)
}

let backend = FluidAudioBackend()
do {
    try await backend.ensureModelReady()
    for f in files {
        let url = URL(fileURLWithPath: f)
        guard FileManager.default.fileExists(atPath: url.path) else {
            FileHandle.standardError.write(Data("murmur-smoke: no such file: \(f)\n".utf8))
            exit(2)
        }
        let text = try await backend.transcribe(fileURL: url)
        print(text)
        if let expect {
            let got = TextMatch.normalize(text)
            let want = TextMatch.normalize(expect)
            if got != want {
                FileHandle.standardError.write(Data("murmur-smoke: MISMATCH got=\"\(got)\" want=\"\(want)\"\n".utf8))
                exit(1)
            }
        }
    }
} catch {
    FileHandle.standardError.write(Data("murmur-smoke: \(error)\n".utf8))
    exit(1)
}
