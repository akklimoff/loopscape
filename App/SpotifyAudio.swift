import AVFoundation
import AppKit
import CoreAudio
import os.log

/// Records what Spotify is playing through a Core Audio process tap: only Spotify's own
/// output, held in memory, never written anywhere. The first tap asks for the "System Audio
/// Recording" permission; a declined one delivers silence rather than an error.
@available(macOS 14.2, *)
final class SpotifyAudio {
    struct Recording {
        let samples: [Float]
        let sampleRate: Double
        /// When the first sample was played.
        let startedAt: Date
    }

    enum Failure: Error {
        case notRunning
        case coreAudio(String, OSStatus)
        case silent
    }

    /// The tap delivers 48 kHz; the onset envelope needs nowhere near that.
    private static let decimation = 4

    private let queue = DispatchQueue(label: "com.aklimoff.loopscape.spotify-audio")
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var samples: [Float] = []
    private var firstHostTime: UInt64?
    private var format: AudioStreamBasicDescription?

    static func record(seconds: TimeInterval, completion: @escaping (Result<Recording, Failure>) -> Void) {
        let recorder = SpotifyAudio()
        do {
            try recorder.start()
        } catch let failure as Failure {
            recorder.stop()
            return completion(.failure(failure))
        } catch {
            recorder.stop()
            return completion(.failure(.coreAudio("start", -1)))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            recorder.stop()
            completion(recorder.result())
        }
    }

    private func start() throws {
        let processes = try Self.spotifyProcesses()
        guard !processes.isEmpty else { throw Failure.notRunning }
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check("create tap", AudioHardwareCreateProcessTap(description, &tap))

        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var tapFormat = AudioStreamBasicDescription()
        var formatAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                       mScope: kAudioObjectPropertyScopeGlobal,
                                                       mElement: kAudioObjectPropertyElementMain)
        try check("tap format", AudioObjectGetPropertyData(tap, &formatAddress, 0, nil, &formatSize, &tapFormat))
        format = tapFormat

        let device: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Loopscape sync",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                               kAudioSubTapDriftCompensationKey: true]],
        ]
        try check("create device", AudioHardwareCreateAggregateDevice(device as CFDictionary, &aggregate))
        try check("io proc", AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, queue) { [weak self] _, input, inputTime, _, _ in
            self?.receive(input, at: inputTime.pointee.mHostTime)
        })
        try check("start", AudioDeviceStart(aggregate, procID))
    }

    private func receive(_ input: UnsafePointer<AudioBufferList>, at hostTime: UInt64) {
        guard var format, let avFormat = AVAudioFormat(streamDescription: &format),
              let buffer = AVAudioPCMBuffer(pcmFormat: avFormat, bufferListNoCopy: input),
              let channels = buffer.floatChannelData else { return }
        if firstHostTime == nil { firstHostTime = hostTime }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(avFormat.channelCount)
        let stride = avFormat.isInterleaved ? channelCount : 1
        let lanes = avFormat.isInterleaved ? 1 : channelCount
        var frame = 0
        while frame + Self.decimation <= frames {
            var sum: Float = 0
            for offset in 0..<Self.decimation {
                if avFormat.isInterleaved {
                    for channel in 0..<channelCount { sum += channels[0][(frame + offset) * stride + channel] }
                } else {
                    for lane in 0..<lanes { sum += channels[lane][frame + offset] }
                }
            }
            samples.append(sum / Float(Self.decimation * channelCount))
            frame += Self.decimation
        }
    }

    private func stop() {
        if aggregate != kAudioObjectUnknown {
            AudioDeviceStop(aggregate, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregate, procID) }
            AudioHardwareDestroyAggregateDevice(aggregate)
            aggregate = AudioObjectID(kAudioObjectUnknown)
        }
        if tap != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tap)
            tap = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func result() -> Result<Recording, Failure> {
        queue.sync {
            guard let firstHostTime, let format, samples.contains(where: { abs($0) > 1e-4 }) else {
                return .failure(.silent)
            }
            let age = Double(mach_absolute_time() &- firstHostTime) * Self.secondsPerHostTick
            return .success(Recording(samples: samples, sampleRate: format.mSampleRate / Double(Self.decimation),
                                      startedAt: Date().addingTimeInterval(-age)))
        }
    }

    private static let secondsPerHostTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }()

    /// Spotify's audio may come from a helper process, so every process of its bundle family
    /// that Core Audio knows is tapped.
    private static func spotifyProcesses() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check("process list size", AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size))
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try check("process list", AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects))
        return objects.filter { bundleID(of: $0)?.hasPrefix("com.spotify.client") == true }
    }

    private static func bundleID(of process: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func check(_ step: String, _ status: OSStatus) throws {
        guard status == noErr else { throw Failure.coreAudio(step, status) }
    }

    private func check(_ step: String, _ status: OSStatus) throws {
        try Self.check(step, status)
    }
}
