import AppKit

/// "Delete" everywhere in the Desktop Shell = move to the Trash, after an
/// XP-style "Are you sure?" (so it's always recoverable: Trash ▸ Put Back).
@MainActor
public enum Trash {
    /// Built-in macOS apps and system files can't be deleted.
    public static func canDelete(_ url: URL) -> Bool {
        !url.path.hasPrefix("/System/") && FileManager.default.isDeletableFile(atPath: url.path)
    }

    /// Asks, then moves `url` to the Trash. Returns true if it was moved.
    @discardableResult
    public static func confirmAndMove(_ url: URL, after: @escaping @MainActor () -> Void = {}) -> Bool {
        let name = FileManager.default.displayName(atPath: url.path)
        let isApp = url.pathExtension == "app"
        let alert = NSAlert()
        alert.messageText = "Are you sure you want to send “\(name)” to the Trash?"
        alert.informativeText = isApp
            ? "This uninstalls \(name). You can put it back from the Trash."
            : "You can put it back from the Trash."
        alert.icon = NSWorkspace.shared.icon(forFile: url.path)
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate() // background services: bring the question to the front
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        NSWorkspace.shared.recycle([url]) { _, error in
            DispatchQueue.main.async {
                onMainActor {
                    if let error { NSAlert(error: error).runModal() } else { after() }
                }
            }
        }
        return true
    }
}
