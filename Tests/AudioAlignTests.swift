import Foundation

private struct Noise {
    var state: UInt64
    mutating func next() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int64(bitPattern: state >> 11) % 2_000_000) / 1_000_000 - 1
    }
}

/// Percussive bursts at irregular times over a quieter bed, which is what the onset envelope
/// has to lock onto in real music.
private func music(seconds: Double, sampleRate: Double, seed: UInt64) -> [Float] {
    var noise = Noise(state: seed)
    var samples = [Float](repeating: 0, count: Int(seconds * sampleRate))
    var at = 0
    while at < samples.count {
        let length = Int(sampleRate * 0.15)
        let gain = 0.3 + 0.7 * abs(noise.next())
        for i in 0..<min(length, samples.count - at) {
            samples[at + i] += gain * noise.next() * Float(exp(-Double(i) / (sampleRate * 0.04)))
        }
        at += Int(sampleRate * (0.12 + 0.35 * Double(abs(noise.next()))))
    }
    for i in samples.indices { samples[i] += 0.05 * noise.next() }
    return samples
}

func audioAlignTests() {
    let rate = 12_000.0

    test("a recorded stretch of a song is found where it sits in the song") {
        let song = music(seconds: 60, sampleRate: rate, seed: 7)
        let start = Int(20.37 * rate)
        var noise = Noise(state: 99)
        let heard = song[start..<start + Int(12 * rate)].map { 0.5 * $0 + 0.05 * noise.next() }
        let match = AudioAlign.locate(AudioAlign.onsets(Array(heard), sampleRate: rate),
                                      in: AudioAlign.onsets(song, sampleRate: rate))
        expect(match.map { abs($0.time - 20.37) < 0.02 } == true, "\(String(describing: match))")
        expect(match?.isConfident == true, "\(String(describing: match))")
    }

    test("a repeated section is told apart by where it was expected") {
        let verse = music(seconds: 30, sampleRate: rate, seed: 7)
        let song = verse + verse
        let start = Int(40 * rate)
        let heard = AudioAlign.onsets(Array(song[start..<start + Int(10 * rate)]), sampleRate: rate)
        let reference = AudioAlign.onsets(song, sampleRate: rate)
        expect(AudioAlign.locate(heard, in: reference)?.isConfident != true, "a repeat is ambiguous on its own")
        let match = AudioAlign.locate(heard, in: reference, near: 41, within: 6)
        expect(match.map { abs($0.time - 40) < 0.02 } == true, "\(String(describing: match))")
        expect(match?.isConfident == true, "\(String(describing: match))")
    }

    test("a stretch of a different song is not confidently placed") {
        let song = music(seconds: 60, sampleRate: rate, seed: 7)
        let other = music(seconds: 12, sampleRate: rate, seed: 123)
        let match = AudioAlign.locate(AudioAlign.onsets(other, sampleRate: rate),
                                      in: AudioAlign.onsets(song, sampleRate: rate))
        expect(match?.isConfident != true, "\(String(describing: match))")
    }

    test("a recording longer than the reference cannot be placed") {
        let short = AudioAlign.onsets(music(seconds: 5, sampleRate: rate, seed: 1), sampleRate: rate)
        let long = AudioAlign.onsets(music(seconds: 12, sampleRate: rate, seed: 2), sampleRate: rate)
        expect(AudioAlign.locate(long, in: short) == nil)
    }

    test("silence is not placed") {
        let song = AudioAlign.onsets(music(seconds: 30, sampleRate: rate, seed: 3), sampleRate: rate)
        let silence = AudioAlign.onsets([Float](repeating: 0, count: Int(12 * rate)), sampleRate: rate)
        expect(AudioAlign.locate(silence, in: song) == nil)
    }
}
