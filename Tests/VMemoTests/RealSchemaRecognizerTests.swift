import Foundation
import XCTest
@testable import VMemo

final class RealSchemaRecognizerTests: XCTestCase {
    func testRecognitionCodesAreStable() {
        XCTAssertEqual(RealSchemaRecognition.needsDisposableValidation.code, "needs_disposable_validation")
        XCTAssertEqual(RealSchemaRecognition.unsupportedSchema.code, "unsupported_schema")
    }

    func testExactDocumentedEvidenceIsRecognizedButStillBlockedForDisposableValidation() {
        let reader = FakePersistentStoreMetadataReader(
            result: .success(metadata(compatibleWithRuntimeModel: true))
        )
        let recognizer = RealSchemaRecognizer(identity: supportedIdentity, metadataReader: reader)

        XCTAssertEqual(recognizer.recognize(snapshot: isolatedSnapshot), .needsDisposableValidation)
        XCTAssertEqual(reader.snapshotURLs, [isolatedSnapshotURL])
    }

    func testUnknownOSBuildModelAndChecksumsFailClosed() {
        let mutations: [(inout RealSchemaIdentity) -> Void] = [
            { $0.osMajor = 15 },
            { $0.osMajor = 27 },
            { $0.bundleIdentifier = "com.example.VoiceMemos" },
            { $0.bundleBuild = "1381" },
            { $0.hasModelArtifact = false },
            { $0.hasVersionInfoArtifact = false },
            { $0.currentModelName = "VoiceMemos13" },
            { $0.archivedModelChecksum = "not-the-documented-checksum" },
            { $0.modelSHA256 = "not-the-documented-sha256" },
            { $0.runtimeModelVersionChecksum = "not-the-documented-runtime-checksum" },
            { $0.runtimeEntityVersionHashesByName["CloudRecording"] = Data(repeating: 0, count: 32) },
        ]

        for mutate in mutations {
            var identity = supportedIdentity
            mutate(&identity)
            XCTAssertEqual(
                recognize(identity: identity, storeMetadata: metadata(compatibleWithRuntimeModel: true)),
                .unsupportedSchema
            )
        }
    }

    func testMissingOrExtraRuntimeEntityHashFailsClosed() {
        var missing = supportedIdentity
        missing.runtimeEntityVersionHashesByName.removeValue(forKey: "Recording")
        XCTAssertEqual(
            recognize(identity: missing, storeMetadata: metadata(compatibleWithRuntimeModel: true)),
            .unsupportedSchema
        )

        var extra = supportedIdentity
        extra.runtimeEntityVersionHashesByName["Unexpected"] = Data(repeating: 0, count: 32)
        XCTAssertEqual(
            recognize(identity: extra, storeMetadata: metadata(compatibleWithRuntimeModel: true)),
            .unsupportedSchema
        )
    }

    func testMissingOrExtraStoreEntityHashFailsClosed() {
        var missingHashes = storeHashes()
        missingHashes.removeValue(forKey: "Recording")
        let missing = PersistentStoreMetadata(
            entityVersionHashes: .dictionary(missingHashes),
            isCompatibleWithRuntimeModel: true
        )
        XCTAssertEqual(recognize(storeMetadata: missing), .unsupportedSchema)

        var extraHashes = storeHashes()
        extraHashes["Unexpected"] = .data(Data(repeating: 0, count: 32))
        let extra = PersistentStoreMetadata(
            entityVersionHashes: .dictionary(extraHashes),
            isCompatibleWithRuntimeModel: true
        )
        XCTAssertEqual(recognize(storeMetadata: extra), .unsupportedSchema)
    }

