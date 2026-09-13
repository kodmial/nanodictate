import Foundation
@testable import DictationCore

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
        // При enabled == false вызовы — no-op и не должны бросать.
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
        sounds.playStart() // no-op
        sounds.enabled = true
        XCTAssertTrue(sounds.enabled)
        sounds.playStart()
        sounds.playEnd()
        sounds.playCancel()
    }
}