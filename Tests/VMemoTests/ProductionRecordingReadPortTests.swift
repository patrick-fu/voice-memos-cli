import Foundation
import XCTest
@testable import VMemo

final class ProductionRecordingReadPortTests: XCTestCase {
    func testIdentityMismatchFailsClosedCleansSnapshotAndDoesNotReadMetadata() {
        let snapshot = ProductionSnapshotSpy()
        let metadata = ProductionMetadataSpy()
        let read = makeRead(snapshot: snapshot, metadata: metadata, identity: unsupportedIdentity)

        XCTAssertThrowsError(try read.list()) { error in
            XCTAssertEqual(error as? ProductionRecordingAdapterError, .unsupportedSchema)
        }
        XCTAssertEqual(snapshot.createCalls, 1)
        XCTAssertEqual(snapshot.cleanupCalls, 1)
        XCTAssertEqual(metadata.calls, 0)
    }

    func testCleanupFailureWinsOverBodyFailure() {
        let snapshot = ProductionSnapshotSpy(cleanupError: FixtureError.failed)
        let read = makeRead(snapshot: snapshot, metadata: ProductionMetadataSpy(), identity: unsupportedIdentity)

        XCTAssertThrowsError(try read.list()) { error in
            XCTAssertEqual(error as? SnapshottingRecordingReadError, .snapshotCleanupFailed)
        }
        XCTAssertEqual(snapshot.createCalls, 1)
        XCTAssertEqual(snapshot.cleanupCalls, 1)
    }

    func testSnapshotCreationFailureDoesNotClean() {
        let snapshot = ProductionSnapshotSpy(createError: FixtureError.failed)
        let read = makeRead(snapshot: snapshot, metadata: ProductionMetadataSpy(), identity: unsupportedIdentity)

        XCTAssertThrowsError(try read.list()) { error in
            XCTAssertEqual(error as? SnapshottingRecordingReadError, .snapshotCreationFailed)
        }
        XCTAssertEqual(snapshot.createCalls, 1)
        XCTAssertEqual(snapshot.cleanupCalls, 0)
    }

    private func makeRead(snapshot: any SnapshotPort, metadata: any PersistentStoreMetadataReading, identity: RealSchemaIdentity) -> ProductionRecordingReadPort {
        ProductionRecordingReadPort(
            source: URL(fileURLWithPath: "/fixture/source.sqlite"),
            destinationRoot: URL(fileURLWithPath: "/tmp", isDirectory: true),
            snapshot: snapshot,
            identity: identity,
            metadataReader: metadata
        )
    }
}

private let unsupportedIdentity = RealSchemaIdentity(
    osMajor: 15, bundleIdentifier: "com.apple.VoiceMemos", bundleBuild: "1380",
    hasModelArtifact: true, hasVersionInfoArtifact: true, currentModelName: "VoiceMemos14",
    archivedModelChecksum: "f2VnefWShYEiB9Sc058A/GWR/33tzv6vFKYxARhArH0=",
    modelSHA256: "551215bc009cf2ca2282c3876fb8d454d526fb5c0158c5a2818a9c2243cbe052",
    runtimeModelVersionChecksum: "Rzot3jLpeh6rB1e94kW4C0J/n0J243OW8MgFMbjWzE4=", runtimeEntityVersionHashesByName: [:]
)

private final class ProductionSnapshotSpy: SnapshotPort, @unchecked Sendable {
    let url = URL(fileURLWithPath: "/fixture/snapshot.sqlite")
    let createError: Error?
    let cleanupError: Error?
    private(set) var createCalls = 0
    private(set) var cleanupCalls = 0
    init(createError: Error? = nil, cleanupError: Error? = nil) { self.createError = createError; self.cleanupError = cleanupError }
    func makeSnapshot(source: URL, destinationRoot: URL) throws -> any SnapshotLease {
        createCalls += 1
        if let createError { throw createError }
        return Lease(url: url, owner: self)
    }
    private struct Lease: SnapshotLease {
        let url: URL
        let owner: ProductionSnapshotSpy
        func cleanup() throws { owner.cleanupCalls += 1; if let error = owner.cleanupError { throw error } }
    }
}

private final class ProductionMetadataSpy: PersistentStoreMetadataReading, @unchecked Sendable {
    private(set) var calls = 0
    func readMetadata(from isolatedSnapshot: any SnapshotLease) throws -> PersistentStoreMetadata {
        calls += 1
        throw FixtureError.failed
    }
}

private enum FixtureError: Error { case failed }
