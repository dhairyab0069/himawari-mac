import Foundation

/// Himawari's own log, ~/Library/Logs/Himawari.log: what it sized, what it's listening to,
/// what went wrong. Repeated lines are written once; past 1 MB the older half goes.
@MainActor
enum Log {
    private static var lastLine = ""
    static func write(_ line: String) {
        guard line != lastLine else { return }
        lastLine = line
        let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Himawari.log")
        // Keep it small: past 1 MB, the older half goes.
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1_000_000,
           let data = try? Data(contentsOf: url) {
            try? data.suffix(size / 2).write(to: url)
        }
        let text = "\(Date().formatted(date: .omitted, time: .standard))  \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(text.utf8)); try? handle.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

}
