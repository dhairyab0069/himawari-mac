import AppKit

extension NSScreen {
    /// Height of the strip at the top taken by the menu bar and, on notched Macs, the camera
    /// housing: the wallpaper's video and scenes stay below it.
    public var menuBarStripHeight: CGFloat { max(safeAreaInsets.top, frame.maxY - visibleFrame.maxY) }
}
