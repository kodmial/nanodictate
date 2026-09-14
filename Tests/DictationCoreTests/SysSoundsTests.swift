import AppKit
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

    // MARK: - Новое поведение (NSSound + защита от дублей)

    /// Системные звуки macOS (Tink/Pop/Ping) обязаны существовать
    /// в /System/Library/Sounds — иначе NSSound(named:) вернёт nil.
    @objc func testSystemSoundsExist() {
        XCTAssertNotNil(NSSound(named: "Tink"))
        XCTAssertNotNil(NSSound(named: "Pop"))
        XCTAssertNotNil(NSSound(named: "Ping"))
    }

    /// После playStart звук помечается играющим — это состояние,
    /// на котором строится защита от повторного переигрывания.
    @objc func testPlayStartMarksCurrentlyPlaying() {
        let sounds = SysSounds(enabled: true)
        sounds.playStart()
        XCTAssertEqual(sounds.playingName, "Tink")
    }

    /// Защита от дублей: тот же звук, помеченный играющим, — повтор пропускаем;
    /// другой звук или завершившийся тот же самый — пропускать не нужно.
    @objc func testDuplicateReplayIsSkippedForSamePlayingSound() {
        let sounds = SysSounds(enabled: true)
        sounds.playStart() // играем "Tink" — первый вызов никогда не скипается
        // Тот же звук и помечен играющим — повторно не запускаем.
        XCTAssertTrue(sounds.shouldSkipReplay(of: "Tink", currentlyPlaying: true))
        // Другой звук — играем (предыдущий при этом останавливается).
        XCTAssertFalse(sounds.shouldSkipReplay(of: "Pop", currentlyPlaying: true))
        // Тот же звук, но уже завершился — можно играть снова.
        XCTAssertFalse(sounds.shouldSkipReplay(of: "Tink", currentlyPlaying: false))
    }

    // MARK: - Звук ошибки сети (Basso)

    /// Basso — системный «звук ошибки» macOS, должен существовать в
    /// /System/Library/Sounds, иначе playError молча пропустит сбой.
    @objc func testErrorSoundExists() {
        XCTAssertNotNil(NSSound(named: "Basso"))
    }

    /// playError() играет Basso и помечает его играющим (как остальные звуки).
    @objc func testPlayErrorUsesBasso() {
        let sounds = SysSounds(enabled: true)
        sounds.playError()
        XCTAssertEqual(sounds.playingName, "Basso")
    }

    /// Отключённые звуки: playError — no-op без падения.
    @objc func testPlayErrorDisabledIsNoOp() {
        let sounds = SysSounds(enabled: false)
        sounds.playError()
        XCTAssertNil(sounds.playingName)
    }
}