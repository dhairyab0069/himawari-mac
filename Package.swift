// swift-tools-version:5.10
import PackageDescription

// Hanabi = ONLY the live-wallpaper app (video + its menu-bar controls).
// The desktop features are separate apps ("Desktop Shell") that run as background
// services, like parts of an OS. Quitting Hanabi doesn't touch them:
//   HanabiFolders  iOS-style folders on the desktop
//   HanabiClock    the desktop clock
//   HanabiTaskbar  the Windows XP taskbar + Start menu (replaces the Dock), ⌃T → Ghostty,
//                  the Desktop Settings menu, and the window tiler that keeps apps clear
//   HanabiWidgets  the floating widget panel (calendar, battery, CPU/memory, storage)
// HanabiKit is the code they share (look, desktop windows, settings, tiling map).
let package = Package(
    name: "Hanabi",
    platforms: [.macOS("14.4")],
    targets: [
        .target(name: "HanabiKit", path: "Sources/HanabiKit"),
        .executableTarget(name: "Hanabi", dependencies: ["HanabiKit"], path: "Sources/Hanabi"), // shares code, runs on its own
        .executableTarget(name: "HanabiFolders", dependencies: ["HanabiKit"], path: "Sources/HanabiFolders"),
        .executableTarget(name: "HanabiClock", dependencies: ["HanabiKit"], path: "Sources/HanabiClock"),
        .executableTarget(name: "HanabiTaskbar", dependencies: ["HanabiKit"], path: "Sources/HanabiTaskbar"),
        .executableTarget(name: "HanabiWidgets", dependencies: ["HanabiKit"], path: "Sources/HanabiWidgets"),
        .executableTarget(name: "HanabiHotkeys", dependencies: ["HanabiKit"], path: "Sources/HanabiHotkeys"),
    ]
)
