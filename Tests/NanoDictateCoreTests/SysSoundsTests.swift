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
}