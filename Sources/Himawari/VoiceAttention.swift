import AppKit
import Foundation
import HimawariKit

/// Voice attention: hears spoken commands in the room and carries them out.
///
/// The whole path is local and quick:
///
///     microphone → Apple's on-device recogniser → a closed phrase list → the player
///
/// There is no language model and nothing leaves the Mac. The recogniser is given the
/// app's own vocabulary, so it looks for a handful of words rather than transcribing
/// the room, and it runs all the time — there is no wake word and no start-up delay.
@MainActor
final class VoiceAttention {

    /// What the app should do when it hears something.
    enum Handler {
        /// A transport command for the player that is playing.
        case transport(PlayerCommand)
        /// A change of volume, as a fraction of full scale.
        case volume(by: Double)
    }

    private let listener = VoiceListener()
    private var handler: (Handler) -> Void = { _ in }

    /// Whether the listener is live right now.
    private(set) var listening = false

    /// The last thing that went wrong, for the menu.
    private(set) var problem: String?

    /// The phrase that was last carried out, for the menu ("heard: next").
    private(set) var lastHeard: String?

    /// How loud the microphone is right now.
    private(set) var lastLevel: Float = 0

    /// Logs how loud the microphone is, so a silent microphone is visible in the log.
    private var levelTimer: Timer?

    init() {
        listener.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .started:
                self.listening = true
                self.problem = nil
                Log.write("voice: listening")
            case .stopped:
                self.listening = false
                Log.write("voice: stopped")
            case .failed(let why):
                self.listening = false
                self.problem = why
                Log.write("voice: \\(why)")
            case .command(let action, let phrase):
                self.lastHeard = phrase
                self.carryOut(action)
            }
        }
    }

    /// Sets what happens when a command is heard.
    func onCommand(_ handler: @escaping (Handler) -> Void) {
        self.handler = handler
    }

    /// Starts listening. macOS asks for the microphone and for speech recognition.
    func start() {
        problem = nil
        listener.start()
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let level = self.listener.microphoneLevel
            self.lastLevel = level
            Log.write(String(format: "voice mic: %.5f", level))
        }
    }

    /// Stops listening and gives the microphone back.
    func stop() {
        levelTimer?.invalidate()
        levelTimer = nil
        listener.stop()
        listening = false
    }

    /// Starts or stops, according to the setting.
    func apply(_ enabled: Bool) {
        if enabled { start() } else { stop() }
    }

    /// Carries a command out.
    private func carryOut(_ action: VoiceAction) {
        switch action {
        case .transport(let command):
            handler(.transport(command))
        case .volume(let by):
            handler(.volume(by: by))
        }
    }
}
