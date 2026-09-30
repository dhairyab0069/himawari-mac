import AppKit
import AVFoundation

/// Moving Lock Screen: your wallpaper video, moving, on the lock screen and as the screen saver.
///
/// Apps can't draw on the lock screen, but since macOS Sonoma the Aerial wallpaper you pick in
/// System Settings keeps moving there, and macOS keeps those videos in your own Library. So:
/// the Aerials you've picked (read, never changed, from macOS's wallpaper settings) get their
/// video file swapped for yours, converted to exactly what macOS's Aerial player expects
/// (4K HEVC, 10-bit, 240 fps, each Aerial's own length). Apple's originals are kept and put
/// back when this is turned off. If macOS restores one, it's swapped again.
///
/// Converting is slow (the 240 fps are for macOS's player, which counts frames that way):
/// roughly real time × 5 on Apple silicon, once per video, in the background.
@MainActor
final class MovingLockScreen {
    static let shared = MovingLockScreen()

    private let fm = FileManager.default
    private let aerials = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/com.apple.wallpaper")
    private let home = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Himawari")
    private var videos: URL { aerials.appending(path: "aerials/videos") }
    private var originals: URL { home.appending(path: "Aerial Originals") }
    private var master: URL { home.appending(path: "Moving Lock Screen.mov") }
    private let stateKey = "movingLockScreenState" // { video, applied: [assetID: bytes] }

    /// "" when idle; "Preparing… 42%" while converting (for the menu).
    private(set) var status = ""
    var onStatus: (() -> Void)?
    private var job: Task<Void, Never>?

    // MARK: - On / off

    /// Makes `video` the lock screen's and screen saver's Aerial. Returns a problem to show, if any.
    func apply(video: URL) -> String? {
        let ids = pickedAerialIDs()
        guard !ids.isEmpty else {
            return "Pick an Aerial first: System Settings ▸ Wallpaper, then any video under Landscape, Cityscape, Underwater or Earth (one with no download arrow). Then turn this on again."
        }
        job?.cancel()
        let state = savedState()
        if state.video == video.path, !state.applied.isEmpty, Set(state.applied.keys).isSuperset(of: ids) {
            repair() // already made for this video: just make sure it's still in place
            return nil
        }
        job = Task { await self.convertAndSwap(video: video, targets: await self.aerials(ids)) }
        return nil
    }

