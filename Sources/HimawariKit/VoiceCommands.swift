import Foundation

/// A spoken instruction, heard in the room, that the app carries out.
///
/// The vocabulary is deliberately tiny and closed: a handful of transport words and
/// two volume directions. Anything else is ignored, so a passing conversation never
/// moves the music. The matching is pure text work — no language model, no network —
/// so it answers in microseconds.
public enum VoiceIntent: Equatable, Sendable {
    case play, pause, toggle
    case next, previous
    case volumeUp, volumeDown
    case louder, quieter   // the same thing, said the other way
}

/// What a spoken phrase turned into.
public enum VoiceAction: Equatable, Sendable {
    /// A transport command for the player that is playing.
    case transport(PlayerCommand)
    /// A change to the volume, by a fraction of full scale.
    case volume(by: Double)
}

/// Turns the words someone said into something the app does.
///
/// The rules are strict on purpose. A phrase has to match one of the known forms
/// exactly — no fuzzy guessing, no "sounds like". "Next" is a command; "next time"
/// and "the next song is nice" are not, because they carry words the command does not.
public enum VoiceCommands {

    /// Every transport command, in the words a person might use.
    /// Each entry is the set of phrases that mean exactly this.
    private static let transportPhrases: [(phrases: [String], command: PlayerCommand)] = [
        (["next", "next track", "next song", "skip", "skip track", "skip song",
          "play next", "play next track", "play next song", "track next", "song next"], .next),
        (["previous", "previous track", "previous song", "last track", "last song",
          "play previous", "play previous track", "play previous song",
          "track previous", "song previous"], .previous),
        (["back", "go back", "take me back", "skip back", "step back"], .back),
        (["pause", "pause it", "pause music", "pause the music", "pause playback", "hold"], .pause),
        (["play", "play it", "play music", "play the music", "play playback", "resume",
          "continue", "unpause"], .play),
        (["toggle", "toggle play", "toggle playback", "play pause", "pause play"], .togglePlayPause),
    ]

    /// Volume, said as a direction. Each step is a fraction of full scale.
    public static let volumeStep = 0.1

    private static let upPhrases: Set<String> = [
        "volume up", "turn up", "turn it up", "turn the volume up", "raise volume",
        "raise the volume", "louder", "make it louder", "make it louder please",
        "volume higher", "increase volume", "increase the volume", "boost volume",
        "boost the volume", "up the volume", "more volume", "volume please up",
    ]

    private static let downPhrases: Set<String> = [
        "volume down", "turn down", "turn it down", "turn the volume down", "lower volume",
        "lower the volume", "quieter", "make it quieter", "make it quieter please",
        "volume lower", "decrease volume", "decrease the volume", "reduce volume",
        "reduce the volume", "down the volume", "less volume", "volume please down",
    ]

    /// Normalises what was heard into something comparable: lower case, no punctuation,
    /// single spaces. "Play  next!" and "play next" become the same thing.
    public static func normalize(_ phrase: String) -> String {
        let lowered = phrase.lowercased()
        let cleaned = lowered.map { character -> Character in
            if character.isLetter || character.isNumber || character == " " { return character }
            return " "
        }
        return String(cleaned)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    /// What a phrase means, or nil when it is not one of our commands.
    ///
    /// `heard` is the whole phrase the recogniser heard. Only the exact phrases
    /// count: "skip" is a command, "skipping the ad" is not.
    public static func action(for heard: String) -> VoiceAction? {
        let phrase = normalize(heard)
        guard !phrase.isEmpty else { return nil }

        if upPhrases.contains(phrase) { return .volume(by: volumeStep) }
        if downPhrases.contains(phrase) { return .volume(by: -volumeStep) }

        for entry in transportPhrases {
            for candidate in entry.phrases where candidate == phrase {
                return .transport(entry.command)
            }
        }
        return nil
    }

    /// The action for words heard SO FAR, when it is safe to act on them already.
    ///
    /// A partial result is a guess: "play" might be the whole word, or the start of
    /// "play next song". So a partial is only acted on when every longer phrase it could
    /// grow into means the same thing. "Next" is safe (the only longer forms are "next
    /// track" and "next song", both the same command); "play" is not (it could become
    /// "play next", which is a different command).
    public static func actionForPartial(_ heard: String) -> VoiceAction? {
        guard let heardAction = action(for: heard) else { return nil }
        let phrase = normalize(heard)
        // Every longer phrase this could grow into must mean the same thing.
        for longer in allPhrases where longer.hasPrefix(phrase + " ") {
            guard action(for: longer) == heardAction else { return nil }
        }
        return heardAction
    }

    /// Every phrase the app understands. Used by the settings screen and by the tests.
    public static var allPhrases: [String] {
        var out = upPhrases.sorted() + downPhrases.sorted()
        for entry in transportPhrases { out.append(contentsOf: entry.phrases.sorted()) }
        return out
    }
}
