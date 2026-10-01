import Accelerate
import Foundation

/// Finds where a few seconds of what Spotify plays sit inside a music video's soundtrack.
/// Raw waveforms of the same song differ between masters and mixes, but the moments where
/// notes and drums start do not, so both are reduced to an onset envelope first.
enum AudioAlign {
    static let frameRate: Double = 100

    struct Match: Equatable {
        /// Seconds into the reference where the segment begins.
        let time: TimeInterval
        let peak: Float
        /// How far the best placement stands above the best one elsewhere.
        let margin: Float

        var isConfident: Bool { peak >= 0.35 && margin >= 0.1 }
    }

    static func onsets(_ samples: [Float], sampleRate: Double) -> [Float] {
        let hop = max(1, Int(sampleRate / frameRate))
        let frames = samples.count / hop
        guard frames > 1 else { return [] }
        var slope = [Float](repeating: 0, count: samples.count)
        if samples.count > 1 {
            vDSP_vsub(samples, 1, Array(samples.dropFirst()), 1, &slope, 1, vDSP_Length(samples.count - 1))
        }
        var envelope = [Float](repeating: 0, count: frames)
        var previous: (Float, Float)?
        samples.withUnsafeBufferPointer { body in
            slope.withUnsafeBufferPointer { edges in
                for frame in 0..<frames {
                    var loud: Float = 0
                    var bright: Float = 0
                    vDSP_svesq(body.baseAddress! + frame * hop, 1, &loud, vDSP_Length(hop))
                    vDSP_svesq(edges.baseAddress! + frame * hop, 1, &bright, vDSP_Length(hop))
                    let current = (log(loud + 1e-6), log(bright + 1e-6))
                    if let previous {
                        envelope[frame] = max(0, current.0 - previous.0) + max(0, current.1 - previous.1)
                    }
                    previous = current
                }
            }
        }
        return envelope
    }

    /// Normalised cross-correlation over every placement, refined between frames by fitting
    /// a parabola through the peak and its neighbours.
    static func locate(_ segment: [Float], in reference: [Float]) -> Match? {
        let length = segment.count
        guard length > 10, reference.count >= length else { return nil }
        var mean: Float = 0
        vDSP_meanv(segment, 1, &mean, vDSP_Length(length))
        var centred = segment.map { $0 - mean }
        var energy: Float = 0
        vDSP_svesq(centred, 1, &energy, vDSP_Length(length))
        guard energy > 1e-6 else { return nil }
        let norm = sqrt(energy)
        vDSP_vsdiv(centred, 1, [norm], &centred, 1, vDSP_Length(length))

        var sums = [Double](repeating: 0, count: reference.count + 1)
        var squares = [Double](repeating: 0, count: reference.count + 1)
        for (i, value) in reference.enumerated() {
            sums[i + 1] = sums[i] + Double(value)
            squares[i + 1] = squares[i] + Double(value) * Double(value)
        }
        let placements = reference.count - length + 1
        var scores = [Float](repeating: 0, count: placements)
        reference.withUnsafeBufferPointer { body in
            for lag in 0..<placements {
                let sum = sums[lag + length] - sums[lag]
                let spread = squares[lag + length] - squares[lag] - sum * sum / Double(length)
                guard spread > 1e-9 else { continue }
                var dot: Float = 0
                vDSP_dotpr(centred, 1, body.baseAddress! + lag, 1, &dot, vDSP_Length(length))
                scores[lag] = dot / Float(spread.squareRoot())
            }
        }

        guard let best = scores.indices.max(by: { scores[$0] < scores[$1] }) else { return nil }
        let exclusion = Int(0.3 * frameRate)
        let rival = scores.indices.lazy
            .filter { abs($0 - best) > exclusion }
            .map { scores[$0] }
            .max() ?? 0
        var refined = Double(best)
        if best > 0, best < placements - 1 {
            let (left, centre, right) = (scores[best - 1], scores[best], scores[best + 1])
            let curvature = left - 2 * centre + right
            if curvature < 0 { refined += Double(0.5 * (left - right) / curvature) }
        }
        return Match(time: refined / frameRate, peak: scores[best], margin: scores[best] - rival)
    }
}
