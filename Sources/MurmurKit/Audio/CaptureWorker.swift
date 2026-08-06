import AVFoundation
import Foundation

/// Serial owner of the authoritative capture artifact (SPEC §5.3). Appends every canonical chunk
/// to `audio.caf` (CAF stays valid when truncated — verified S12), fsyncs ~every 2 s to narrow
/// the crash window, tracks duration + RMS for the VAD gate, and best-effort feeds the streaming
/// session for HUD partials.
public actor CaptureWorker {
    private let cafURL: URL
    private var caf: AVAudioFile?
    private var syncFD: Int32 = -1
    private var lastSync = Date()
    private var frames = 0
    private var sumSquares: Double = 0
    private var streaming: StreamingSession?

    public init(cafURL: URL) {
        self.cafURL = cafURL
    }

    public func open(streaming: StreamingSession?) throws {
        caf = try AVAudioFile(
            forWriting: cafURL, settings: CanonicalAudio.format.settings,
            commonFormat: .pcmFormatFloat32, interleaved: false)
        syncFD = Darwin.open(cafURL.path, O_RDONLY)
        self.streaming = streaming
    }

    public func append(_ samples: [Float]) {
        guard let caf, let buf = CanonicalAudio.buffer(from: samples) else { return }
        do {
            try caf.write(from: buf)
        } catch {
            Log.error("capture.write_failed", msg: "\(error)")
            return
        }
        frames += samples.count
        for s in samples { sumSquares += Double(s) * Double(s) }
        if Date().timeIntervalSince(lastSync) > 2, syncFD >= 0 {
            fsync(syncFD)
            lastSync = Date()
        }
        if let streaming {
            Task { await streaming.feed(samples) }
        }
    }

    /// Close the capture file. Returns duration + RMS of everything written.
    /// After this returns, `audio.caf` is complete and durable.
    public func finish() -> (durationSec: Double, rms: Float) {
        caf = nil  // AVAudioFile closes on dealloc
        if syncFD >= 0 {
            fsync(syncFD)
            close(syncFD)
            syncFD = -1
        }
        let duration = Double(frames) / CanonicalAudio.sampleRate
        let rms = frames > 0 ? Float((sumSquares / Double(frames)).squareRoot()) : 0
        return (duration, rms)
    }

    public var streamingSession: StreamingSession? { streaming }
}
