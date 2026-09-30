import AppKit
import IOKit.ps

/// Battery Saver: on while the Mac runs on battery or Low Power Mode is on.
/// Everything that costs power (live blur over the moving wallpaper, 2160p
/// streams, YouTube web players, frequent checks) asks `PowerState.saving`
/// and scales down, and reacts when it changes.
@MainActor
public enum PowerState {
    public private(set) static var onBattery = checkBattery()
    public static var lowPowerMode: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }
    public static var saving: Bool { onBattery || lowPowerMode }

    private static var observers: [@MainActor () -> Void] = []
    private static var watching = false

    /// Called whenever Battery Saver turns on or off.
    public static func onChange(_ block: @escaping @MainActor () -> Void) {
        observers.append(block)
        guard !watching else { return }
        watching = true
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            onMainActor { fire() }
        }
        // Plugging in / unplugging: a cheap check every 20 s is plenty.
        Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            onMainActor {
                let now = checkBattery()
                if now != onBattery { onBattery = now; fire() }
            }
        }
    }

    private static var lastSaving: Bool?
    private static func fire() {
        guard saving != lastSaving else { return }
        lastSaving = saving
        observers.forEach { $0() }
    }

    private static func checkBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (source as String) == kIOPMBatteryPowerKey
    }
}
