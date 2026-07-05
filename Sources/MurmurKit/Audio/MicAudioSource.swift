import AVFoundation
import Foundation

/// Live microphone source. Owns `AVAudioEngine` + the hardware-format tap + the converter to
/// canonical (SPEC §5.1–5.2). The tap callback does the minimum real-time-safe work: copy the
/// buffer and hop off the audio thread; conversion happens on a serial queue.
public final class MicAudioSource: AudioSource, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let convertQueue = DispatchQueue(label: "murmur.mic.convert")
    private var converter: AVAudioConverter?

    public init() {}

    public func start(onSamples: @escaping @Sendable ([Float]) -> Void) throws {
        let input = engine.inputNode
        let hw = input.inputFormat(forBus: 0)
        guard hw.sampleRate > 0 else {
            throw AudioSourceError.engineStartFailed("no input device (hw sample rate 0)")
        }
        guard let converter = AVAudioConverter(from: hw, to: CanonicalAudio.format) else {
            throw AudioSourceError.converterUnavailable
        }
        self.converter = converter

        // The tap must use the hardware format; nothing but copy+enqueue happens in it (§5.2).
        input.installTap(onBus: 0, bufferSize: 4096, format: hw) { [convertQueue] buffer, _ in
            guard let copy = Self.deepCopy(buffer) else { return }
            convertQueue.async {
                let outCapacity = AVAudioFrameCount(
                    Double(copy.frameLength) * CanonicalAudio.sampleRate / hw.sampleRate + 32)
                guard let out = AVAudioPCMBuffer(pcmFormat: CanonicalAudio.format, frameCapacity: outCapacity)
                else { return }
                var fed = false
                var convError: NSError?
                converter.convert(to: out, error: &convError) { _, status in
                    if fed {
                        status.pointee = .noDataNow
                        return nil
                    }
                    fed = true
                    status.pointee = .haveData
                    return copy
                }
                guard convError == nil else { return }
                let samples = CanonicalAudio.samples(from: out)
                if !samples.isEmpty { onSamples(samples) }
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioSourceError.engineStartFailed("\(error)")
        }
    }

    public func stop() async {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Drain: everything already dispatched to the serial convert queue runs before this.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            convertQueue.async { cont.resume() }
        }
    }

    private static func deepCopy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
        else { return nil }
        copy.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
            for c in 0..<channels {
                dst[c].update(from: src[c], count: Int(buffer.frameLength))
            }
        } else if let src = buffer.int16ChannelData, let dst = copy.int16ChannelData {
            for c in 0..<channels {
                dst[c].update(from: src[c], count: Int(buffer.frameLength))
            }
        } else if let src = buffer.int32ChannelData, let dst = copy.int32ChannelData {
            for c in 0..<channels {
                dst[c].update(from: src[c], count: Int(buffer.frameLength))
            }
        } else {
            return nil
        }
        return copy
    }
}
