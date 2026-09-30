import AppKit

/// Everything the user can change, shared by Himawari and its desktop clock (and, if it's
/// installed, the separate Desktop Shell, which uses the same domain).
///
/// All of them read and write one preferences domain. After a change, call
/// `Settings.broadcastChange()`; every process listening with
/// `Settings.onChange` then re-reads and re-draws.
public final class Settings {
    public static let shared = Settings()
    public static let domain = "local.dhairyabhatia.desktop"
    private static let changed = Notification.Name("local.dhairyabhatia.desktop.changed")

    private let defaults: UserDefaults

    private init() {
        // The wallpaper app's own domain IS the shared one; the services open it as a suite.
        defaults = Bundle.main.bundleIdentifier == Self.domain ? .standard : UserDefaults(suiteName: Self.domain)!
        defaults.register(defaults: [
            "volume": 0.5,
            "muted": true,             // wallpapers are silent unless you ask
            "pauseOnBattery": true,
            "pauseWhenCovered": true,
            "userPaused": false,
            "showInDock": false,
            "showClock": true,
            "clockPosition": ClockPosition.topCenter.rawValue,
            "clock24h": false,
            "clockSeconds": false,
        ])
    }

    // MARK: - Telling the other processes

    /// Tell every Himawari process that settings or the layout changed.
    public static func broadcastChange() {
        DistributedNotificationCenter.default().postNotificationName(changed, object: nil, userInfo: nil,
                                                                    deliverImmediately: true)
    }

    /// Run `block` on the main thread whenever any Himawari process broadcasts a change
    /// (bursts are coalesced into one call).
    @MainActor
    public static func onChange(_ block: @escaping @MainActor () -> Void) {
        let debounce = Debounce()
        DistributedNotificationCenter.default().addObserver(forName: changed, object: nil, queue: .main) { _ in
            onMainActor {
                debounce.pending?.cancel()
                let work = DispatchWorkItem { onMainActor { block() } }
                debounce.pending = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            }
        }
    }

    // MARK: - Raw access (for values other processes write)

    public func string(_ key: String) -> String? {
        defaults.synchronize() // pick up what another process just wrote
        return defaults.string(forKey: key)
    }

    public func set(_ value: Any?, for key: String) { defaults.set(value, forKey: key) }

    public func stringArray(_ key: String) -> [String]? {
        defaults.synchronize()
        return defaults.stringArray(forKey: key)
    }

    public func counts(_ key: String) -> [String: Int] {
        defaults.synchronize()
        return defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
    }

    private func bool(_ key: String) -> Bool {
        defaults.synchronize()
        return defaults.bool(forKey: key)
    }

    // MARK: - Wallpaper

    public var videoPath: String? {
        get { defaults.string(forKey: "videoPath") }
        set { defaults.set(newValue, forKey: "videoPath") }
    }

    public var volume: Float {
        get { defaults.float(forKey: "volume") }
        set { defaults.set(newValue, forKey: "volume") }
    }

    public var muted: Bool {
        get { bool("muted") }
        set { defaults.set(newValue, forKey: "muted") }
    }

    public var pauseOnBattery: Bool {
        get { bool("pauseOnBattery") }
        set { defaults.set(newValue, forKey: "pauseOnBattery") }
    }

    public var pauseWhenCovered: Bool {
        get { bool("pauseWhenCovered") }
        set { defaults.set(newValue, forKey: "pauseWhenCovered") }
    }

    /// Paused by hand from the menu (as opposed to paused automatically).
    public var userPaused: Bool {
        get { bool("userPaused") }
        set { defaults.set(newValue, forKey: "userPaused") }
    }

    public var showInDock: Bool {
        get { bool("showInDock") }
        set { defaults.set(newValue, forKey: "showInDock") }
    }

    // MARK: - Clock service

    public var showClock: Bool {
        get { bool("showClock") }
        set { defaults.set(newValue, forKey: "showClock") }
    }

    public var clockPosition: ClockPosition {
        get { ClockPosition(rawValue: string("clockPosition") ?? "") ?? .topCenter }
        set { defaults.set(newValue.rawValue, forKey: "clockPosition") }
    }

    public var clock24h: Bool {
        get { bool("clock24h") }
        set {
            defaults.set(newValue, forKey: "clock24h")
            defaults.set((newValue ? ClockFormat.twentyFour : .twelve).rawValue, forKey: "clockFormat")
        }
    }

    /// How the desktop clock tells the time (left-click the clock to cycle through them).
    public var clockFormat: ClockFormat {
        get { ClockFormat(rawValue: string("clockFormat") ?? "") ?? (clock24h ? .twentyFour : .twelve) }
        set {
            defaults.set(newValue.rawValue, forKey: "clockFormat")
            if newValue == .twelve || newValue == .twentyFour { defaults.set(newValue == .twentyFour, forKey: "clock24h") }
        }
    }

    public var clockShowDate: Bool {
        get { defaults.object(forKey: "clockShowDate") == nil ? true : bool("clockShowDate") }
        set { defaults.set(newValue, forKey: "clockShowDate") }
    }

    public var clockSize: ClockSize {
        get { ClockSize(rawValue: string("clockSize") ?? "") ?? .medium }
        set { defaults.set(newValue.rawValue, forKey: "clockSize") }
    }

    public var clockStyle: ClockStyle {
        get { ClockStyle(rawValue: string("clockStyle") ?? "") ?? .aero }
        set { defaults.set(newValue.rawValue, forKey: "clockStyle") }
    }

    public var clockSeconds: Bool {
        get { bool("clockSeconds") }
        set { defaults.set(newValue, forKey: "clockSeconds") }
    }

}

/// Holds the pending coalesced callback. Only ever touched on the main thread.
private final class Debounce: @unchecked Sendable {
    var pending: DispatchWorkItem?
}

public enum ClockFormat: String, CaseIterable {
    case twelve = "12-Hour"
    case twentyFour = "24-Hour"
    case beats = "Swatch Internet Time"   // @000–@999, the same everywhere on Earth (1998)
    case decimal = "French Decimal Time"  // 10 hours a day, 100 minutes an hour (1793)
    case words = "In Words"               // "twenty past five"

    public var next: ClockFormat {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

public enum ClockSize: String, CaseIterable {
    case small = "Small", medium = "Medium", large = "Large"
    public var scale: CGFloat { switch self { case .small: 0.65; case .medium: 1; case .large: 1.35 } }
}

public enum ClockStyle: String, CaseIterable {
    case aero = "Aero Glass", vfd = "Fluorescent Display", rounded = "Rounded", serif = "Serif"
}

public enum ClockPosition: String, CaseIterable {
    case topLeft = "Top Left", topCenter = "Top Center", topRight = "Top Right"
    case center = "Center", bottomLeft = "Bottom Left", bottomRight = "Bottom Right"
}
