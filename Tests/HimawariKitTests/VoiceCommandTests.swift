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
        XCTAssertEqual(action("go back"), .transport(.previous))
        XCTAssertEqual(action("pause"), .transport(.pause))
        XCTAssertEqual(action("play"), .transport(.play))
        XCTAssertEqual(action("resume"), .transport(.play))
        XCTAssertEqual(action("toggle"), .transport(.togglePlayPause))
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
