import Accelerate
import AppKit
import CoreAudio
import os

/// Live levels of what the Music app is playing, for the side gear's VU meters and
/// spectrum: a Core Audio process tap on Music (nothing is recorded or saved, only
/// measured), read by an I/O block on its own queue. macOS asks once for permission
/// ("…record audio from other apps"). Runs only while the gear is on screen and a song
/// plays; if the tap can't be made, the meters fall back to their own animation.
final class AudioLevels: @unchecked Sendable {
    static let bandCount = 10
    /// Band centers in Hz, matching the labels under the spectrum.
    private static let centers: [Double] = [31, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    struct Snapshot {
        var left: Float = 0, right: Float = 0 // RMS since the last read (0…1 of full scale)
        var bands = [Float](repeating: 0, count: AudioLevels.bandCount) // 0…1, loudest since the last read
    }

    private let pending = OSAllocatedUnfairLock(initialState: Snapshot())
    /// When the tap last carried any sound, and when it started. A tap macOS hasn't allowed to
    /// hear other apps doesn't fail: it delivers silence. So "running" isn't enough to trust it.
    private let lastHeard = OSAllocatedUnfairLock(initialState: CFTimeInterval(0))
    private var startedAt: CFTimeInterval = 0
    private var tappedPid: pid_t?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "local.dhairyabhatia.himawari.levels", qos: .userInteractive)
    private(set) var running = false
    private var failedAt: Date?
    private var watchingOutput = false
    /// Why the last start didn't work (for the log).
    private(set) var problem = ""
    /// Called (on the main thread) when the permission is granted, so the owner can start again.
    var onPermission: (() -> Void)?

