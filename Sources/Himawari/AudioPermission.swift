import Foundation
import HimawariKit

/// The "System Audio Recording Only" permission that Core Audio process taps need.
///
/// macOS has no public call to read or request it, and a tap made without it doesn't fail: it
/// delivers silence. Apple's own sample (and tools like AudioCap) use the TCC framework's
/// preflight / request calls for exactly this; they're looked up at run time, so if a future
/// macOS removes them Himawari just treats the permission as granted and lets the tap try.
enum AudioPermission {
    enum Status { case authorized, denied, unknown }

    private static let service = "kTCCServiceAudioCapture" as CFString
    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    private static let preflight: Preflight? = tcc.flatMap { dlsym($0, "TCCAccessPreflight") }.map { unsafeBitCast($0, to: Preflight.self) }
    private static let requestAccess: Request? = tcc.flatMap { dlsym($0, "TCCAccessRequest") }.map { unsafeBitCast($0, to: Request.self) }

    static var status: Status {
        guard let preflight else { return .authorized }
        switch preflight(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Shows macOS's prompt (once); `done` runs on the main thread.
    static func request(_ done: @escaping @MainActor (Bool) -> Void) {
        guard let requestAccess else { DispatchQueue.main.async { onMainActor { done(true) } }; return }
        let box = Done(done)
        requestAccess(service, nil) { granted in
            DispatchQueue.main.async { onMainActor { box.run(granted) } }
        }
    }

    private final class Done: @unchecked Sendable {
        let run: @MainActor (Bool) -> Void
        init(_ run: @escaping @MainActor (Bool) -> Void) { self.run = run }
    }
}
