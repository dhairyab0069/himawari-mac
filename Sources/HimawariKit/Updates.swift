import Foundation

/// A Himawari release, as GitHub lists it.
public struct Release: Equatable, Sendable {
    public var version: String      // "1.5.1"
    public var name: String         // "Himawari Beta 1.5.1"
    public var notes: String        // the release notes (Markdown)
    public var dmg: URL?            // the disk image to install from
    public var page: URL?           // the release's page

    /// Reads GitHub's "latest release" answer.
    public init?(json: [String: Any]) {
        guard let tag = json["tag_name"] as? String else { return nil }
        version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        name = json["name"] as? String ?? "Himawari \(version)"
        notes = json["body"] as? String ?? ""
        page = (json["html_url"] as? String).flatMap(URL.init(string:))
        let assets = json["assets"] as? [[String: Any]] ?? []
        dmg = assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(".dmg") == true }
            .flatMap { $0["browser_download_url"] as? String }.flatMap(URL.init(string:))
    }

    public init(version: String, name: String, notes: String, dmg: URL?, page: URL?) {
        (self.version, self.name, self.notes, self.dmg, self.page) = (version, name, notes, dmg, page)
    }

    /// Is version `a` newer than `b`? Numbers compared part by part ("1.4.5.1" < "1.5" < "1.5.1"),
    /// a missing part counting as 0.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    private static func parts(_ v: String) -> [Int] {
        let trimmed = v.hasPrefix("v") ? String(v.dropFirst()) : v
        return trimmed.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    /// The first paragraph or two of the notes, plain, for an alert.
    public var summary: String {
        let lines = notes.components(separatedBy: .newlines)
            .prefix { !$0.hasPrefix("## Install") }
            .map { $0.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "## ", with: "") }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 700 ? String(text.prefix(700)) + "…" : text
    }
}
