import Foundation
import XCTest
@testable import VMemo

final class SnapshottingRecordingReadPortTests: XCTestCase {
    func testListSearchAndShowEachCreateAndCleanAnIndependentLease() throws {
        let fixture = try SyntheticSchemaFixture.make(
            records: [.init(id: "11111111-1111-1111-1111-111111111111", title: "Fixture", isActive: 1)]
        )
        defer { try? fixture.cleanup() }
        let snapshot = SnapshotPortFake(url: fixture.databaseURL)
        let read = SnapshottingRecordingReadPort(
            source: URL(fileURLWithPath: "/synthetic/source.sqlite"),
            destinationRoot: URL(fileURLWithPath: "/synthetic/snapshots", isDirectory: true),
            snapshot: snapshot
        )

        XCTAssertEqual(try read.list().count, 1)
        XCTAssertEqual(try read.search(query: "fixture").count, 1)
        XCTAssertEqual(try read.show(id: RecordingID(value: "11111111-1111-1111-1111-111111111111")).title, "Fixture")

        XCTAssertEqual(snapshot.createCalls, 3)
        XCTAssertEqual(snapshot.cleanupCalls, 3)
        XCTAssertEqual(snapshot.leaseIdentifiers, [0, 1, 2])
        XCTAssertEqual(snapshot.sources, Array(repeating: URL(fileURLWithPath: "/synthetic/source.sqlite"), count: 3))
        XCTAssertEqual(snapshot.destinationRoots, Array(repeating: URL(fileURLWithPath: "/synthetic/snapshots", isDirectory: true), count: 3))
    }

    func testUnsupportedSchemaAndNotFoundStillCleanLeaseExactlyOnce() throws {
        let unsupported = try SyntheticSchemaFixture.make(
            records: [.init(id: "11111111-1111-1111-1111-111111111111", title: "Fixture", isActive: 1)],
            fault: .unknownToken
        )
        defer { try? unsupported.cleanup() }
        let unsupportedSnapshot = SnapshotPortFake(url: unsupported.databaseURL)
        let unsupportedRead = makeRead(snapshot: unsupportedSnapshot)

        XCTAssertThrowsError(try unsupportedRead.list()) { error in
            XCTAssertEqual(error as? SchemaAdapterError, .unsupportedSchema)
        }
        XCTAssertEqual(unsupportedSnapshot.createCalls, 1)
        XCTAssertEqual(unsupportedSnapshot.cleanupCalls, 1)

        let missing = try SyntheticSchemaFixture.make(records: [])
        defer { try? missing.cleanup() }
        let missingSnapshot = SnapshotPortFake(url: missing.databaseURL)
        let missingRead = makeRead(snapshot: missingSnapshot)

        XCTAssertThrowsError(try missingRead.show(id: RecordingID(value: "11111111-1111-1111-1111-111111111111"))) { error in
            XCTAssertEqual(error as? SchemaAdapterError, .recordingNotFound)
        }
        XCTAssertEqual(missingSnapshot.createCalls, 1)
        XCTAssertEqual(missingSnapshot.cleanupCalls, 1)
    }

    func testSnapshotCreationFailureDoesNotAttemptCleanup() {
        let snapshot = SnapshotPortFake(url: URL(fileURLWithPath: "/synthetic/unused.sqlite"), createError: FixtureError.failed)
        let read = makeRead(snapshot: snapshot)

        XCTAssertThrowsError(try read.list()) { error in
            XCTAssertEqual(error as? SnapshottingRecordingReadError, .snapshotCreationFailed)
        }
        XCTAssertEqual(snapshot.createCalls, 1)
        XCTAssertEqual(snapshot.cleanupCalls, 0)

        let result = CommandRunner(
            read: read,
            asset: UnconfiguredAssetPort(),
            write: UnconfiguredWritePort()
        ).run(.list, output: .json)
        XCTAssertEqual(result.exitCode, ProcessExit.safetyFailure.rawValue)
        XCTAssertTrue(result.stderr.contains("snapshot_creation_failed"))
        XCTAssertFalse(result.stderr.contains("/synthetic/source.sqlite"))
        XCTAssertEqual(snapshot.cleanupCalls, 0)
    }