    /// Puts Apple's originals back and deletes our copies.
    func restore() {
        job?.cancel()
        job = nil
        for file in (try? fm.contentsOfDirectory(at: originals, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "mov" {
            let target = videos.appending(path: file.lastPathComponent)
            try? fm.removeItem(at: target)
            try? fm.moveItem(at: file, to: target)
        }
        try? fm.removeItem(at: master)
        UserDefaults.standard.removeObject(forKey: stateKey)
        setStatus("")
        Log.write("moving lock screen: Apple's Aerials restored")
    }

    /// macOS sometimes re-downloads an Aerial: put ours back (from the master copy) if so.
    func repair() {
        let state = savedState()
        for (id, bytes) in state.applied {
            let file = videos.appending(path: "\(id).mov")
            let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int ?? -1
            guard size != bytes else { continue }
            guard fm.fileExists(atPath: master.path) else {
                // No master (made by hand before this feature): convert again.
                job = Task { await self.convertAndSwap(video: URL(fileURLWithPath: state.video), targets: await self.aerials(self.pickedAerialIDs())) }
                return
            }
            Log.write("moving lock screen: macOS restored \(id), swapping it again")
            Task { await self.swap(into: id, seconds: await self.duration(ofOriginal: id)) }
        }
    }

    // MARK: - Which Aerials

    struct Aerial { let id: String; let seconds: Double }

    /// The Aerials chosen in System Settings (as wallpaper or screen saver) that are downloaded.
    func pickedAerialIDs() -> [String] {
        guard let data = try? Data(contentsOf: aerials.appending(path: "Store/Index.plist")),
              let store = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return [] }
        var ids = Set<String>()
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                if dict["Provider"] as? String == "com.apple.wallpaper.choice.aerials",
                   let config = dict["Configuration"] as? Data,
                   let inner = try? PropertyListSerialization.propertyList(from: config, format: nil) as? [String: Any],
                   let id = inner["assetID"] as? String {
                    ids.insert(id)
                }
                dict.values.forEach(walk)
            } else if let array = node as? [Any] {
                array.forEach(walk)
            }
        }
        walk(store)
        return ids.sorted().filter { id in
            fm.fileExists(atPath: videos.appending(path: "\(id).mov").path)
                || fm.fileExists(atPath: originals.appending(path: "\(id).mov").path)
        }
    }

    private func aerials(_ ids: [String]) async -> [Aerial] {
        var out: [Aerial] = []
        for id in ids {
            let seconds = await duration(ofOriginal: id)
            if seconds > 0 { out.append(Aerial(id: id, seconds: seconds)) }
        }
        return out
    }

    /// The length of Apple's video for this Aerial (from our backup if it's already swapped).
    private func duration(ofOriginal id: String) async -> Double {
        let backup = originals.appending(path: "\(id).mov"), current = videos.appending(path: "\(id).mov")
        let file = fm.fileExists(atPath: backup.path) ? backup : current
        guard fm.fileExists(atPath: file.path) else { return 0 }
        return (try? await AVURLAsset(url: file).load(.duration)).map(CMTimeGetSeconds) ?? 0
    }

    // MARK: - Converting

    private func convertAndSwap(video: URL, targets: [Aerial]) async {
        let longest = targets.map(\.seconds).max() ?? 0
        guard longest > 0 else { return }
        Log.write("moving lock screen: converting \(video.lastPathComponent) for \(targets.count) Aerial(s), \(Int(longest)) s")
        try? fm.createDirectory(at: originals, withIntermediateDirectories: true)
        do {
            try await AerialEncoder.encode(video, to: master, seconds: longest) { [weak self] fraction in
                Task { @MainActor in self?.setStatus("Preparing… \(Int(fraction * 100))%") }
            }
        } catch {
            if !Task.isCancelled { Log.write("moving lock screen: converting failed: \(error.localizedDescription)") }
            setStatus("")
            return
        }
        var applied: [String: Int] = [:]
        for target in targets {
            if let bytes = await swap(into: target.id, seconds: target.seconds) { applied[target.id] = bytes }
        }
        saveState(video: video.path, applied: applied)
        setStatus("")
        Log.write("moving lock screen: on for \(applied.count) Aerial(s)")
    }

    /// Trims the master to this Aerial's length (no re-encoding) and swaps it in, keeping Apple's original.
    @discardableResult
    private func swap(into id: String, seconds: Double) async -> Int? {
        let target = videos.appending(path: "\(id).mov"), backup = originals.appending(path: "\(id).mov")
        let trimmed = home.appending(path: "\(id).trim.mov")
        try? fm.removeItem(at: trimmed)
        guard let export = AVAssetExportSession(asset: AVURLAsset(url: master), presetName: AVAssetExportPresetPassthrough) else { return nil }
        export.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 600))
        do { try await export.export(to: trimmed, as: .mov) } catch {
            Log.write("moving lock screen: trimming for \(id) failed: \(error.localizedDescription)")
            return nil
        }
        if !fm.fileExists(atPath: backup.path), fm.fileExists(atPath: target.path) {
            try? fm.moveItem(at: target, to: backup) // Apple's original, kept
        }
        try? fm.removeItem(at: target)
        guard (try? fm.moveItem(at: trimmed, to: target)) != nil else { return nil }
        return (try? fm.attributesOfItem(atPath: target.path))?[.size] as? Int
    }

    // MARK: - State

    private func savedState() -> (video: String, applied: [String: Int]) {
        let d = UserDefaults.standard.dictionary(forKey: stateKey) ?? [:]
        return (d["video"] as? String ?? "", d["applied"] as? [String: Int] ?? [:])
    }

    private func saveState(video: String, applied: [String: Int]) {
        UserDefaults.standard.set(["video": video, "applied": applied], forKey: stateKey)
    }

    /// For a swap made by hand before this existed: remember it as ours.
    func adopt(video: URL) {
        guard savedState().applied.isEmpty else { return }
        var applied: [String: Int] = [:]
        for file in (try? fm.contentsOfDirectory(at: originals, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "mov" {
            let id = file.deletingPathExtension().lastPathComponent
            if let bytes = (try? fm.attributesOfItem(atPath: videos.appending(path: "\(id).mov").path))?[.size] as? Int {
                applied[id] = bytes
            }
        }
        if !applied.isEmpty { saveState(video: video.path, applied: applied) }
    }

    private func setStatus(_ text: String) {
        guard text != status else { return }
        status = text
        onStatus?()
    }
}

/// Converts a video into what macOS's Aerial player expects: 3840×2160 (filled, centered),
/// HEVC Main 10, 240 fps (each source frame repeated as needed, which HEVC stores cheaply),
/// looped to `seconds`, no audio. Apple's hardware encoder does the work.
enum AerialEncoder {
    static let fps: Int32 = 240
    static let size = CGSize(width: 3840, height: 2160)

    enum Failure: LocalizedError {
        case noVideo, cannotWrite(String)
        var errorDescription: String? {
            switch self {
            case .noVideo: "the file has no video track"
            case .cannotWrite(let why): why
            }
        }
    }

    /// Scales and places the whole video with `transform`, into a 3840×2160 frame.
    /// macOS 26 replaced the mutable composition classes with value "Configurations";
    /// older systems (Himawari runs back to 14.4) only have the mutable ones.
    private static func fillComposition(track: AVAssetTrack, transform: CGAffineTransform,
                                        frame: CMTime, range: CMTimeRange) -> AVVideoComposition {
        if #available(macOS 26.0, *) {
            var layer = AVVideoCompositionLayerInstruction.Configuration(assetTrack: track)
            layer.setTransform(transform, at: .zero)
            let instruction = AVVideoCompositionInstruction(configuration: .init(
                layerInstructions: [AVVideoCompositionLayerInstruction(configuration: layer)], timeRange: range))
            return AVVideoComposition(configuration: .init(frameDuration: frame, instructions: [instruction], renderSize: size))
        }
        let composition = AVMutableVideoComposition()
        composition.renderSize = size
        composition.frameDuration = frame
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = range
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(transform, at: .zero)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]
        return composition
    }

    static func encode(_ source: URL, to output: URL, seconds: Double, progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let sourceSeconds = try await asset.load(.duration).seconds
        let nominal = try await track.load(.nominalFrameRate)
        let frameSeconds = 1 / Double(nominal > 0 ? nominal : 30)

        // Aspect-fill into 3840×2160.
        let turned = natural.applying(transform)
        let w = abs(turned.width), h = abs(turned.height)
        let scale = max(size.width / w, size.height / h)
        let fill = transform
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: (size.width - w * scale) / 2, y: (size.height - h * scale) / 2))

        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000,
                                              AVVideoProfileLevelKey: "HEVC_Main10_AutoLevel",
                                              AVVideoExpectedSourceFrameRateKey: Int(fps)],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height)])
        guard writer.canAdd(input) else { throw Failure.cannotWrite("the encoder refused the settings") }
        writer.add(input)
        guard writer.startWriting() else { throw Failure.cannotWrite(writer.error?.localizedDescription ?? "couldn't start writing") }
        writer.startSession(atSourceTime: .zero)

        let total = Int(seconds * Double(fps))
        var written = 0, passStart = 0.0
        while written < total {
            try Task.checkCancellation()
            // One pass through the source, scaled by a video composition.
            let reader = try AVAssetReader(asset: asset)
            let composition = fillComposition(track: track, transform: fill,
                                              frame: CMTime(seconds: frameSeconds, preferredTimescale: 60_000),
                                              range: CMTimeRange(start: .zero, duration: CMTime(seconds: sourceSeconds, preferredTimescale: 600)))
            let out = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            out.videoComposition = composition
            reader.add(out)
            guard reader.startReading() else { throw Failure.cannotWrite(reader.error?.localizedDescription ?? "couldn't read the video") }
            while written < total, let sample = out.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let frame = CMSampleBufferGetImageBuffer(sample) else { continue }
                let showsUntil = passStart + CMSampleBufferGetPresentationTimeStamp(sample).seconds + frameSeconds
                // Repeat this frame for every 1/240 s it's on screen.
                while written < total, Double(written) / Double(fps) < showsUntil {
                    while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
                    guard adaptor.append(frame, withPresentationTime: CMTime(value: CMTimeValue(written), timescale: fps)) else {
                        throw Failure.cannotWrite(writer.error?.localizedDescription ?? "the encoder stopped")
                    }
                    written += 1
                    if written % 480 == 0 { progress(Double(written) / Double(total)) }
                }
            }
            reader.cancelReading()
            passStart += sourceSeconds
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw Failure.cannotWrite(writer.error?.localizedDescription ?? "finishing failed") }
        progress(1)
    }
}
