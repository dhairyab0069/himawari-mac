import AVFoundation
import Foundation
import HimawariKit
import Speech

/// A headless check of the voice pipeline.
///
/// Two ways to run it:
///
/// - From the command line: `Himawari --voice-check <file> [more files ...]`.
///   The binary asks macOS for speech-recognition permission the first time.
/// - From the running app: write the list of audio files into the request file
///   (`~/Library/Logs/Himawari-voice-check.txt`). The app, which already holds the
///   permission, checks them and writes the report back into the same file.
///
/// In both cases each file goes through the **same** on-device recogniser and the
/// **same** phrase list the app uses when it listens to the room, and nothing is
/// played out loud. So it can be checked in a quiet room, or on a machine with no
/// microphone at all.
enum VoiceCheck {

    /// Where the request file lives.
    static var requestPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/Himawari-voice-check.txt").path
    }

    /// Where the report is written.
    static var reportPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/Himawari-voice-check-report.txt").path
    }

    /// Watches for a request file and checks whatever it lists.
    ///
    /// The request is moved aside before the report is written, so the report can never
    /// be read back as a new request.
    static func watchRequests() {
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            guard let text = try? String(contentsOfFile: requestPath, encoding: .utf8) else { return }
            let files = text.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !files.isEmpty else { return }
            Log.write("voice-check: request for \(files.count) file(s)")
            // Take the request away first.
            let taken = requestPath + ".taken"
            try? FileManager.default.removeItem(atPath: taken)
            try? FileManager.default.moveItem(atPath: requestPath, toPath: taken)

            Task { @MainActor in
                var report = "voice-check " + Date().formatted(date: .omitted, time: .standard) + "\n"
                report += await check(files)
                try? report.write(to: URL(fileURLWithPath: reportPath), atomically: true, encoding: .utf8)
                Log.write(report.replacingOccurrences(of: "\n", with: " | "))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Recognises each file and returns a report.
    static func check(_ files: [String]) async -> String {
        var out = ""
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.isAvailable else {
            return "FAIL: the speech recogniser is not available on this Mac\n"
        }
        out += "recogniser: on-device=" + String(recognizer.supportsOnDeviceRecognition) + "\n"

        for path in files {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else {
                out += "FAIL  " + url.lastPathComponent + ": no such file\n"
                continue
            }

            // Recognition from a file is not always done on the device, so try on-device
            // first and fall back to the system's own recognition if that hears nothing.
            var text = ""
            var failure = ""
            var segments = 0
            var mode = "on-device"
            if recognizer.supportsOnDeviceRecognition {
                let first = await recognise(recognizer, url: url, onDevice: true)
                text = first.0
                failure = first.1
                segments = first.2
            }
            if segments == 0 && failure.isEmpty {
                mode = "system"
                let second = await recognise(recognizer, url: url, onDevice: false)
                text = second.0
                failure = second.1
                segments = second.2
            }

            if !failure.isEmpty {
                out += "FAIL  " + url.lastPathComponent + ": " + failure + "\n"
                continue
            }
            let action = VoiceCommands.action(for: text)
            let tag = action == nil ? "IGNORE" : "ACT   "
            let verdict = action.map { describe($0) } ?? "not a command"
            let count = String(segments)
            out += tag + " " + url.lastPathComponent + " [" + mode + "]: heard '" + text + "' (" + count + " segments) -> " + verdict + "\n"
        }
        return out
    }

    /// Recognises one file. Returns the text, any error, and the number of segments.
    private static func recognise(_ recognizer: SFSpeechRecognizer, url: URL, onDevice: Bool) async -> (String, String, Int) {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        if onDevice { request.requiresOnDeviceRecognition = true }
        request.contextualStrings = VoiceCommands.allPhrases

        return await withCheckedContinuation { continuation in
            var finished = false
            let task = recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                finished = true
                if let error {
                    continuation.resume(returning: ("", error.localizedDescription, 0))
                } else if let result {
                    let transcription = result.bestTranscription
                    continuation.resume(returning: (transcription.formattedString, "", transcription.segments.count))
                } else {
                    continuation.resume(returning: ("", "", 0))
                }
            }
            // A recogniser that never answers must not hang the check.
            Task {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !finished else { return }
                finished = true
                task.cancel()
                continuation.resume(returning: ("", "", 0))
            }
        }
    }

    /// Command-line entry point. Returns the process exit code.
    static func run(_ arguments: [String]) -> Int32 {
        let files = arguments.filter { !$0.hasPrefix("--") }
        guard !files.isEmpty else {
            print("usage: Himawari --voice-check <audio file> ...")
            return 2
        }
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            let semaphore = DispatchSemaphore(value: 0)
            var ok = false
            SFSpeechRecognizer.requestAuthorization { status in
                ok = status == .authorized
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 60)
            print("requested speech authorization: " + String(ok))
        }
        let status = SFSpeechRecognizer.authorizationStatus()
        let names = ["notDetermined", "denied", "restricted", "authorized"]
        let name = names[min(status.rawValue, names.count - 1)]
        print("speech authorization: " + name)
        guard status == .authorized else { return 1 }
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            print(await check(files), terminator: "")
            done.signal()
        }
        _ = done.wait(timeout: .now() + 600)
        return 0
    }

    private static func describe(_ action: VoiceAction) -> String {
        switch action {
        case .transport(let command): return command.helperLine
        case .volume(let by): return by > 0 ? "volume up" : "volume down"
        }
    }
}