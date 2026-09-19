//
//  SysSounds.swift
//  NanoDictateCore
//
//  Short dictation start/end system sounds + file logger.
//  AppKit + Foundation only (macOS 12, Swift 5.7).
//
//  Sounds via NSSound(named:) from macOS system sounds:
//  files in /System/Library/Sounds/*.aiff (Tink, Pop, Ping...).
//  Numeric SystemSoundID from iOS catalog silently ignored by macOS —
//  play via NSSound.
//
//  Replay protection: before play() stop previous (NSSound.stop); same
//  sound still playing (isPlaying) — no restart, no self-overlap
//  (restart of same sound allowed only after it finished).
//

import AppKit
import Foundation

// MARK: - Системные звуки

/// Plays short macOS system sounds via NSSound.
public final class SysSounds {
  /// `enabled == false` — completely silent.
  public var enabled: Bool

  /// macOS system sounds (filenames w/o extension from /System/Library/Sounds).
  private static let startSoundName = "Tink"
  private static let endSoundName = "Pop"
  private static let cancelSoundName = "Ping"
  /// macOS classic "error sound" — network failures (no internet / STT timeout).
  private static let errorSoundName = "Basso"

  // MARK: Новые кейсы (быстрые UX-победы). Каждый — отдельный кейс с дефолтным

  // поведением: существующие кейсы/методы (start/end/cancel/error) НЕ меняются.

  /// Success sound AFTER text insertion. Default same Pop as playEnd, but a
  /// separate case/method: new queue "insert then sound" pinned to it, old
  /// playEnd untouched.
  private static let completionAfterInsertSoundName = "Pop"
  /// "Empty result" sound: STT returned under two words — nothing inserted,
  /// Funk instead of success (not Basso — this is not an error).
  private static let emptyResultSoundName = "Funk"
  /// Last insertion undo sound (double-Alt undo).
  private static let undoSoundName = "Pop"

  // Lazy cache: NSSound created once per name, reused. One cache for all —
  // classic start/end/cancel/error and new cases (completionAfterInsert/
  // emptyResult/undo).
  private var soundsByName: [String: NSSound] = [:]

  /// Sound currently playing (stopped on sound change).
  private var playingSound: NSSound?

  /// Name of sound marked playing (internal — tests read it).
  private(set) var playingName: String?

  /// Label of last requested sound (start/end/cancel/error/
  /// completionAfterInsert/emptyResult/undo). Lets tests distinguish cases
  /// sharing one sound ("Pop" for end and completionAfterInsert), while
  /// playingName stores only the filename.
  private(set) var lastPlayedLabel: String?

  private let lock = NSLock()

  public init(enabled: Bool = true) {
    self.enabled = enabled
  }

  public func playStart() {
    play(Self.startSoundName, label: "start")
  }

  /// Successful finish (text inserted).
  public func playEnd() {
    play(Self.endSoundName, label: "end")
  }

  /// Cancel (Esc).
  public func playCancel() {
    play(Self.cancelSoundName, label: "cancel")
  }

  /// Dictation error (no internet / STT timeout).
  public func playError() {
    play(Self.errorSoundName, label: "error")
  }

  // MARK: Новые методы (UX quick wins)

  /// Finish sound AFTER text insertion (not before). Called from
  /// completeInsertion after Inserter.insert — user hears it only when text
  /// is confirmed inserted.
  public func playCompletionAfterInsert() {
    play(Self.completionAfterInsertSoundName, label: "completionAfterInsert")
  }

  /// "Empty result" sound: STT returned <2 words — nothing inserted. Distinct
  /// from mic failure (Basso): emptiness ≠ failure.
  public func playEmptyResult() {
    play(Self.emptyResultSoundName, label: "emptyResult")
  }

  /// Last insertion undo sound (double-Alt undo within window).
  public func playUndo() {
    play(Self.undoSoundName, label: "undo")
  }

  /// Duplicate protection: skip replay of `name` only when it is the same
  /// sound and still playing — else same-name sound replayable.
  func shouldSkipReplay(of name: String, currentlyPlaying: Bool) -> Bool {
    playingName == name && currentlyPlaying
  }

  private func play(_ name: String, label: String) {
    guard enabled else { return }  // disabled — full no-op
    Logger.log("sounds: \(label)", level: "debug")

    // Test runner (NANODICTATE_TESTS=1): real system sound NOT played — no
    // user disturbance. Sound intent still recorded (playingName,
    // lastPlayedLabel) — tests build on them: which sound called, replay
    // protection. lastPlayedLabel distinguishes cases sharing one sound
    // (end and completionAfterInsert both "Pop", different labels).
    if RuntimeEnvironment.isTestRun {
      lock.lock()
      defer { lock.unlock() }
      playingSound = nil
      playingName = name
      lastPlayedLabel = label
      return
    }

    lock.lock()
    defer { lock.unlock() }

    guard let sound = sound(name: name) else {
      // Sound missing from system catalog — silently skipped (as
      // AudioServices silently ignored SystemSoundID). Silence diagnosis
      // stays at debug level.
      Logger.log("sounds: \(name) not found in system catalog — skipped", level: "debug")
      return
    }

    guard !shouldSkipReplay(of: name, currentlyPlaying: sound.isPlaying) else {
      return
    }

    // Sound changed while previous still playing — stop it.
    if let current = playingSound, current !== sound, current.isPlaying {
      current.stop()
    }

    sound.play()
    playingSound = sound
    playingName = name
    lastPlayedLabel = label
  }

  private func sound(name: String) -> NSSound? {
    if let cached = soundsByName[name] {
      return cached
    }
    guard let created = NSSound(named: name) else { return nil }
    soundsByName[name] = created
    return created
  }
}

// MARK: - Логгер

/// Minimal thread-safe file logger: appends to `<logDirectory>/agent.log`.
public enum Logger {
  /// Logs directory; `~` expanded automatically.
  public static var logDirectory: String = "~/Library/Logs/NanoDictate"

  private static let lock = NSLock()

  /// Appends `yyyy-MM-dd HH:mm:ss [level] message` to agent.log. Creates
  /// dir/file as needed. Never throws.
  public static func log(_ message: String, level: String = "info") {
    lock.lock()
    defer { lock.unlock() }

    // Test runner: prod ~/Library/Logs/NanoDictate/agent.log untouched —
    // test lines go to /tmp/nanodictate-tests/agent.log. If a test
    // redirected logDirectory itself (LoggerTests) — respect it.
    var effectiveDirectory = logDirectory
    if RuntimeEnvironment.isTestRun, logDirectory == "~/Library/Logs/NanoDictate" {
      effectiveDirectory = "/tmp/nanodictate-tests"
    }

    let expanded = (effectiveDirectory as NSString).expandingTildeInPath
    let fileManager = FileManager.default

    var isDirectory: ObjCBool = false
    if !fileManager.fileExists(atPath: expanded, isDirectory: &isDirectory) {
      do {
        try fileManager.createDirectory(atPath: expanded, withIntermediateDirectories: true)
      } catch {
        return  // no access to log dir — silent skip
      }
    }

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "\(formatter.string(from: Date())) [\(level)] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }

    let fileURL = URL(fileURLWithPath: expanded).appendingPathComponent("agent.log")

    if let handle = try? FileHandle(forWritingTo: fileURL) {
      defer { try? handle.close() }
      handle.seekToEndOfFile()
      handle.write(data)
    } else if !fileManager.fileExists(atPath: fileURL.path) {
      try? data.write(to: fileURL)
    }
  }
}
