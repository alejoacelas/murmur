import Foundation

/// Assertion helpers for the test policy (SPEC §10.3): exact normalized match on short clips,
/// WER on the long one — WER on a two-word clip is meaningless.
public enum TextMatch {
    /// Lowercase, strip punctuation (keep letters/digits/spaces), collapse whitespace.
    public static func normalize(_ s: String) -> String {
        let lowered = s.lowercased()
        var out = String.UnicodeScalarView()
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.append(scalar)
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                out.append(" ")
            }
            // punctuation dropped
        }
        let words = String(out).split(separator: " ", omittingEmptySubsequences: true)
        return words.joined(separator: " ")
    }

    /// Word error rate of `hypothesis` against `reference`, computed on normalized words
    /// (word-level Levenshtein / reference length).
    public static func wer(reference: String, hypothesis: String) -> Double {
        let ref = normalize(reference).split(separator: " ").map(String.init)
        let hyp = normalize(hypothesis).split(separator: " ").map(String.init)
        if ref.isEmpty { return hyp.isEmpty ? 0 : 1 }
        if hyp.isEmpty { return 1 }  // every reference word deleted
        var prev = Array(0...hyp.count)
        var cur = [Int](repeating: 0, count: hyp.count + 1)
        for i in 1...ref.count {
            cur[0] = i
            for j in 1...hyp.count {
                let sub = prev[j - 1] + (ref[i - 1] == hyp[j - 1] ? 0 : 1)
                cur[j] = min(sub, prev[j] + 1, cur[j - 1] + 1)
            }
            swap(&prev, &cur)
        }
        return Double(prev[hyp.count]) / Double(ref.count)
    }
}
