import AVFoundation
import Foundation

/// Replays an audio file through the exact enqueue path the mic uses (SPEC §3). Converts any
/// input format to canonical 16 kHz mono Float32 and emits ~100 ms chunks. With `realtime: true`
/// chunks are paced at wall-clock speed — needed by crash-mid-recording tests that must catch the
/// session while it is still `recording`.
public final class FileAudioSource: AudioSource, @unchecked Sendable {
    private let url: URL
    private let realtime: Bool
    private let state = NSLock()
    private var task: Task<Void, Never>?
    private var stopped = false

    public init(url: URL, realtime: Bool = false) {
        self.url = url
        self.realtime = realtime
    }

    public func start(onSamples: @escaping @Sendable ([Float]) -> Void) throws {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioSourceError.fileUnreadable("\(url.path): \(error)")
        }
        let src = file.processingFormat
        guard let converter = AVAudioConverter(from: src, to: CanonicalAudio.format) else {
            throw AudioSourceError.converterUnavailable
        }
        let realtime = self.realtime
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let chunkFrames = AVAudioFrameCount(src.sampleRate / 10)  // ~100 ms of input
            while true {
                if Task.isCancelled { break }
                if self?.isStopped() ?? true { break }
                guard let inBuf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: chunkFrames) else { break }
                do {
                    try file.read(into: inBuf, frameCount: chunkFrames)
                } catch {
                    break
                }
                if inBuf.frameLength == 0 { break }

                let outCapacity = AVAudioFrameCount(
                    Double(inBuf.frameLength) * CanonicalAudio.sampleRate / src.sampleRate + 32)
                guard let outBuf = AVAudioPCMBuffer(pcmFormat: CanonicalAudio.format, frameCapacity: outCapacity)
                else { break }
                var fed = false
                var convError: NSError?
                converter.convert(to: outBuf, error: &convError) { _, status in
                    if fed {
                        status.pointee = .noDataNow
                        return nil
                    }
                    fed = true
                    status.pointee = .haveData
                    return inBuf
                }
                if convError != nil { break }
                let samples = CanonicalAudio.samples(from: outBuf)
                if !samples.isEmpty { onSamples(samples) }

                if realtime {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                if file.framePosition >= file.length { break }
            }
        }
    }

    public func stop() async {
        markStopped()
        await task?.value  // drained: the read loop has exited and delivered its last chunk
        task = nil
    }

    /// Wait for natural EOF without truncating (inject waits for the whole file, then stops).
    public func awaitEOF() async {
        await task?.value
    }

    private func markStopped() {
        state.lock()
        defer { state.unlock() }
        stopped = true
    }

    private func isStopped() -> Bool {
        state.lock()
        defer { state.unlock() }
        return stopped
    }
}
