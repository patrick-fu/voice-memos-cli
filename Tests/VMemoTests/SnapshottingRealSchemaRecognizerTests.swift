import Foundation
import XCTest
@testable import VMemo

final class SnapshottingRealSchemaRecognizerTests: XCTestCase {
    func testCoordinatorCreatesSnapshotRecognizesAndCleansExactlyOnce() throws {
        let snapshot = CoordinatorSnapshotPortSpy()
        let reader = CoordinatorMetadataReader(result: .success(supportedStoreMetadata))
        let coordinator = makeCoordinator(snapshot: snapshot, metadataReader: reader)

        XCTAssertEqual(try coordinator.recognize(), .needsDisposableValidation)
        XCTAssertEqual(snapshot.createCalls, 1)
        XCTAssertEqual(snapshot.cleanupCalls, 1)
        XCTAssertEqual(snapshot.sources, [sourceURL])
        XCTAssertEqual(snapshot.destinationRoots, [destinationRoot])
        XCTAssertEqual(reader.snapshotURLs, [snapshot.snapshotURL])
    }

    func testSnapshotCreationFailureFailsClosedWithoutCleanupAndUsesStableCode() {
        let snapshot = CoordinatorSnapshotPortSpy(createError: CoordinatorFixtureError.failed)
        let coordinator = makeCoordinator(snapshot: snapshot, metadataReader: CoordinatorMetadataReader(result: .success(supportedStoreMetadata)))

        XCTAssertThrowsError(try coordinator.recognize()) { error in
            XCTAssertEqual(error as? SnapshottingRealSchemaRecognitionError, .snapshotCreationFailed)
        }
        XCTAssertEqual(SnapshottingRealSchemaRecognitionError.snapshotCreationFailed.code, "snapshot_creation_failed")
        XCTAssertEqual(snapshot.createCalls, 1)
        XCTAssertEqual(snapshot.cleanupCalls, 0)
    }

    func testCleanupFailureWinsOverUnsupportedRecognitionAndUsesStableCode() {
        let snapshot = CoordinatorSnapshotPortSpy(cleanupError: CoordinatorFixtureError.failed)
        let reader = CoordinatorMetadataReader(result: .failure(CoordinatorFixtureError.failed))
        let coordinator = makeCoordinator(snapshot: snapshot, metadataReader: reader)

        XCTAssertThrowsError(try coordinator.recognize()) { error in
            XCTAssertEqual(error as? SnapshottingRealSchemaRecognitionError, .snapshotCleanupFailed)
        }
        XCTAssertEqual(SnapshottingRealSchemaRecognitionError.snapshotCleanupFailed.code, "snapshot_cleanup_failed")
        XCTAssertEqual(snapshot.createCalls, 1)
        XCTAssertEqual(snapshot.cleanupCalls, 1)
        XCTAssertEqual(reader.snapshotURLs, [snapshot.snapshotURL])
    }

    private func makeCoordinator(
        snapshot: any SnapshotPort,
        metadataReader: any PersistentStoreMetadataReading
    ) -> SnapshottingRealSchemaRecognizer {
        SnapshottingRealSchemaRecognizer(
            source: sourceURL,
            destinationRoot: destinationRoot,
            snapshot: snapshot,
            identity: coordinatorIdentity,
            metadataReader: metadataReader
        )
    }
}

private let sourceURL = URL(fileURLWithPath: "/synthetic/source.sqlite")
private let destinationRoot = URL(fileURLWithPath: "/synthetic/snapshots", isDirectory: true)

private let supportedStoreMetadata = PersistentStoreMetadata(
    entityVersionHashes: .dictionary(coordinatorIdentity.runtimeEntityVersionHashesByName.mapValues(PersistentStoreMetadataValue.data)),
    isCompatibleWithRuntimeModel: true
)

private let coordinatorIdentity = RealSchemaIdentity(
    osMajor: 26,
    bundleIdentifier: "com.apple.VoiceMemos",
    bundleBuild: "1380",
    hasModelArtifact: true,
    hasVersionInfoArtifact: true,
    currentModelName: "VoiceMemos14",
    archivedModelChecksum: "f2VnefWShYEiB9Sc058A/GWR/33tzv6vFKYxARhArH0=",
    modelSHA256: "551215bc009cf2ca2282c3876fb8d454d526fb5c0158c5a2818a9c2243cbe052",
    runtimeModelVersionChecksum: "Rzot3jLpeh6rB1e94kW4C0J/n0J243OW8MgFMbjWzE4=",
    runtimeEntityVersionHashesByName: [
        "CloudRecording": Data(base64Encoded: "Q5vgte0JyNzGeRWTSQMvMe/yCVv4FqwlLinaPgrxQpw=")!,
        "DatabaseProperty": Data(base64Encoded: "DdeyItMrmgzYUVyA8NUAc8cS1Sr4LwwTo+KneZZrPBI=")!,
        "EntityRevision": Data(base64Encoded: "MCYSLwlQNrzkytEuk0Paa2vv7h+rbxnn3DWtIuHpxa0=")!,
        "Folder": Data(base64Encoded: "BTuJxZB4F1ci2UMqAPo0Fx2Oif08rXM0z+/UQoivHc0=")!,
        "Migration": Data(base64Encoded: "C9+RC8Owb0OTnIogkfdqVeaZV1hChUC6VuqvEwC0DUU=")!,
        "Recording": Data(base64Encoded: "l+6Nf+h4pgpvs9n/EqyKB5n5y0F2UwNh6/6d/evM+L8=")!,
    ]
)

private final class CoordinatorSnapshotPortSpy: SnapshotPort, @unchecked Sendable {
    let snapshotURL = URL(fileURLWithPath: "/synthetic/isolated.sqlite")
    let createError: Error?
    let cleanupError: Error?
    private(set) var createCalls = 0
    private(set) var cleanupCalls = 0
    private(set) var sources: [URL] = []
    private(set) var destinationRoots: [URL] = []

    init(createError: Error? = nil, cleanupError: Error? = nil) {
        self.createError = createError
        self.cleanupError = cleanupError
    }

    func makeSnapshot(source: URL, destinationRoot: URL) throws -> any SnapshotLease {
        createCalls += 1
        sources.append(source)
        destinationRoots.append(destinationRoot)
        if let createError { throw createError }
        return Lease(url: snapshotURL, owner: self)
    }

    private struct Lease: SnapshotLease {
        let url: URL
        let owner: CoordinatorSnapshotPortSpy

        func cleanup() throws {
            owner.cleanupCalls += 1
            if let cleanupError = owner.cleanupError { throw cleanupError }
        }
    }
}

private final class CoordinatorMetadataReader: PersistentStoreMetadataReading, @unchecked Sendable {
    enum Result {
        case success(PersistentStoreMetadata)
        case failure(any Error)
    }

    let result: Result
    private(set) var snapshotURLs: [URL] = []

    init(result: Result) {
        self.result = result
    }

    func readMetadata(from isolatedSnapshot: any SnapshotLease) throws -> PersistentStoreMetadata {
        snapshotURLs.append(isolatedSnapshot.url)
        switch result {
        case let .success(metadata): return metadata
        case let .failure(error): throw error
        }
    }
}

private enum CoordinatorFixtureError: Error {
    case failed
}
