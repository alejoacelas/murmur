import AVFoundation
import Foundation

/// Whole-file audio utilities: canonical-sample loading (VAD gate, tests) and the derived WAV
/// cache (SPEC §5.3 — audio.caf is the source of truth; audio.wav is a convenience transcode).
public enum AudioFiles {
    /// Load any readable audio file as canonical 16 kHz mono Float32 samples.
    public static func loadCanonicalSamples(_ url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw TranscriptionError.audioUnreadable("\(url.path): \(error)")
        }
        let src = file.processingFormat
        if file.length == 0 { return [] }
        guard let converter = AVAudioConverter(from: src, to: CanonicalAudio.format) else {
            throw AudioSourceError.converterUnavailable
        }
        var out: [Float] = []
        let chunkFrames = AVAudioFrameCount(src.sampleRate)  // 1 s per read
        while file.framePosition < file.length {
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: chunkFrames) else { break }
            try file.read(into: inBuf, frameCount: chunkFrames)
            if inBuf.frameLength == 0 { break }
            let capacity = AVAudioFrameCount(
                Double(inBuf.frameLength) * CanonicalAudio.sampleRate / src.sampleRate + 32)
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: CanonicalAudio.format, frameCapacity: capacity)
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
            out.append(contentsOf: CanonicalAudio.samples(from: outBuf))
        }
        return out
    }

    /// Transcode the authoritative CAF to a 16-bit WAV cache. Best-effort: failure is logged,
    /// never fatal — transcription reads the CAF.
    public static func transcodeToWAV(caf: URL, wav: URL) {
        do {
            let samples = try loadCanonicalSamples(caf)
            guard let buf = CanonicalAudio.buffer(from: samples) else { return }
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            let out = try AVAudioFile(
                forWriting: wav, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try out.write(from: buf)
        } catch {
            Log.warn("audio.wav_transcode_failed", msg: "\(error)")
        }
    }
}
