import AppKit

/// The tiling map of the main screen, shared by every Hanabi process: which
/// strips are reserved (widgets, folders, taskbar), and what's left over for
/// app windows and the clock.
///
/// Each part publishes its own strip with `setZone`; everyone else reads
/// them with `freeArea`. Zones live in the shared preferences, so they work
/// across processes, and a change is broadcast so the others re-tile.
@MainActor
public enum DesktopLayout {
    public enum Zone: String, CaseIterable {
        case widgets, folders, taskbar
    }

    public static let gap: CGFloat = 8

    /// Publish (or clear, with nil) a reserved strip, in AppKit screen coordinates.
    public static func setZone(_ zone: Zone, _ rect: NSRect?) {
        let key = "zone." + zone.rawValue
        let value = rect.map { NSStringFromRect($0.integral) }
        guard Settings.shared.string(key) != value else { return } // unchanged: don't start a re-tile loop
        Settings.shared.set(value, for: key)
        Settings.broadcastChange()
    }

    public static func zone(_ zone: Zone) -> NSRect? {
        Settings.shared.string("zone." + zone.rawValue).map { NSRectFromString($0) }
    }

    /// The main screen's usable area (minus menu bar) minus every reserved strip except `excluding`.
    public static func freeArea(of screen: NSScreen, excluding: Set<Zone> = []) -> NSRect {
        var area = screen.visibleFrame
        for z in Zone.allCases where !excluding.contains(z) {
            if let rect = zone(z) { area = cut(rect, from: area) }
        }
        return area
    }

    /// Remove an edge-attached zone from `area` by trimming whichever side
    /// loses the least space while fully clearing the zone (plus a gap).
    private static func cut(_ zone: NSRect, from area: NSRect) -> NSRect {
        guard area.intersects(zone) else { return area }
        let trimLeft = zone.maxX + gap - area.minX
        let trimRight = area.maxX - (zone.minX - gap)
        let trimBottom = zone.maxY + gap - area.minY
        let trimTop = area.maxY - (zone.minY - gap)
        let options: [(lost: CGFloat, result: NSRect)] = [
            (trimLeft * area.height, NSRect(x: area.minX + trimLeft, y: area.minY, width: area.width - trimLeft, height: area.height)),
            (trimRight * area.height, NSRect(x: area.minX, y: area.minY, width: area.width - trimRight, height: area.height)),
            (trimBottom * area.width, NSRect(x: area.minX, y: area.minY + trimBottom, width: area.width, height: area.height - trimBottom)),
            (trimTop * area.width, NSRect(x: area.minX, y: area.minY, width: area.width, height: area.height - trimTop)),
        ]
        return options.filter { $0.result.width > 0 && $0.result.height > 0 }.min { $0.lost < $1.lost }?.result ?? area
    }

    /// AppKit (bottom-left origin) → CoreGraphics / Accessibility (top-left origin of the main display).
    public static func toTopLeft(_ rect: NSRect) -> CGRect {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}
