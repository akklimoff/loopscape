import Accelerate
import Foundation

/// Finds where a few seconds of what Spotify plays sit inside a music video's soundtrack.
/// Raw waveforms differ between masters and mixes, but the moments where notes and drums
/// start do not, so both are reduced to onset envelopes first. One envelope is not enough:
/// a rock song's drums repeat every bar, and a single-band match placed a real recording
/// almost as well one bar off (0.68 against 0.59). Per-band envelopes also carry the vocal
/// and guitar line, which does not repeat bar to bar (0.85 against 0.50).
enum AudioAlign {
    static let frameRate: Double = 100
    static let bandCount = 8

    struct Match: Equatable {
        /// Seconds into the reference where the segment begins.
        let time: TimeInterval
        let peak: Float
        /// How far the best placement stands above the best one elsewhere.
        let margin: Float

        var isConfident: Bool { peak >= 0.35 && margin >= 0.15 }
    }

    private static let fftSize = 512
    private static let lowestBand = 60.0
    private static let highestBand = 6000.0

    /// One onset envelope per log-spaced band, at `frameRate`.
    static func onsets(_ samples: [Float], sampleRate: Double) -> [[Float]] {
        let size = fftSize
        let hop = max(1, Int(sampleRate / frameRate))
        guard samples.count > size else { return [] }
        let frames = (samples.count - size) / hop + 1
        let log2n = vDSP_Length(log2(Double(size)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        let bins = (0...bandCount).map { band -> Int in
            let hertz = lowestBand * pow(highestBand / lowestBand, Double(band) / Double(bandCount))
            return min(size / 2 - 1, max(1, Int(hertz / sampleRate * Double(size))))
        }

        var envelopes = [[Float]](repeating: [Float](repeating: 0, count: frames), count: bandCount)
        var previous = [Float](repeating: 0, count: bandCount)
        var frame = [Float](repeating: 0, count: size)
        var real = [Float](repeating: 0, count: size / 2)
        var imaginary = [Float](repeating: 0, count: size / 2)
        var power = [Float](repeating: 0, count: size / 2)
        samples.withUnsafeBufferPointer { body in
            for index in 0..<frames {
                vDSP_vmul(body.baseAddress! + index * hop, 1, window, 1, &frame, 1, vDSP_Length(size))
                real.withUnsafeMutableBufferPointer { realPart in
                    imaginary.withUnsafeMutableBufferPointer { imaginaryPart in
                        var split = DSPSplitComplex(realp: realPart.baseAddress!, imagp: imaginaryPart.baseAddress!)
                        frame.withUnsafeBufferPointer {
                            $0.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) {
                                vDSP_ctoz($0, 2, &split, 1, vDSP_Length(size / 2))
                            }
                        }
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(size / 2))
                    }
                }
                power.withUnsafeBufferPointer { spectrum in
                    for band in 0..<bandCount {
                        let width = max(1, bins[band + 1] - bins[band])
                        var energy: Float = 0
                        vDSP_sve(spectrum.baseAddress! + bins[band], 1, &energy, vDSP_Length(width))
                        let level = log(energy + 1e-6)
                        if index > 0 { envelopes[band][index] = max(0, level - previous[band]) }
                        previous[band] = level
                    }
                }
            }
        }
        return envelopes
    }

    /// Normalised cross-correlation over every placement, averaged across bands and refined
    /// between frames by fitting a parabola through the peak and its neighbours.
    /// With `near`, only placements within `within` seconds of it count: a chorus heard again
    /// is ambiguous over the whole song but not around where the song is known to be.
    static func locate(_ segment: [[Float]], in reference: [[Float]],
                       near expected: TimeInterval? = nil, within radius: TimeInterval = 0) -> Match? {
        guard segment.count == reference.count, let length = segment.first?.count,
              let available = reference.first?.count, length > 10, available >= length else { return nil }
        var first = 0
        var last = available - length
        if let expected {
            first = max(0, Int((expected - radius) * frameRate))
            last = min(last, Int((expected + radius) * frameRate))
            guard first <= last else { return nil }
        }
        let window = reference.map { Array($0[first..<(last + length)]) }
        let placements = last - first + 1
        var scores = [Float](repeating: 0, count: placements)
        var usedBands = 0
        for band in segment.indices {
            guard let normalised = normalise(segment[band]) else { continue }
            usedBands += 1
            accumulate(normalised, against: window[band], into: &scores)
        }
        guard usedBands > 0 else { return nil }
        vDSP_vsdiv(scores, 1, [Float(usedBands)], &scores, 1, vDSP_Length(placements))

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
        return Match(time: (Double(first) + refined) / frameRate, peak: scores[best], margin: scores[best] - rival)
    }

    private static func normalise(_ values: [Float]) -> [Float]? {
        var mean: Float = 0
        vDSP_meanv(values, 1, &mean, vDSP_Length(values.count))
        var centred = values.map { $0 - mean }
        var energy: Float = 0
        vDSP_svesq(centred, 1, &energy, vDSP_Length(centred.count))
        guard energy > 1e-6 else { return nil }
        vDSP_vsdiv(centred, 1, [sqrt(energy)], &centred, 1, vDSP_Length(centred.count))
        return centred
    }

    private static func accumulate(_ segment: [Float], against reference: [Float], into scores: inout [Float]) {
        let length = segment.count
        var sums = [Double](repeating: 0, count: reference.count + 1)
        var squares = [Double](repeating: 0, count: reference.count + 1)
        for (i, value) in reference.enumerated() {
            sums[i + 1] = sums[i] + Double(value)
            squares[i + 1] = squares[i] + Double(value) * Double(value)
        }
        reference.withUnsafeBufferPointer { body in
            for lag in scores.indices {
                let sum = sums[lag + length] - sums[lag]
                let spread = squares[lag + length] - squares[lag] - sum * sum / Double(length)
                guard spread > 1e-9 else { continue }
                var dot: Float = 0
                vDSP_dotpr(segment, 1, body.baseAddress! + lag, 1, &dot, vDSP_Length(length))
                scores[lag] += dot / Float(spread.squareRoot())
            }
        }
    }
}