    func testSuccessfulBodyWithCleanupFailureReturnsStablePipelineErrorAndSafetyExit() throws {
        let fixture = try SyntheticSchemaFixture.make(records: [])
        defer { try? fixture.cleanup() }
        let snapshot = SnapshotPortFake(url: fixture.databaseURL, cleanupError: FixtureError.failed)
        let read = makeRead(snapshot: snapshot)

        XCTAssertThrowsError(try read.list()) { error in
            XCTAssertEqual(error as? SnapshottingRecordingReadError, .snapshotCleanupFailed)
        }
        XCTAssertEqual(snapshot.cleanupCalls, 1)

        let result = CommandRunner(
            read: read,
            asset: UnconfiguredAssetPort(),
            write: UnconfiguredWritePort()
        ).run(.list, output: .json)
        XCTAssertEqual(result.exitCode, ProcessExit.safetyFailure.rawValue)
        XCTAssertTrue(result.stderr.contains("snapshot_cleanup_failed"))
        XCTAssertFalse(result.stderr.contains(fixture.databaseURL.path))
    }

    func testBodyFailureWithSuccessfulCleanupPreservesBodyError() throws {
        let fixture = try SyntheticSchemaFixture.make(records: [], fault: .unknownToken)
        defer { try? fixture.cleanup() }
        let snapshot = SnapshotPortFake(url: fixture.databaseURL)
        let read = makeRead(snapshot: snapshot)

        XCTAssertThrowsError(try read.list()) { error in
            XCTAssertEqual(error as? SchemaAdapterError, .unsupportedSchema)
        }
        XCTAssertEqual(snapshot.cleanupCalls, 1)
    }

    func testCleanupFailureWinsOverBodyFailure() throws {
        let fixture = try SyntheticSchemaFixture.make(records: [], fault: .unknownToken)
        defer { try? fixture.cleanup() }
        let snapshot = SnapshotPortFake(url: fixture.databaseURL, cleanupError: FixtureError.failed)
        let read = makeRead(snapshot: snapshot)

        XCTAssertThrowsError(try read.list()) { error in
            XCTAssertEqual(error as? SnapshottingRecordingReadError, .snapshotCleanupFailed)
        }
        XCTAssertEqual(snapshot.cleanupCalls, 1)
    }

    func testSQLiteSnapshotAndSchemaAdapterIntegrationCleansCallerRootAfterEachOperation() throws {
        let fixture = try SyntheticSchemaFixture.make(
            records: [.init(id: "11111111-1111-1111-1111-111111111111", title: "Fixture", isActive: 1)]
        )
        defer { try? fixture.cleanup() }
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshotRoot = root.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotRoot, withIntermediateDirectories: false)
        let read = SnapshottingRecordingReadPort(
            source: fixture.databaseURL,
            destinationRoot: snapshotRoot,
            snapshot: SQLiteSnapshotAdapter()
        )

        XCTAssertEqual(try read.list().count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: snapshotRoot.path), [])
        XCTAssertEqual(try read.search(query: "fixture").count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: snapshotRoot.path), [])
        XCTAssertEqual(try read.show(id: RecordingID(value: "11111111-1111-1111-1111-111111111111")).title, "Fixture")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: snapshotRoot.path), [])
    }

    private func makeRead(snapshot: any SnapshotPort) -> SnapshottingRecordingReadPort {
        SnapshottingRecordingReadPort(
            source: URL(fileURLWithPath: "/synthetic/source.sqlite"),
            destinationRoot: URL(fileURLWithPath: "/synthetic/snapshots", isDirectory: true),
            snapshot: snapshot
        )
    }

    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vmemo-pipeline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}

private final class SnapshotPortFake: SnapshotPort, @unchecked Sendable {
    let url: URL
    let createError: Error?
    let cleanupError: Error?
    private(set) var createCalls = 0
    private(set) var cleanupCalls = 0
    private(set) var leaseIdentifiers: [Int] = []
    private(set) var sources: [URL] = []
    private(set) var destinationRoots: [URL] = []

    init(url: URL, createError: Error? = nil, cleanupError: Error? = nil) {
        self.url = url
        self.createError = createError
        self.cleanupError = cleanupError
    }

    func makeSnapshot(source: URL, destinationRoot: URL) throws -> any SnapshotLease {
        createCalls += 1
        sources.append(source)
        destinationRoots.append(destinationRoot)
        if let createError { throw createError }
        return Lease(url: url, identifier: createCalls - 1, owner: self)
    }

    private struct Lease: SnapshotLease {
        let url: URL
        let identifier: Int
        let owner: SnapshotPortFake

        func cleanup() throws {
            owner.cleanupCalls += 1
            owner.leaseIdentifiers.append(identifier)
            if let cleanupError = owner.cleanupError { throw cleanupError }
        }
    }
}

private enum FixtureError: Error {
    case failed
}
