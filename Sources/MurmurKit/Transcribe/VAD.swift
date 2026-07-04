import Foundation

/// Silence gate (SPEC §5.4). Parakeet — like most ASR — can hallucinate on silence/noise, so a
/// recording whose RMS is below threshold produces NO transcript and inserts nothing.
public enum VAD {
    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var acc: Double = 0
        for s in samples { acc += Double(s) * Double(s) }
        return Float((acc / Double(samples.count)).squareRoot())
    }

    public static func isSilence(_ samples: [Float], threshold: Float) -> Bool {
        rms(samples) < threshold
    }
}
