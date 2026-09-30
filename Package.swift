// swift-tools-version:5.10
import PackageDescription

// Himawari: the live-wallpaper app (video, music wallpaper, side gear, CD) and its desktop
// clock, a small helper app it starts and stops. HimawariKit is the code they share.
// (The XP taskbar, desktop folders, widgets and hotkeys are now their own project, Desktop Shell.)
let package = Package(
    name: "Himawari",
    platforms: [.macOS("14.4")],
    targets: [
        .target(name: "HimawariKit", path: "Sources/HimawariKit"),
        .executableTarget(name: "Himawari", dependencies: ["HimawariKit"], path: "Sources/Himawari"),
        .executableTarget(name: "HimawariClock", dependencies: ["HimawariKit"], path: "Sources/HimawariClock"),
    ]
)
