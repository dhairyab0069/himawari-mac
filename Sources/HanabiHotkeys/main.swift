import AppKit
import Carbon.HIToolbox
import HanabiKit

/// Background service "Desktop Hotkeys": system-wide keyboard shortcuts that
/// work in every app, on the desktop and in every Space, on their own (they
/// don't depend on the taskbar or anything else running).
///
///   ⌘⌃T         a new Ghostty terminal right where you are (like Ubuntu's Ctrl+Alt+T)
///   tap ⌥ Option  open the Start menu (like the Windows key)
///
/// Started at login by launchd, restarted if it ever crashes.
@MainActor
final class HotkeyService {
    private var ghostty: HotKey?
    private var optionTap: OptionTap?
    private var askedForAccess = false

    init() {
        refresh()
        Settings.onChange { [weak self] in self?.refresh() }
    }

    func refresh() {
        let s = Settings.shared
        if s.ghosttyHotkey, ghostty == nil {
            ghostty = HotKey(keyCode: kVK_ANSI_T, modifiers: cmdKey | controlKey, id: 1) { Ghostty.newWindow() }
            log(ghostty == nil ? "⌘⌃T could not be registered: another app already uses it" : "⌘⌃T registered → Ghostty")
        } else if !s.ghosttyHotkey, let key = ghostty {
            key.unregister()
            ghostty = nil
            log("⌘⌃T turned off")
        }

        if s.optionOpensStart, optionTap == nil {
            optionTap = OptionTap { Settings.requestStartMenu() }
            log("⌥ tap → Start menu" + (AXIsProcessTrusted() ? "" : " (waiting for Accessibility access)"))
        } else if !s.optionOpensStart, optionTap != nil {
            optionTap = nil
            log("⌥ tap turned off")
        }

        // Watching ⌥ system-wide, and opening Ghostty's Quick Terminal over full-screen
        // apps, both need Accessibility access. Ask once.
        if !AXIsProcessTrusted(), !askedForAccess {
            askedForAccess = true
            let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        }
    }

    private func log(_ message: String) {
        print(message) // → ~/Library/Logs/Desktop Shell/hotkeys.log
        fflush(stdout)
    }
}

/// Detects a *tap* of ⌥ Option on its own: pressed and released within half a
/// second, with no other key, click or scroll in between. So ⌥-shortcuts,
/// ⌥-clicks and holding ⌥ keep working exactly as before.
@MainActor
final class OptionTap {
    private var monitors: [Any] = []
    private var pressedAt: Date?
    private var interrupted = false

    init(action: @escaping @MainActor () -> Void) {
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            onMainActor { [weak self] in
                guard let self else { return }
                if flags == .option {                       // ⌥ went down, alone
                    self.pressedAt = Date()
                    self.interrupted = false
                } else if flags.isEmpty, let pressed = self.pressedAt {   // released
                    if !self.interrupted, Date().timeIntervalSince(pressed) < 0.5 { action() }
                    self.pressedAt = nil
                } else {                                    // ⌥ together with ⌘/⌃/⇧: not a tap
                    self.pressedAt = nil
                }
            }
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel],
                                                     handler: { _ in
            onMainActor { [weak self] in self?.interrupted = true } // ⌥ was used as a modifier
        }) { monitors.append(m) }
    }

    deinit {
        for m in monitors { NSEvent.removeMonitor(m) }
    }
}

runBackgroundService { HotkeyService() }
