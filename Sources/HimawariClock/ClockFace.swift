import AppKit
import HimawariKit
import SwiftUI

/// What the clock shows, for each way of telling the time.
enum ClockFace {
    /// (the time, a smaller suffix like " AM", a caption to use instead of the date).
    static func parts(_ date: Date, format: ClockFormat, seconds: Bool) -> (main: String, small: String, caption: String?) {
        switch format {
        case .twelve, .twentyFour:
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = (format == .twentyFour ? "HH:mm" : "h:mm") + (seconds ? ":ss" : "")
            let time = f.string(from: date)
            guard format == .twelve else { return (time, "", nil) }
            f.dateFormat = " a"
            return (time, f.string(from: date), nil)

        case .beats:
            // Swatch Internet Time: 1000 ".beats" a day, counted from midnight in Biel (UTC+1,
            // no daylight saving), so it's the same moment everywhere.
            let s = (date.timeIntervalSince1970 + 3600).truncatingRemainder(dividingBy: 86400)
            let beats = s / 86.4
            let main = seconds ? String(format: "@%06.2f", beats) : String(format: "@%03d", Int(beats))
            return (main, "", "Swatch Internet Time · .beats")

        case .decimal:
            // French Republican decimal time (1793): 10 hours a day, 100 minutes an hour,
            // 100 seconds a minute. A decimal second is 0.864 real seconds.
            let midnight = Calendar.current.startOfDay(for: date)
            let ds = Int(date.timeIntervalSince(midnight) / 0.864)
            let h = ds / 10000, m = (ds / 100) % 100, sec = ds % 100
            let main = seconds ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", h, m)
            return (main, "", "Decimal Time · " + date.formatted(.dateTime.weekday(.wide).day().month(.wide)))

        case .words:
            return (words(date), "", nil)
        }
    }

    /// When the display changes: (a moment it changed, how often).
    static func ticks(format: ClockFormat, seconds: Bool) -> (anchor: Date, step: TimeInterval) {
        switch format {
        case .twelve, .twentyFour: return (Date(timeIntervalSince1970: 0), seconds ? 1 : 60)
        case .beats: return (Date(timeIntervalSince1970: -3600), seconds ? 0.864 : 86.4)   // Biel midnight
        case .decimal: return (Calendar.current.startOfDay(for: Date()), seconds ? 0.864 : 86.4)
        case .words: return (Date(timeIntervalSince1970: 0), 60)
        }
    }

    /// "twenty past five", "quarter to six", "noon": the nearest five minutes.
    static func words(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        var hour = c.hour ?? 0
        let rounded = Int((Double(c.minute ?? 0) / 5).rounded()) * 5
        let phrases = [0: "", 5: "five past", 10: "ten past", 15: "quarter past", 20: "twenty past",
                       25: "twenty-five past", 30: "half past", 35: "twenty-five to", 40: "twenty to",
                       45: "quarter to", 50: "ten to", 55: "five to", 60: ""]
        if rounded > 30 { hour += 1 }
        hour %= 24
        let names = ["twelve", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven"]
        let exact = rounded == 0 || rounded == 60
        if exact && hour == 0 { return "midnight" }
        if exact && hour == 12 { return "noon" }
        let name = names[hour % 12]
        return exact ? "\(name) o'clock" : "\(phrases[rounded]!) \(name)"
    }
}

/// The clock's heartbeat: fires exactly when the displayed time changes (each second, minute,
/// or 0.864 s decimal second / centibeat), counted from `anchor`, re-aimed at the next boundary
/// every time so it never drifts. A strict timer with 2 ms leeway, and no App Nap while
/// seconds show: macOS would otherwise let a background app's timer slip by up to a second.
@MainActor
final class ClockTicker: ObservableObject {
    @Published private(set) var now = Date()
    private var timer: DispatchSourceTimer?
    private var activity: NSObjectProtocol?
    private var anchor = Date(timeIntervalSince1970: 0)
    private var step: TimeInterval = 60

    func run(anchor: Date, step: TimeInterval) {
        self.anchor = anchor
        self.step = step
        if step < 60, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                              reason: "Desktop clock shows seconds")
        } else if step >= 60, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        now = Date()
        scheduleNext()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    private func scheduleNext() {
        timer?.cancel()
        let current = Date()
        let boundary = anchor.addingTimeInterval(((current.timeIntervalSince(anchor) / step).rounded(.down) + 1) * step)
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        t.schedule(deadline: .now() + boundary.timeIntervalSince(current), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in
            onMainActor {
                guard let self else { return }
                self.now = max(Date(), boundary) // woke a hair early: still show the new second
                self.scheduleNext()
            }
        }
        timer = t
        t.resume()
    }
}

/// Text whose digits all take the width of the widest one (like tabular figures, which the
/// Aero fonts don't have), so a clock's seconds never make the rest of the line shuffle.
struct FixedWidthDigits: View {
    let text: String
    let font: NSFont

    var body: some View {
        let digit = "0123456789".map { NSAttributedString(string: String($0), attributes: [.font: font]).size().width }.max() ?? 0
        HStack(spacing: 0) {
            ForEach(Array(text.enumerated()), id: \.offset) { _, character in
                Text(String(character))
                    .font(Font(font))
                    .frame(width: character.isNumber ? ceil(digit) : nil)
            }
        }
    }
}
