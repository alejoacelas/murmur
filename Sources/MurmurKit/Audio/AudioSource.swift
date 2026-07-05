import AVFoundation
import Foundation

/// The seam that makes the whole record path deterministic (SPEC §3): mic and file injection are
/// interchangeable, and both emit the SAME canonical stream — 16 kHz mono Float32 PCM — so nothing
/// downstream can tell them apart. Delivered as `[Float]` (one copy at the source boundary) so
/// chunks cross actor boundaries cleanly; `CaptureWorker` re-wraps for file writes.
public protocol AudioSource: Sendable {
    /// Begin delivering canonical samples off the main actor until EOF/stop.
    /// The callback must be cheap; ordering is the caller's job (enqueue into an AsyncStream).
    func start(onSamples: @escaping @Sendable ([Float]) -> Void) throws
    /// Returns only after the last buffer has been delivered (source fully drained; SPEC §3).
    func stop() async
}

public enum AudioSourceError: Error, CustomStringConvertible {
    case fileUnreadable(String)
    case engineStartFailed(String)
    case converterUnavailable

    public var description: String {
        switch self {
        case .fileUnreadable(let s): return "audio file unreadable: \(s)"
        case .engineStartFailed(let s): return "audio engine start failed: \(s)"
        case .converterUnavailable: return "could not create audio converter"
        }
    }
}

public enum CanonicalAudio {
    public static let sampleRate: Double = 16_000
    public static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    /// Wrap canonical samples back into a PCM buffer (for AVAudioFile writes / streaming feed).
    public static func buffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        return buf
    }

    /// Extract mono Float32 samples from a canonical-format buffer.
    public static func samples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }
}
