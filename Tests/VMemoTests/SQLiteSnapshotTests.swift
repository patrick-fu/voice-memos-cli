import Foundation
import XCTest
@testable import VMemo

final class SQLiteSnapshotTests: XCTestCase {
    func testMakeSnapshotCopiesCleanCloseDatabaseInsideCallerFixtureRoot() throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try filePermissions(root), 0o700)
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        let destinationRoot = root.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let source = sourceRoot.appendingPathComponent("source.sqlite")
        try SQLiteFixture.cleanCloseDatabase(at: source, value: "committed-clean-close")
        let before = try SourceAudit.capture(root: sourceRoot)
        let port: any SnapshotPort = SQLiteSnapshotAdapter()

        let snapshot = try port.makeSnapshot(source: source, destinationRoot: destinationRoot)

        XCTAssertEqual(snapshot.url.deletingLastPathComponent().deletingLastPathComponent().path, destinationRoot.path)
        XCTAssertEqual(try filePermissions(snapshot.url), 0o600)
        XCTAssertEqual(try SQLiteFixture.textValue(at: snapshot.url, query: "SELECT value FROM fixture;"), "committed-clean-close")
        XCTAssertEqual(try SourceAudit.capture(root: sourceRoot).entries, before.entries)
        XCTAssertFalse(FileManager.default.fileExists(atPath: SQLiteFixture.walURL(for: snapshot.url).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: SQLiteFixture.shmURL(for: snapshot.url).path))

        try snapshot.cleanup()

        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.url.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destinationRoot.path), [])
    }

    func testMakeSnapshotIncludesCommittedWALRowWithoutChangingSourceEntries() throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        let destinationRoot = root.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let source = sourceRoot.appendingPathComponent("source.sqlite")
        let activeDatabase = try SQLiteFixture.activeWALDatabase(at: source, value: "committed-in-wal")
        defer { activeDatabase.close() }
        let before = try SourceAudit.capture(root: sourceRoot)

        let snapshot = try SQLiteSnapshotAdapter().makeSnapshot(source: source, destinationRoot: destinationRoot)
        defer { try? snapshot.cleanup() }

        XCTAssertEqual(try SQLiteFixture.textValue(at: snapshot.url, query: "SELECT value FROM fixture;"), "committed-in-wal")
        XCTAssertEqual(try SourceAudit.capture(root: sourceRoot).entries, before.entries)
    }

    func testMakeSnapshotRejectsMissingSourceWithoutCreatingDestinationArtifacts() throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destinationRoot = root.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])

        XCTAssertThrowsError(
            try SQLiteSnapshotAdapter().makeSnapshot(
                source: root.appendingPathComponent("missing.sqlite"),
                destinationRoot: destinationRoot
            )
        ) { error in
            XCTAssertEqual(error as? SQLiteSnapshotError, .invalidSource)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destinationRoot.path), [])
    }

    func testMakeSnapshotRejectsSourceSymlinkWithoutCreatingDestinationArtifacts() throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        let destinationRoot = root.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let target = sourceRoot.appendingPathComponent("source.sqlite")
        let sourceLink = sourceRoot.appendingPathComponent("source-link.sqlite")
        try SQLiteFixture.cleanCloseDatabase(at: target, value: "committed-clean-close")
        try FileManager.default.createSymbolicLink(at: sourceLink, withDestinationURL: target)

        XCTAssertThrowsError(try SQLiteSnapshotAdapter().makeSnapshot(source: sourceLink, destinationRoot: destinationRoot)) { error in
            XCTAssertEqual(error as? SQLiteSnapshotError, .invalidSource)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destinationRoot.path), [])
    }

    func testMakeSnapshotRejectsDestinationRootSymlink() throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        let destinationTarget = root.appendingPathComponent("snapshots-target", isDirectory: true)
        let destinationLink = root.appendingPathComponent("snapshots-link", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: destinationTarget, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let source = sourceRoot.appendingPathComponent("source.sqlite")
        try SQLiteFixture.cleanCloseDatabase(at: source, value: "committed-clean-close")
        try FileManager.default.createSymbolicLink(at: destinationLink, withDestinationURL: destinationTarget)

        XCTAssertThrowsError(try SQLiteSnapshotAdapter().makeSnapshot(source: source, destinationRoot: destinationLink)) { error in
            XCTAssertEqual(error as? SQLiteSnapshotError, .invalidDestinationRoot)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destinationTarget.path), [])
    }

    func testMakeSnapshotRejectsSourceFileURLWithQuery() throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        let destinationRoot = root.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let source = sourceRoot.appendingPathComponent("source.sqlite")
        try SQLiteFixture.cleanCloseDatabase(at: source, value: "committed-clean-close")
        let unsafeURL = try XCTUnwrap(URL(string: source.absoluteString + "?mode=rw"))

        XCTAssertThrowsError(try SQLiteSnapshotAdapter().makeSnapshot(source: unsafeURL, destinationRoot: destinationRoot)) { error in
            XCTAssertEqual(error as? SQLiteSnapshotError, .invalidSource)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destinationRoot.path), [])
    }

    func testMakeSnapshotRejectsMalformedDatabaseAndRemovesPartialSnapshot() throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        let destinationRoot = root.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let source = sourceRoot.appendingPathComponent("malformed.sqlite")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: source.path,
            contents: Data("not a sqlite database".utf8),
            attributes: [.posixPermissions: 0o600]
        ))
        let before = try SourceAudit.capture(root: sourceRoot)

        XCTAssertThrowsError(try SQLiteSnapshotAdapter().makeSnapshot(source: source, destinationRoot: destinationRoot))

        XCTAssertEqual(try SourceAudit.capture(root: sourceRoot).entries, before.entries)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destinationRoot.path), [])
    }

    func testMakeSnapshotFailsClosedWhenDestinationRootIsNotWritable() throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        let destinationRoot = root.appendingPathComponent("restricted", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o500])
        let source = sourceRoot.appendingPathComponent("source.sqlite")
        try SQLiteFixture.cleanCloseDatabase(at: source, value: "committed-clean-close")
        let before = try SourceAudit.capture(root: sourceRoot)

        XCTAssertThrowsError(try SQLiteSnapshotAdapter().makeSnapshot(source: source, destinationRoot: destinationRoot)) { error in
            XCTAssertEqual(error as? SQLiteSnapshotError, .destinationCreationFailed)
        }
        XCTAssertEqual(try SourceAudit.capture(root: sourceRoot).entries, before.entries)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destinationRoot.path), [])
    }

    func testSnapshotCleanupOnlyRemovesItsOwnDirectory() throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        let destinationRoot = root.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let source = sourceRoot.appendingPathComponent("source.sqlite")
        try SQLiteFixture.cleanCloseDatabase(at: source, value: "committed-clean-close")
        let snapshot = try SQLiteSnapshotAdapter().makeSnapshot(source: source, destinationRoot: destinationRoot)
        let sibling = destinationRoot.appendingPathComponent("keep.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: sibling.path, contents: Data("keep".utf8), attributes: [.posixPermissions: 0o600]))

        try snapshot.cleanup()

        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.url.path))
    }

    func testSnapshotCleanupFailsClosedWhenItsParentCannotBeModified() throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        let destinationRoot = root.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let source = sourceRoot.appendingPathComponent("source.sqlite")
        try SQLiteFixture.cleanCloseDatabase(at: source, value: "committed-clean-close")
        let snapshot = try SQLiteSnapshotAdapter().makeSnapshot(source: source, destinationRoot: destinationRoot)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: destinationRoot.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destinationRoot.path) }

        XCTAssertThrowsError(try snapshot.cleanup()) { error in
            XCTAssertEqual(error as? SQLiteSnapshotError, .cleanupFailed)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationRoot.path))
    }

    func testSnapshotCleanupDoesNotRemoveReplacementDirectory() throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        let destinationRoot = root.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let source = sourceRoot.appendingPathComponent("source.sqlite")
        try SQLiteFixture.cleanCloseDatabase(at: source, value: "committed-clean-close")
        let snapshot = try SQLiteSnapshotAdapter().makeSnapshot(source: source, destinationRoot: destinationRoot)
        let originalDirectory = snapshot.url.deletingLastPathComponent()
        let movedDirectory = destinationRoot.appendingPathComponent("moved-snapshot", isDirectory: true)
        try FileManager.default.moveItem(at: originalDirectory, to: movedDirectory)
        try FileManager.default.createDirectory(at: originalDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let replacement = originalDirectory.appendingPathComponent("replacement.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: replacement.path, contents: Data("replacement".utf8), attributes: [.posixPermissions: 0o600]))

        XCTAssertThrowsError(try snapshot.cleanup()) { error in
            XCTAssertEqual(error as? SQLiteSnapshotError, .cleanupFailed)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacement.path))
    }

    private func makeFixtureRoot() throws -> URL {
        var template = Array("/tmp/vmemo-snapshot-tests.XXXXXX".utf8CString)
        guard mkdtemp(&template) != nil else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let root = URL(fileURLWithPath: String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        return root
    }

    private func filePermissions(_ path: URL) throws -> Int16 {
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? Int16)
    }
}

private struct SourceAudit {
    struct Entry: Equatable {
        let name: String
        let isDirectory: Bool
        let inode: UInt64
        let size: Int64
        let mtime: Int64
        let mtimeNtime: Int32
        let permissions: Int16
    }

    let entries: [Entry]

    static func capture(root: URL) throws -> SourceAudit {
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        return SourceAudit(entries: try names.map { name in
            let path = root.appendingPathComponent(name)
            let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
            let posix = try XCTUnwrap(attributes[.posixPermissions] as? Int16)
            let type = try XCTUnwrap(attributes[.type] as? FileAttributeType)
            let inode = try XCTUnwrap(attributes[.systemFileNumber] as? UInt64)
            let size = try XCTUnwrap(attributes[.size] as? Int64)
            let date = try XCTUnwrap(attributes[.modificationDate] as? Date)
            let seconds = Int64(date.timeIntervalSince1970)
            let nanoseconds = Int32((date.timeIntervalSince1970 - Double(seconds)) * 1_000_000_000)
            return Entry(
                name: name,
                isDirectory: type == .typeDirectory,
                inode: inode,
                size: size,
                mtime: seconds,
                mtimeNtime: nanoseconds,
                permissions: posix
            )
        })
    }
}
