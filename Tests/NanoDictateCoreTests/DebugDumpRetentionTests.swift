import Foundation
@testable import NanoDictateCore

// MARK: - DebugDumpRetentionTests

/// Retention limits for debug audio recordings (`recording-*.wav`).
/// Policy: at most maxRecordingFiles newest files, at most maxRecordingBytes
/// total, no file older than maxRecordingAge; oldest first, age then count
/// then bytes. Only managed files directly inside the dedicated recordings
/// directory are ever deleted.
final class DebugDumpRetentionTests: XCTestCase {

    private var tempDirs: [String] = []
    private var savedRecordingsDir = ""
    private var savedMaxFiles = 0
    private var savedMaxBytes: Int64 = 0
    private var savedMaxAge: TimeInterval = 0

    override func setUp() {
        super.setUp()
        savedRecordingsDir = DebugDump.recordingsDirectory
        savedMaxFiles = DebugDump.maxRecordingFiles
        savedMaxBytes = DebugDump.maxRecordingBytes
        savedMaxAge = DebugDump.maxRecordingAge
    }

    override func tearDown() {
        for dir in tempDirs {
            try? FileManager.default.removeItem(atPath: dir)
        }
        tempDirs = []
        DebugDump.recordingsDirectory = savedRecordingsDir
        DebugDump.maxRecordingFiles = savedMaxFiles
        DebugDump.maxRecordingBytes = savedMaxBytes
        DebugDump.maxRecordingAge = savedMaxAge
        super.tearDown()
    }

    private func makeTempDir() -> String {
        let dir = NSTemporaryDirectory() + "nanodictate-retention-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        DebugDump.recordingsDirectory = dir
        return dir
    }

    private func writeFile(in dir: String, name: String, bytes: Int, mtime: Date) {
        let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try? Data(repeating: 0x41, count: bytes).write(to: url)
        try? FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
    }

    private func listNames(in dir: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    }

    // MARK: - Documented upper bound exists

    @objc func testDefaultRetentionLimitsAreBounded() {
        XCTAssertGreaterThan(DebugDump.maxRecordingFiles, 0)
        XCTAssertGreaterThan(DebugDump.maxRecordingBytes, 0)
        XCTAssertGreaterThan(DebugDump.maxRecordingAge, 0)
        // Documented upper bound: 20 files / 50 MiB / 7 days.
        XCTAssertEqual(DebugDump.maxRecordingFiles, 20)
        XCTAssertEqual(DebugDump.maxRecordingBytes, 50 * 1024 * 1024)
        XCTAssertEqual(DebugDump.maxRecordingAge, 7 * 24 * 3600, accuracy: 0.001)
    }

    // MARK: - Pure planning: order is oldest-first

