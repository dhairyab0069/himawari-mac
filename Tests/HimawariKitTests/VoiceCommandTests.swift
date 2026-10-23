import XCTest
@testable import HimawariKit

/// The spoken vocabulary: what counts as a command, and what does not.
final class VoiceCommandTests: XCTestCase {

    private func action(_ phrase: String) -> VoiceAction? {
        VoiceCommands.action(for: phrase)
    }

    func testTransportCommands() {
        XCTAssertEqual(action("next"), .transport(.next))
        XCTAssertEqual(action("Next"), .transport(.next))
        XCTAssertEqual(action("play next"), .transport(.next))
        XCTAssertEqual(action("next song"), .transport(.next))
        XCTAssertEqual(action("skip"), .transport(.next))
        XCTAssertEqual(action("previous"), .transport(.previous))
        XCTAssertEqual(action("pause"), .transport(.pause))
        XCTAssertEqual(action("play"), .transport(.play))
        XCTAssertEqual(action("resume"), .transport(.play))
        XCTAssertEqual(action("toggle"), .transport(.togglePlayPause))
    }

    func testBackIsItsOwnCommand() {
        // "back" is the Back button, not "previous": it restarts a song that is under
        // way, and steps back only at the very start.
        XCTAssertEqual(action("back"), .transport(.back))
        XCTAssertEqual(action("go back"), .transport(.back))
        XCTAssertEqual(action("Back"), .transport(.back))
        // "previous" still means the song before this one.
        XCTAssertEqual(action("previous"), .transport(.previous))
        XCTAssertEqual(action("previous song"), .transport(.previous))
    }

    func testBackBehaviourFollowsTheButton() {
        // A song under way: Back starts it again. At the very start: the song before.
        XCTAssertEqual(MusicNowPlaying.backBehaviour(position: 30), .restart)
        XCTAssertEqual(MusicNowPlaying.backBehaviour(position: 10), .restart)
        XCTAssertEqual(MusicNowPlaying.backBehaviour(position: 0), .previous)
        XCTAssertEqual(MusicNowPlaying.backBehaviour(position: 2), .previous)
        // An unknown position: step back, as it always used to.
        XCTAssertEqual(MusicNowPlaying.backBehaviour(position: nil), .previous)
    }

    func testPartialResultsDoNotFireTheWrongCommand() {
        // "play" might still become "play next song" (a different command), so it must
        // not fire on a partial.
        XCTAssertNil(VoiceCommands.actionForPartial("play"))
        // "play next" can only grow into "play next song"/"play next track": all the same.
        XCTAssertEqual(VoiceCommands.actionForPartial("play next"), .transport(.next))
        // "next" can only grow into "next track"/"next song", which are the same command.
        XCTAssertEqual(VoiceCommands.actionForPartial("next"), .transport(.next))
        XCTAssertEqual(VoiceCommands.actionForPartial("volume up"), .volume(by: VoiceCommands.volumeStep))
        // A word that is not a command at all.
        XCTAssertNil(VoiceCommands.actionForPartial("next time"))
    }

    func testVolumeCommands() {
        XCTAssertEqual(action("volume up"), .volume(by: VoiceCommands.volumeStep))
        XCTAssertEqual(action("volume down"), .volume(by: -VoiceCommands.volumeStep))
        XCTAssertEqual(action("turn it up"), .volume(by: VoiceCommands.volumeStep))
        XCTAssertEqual(action("louder"), .volume(by: VoiceCommands.volumeStep))
        XCTAssertEqual(action("quieter"), .volume(by: -VoiceCommands.volumeStep))
        XCTAssertEqual(action("make it quieter"), .volume(by: -VoiceCommands.volumeStep))
    }

    func testPunctuationAndCaseAreIgnored() {
        XCTAssertEqual(action("PLAY NEXT!"), .transport(.next))
        XCTAssertEqual(action("  Volume   Up  "), .volume(by: VoiceCommands.volumeStep))
        XCTAssertEqual(action("pause."), .transport(.pause))
        XCTAssertEqual(action("next-track"), .transport(.next)) // the dash is a separator
    }

    func testOrdinarySpeechIsNotACommand() {
        // The whole point: a conversation must not move the music.
        XCTAssertNil(action("next time"))
        XCTAssertNil(action("the next song is nice"))
        XCTAssertNil(action("play the next episode"))
        XCTAssertNil(action("I was listening to that"))
        XCTAssertNil(action("can you pause"))
        XCTAssertNil(action("please pause the music now"))
        XCTAssertNil(action("turn up the volume on the television"))
        XCTAssertNil(action(""))
        XCTAssertNil(action("   "))
        XCTAssertNil(action("..."))
    }

    func testNearMissesAreRejected() {
        // One word off is not the command.
        XCTAssertNil(action("nexts"))
        XCTAssertNil(action("net"))
        XCTAssertNil(action("pausey"))
        XCTAssertNil(action("play nexts"))
    }

    func testNormalizeKeepsOnlyLettersNumbersAndSpaces() {
        XCTAssertEqual(VoiceCommands.normalize("Play  NEXT!"), "play next")
        XCTAssertEqual(VoiceCommands.normalize("volume-up"), "volume up")
        XCTAssertEqual(VoiceCommands.normalize("  "), "")
    }

    func testEveryPhraseIsUnderstood() {
        // The vocabulary and the matcher must not drift apart.
        for phrase in VoiceCommands.allPhrases {
            XCTAssertNotNil(action(phrase), phrase)
        }
    }

    func testVolumeStepIsSensible() {
        XCTAssertGreaterThan(VoiceCommands.volumeStep, 0)
        XCTAssertLessThanOrEqual(VoiceCommands.volumeStep, 0.25)
    }
}
