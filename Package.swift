// swift-tools-version:5.10
import PackageDescription

// Himawari = ONLY the live-wallpaper app (video + its menu-bar controls).
// The desktop features are separate apps ("Desktop Shell") that run as background
// services, like parts of an OS. Quitting Himawari doesn't touch them:
//   HimawariFolders  iOS-style folders on the desktop
//   HimawariClock    the desktop clock
//   HimawariTaskbar  the Windows XP taskbar + Start menu (replaces the Dock), ⌃T → Ghostty,
//                  the Desktop Settings menu, and the window tiler that keeps apps clear
//   HimawariWidgets  the floating widget panel (calendar, battery, CPU/memory, storage)
// HimawariKit is the code they share (look, desktop windows, settings, tiling map).
let package = Package(
    name: "Himawari",
    platforms: [.macOS("14.4")],
    targets: [
        .target(name: "HimawariKit", path: "Sources/HimawariKit"),
        .executableTarget(name: "Himawari", dependencies: ["HimawariKit"], path: "Sources/Himawari"), // shares code, runs on its own
        .executableTarget(name: "HimawariFolders", dependencies: ["HimawariKit"], path: "Sources/HimawariFolders"),
        .executableTarget(name: "HimawariClock", dependencies: ["HimawariKit"], path: "Sources/HimawariClock"),
        .executableTarget(name: "HimawariTaskbar", dependencies: ["HimawariKit"], path: "Sources/HimawariTaskbar"),
        .executableTarget(name: "HimawariWidgets", dependencies: ["HimawariKit"], path: "Sources/HimawariWidgets"),
        .executableTarget(name: "HimawariHotkeys", dependencies: ["HimawariKit"], path: "Sources/HimawariHotkeys"),
    ]
)