    @objc func testPlannedDeletionsRemoveOldestFirstByCount() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let entries = (0..<5).map {
            DebugDump.RecordingEntry(
                name: String(format: "recording-00000000-000000-%03d.wav", $0),
                modificationDate: now.addingTimeInterval(TimeInterval($0 * 60)),
                byteCount: 10)
        }
        let deletions = DebugDump.plannedDeletions(
            entries: entries, now: now, maxFiles: 3, maxBytes: 1_000_000, maxAge: 3600 * 24 * 30)
        XCTAssertEqual(deletions, [entries[0].name, entries[1].name])
    }

    @objc func testPlannedDeletionsRemoveOldestFirstByBytes() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let entries = (0..<3).map {
            DebugDump.RecordingEntry(
                name: String(format: "recording-00000000-000000-%03d.wav", $0),
                modificationDate: now.addingTimeInterval(TimeInterval($0 * 60)),
                byteCount: 100)
        }
        // Total 300 bytes, budget 200 -> oldest single file evicted.
        let deletions = DebugDump.plannedDeletions(
            entries: entries, now: now, maxFiles: 10, maxBytes: 200, maxAge: 3600 * 24 * 30)
        XCTAssertEqual(deletions, [entries[0].name])
    }

    @objc func testPlannedDeletionsEvictAgedFirst() {
        let now = Date(timeIntervalSince1970: 3_000_000)
        let old = DebugDump.RecordingEntry(
            name: "recording-old.wav", modificationDate: now.addingTimeInterval(-10_000), byteCount: 10)
        let fresh = DebugDump.RecordingEntry(
            name: "recording-fresh.wav", modificationDate: now, byteCount: 10)
        let deletions = DebugDump.plannedDeletions(
            entries: [old, fresh], now: now, maxFiles: 10, maxBytes: 1_000_000, maxAge: 3600)
        XCTAssertEqual(deletions, ["recording-old.wav"])
    }

    // MARK: - Boundary values: exact limits are kept

    @objc func testBoundaryExactCountIsKept() {
        let now = Date()
        let entries = (0..<3).map {
            DebugDump.RecordingEntry(
                name: "recording-\($0).wav", modificationDate: now, byteCount: 10)
        }
        let deletions = DebugDump.plannedDeletions(
            entries: entries, now: now, maxFiles: 3, maxBytes: 1_000_000, maxAge: 3600)
        XCTAssertTrue(deletions.isEmpty)
    }

    @objc func testBoundaryExactBytesAreKept() {
        let now = Date()
        let entries = [
            DebugDump.RecordingEntry(name: "recording-a.wav", modificationDate: now, byteCount: 100),
            DebugDump.RecordingEntry(name: "recording-b.wav", modificationDate: now, byteCount: 100),
        ]
        let deletions = DebugDump.plannedDeletions(
            entries: entries, now: now, maxFiles: 10, maxBytes: 200, maxAge: 3600)
        XCTAssertTrue(deletions.isEmpty)
    }

    @objc func testBoundaryExactAgeIsKept() {
        let now = Date(timeIntervalSince1970: 4_000_000)
        let entry = DebugDump.RecordingEntry(
            name: "recording-edge.wav",
            modificationDate: now.addingTimeInterval(-3600),
            byteCount: 10)
        let deletions = DebugDump.plannedDeletions(
            entries: [entry], now: now, maxFiles: 10, maxBytes: 1_000_000, maxAge: 3600)
        XCTAssertTrue(deletions.isEmpty)
    }

    // MARK: - Filesystem: count pruning keeps newest

    @objc func testPruneKeepsNewestFilesByCount() {
        let dir = makeTempDir()
        DebugDump.maxRecordingFiles = 3
        DebugDump.maxRecordingBytes = 1_000_000_000
        DebugDump.maxRecordingAge = 3600 * 24 * 30
        let base = Date(timeIntervalSince1970: 5_000_000)
        for i in 0..<5 {
            writeFile(
                in: dir, name: String(format: "recording-20240101-000000-%03d.wav", i),
                bytes: 10, mtime: base.addingTimeInterval(TimeInterval(i * 60)))
        }
        DebugDump.pruneRecordings(now: base.addingTimeInterval(300))
        let remaining = Set(listNames(in: dir))
        XCTAssertEqual(remaining, Set([
            "recording-20240101-000000-002.wav",
            "recording-20240101-000000-003.wav",
            "recording-20240101-000000-004.wav",
        ]))
    }

    @objc func testPruneEnforcesTotalBytes() {
        let dir = makeTempDir()
        DebugDump.maxRecordingFiles = 100
        DebugDump.maxRecordingBytes = 250
        DebugDump.maxRecordingAge = 3600 * 24 * 30
        let base = Date(timeIntervalSince1970: 6_000_000)
        for i in 0..<3 {
            writeFile(
                in: dir, name: String(format: "recording-20240101-000000-%03d.wav", i),
                bytes: 100, mtime: base.addingTimeInterval(TimeInterval(i * 60)))
        }
        DebugDump.pruneRecordings(now: base.addingTimeInterval(300))
        let remaining = Set(listNames(in: dir))
        XCTAssertEqual(remaining, Set([
            "recording-20240101-000000-001.wav",
            "recording-20240101-000000-002.wav",
        ]))
    }

    @objc func testPruneEvictsFilesOlderThanMaxAge() {
        let dir = makeTempDir()
        DebugDump.maxRecordingFiles = 100
        DebugDump.maxRecordingBytes = 1_000_000_000
        DebugDump.maxRecordingAge = 3600
        let now = Date(timeIntervalSince1970: 7_000_000)
        writeFile(in: dir, name: "recording-old.wav", bytes: 10, mtime: now.addingTimeInterval(-7200))
        writeFile(in: dir, name: "recording-fresh.wav", bytes: 10, mtime: now)
        DebugDump.pruneRecordings(now: now)
        let remaining = Set(listNames(in: dir))
        XCTAssertEqual(remaining, ["recording-fresh.wav"])
    }

    // MARK: - Unexpected files and directories are never deleted

    @objc func testPruneIgnoresUnexpectedFilesAndDirectories() {
        let dir = makeTempDir()
        DebugDump.maxRecordingFiles = 0
        DebugDump.maxRecordingBytes = 0
        DebugDump.maxRecordingAge = 0
        let now = Date(timeIntervalSince1970: 8_000_000)
        writeFile(in: dir, name: "notes.txt", bytes: 10, mtime: now)
        writeFile(in: dir, name: "audio.wav", bytes: 10, mtime: now)
        writeFile(in: dir, name: "recording-notes.txt", bytes: 10, mtime: now)
        // Subdirectory (even with a managed-looking name inside) is untouched.
        let sub = (dir as NSString).appendingPathComponent("subdir.wav")
        try? FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        let nested = (sub as NSString).appendingPathComponent("recording-nested.wav")
        _ = try? Data(repeating: 0x41, count: 10).write(to: URL(fileURLWithPath: nested))
        writeFile(in: dir, name: "recording-victim.wav", bytes: 10, mtime: now)
        DebugDump.pruneRecordings(now: now)
        XCTAssertTrue(FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent("notes.txt")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent("audio.wav")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent("recording-notes.txt")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested))
        XCTAssertFalse(FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent("recording-victim.wav")))
    }

    @objc func testPruneCannotEscapeRecordingsDirectory() {
        let dir = makeTempDir()
        let outside = NSTemporaryDirectory() + "nanodictate-outside-\(UUID().uuidString).wav"
        _ = try? Data(repeating: 0x41, count: 10).write(to: URL(fileURLWithPath: outside))
        tempDirs.append(outside)
        DebugDump.maxRecordingFiles = 0
        DebugDump.maxRecordingBytes = 0
        DebugDump.maxRecordingAge = 0
        XCTAssertFalse(DebugDump.isPathInsideRecordingsDirectory(outside))
        XCTAssertTrue(DebugDump.isPathInsideRecordingsDirectory((dir as NSString).appendingPathComponent("recording-x.wav")))
        DebugDump.pruneRecordings(now: Date())
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside))
    }

    // MARK: - Cleanup errors are non-fatal

    @objc func testPruneOnMissingDirectoryDoesNotCrash() {
        DebugDump.recordingsDirectory = NSTemporaryDirectory() + "nanodictate-missing-\(UUID().uuidString)"
        DebugDump.pruneRecordings(now: Date())
        // Reachable: no throw, no crash.
        XCTAssertTrue(true)
    }

    @objc func testPruneOnFileNotDirectoryDoesNotCrash() {
        let blocker = NSTemporaryDirectory() + "nanodictate-blocker-\(UUID().uuidString)"
        _ = try? Data("x".utf8).write(to: URL(fileURLWithPath: blocker))
        tempDirs.append(blocker)
        DebugDump.recordingsDirectory = blocker
        DebugDump.pruneRecordings(now: Date())
        XCTAssertTrue(FileManager.default.fileExists(atPath: blocker))
    }
}