    // Analysis (touched only on `queue` once running)
    private let n = 1024
    private let fft = vDSP.FFT(log2n: 10, radix: .radix2, ofType: DSPSplitComplex.self)
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: 1024, isHalfWindow: false)
    private var mono = [Float](repeating: 0, count: 1024)
    private var filled = 0
    private var real = [Float](repeating: 0, count: 512), imag = [Float](repeating: 0, count: 512)
    private var power = [Float](repeating: 0, count: 512)
    private var bandBins: [Range<Int>] = []
    private var interleaved = true

    /// Everything measured since the last call (then starts over).
    func read() -> Snapshot {
        pending.withLock { state in
            let s = state
            state = Snapshot()
            return s
        }
    }

    // MARK: Starting and stopping (main thread)

    @discardableResult
    func start() -> Bool {
        let musicPid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first?.processIdentifier
        // Music quit and came back: the tap still points at the old process and hears nothing.
        if running, musicPid == tappedPid { return true }
        if running { stop() }
        watchOutputDevice()
        if let failedAt, Date().timeIntervalSince(failedAt) < 60 { return false } // don't retry (or re-prompt) constantly
        // Without the permission a tap is still created, but it only ever hears silence. So ask
        // first (macOS shows its prompt once), and don't build a tap that can't hear anything.
        switch AudioPermission.status {
        case .denied:
            problem = "not allowed to hear Music (System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording ▸ System Audio Recording Only)"
            failedAt = Date()
            return false
        case .unknown:
            problem = "asking for permission to hear Music"
            failedAt = Date()
            AudioPermission.request { granted in
                Log.write(granted ? "levels: allowed to hear Music" : "levels: not allowed to hear Music; the gear animates by itself")
                if granted { self.failedAt = nil; self.onPermission?() }
            }
            return false
        case .authorized:
            break
        }
        guard let pid = musicPid else { problem = "Music isn't running"; return false }

        // Music's audio process object; if macOS won't say, listen to everything (still mostly Music).
        var process = AudioObjectID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pidValue = pid
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let found = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                               UInt32(MemoryLayout<pid_t>.size), &pidValue, &size, &process) == noErr
            && process != kAudioObjectUnknown
        let description = found ? CATapDescription(stereoMixdownOfProcesses: [process])
                                : CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Himawari levels"
        description.isPrivate = true
        description.muteBehavior = .unmuted // you still hear everything, of course
        var err = AudioHardwareCreateProcessTap(description, &tapID)
        guard err == noErr else { return fail("creating the tap (Music process found: \(found))", err) }

        var format = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        address.mSelector = kAudioTapPropertyFormat
        err = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard err == noErr, format.mSampleRate > 0 else { return fail("reading the tap's format", err) }
        interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let binHz = format.mSampleRate / Double(n)
        bandBins = Self.centers.map { center in
            let lo = max(1, Int((center / 2.squareRoot() / binHz).rounded(.down)))
            let hi = min(n / 2, max(lo + 1, Int((center * 2.squareRoot() / binHz).rounded(.up))))
            return lo..<hi
        }

        guard let output = Self.defaultOutputUID() else { return fail("finding the output device", 0) }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Himawari Levels",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        err = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard err == noErr else { return fail("creating the aggregate device", err) }
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            self?.process(input)
        }
        guard status == noErr else { return fail("creating the I/O proc", status) }
        err = AudioDeviceStart(aggregateID, procID)
        guard err == noErr else { return fail("starting the device", err) }
        problem = "format \(format.mSampleRate) Hz, \(format.mChannelsPerFrame) ch, interleaved \(interleaved)"
        running = true
        tappedPid = pid
        startedAt = CACurrentMediaTime()
        failedAt = nil
        return true
    }

    /// Running and actually hearing Music (a few seconds' grace after starting, and across quiet
    /// moments in a song). Silence for longer means the meters should animate by themselves.
    var hearing: Bool {
        guard running else { return false }
        let now = CACurrentMediaTime()
        return now - startedAt < 4 || now - lastHeard.withLock { $0 } < 4
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        running = false
    }

    /// AirPods connected, speakers changed: rebuild the tap on the new output, or the meters freeze.
    private func watchOutputDevice() {
        guard !watchingOutput else { return }
        watchingOutput = true
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main) { [weak self] _, _ in
            guard let self, self.running else { return } // (delivered on the main queue)
            self.stop()
            self.failedAt = nil
            self.start()
        }
    }

    private func fail(_ step: String, _ status: OSStatus) -> Bool {
        problem = "failed at \(step): OSStatus \(status)"
        stop()
        failedAt = Date()
        return false
    }

    private static func defaultOutputUID() -> String? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    // MARK: Measuring (audio queue)

    private func process(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, let base = first.mData?.assumingMemoryBound(to: Float.self) else { return }
        var sumL: Float = 0, sumR: Float = 0
        var frames = 0
        if interleaved {
            let channels = max(Int(first.mNumberChannels), 1)
            frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
            for f in 0..<frames {
                let l = base[f * channels], r = channels > 1 ? base[f * channels + 1] : l
                sumL += l * l; sumR += r * r
                push((l + r) / 2)
            }
        } else {
            frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) ?? base : base
            for f in 0..<frames {
                let l = base[f], r = right[f]
                sumL += l * l; sumR += r * r
                push((l + r) / 2)
            }
        }
        guard frames > 0 else { return }
        let l = (sumL / Float(frames)).squareRoot(), r = (sumR / Float(frames)).squareRoot()
        if max(l, r) > 1e-5 { lastHeard.withLock { $0 = CACurrentMediaTime() } }
        pending.withLock { state in
            state.left = max(state.left, l)
            state.right = max(state.right, r)
        }
    }

    private func push(_ sample: Float) {
        mono[filled] = sample
        filled += 1
        if filled == n {
            filled = 0
            analyze()
        }
    }

    private func analyze() {
        guard let fft else { return }
        vDSP.multiply(mono, window, result: &mono)
        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                mono.withUnsafeBufferPointer { samples in
                    samples.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                fft.forward(input: split, output: &split)
                vDSP.squareMagnitudes(split, result: &power)
            }
        }
        // A full-scale sine lands near 10·log10((n/2)²) ≈ 54 dB here: that's 0 dBFS.
        var bands = [Float](repeating: 0, count: Self.bandCount)
        for (i, bins) in bandBins.enumerated() {
            var sum: Float = 0
            for k in bins { sum += power[k] }
            let db = 10 * log10(sum / Float(bins.count) + 1e-12) - 54 + Float(i) * 2.2 // tilt: music is quieter up high
            bands[i] = min(max((db + 70) / 60, 0), 1) // −70…−10 dBFS → 0…1
        }
        let measured = bands
        pending.withLock { state in
            for i in 0..<Self.bandCount { state.bands[i] = max(state.bands[i], measured[i]) }
        }
    }
}
