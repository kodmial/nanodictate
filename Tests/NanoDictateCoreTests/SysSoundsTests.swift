import AppKit
import Foundation
@testable import NanoDictateCore

final class SysSoundsTests: XCTestCase {

    @objc func testEnabledDefault() {
        let sounds = SysSounds()
        XCTAssertTrue(sounds.enabled)
    }

    @objc func testInitWithEnabledTrueDoesNotCrash() {
        let sounds = SysSounds(enabled: true)
        sounds.playStart()
        sounds.playEnd()
        sounds.playCancel()
    }

    @objc func testDisabledSoundsAreNoOp() {
        let sounds = SysSounds(enabled: false)
        XCTAssertFalse(sounds.enabled)
        // No-op calls must not throw when disabled.
        sounds.playStart()
        sounds.playEnd()
        sounds.playCancel()
    }

    @objc func testDisableAfterInit() {
        let sounds = SysSounds(enabled: true)
        sounds.enabled = false
        XCTAssertFalse(sounds.enabled)
        sounds.playStart()
        sounds.playCancel()
    }

    @objc func testReenableAfterDisable() {
        let sounds = SysSounds(enabled: false)
        sounds.playStart()
        sounds.enabled = true
        XCTAssertTrue(sounds.enabled)
        sounds.playStart()
        sounds.playEnd()
        sounds.playCancel()
    }

    // MARK: - Новое поведение (NSSound + защита от дублей)

    /// System sounds must exist in /System/Library/Sounds, else NSSound(named:) is nil.
    @objc func testSystemSoundsExist() {
        XCTAssertNotNil(NSSound(named: "Tink"))
        XCTAssertNotNil(NSSound(named: "Pop"))
        XCTAssertNotNil(NSSound(named: "Ping"))
    }

    /// playStart marks sound playing — basis of duplicate-replay guard.
    @objc func testPlayStartMarksCurrentlyPlaying() {
        let sounds = SysSounds(enabled: true)
        sounds.playStart()
        XCTAssertEqual(sounds.playingName, "Tink")
    }

    /// Same playing sound skipped; different or finished sound plays.
    @objc func testDuplicateReplayIsSkippedForSamePlayingSound() {
        let sounds = SysSounds(enabled: true)
        sounds.playStart() // First play is never skipped.
        XCTAssertTrue(sounds.shouldSkipReplay(of: "Tink", currentlyPlaying: true))
        // Different sound plays; previous stops.
        XCTAssertFalse(sounds.shouldSkipReplay(of: "Pop", currentlyPlaying: true))
        XCTAssertFalse(sounds.shouldSkipReplay(of: "Tink", currentlyPlaying: false))
    }

    // MARK: - Звук ошибки сети (Basso)

    /// Basso must exist in /System/Library/Sounds, else playError silently skips.
    @objc func testErrorSoundExists() {
        XCTAssertNotNil(NSSound(named: "Basso"))
    }

    @objc func testPlayErrorUsesBasso() {
        let sounds = SysSounds(enabled: true)
        sounds.playError()
        XCTAssertEqual(sounds.playingName, "Basso")
    }

    @objc func testPlayErrorDisabledIsNoOp() {
        let sounds = SysSounds(enabled: false)
        sounds.playError()
        XCTAssertNil(sounds.playingName)
    }

    // MARK: - Post-insert / empty-result / undo sounds (labels distinguish shared files)

    /// Completion-after-insert shares the Pop file with playEnd but records
    /// its own label, so tests can tell the two call sites apart.
    @objc func testPlayCompletionAfterInsertSharesPopWithOwnLabel() {
        let sounds = SysSounds(enabled: true)
        sounds.playCompletionAfterInsert()
        XCTAssertEqual(sounds.playingName, "Pop")
        XCTAssertEqual(sounds.lastPlayedLabel, "completionAfterInsert")
        sounds.playEnd()
        XCTAssertEqual(sounds.playingName, "Pop")
        XCTAssertEqual(sounds.lastPlayedLabel, "end")
    }

    @objc func testPlayEmptyResultUsesFunk() {
        let sounds = SysSounds(enabled: true)
        sounds.playEmptyResult()
        XCTAssertEqual(sounds.playingName, "Funk")
        XCTAssertEqual(sounds.lastPlayedLabel, "emptyResult")
    }

    @objc func testPlayUndoUsesPopWithOwnLabel() {
        let sounds = SysSounds(enabled: true)
        sounds.playUndo()
        XCTAssertEqual(sounds.playingName, "Pop")
        XCTAssertEqual(sounds.lastPlayedLabel, "undo")
    }

    @objc func testPlayCancelUsesPing() {
        let sounds = SysSounds(enabled: true)
        sounds.playCancel()
        XCTAssertEqual(sounds.playingName, "Ping")
        XCTAssertEqual(sounds.lastPlayedLabel, "cancel")
    }

    /// Disabled sounds never record intent, including the new cases.
    @objc func testDisabledNewSoundsAreNoOp() {
        let sounds = SysSounds(enabled: false)
        sounds.playCompletionAfterInsert()
        sounds.playEmptyResult()
        sounds.playUndo()
        sounds.playCancel()
        sounds.playEnd()
        XCTAssertNil(sounds.playingName)
        XCTAssertNil(sounds.lastPlayedLabel)
    }

    /// shouldSkipReplay only skips the same still-playing sound.
    @objc func testShouldSkipReplayMatrix() {
        let sounds = SysSounds(enabled: true)
        sounds.playStart() // playingName == "Tink"
        XCTAssertTrue(sounds.shouldSkipReplay(of: "Tink", currentlyPlaying: true))
        XCTAssertFalse(sounds.shouldSkipReplay(of: "Tink", currentlyPlaying: false))
        XCTAssertFalse(sounds.shouldSkipReplay(of: "Pop", currentlyPlaying: false))
        // Fresh instance with no sound yet never skips.
        let fresh = SysSounds(enabled: true)
        XCTAssertFalse(fresh.shouldSkipReplay(of: "Tink", currentlyPlaying: true))
    }
}