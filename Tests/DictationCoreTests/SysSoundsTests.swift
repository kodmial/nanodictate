import XCTest
@testable import DictationCore

final class SysSoundsTests: XCTestCase {

    func testEnabledDefault() {
        let sounds = SysSounds()
        XCTAssertTrue(sounds.enabled)
    }

    func testInitWithEnabledTrueDoesNotCrash() {
        let sounds = SysSounds(enabled: true)
        sounds.playStart()
        sounds.playEnd()
        sounds.playCancel()
    }

    func testDisabledSoundsAreNoOp() {
        let sounds = SysSounds(enabled: false)
        XCTAssertFalse(sounds.enabled)
        // При enabled == false вызовы — no-op и не должны бросать.
        sounds.playStart()
        sounds.playEnd()
        sounds.playCancel()
    }

    func testDisableAfterInit() {
        let sounds = SysSounds(enabled: true)
        sounds.enabled = false
        XCTAssertFalse(sounds.enabled)
        sounds.playStart()
        sounds.playCancel()
    }

    func testReenableAfterDisable() {
        let sounds = SysSounds(enabled: false)
        sounds.playStart() // no-op
        sounds.enabled = true
        XCTAssertTrue(sounds.enabled)
        sounds.playStart()
        sounds.playEnd()
        sounds.playCancel()
    }
}