    func testStoreEntityHashWrongLengthValueOrRepresentationFailsClosed() {
        var wrongLengthHashes = storeHashes()
        wrongLengthHashes["CloudRecording"] = .data(Data(repeating: 0, count: 31))
        let wrongLength = PersistentStoreMetadata(
            entityVersionHashes: .dictionary(wrongLengthHashes),
            isCompatibleWithRuntimeModel: true
        )
        XCTAssertEqual(recognize(storeMetadata: wrongLength), .unsupportedSchema)

        var wrongValueHashes = storeHashes()
        var altered = try! XCTUnwrap(supportedIdentity.runtimeEntityVersionHashesByName["CloudRecording"])
        altered[altered.startIndex] ^= 0x01
        wrongValueHashes["CloudRecording"] = .data(altered)
        let wrongValue = PersistentStoreMetadata(
            entityVersionHashes: .dictionary(wrongValueHashes),
            isCompatibleWithRuntimeModel: true
        )
        XCTAssertEqual(recognize(storeMetadata: wrongValue), .unsupportedSchema)

        var wrongRepresentationHashes = storeHashes()
        wrongRepresentationHashes["CloudRecording"] = .unsupportedValue
        let wrongRepresentation = PersistentStoreMetadata(
            entityVersionHashes: .dictionary(wrongRepresentationHashes),
            isCompatibleWithRuntimeModel: true
        )
        XCTAssertEqual(recognize(storeMetadata: wrongRepresentation), .unsupportedSchema)

        XCTAssertEqual(
            recognize(storeMetadata: PersistentStoreMetadata(entityVersionHashes: .unsupportedRepresentation, isCompatibleWithRuntimeModel: true)),
            .unsupportedSchema
        )
    }

    func testCompatibilityFailureFailsClosedEvenWithExactHashes() {
        XCTAssertEqual(
            recognize(storeMetadata: metadata(compatibleWithRuntimeModel: false)),
            .unsupportedSchema
        )
    }

    func testMetadataReaderErrorFailsClosed() {
        let reader = FakePersistentStoreMetadataReader(result: .failure(FixtureError.metadataUnavailable))
        let recognizer = RealSchemaRecognizer(identity: supportedIdentity, metadataReader: reader)

        XCTAssertEqual(recognizer.recognize(snapshot: isolatedSnapshot), .unsupportedSchema)
        XCTAssertEqual(reader.snapshotURLs, [isolatedSnapshotURL])
    }

    func testRecognizerHasOnlyMetadataReaderSeamAndNeverProjectsRecordings() {
        let reader = FakePersistentStoreMetadataReader(
            result: .success(metadata(compatibleWithRuntimeModel: true))
        )

        _ = RealSchemaRecognizer(identity: supportedIdentity, metadataReader: reader)
            .recognize(snapshot: isolatedSnapshot)

        XCTAssertEqual(reader.snapshotURLs, [isolatedSnapshotURL])
    }

    private func recognize(
        identity: RealSchemaIdentity = supportedIdentity,
        storeMetadata: PersistentStoreMetadata
    ) -> RealSchemaRecognition {
        RealSchemaRecognizer(
            identity: identity,
            metadataReader: FakePersistentStoreMetadataReader(result: .success(storeMetadata))
        ).recognize(snapshot: isolatedSnapshot)
    }

    private func metadata(compatibleWithRuntimeModel: Bool) -> PersistentStoreMetadata {
        PersistentStoreMetadata(
            entityVersionHashes: .dictionary(storeHashes()),
            isCompatibleWithRuntimeModel: compatibleWithRuntimeModel
        )
    }

    private func storeHashes() -> [String: PersistentStoreMetadataValue] {
        supportedIdentity.runtimeEntityVersionHashesByName.mapValues(PersistentStoreMetadataValue.data)
    }
}

private let isolatedSnapshotURL = URL(fileURLWithPath: "/tmp/vmemo-isolated-snapshot.sqlite")
private let isolatedSnapshot = FakeSnapshotLease(url: isolatedSnapshotURL)

private let supportedIdentity = RealSchemaIdentity(
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

private final class FakePersistentStoreMetadataReader: PersistentStoreMetadataReading, @unchecked Sendable {
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

private enum FixtureError: Error {
    case metadataUnavailable
}

private struct FakeSnapshotLease: SnapshotLease {
    let url: URL

    func cleanup() throws {}
}
