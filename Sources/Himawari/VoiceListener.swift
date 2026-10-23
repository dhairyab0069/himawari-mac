import AVFoundation
import Foundation
import Speech
import HimawariKit

/// Listens for spoken commands in the room and hands them to the app.
///
/// How it works, and why it is quick:
///
/// - The recogniser is Apple's, running **on this Mac** (no server, no language model).
/// - It is given the app's own vocabulary up front, so it only ever looks for those
///   words. It does not transcribe the room; it looks for a command.
/// - It runs **continuously**, so the reply is not waiting for a wake word and there
///   is no start-up delay: the phrase is already being scored when it is finished.
/// - Recognition requests ask for **partial results**, so a command can fire before
///   the speaker has finished the word.
///
/// Only one recognition task runs at a time; a new phrase cancels the old one.
final class VoiceListener: NSObject, @unchecked Sendable {

    /// What the listener heard and understood.
    enum Event {
        /// A phrase matched a command.
        case command(VoiceAction, phrase: String)
        /// The recogniser is listening.
        case started
        /// Something went wrong; the app carries on without it.
        case failed(String)
        /// The user (or the system) turned it off.
        case stopped
    }

    /// Called on the main thread.
    var onEvent: ((Event) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let queue = DispatchQueue(label: "local.dhairyabhatia.himawari.voice", qos: .userInitiated)

    /// The stream of sound from the microphone.
    private var engine: AVAudioEngine?
    private var running = false

    /// How loud the microphone is right now (root mean square of the last buffer).
    /// Read by the app's log so a silent microphone is visible.
    let micLevel = NSLock()
    private var level: Float = 0
    /// Called about once a second with the current level.
    var onLevel: ((Float) -> Void)?

    /// Set while the app is speaking or otherwise busy, so the app does not hear itself.
    private(set) var muted = false

    /// Whether macOS has allowed speech recognition.
    private(set) var authorized = false

    /// Whether the microphone is available and the listener is live.
    var isListening: Bool { running }

    /// How loud the microphone is right now.
    var microphoneLevel: Float {
        micLevel.lock(); defer { micLevel.unlock() }
        return level
    }

    // MARK: - Starting and stopping

    /// Asks for permission and starts listening. Safe to call more than once.
    func start() {
        guard !running else { return }

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard let self else { return }
            switch status {
            case .authorized:
                self.authorized = true
                self.begin()
            case .denied:
                self.authorized = false
                self.post(.failed("Speech recognition was denied. Enable it in System Settings › Privacy & Security › Speech Recognition."))
            case .restricted:
                self.authorized = false
                self.post(.failed("Speech recognition is restricted on this Mac."))
            case .notDetermined:
                self.authorized = false
            @unknown default:
                self.authorized = false
            }
        }
    }

    /// Starts the microphone and the recogniser.
    private func begin() {
        queue.async { [weak self] in
            guard let self, !self.running else { return }

            guard let recognizer = self.recognizer else {
                self.post(.failed("The speech recogniser could not be created."))
                return
            }
            guard recognizer.isAvailable else {
                self.post(.failed("The speech recogniser is not available right now."))
                return
            }
            Log.write("voice: recogniser ready, onDevice=\(recognizer.supportsOnDeviceRecognition)")

            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)

            // A device with no input (or a format of zero sample rate) can't be tapped.
            guard format.sampleRate > 0, format.channelCount > 0 else {
                self.post(.failed("No microphone is available."))
                return
            }

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.taskHint = .dictation
            // On this Mac, not on a server.
            if recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }
            // The app's own words: the recogniser looks for these, not for everything.
            request.contextualStrings = VoiceCommands.allPhrases

            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
                // A cheap check that the microphone is really delivering sound.
                if let data = buffer.floatChannelData?[0] {
                    var sum: Float = 0
                    for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
                    let rms = sqrt(sum / Float(max(1, buffer.frameLength)))
                    self.micLevel.lock()
                    self.level = rms
                    self.micLevel.unlock()
                }
            }

            engine.prepare()
            do {
                try engine.start()
            } catch {
                self.post(.failed("The microphone could not be started: \(error.localizedDescription)"))
                return
            }

            self.engine = engine
            self.request = request
            self.running = true

            self.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self else { return }
                if let error {
                    // A cancelled task is the normal way a phrase ends.
                    let ns = error as NSError
                    if ns.domain == "kAFAssistantErrorDomain" && ns.code == 216 || ns.code == 1101 {
                        return
                    }
                    self.post(.failed(error.localizedDescription))
                    return
                }
                guard let result else { return }
                let text = result.bestTranscription.formattedString
                Log.write("voice heard: '\(text)' final=\(result.isFinal)")
                if result.isFinal {
                    self.finishPhrase(text)
                } else {
                    // Partial: act early if it already says a command.
                    self.check(text, final: false)
                }
            }

            self.post(.started)
        }
    }

    /// Stops listening and releases the microphone.
    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.request?.endAudio()
            self.task?.cancel()
            self.task = nil
            self.request = nil
            if let engine = self.engine {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
            self.engine = nil
            self.running = false
            self.post(.stopped)
        }
    }

    // MARK: - Reading phrases

    /// The last phrase acted on, so the same words are not heard twice.
    private var lastPhrase = ""
    private var lastActedAt = Date.distantPast

    /// Looks at what was heard and carries out a command if it is one.
    ///
    /// A partial result is a guess — the words heard so far might still grow ("play" could
    /// become "play next song"), so a partial is only acted on when it cannot grow into a
    /// different command. The final result is taken as it stands.
    private func check(_ text: String, final: Bool) {
        guard !muted else { return }
        let action = final ? VoiceCommands.action(for: text) : VoiceCommands.actionForPartial(text)
        guard let action else { return }

        let phrase = VoiceCommands.normalize(text)
        let now = Date()
        // Ignore the same words again for a moment: a partial result repeats itself.
        if phrase == lastPhrase, now.timeIntervalSince(lastActedAt) < 2.0 { return }
        lastPhrase = phrase
        lastActedAt = now
        post(.command(action, phrase: phrase))
    }

    /// The phrase is over: look at it one last time.
    private func finishPhrase(_ text: String) {
        check(text, final: true)
        // Start a fresh request so the next phrase is heard cleanly.
        queue.async { [weak self] in
            guard let self, self.running else { return }
            self.task?.finish()
            self.task = nil
            self.beginSession()
        }
    }

    /// Creates a new recognition request, reusing the live engine.
    private func beginSession() {
        guard let recognizer = recognizer, recognizer.isAvailable, running else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        request.contextualStrings = VoiceCommands.allPhrases
        if let engine = engine {
            let format = engine.inputNode.outputFormat(forBus: 0)
            engine.inputNode.removeTap(onBus: 0)
            engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
        }
        self.request = request
        self.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let error {
                let ns = error as NSError
                if ns.code == 216 || ns.code == 1101 { return }
                self.post(.failed(error.localizedDescription))
                return
            }
            guard let result else { return }
            let text = result.bestTranscription.formattedString
            if result.isFinal { self.finishPhrase(text) } else { self.check(text, final: false) }
        }
    }

    private func post(_ event: Event) {
        let deliver = onEvent
        DispatchQueue.main.async { deliver?(event) }
    }
}
