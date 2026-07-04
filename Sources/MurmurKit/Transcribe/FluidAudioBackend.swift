import AVFoundation
import FluidAudio
import Foundation

/// FluidAudio/Parakeet implementation of `TranscriptionBackend`, written against the exact
/// 0.15.4 API verified by spikes S1–S5: `AsrModels.downloadAndLoad(to:version:)`,
/// `AsrManager(config:).loadModels(_:)`, `transcribe(_:decoderState:)` (no `source:`), and
/// `SlidingWindowAsrManager` sharing the same loaded `AsrModels` for streaming.
public actor FluidAudioBackend: TranscriptionBackend {
    /// Repo folder name inside the model cache; the `to:` override must point at this
    /// version-specific directory (spike S4).
    private static let repoFolder = "parakeet-tdt-0.6b-v2"

    private var models: AsrModels?
    private var manager: AsrManager?
    private var loading: Task<AsrManager, Error>?

    public init() {}

    public var modelReady: Bool { manager != nil }

    public func ensureModelReady() async throws {
        _ = try await warmManager()
    }

    public func transcribe(_ samples: [Float]) async throws -> String {
        let asr = try await warmManager()
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let result = try await asr.transcribe(samples, decoderState: &state)
        Log.info("transcribe.done", msg: "chars=\(result.text.count) confidence=\(result.confidence)")
        return result.text
    }

    public func transcribe(fileURL: URL) async throws -> String {
        let asr = try await warmManager()
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let result = try await asr.transcribe(fileURL, decoderState: &state)
        Log.info("transcribe.done", msg: "chars=\(result.text.count) confidence=\(result.confidence)")
        return result.text
    }

    public func makeStreamingSession() async -> StreamingSession? {
        guard let models else { return nil }  // model must be warm first
        do {
            let sw = SlidingWindowAsrManager(config: .default)
            try await sw.loadModels(models)  // shares the loaded models — no second copy
            try await sw.startStreaming(source: .microphone)  // label only; we feed manually
            return FluidStreamingSession(manager: sw)
        } catch {
            Log.warn("stream.session_failed", msg: "\(error)")
            return nil
        }
    }

    /// Load once, keep warm, de-duplicate concurrent callers (they share one download/load).
    private func warmManager() async throws -> AsrManager {
        if let manager { return manager }
        if let loading { return try await loading.value }
        let task = Task { () throws -> (AsrModels, AsrManager) in
            let t0 = Date()
            Log.info("model.load_begin", msg: "repo=\(Self.repoFolder)")
            let loaded = try await AsrModels.downloadAndLoad(
                to: Paths.modelCacheDir(repoFolder: Self.repoFolder), version: .v2)
            let mgr = AsrManager(config: .default)
            try await mgr.loadModels(loaded)
            Log.info("model.load_end", msg: "elapsedMs=\(Int(Date().timeIntervalSince(t0) * 1000))")
            return (loaded, mgr)
        }
        let wrapped = Task { try await task.value.1 }
        loading = wrapped
        do {
            let (loadedModels, mgr) = try await task.value
            models = loadedModels
            manager = mgr
            loading = nil
            return mgr
        } catch {
            loading = nil
            Log.error("model.load_failed", msg: "\(error)")
            throw error
        }
    }
}

/// Streaming partials via `SlidingWindowAsrManager` external feed (spike S5).
private actor FluidStreamingSession: StreamingSession {
    private let manager: SlidingWindowAsrManager
    private static let feedFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    init(manager: SlidingWindowAsrManager) {
        self.manager = manager
    }

    var updates: AsyncStream<StreamingUpdate> {
        get async {
            let source = await manager.transcriptionUpdates
            return AsyncStream { continuation in
                let task = Task {
                    for await u in source {
                        continuation.yield(StreamingUpdate(text: u.text, isConfirmed: u.isConfirmed))
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    func feed(_ samples: [Float]) async {
        guard !samples.isEmpty,
            let buf = AVAudioPCMBuffer(
                pcmFormat: Self.feedFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        await manager.streamAudio(buf)
    }

    func finish() async throws -> String {
        let text = try await manager.finish()
        await manager.cleanup()
        return text
    }

    func cancel() async {
        await manager.cancel()
        await manager.cleanup()
    }
}
