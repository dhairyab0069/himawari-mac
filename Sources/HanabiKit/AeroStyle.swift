import AppKit
import SwiftUI

// The shared Frutiger Aero look: humanist font, white text with an aqua glow,
// and see-through glossy glass.

extension Color {
    public static let aeroGlow = Color(red: 0.35, green: 0.80, blue: 1.0)
    public static let aeroBlue = Color(red: 0.25, green: 0.65, blue: 1.0)
}

/// Frutiger if you have it installed, then the closest fonts macOS ships with.
public func aeroFont(size: CGFloat, weight: NSFont.Weight = .regular) -> Font {
    Font(aeroNSFont(size: size, weight: weight))
}

/// The same font, as an NSFont (for measuring text).
public func aeroNSFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
    let appKitWeight = weight == .light ? 4 : weight == .semibold ? 8 : 5 // NSFontManager's 0–15 scale
    for name in ["Frutiger", "Frutiger LT Std", "Segoe UI", "Myriad Pro", "Avenir Next"] {
        if let font = NSFontManager.shared.font(withFamily: name, traits: [], weight: appKitWeight, size: size) {
            return font
        }
    }
    return .systemFont(ofSize: size, weight: weight)
}

extension View {
    /// White text with a soft aqua glow and a faint shadow so it reads on any wallpaper.
    public func aeroText(opacity: Double = 0.92, glow: Double = 0.8) -> some View {
        self.foregroundStyle(.white.opacity(opacity))
            .shadow(color: .aeroGlow.opacity(glow), radius: 8)
            .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
    }
}

/// See-through Aero glass: a faint aqua tint, a gloss across the top half, a bright rim.
public struct AeroGlass: View {
    public var cornerRadius: CGFloat = 22
    public init(cornerRadius: CGFloat = 22) { self.cornerRadius = cornerRadius }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: [Color.aeroGlow.opacity(0.16), Color.aeroBlue.opacity(0.10)],
                                      startPoint: .top, endPoint: .bottom))
            shape.fill(LinearGradient(stops: [.init(color: .white.opacity(0.30), location: 0),
                                              .init(color: .white.opacity(0.06), location: 0.48),
                                              .init(color: .clear, location: 0.5)],
                                      startPoint: .top, endPoint: .bottom))
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.15)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 1)
        }
    }
}

/// A glossy aqua bar, 0…1.
public struct AeroBar: View {
    let value: Double
    public init(value: Double) { self.value = value }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15))
                Capsule()
                    .fill(LinearGradient(colors: [Color.aeroGlow, Color.aeroBlue], startPoint: .top, endPoint: .bottom))
                    .overlay(Capsule().fill(LinearGradient(colors: [.white.opacity(0.5), .clear],
                                                           startPoint: .top, endPoint: .center)))
                    .frame(width: max(8, geo.size.width * min(max(value, 0), 1)))
                    .shadow(color: .aeroGlow.opacity(0.6), radius: 4)
            }
        }
        .frame(height: 8)
    }
}
