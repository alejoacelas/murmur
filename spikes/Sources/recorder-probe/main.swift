// S12 spike — write a CAF continuously (synthesized tone, no mic needed) until killed.
// The driver script SIGKILLs this mid-write, then checks the partial CAF is readable.
// Usage: recorder-probe <out.caf>
import AVFoundation
import Foundation

guard CommandLine.arguments.count > 1 else {
    print("usage: recorder-probe <out.caf>")
    exit(2)
}
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
let file = try AVAudioFile(
    forWriting: out, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)

print("PID \(getpid())")
fflush(stdout)

var phase: Float = 0
let frames: AVAudioFrameCount = 1600  // 100 ms per buffer
let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
buf.frameLength = frames
var written = 0
while true {
    let p = buf.floatChannelData![0]
    for i in 0..<Int(frames) {
        p[i] = sinf(phase) * 0.3
        phase += 0.12
    }
    try file.write(from: buf)
    written += Int(frames)
    if written % 16_000 == 0 {
        print("WROTE_SEC \(written / 16_000)")
        fflush(stdout)
    }
    usleep(20_000)  // faster than real-time, keeps the write loop hot
}
