import Foundation
import XCTest
@testable import VMemo

final class ProductionMutationResolverTests: XCTestCase {
    func testResolveRenameReturnsActiveUniqueTargetAndCommitSink() throws {
        let fixture = try library([
            .init(id: "recording-sink", title: "Sink title", path: "sink.m4a", eviction: .null),
            .init(id: "recording-target", title: "Target title", path: "target.m4a", eviction: .null),
        ])
        defer { fixture.cleanup() }

        let resolved = try ProductionMutationResolver(snapshotURL: fixture.databaseURL).resolve(renameRequest())

        XCTAssertEqual(resolved.id, RecordingID(value: "recording-target"))
        XCTAssertEqual(resolved.currentTitle, "Target title")
        XCTAssertTrue(resolved.isActive)
        XCTAssertEqual(resolved.effect, .rename(
            expectedTitle: "Renamed title",
            commitSink: MutationCommitSink(id: RecordingID(value: "recording-sink"), title: "Sink title")
        ))
        XCTAssertEqual(resolved.sourceFingerprint.count, 64)
        assertNoSecrets(resolved.sourceFingerprint)
    }

    func testDuplicateActiveTitleFailsClosed() throws {
        try assertResolve(
            rows: [
                .init(id: "recording-sink", title: "Sink title", path: "sink.m4a", eviction: .null),
                .init(id: "recording-other", title: "Target title", path: "other.m4a", eviction: .null),
                .init(id: "recording-target", title: "Target title", path: "target.m4a", eviction: .null),
            ],
            request: renameRequest(),
            error: ProductionMutationResolverError.ambiguousTitle
        )
    }

    func testDuplicateRecentTitleFailsClosed() throws {
        try assertResolve(
            rows: [
                .init(id: "recording-sink", title: "Sink title", path: "sink.m4a", eviction: .null),
                .init(id: "recording-recent", title: "Target title", path: "recent.m4a", eviction: .real(1)),
                .init(id: "recording-target", title: "Target title", path: "target.m4a", eviction: .null),
            ],
            request: renameRequest(),
            error: ProductionMutationResolverError.ambiguousTitle
        )
    }

    func testMissingCommitSinkFailsClosed() throws {
        try assertResolve(
            rows: [
                .init(id: "recording-recent", title: "Recent title", path: "recent.m4a", eviction: .real(1)),
                .init(id: "recording-target", title: "Target title", path: "target.m4a", eviction: .null),
            ],
            request: renameRequest(),
            error: ProductionMutationResolverError.missingCommitSink
        )
    }

    func testDuplicateCommitSinkFailsClosed() throws {
        try assertResolve(
            rows: [
                .init(id: "recording-a", title: "Shared sink", path: "a.m4a", eviction: .null),
                .init(id: "recording-b", title: "Shared sink", path: "b.m4a", eviction: .null),
                .init(id: "recording-target", title: "Target title", path: "target.m4a", eviction: .null),
            ],
            request: renameRequest(),
            error: ProductionMutationResolverError.duplicateCommitSink
        )
    }

    func testEmptySameAndConflictingNewTitlesFailClosed() throws {
        let rows = [
            ProductionStoreFixture.Row(id: "recording-sink", title: "Sink title", path: "sink.m4a", eviction: .null),
            .init(id: "recording-recent", title: "Recent title", path: "recent.m4a", eviction: .real(1)),
            .init(id: "recording-target", title: "Target title", path: "target.m4a", eviction: .null),
        ]
        try assertResolve(rows: rows, request: renameRequest(""), error: ProductionMutationResolverError.invalidNewTitle)
        try assertResolve(rows: rows, request: renameRequest("Target title"), error: ProductionMutationResolverError.unchangedTitle)
        try assertResolve(rows: rows, request: renameRequest("Sink title"), error: ProductionMutationResolverError.conflictingTitle)
        try assertResolve(rows: rows, request: renameRequest("Recent title"), error: ProductionMutationResolverError.conflictingTitle)
    }

    func testInactiveTargetFailsClosed() throws {
        try assertResolve(
            rows: [
                .init(id: "recording-sink", title: "Sink title", path: "sink.m4a", eviction: .null),
                .init(id: "recording-target", title: "Target title", path: "target.m4a", eviction: .real(1)),
            ],
            request: renameRequest(),
            error: ProductionMutationResolverError.inactiveTarget
        )
    }

    func testDeleteRequiresUniqueActiveTitleAbsentFromRecent() throws {
        let fixture = try library([
            .init(id: "recording-sink", title: "Sink title", path: "sink.m4a", eviction: .null),
            .init(id: "recording-target", title: "Target title", path: "target.m4a", eviction: .null),
        ])
        defer { fixture.cleanup() }

        let resolved = try ProductionMutationResolver(snapshotURL: fixture.databaseURL).resolve(deleteRequest())
        XCTAssertEqual(resolved.effect, .moveToRecentlyDeleted)
        XCTAssertEqual(resolved.currentTitle, "Target title")
        XCTAssertTrue(resolved.isActive)
    }

    func testFreshRenamePostconditionSuccessAndFailure() throws {
        let pre = try library(uniqueLibrary())
        let post = try library([
            .init(id: "recording-sink", title: "Sink title", path: "sink.m4a", eviction: .null),
            .init(id: "recording-target", title: "Renamed title", path: "target.m4a", eviction: .null),
        ])
        let failed = try library(uniqueLibrary())
        defer {
            pre.cleanup()
            post.cleanup()
            failed.cleanup()
        }
        let expected = try ProductionMutationResolver(snapshotURL: pre.databaseURL).resolve(renameRequest())

        try ProductionMutationResolver(snapshotURL: post.databaseURL).verifyPostcondition(expected)
        XCTAssertThrowsError(try ProductionMutationResolver(snapshotURL: failed.databaseURL).verifyPostcondition(expected)) { error in
            assertPrivacySafe(error, ProductionMutationResolverError.postconditionFailed)
        }
    }

    func testFreshDeletePostconditionSuccessAndFailure() throws {
        let pre = try library(uniqueLibrary())
        let post = try library([
            .init(id: "recording-sink", title: "Sink title", path: "sink.m4a", eviction: .null),
            .init(id: "recording-target", title: "Target title", path: "target.m4a", eviction: .real(2.5)),
        ])
        let failed = try library(uniqueLibrary())
        defer {
            pre.cleanup()
            post.cleanup()
            failed.cleanup()
        }
        let expected = try ProductionMutationResolver(snapshotURL: pre.databaseURL).resolve(deleteRequest())

        try ProductionMutationResolver(snapshotURL: post.databaseURL).verifyPostcondition(expected)
        XCTAssertThrowsError(try ProductionMutationResolver(snapshotURL: failed.databaseURL).verifyPostcondition(expected)) { error in
            assertPrivacySafe(error, ProductionMutationResolverError.postconditionFailed)
        }
    }

    func testUnknownRowTypeRejectsWholeSnapshot() throws {
        let fixture = try ProductionStoreFixture.make(
            rows: uniqueLibrary(),
            fault: .integerEviction
        )
        defer { fixture.cleanup() }
        XCTAssertThrowsError(try ProductionMutationResolver(snapshotURL: fixture.databaseURL).resolve(renameRequest())) { error in
            assertPrivacySafe(error, ProductionRecordingAdapterError.unsupportedSchema)
        }
    }

    func testUnknownSiblingRowTypeRejectsValidTarget() throws {
        try assertResolve(
            rows: [
                .init(id: "recording-invalid", title: "Other title", path: "other.m4a", eviction: .integer),
                .init(id: "recording-sink", title: "Sink title", path: "sink.m4a", eviction: .null),
                .init(id: "recording-target", title: "Target title", path: "target.m4a", eviction: .null),
            ],
            request: renameRequest(),
            error: ProductionRecordingAdapterError.unsupportedSchema
        )
    }

    func testSourceFingerprintDriftFailsClosed() throws {
        let original = try library(uniqueLibrary())
        let drifted = try library([
            .init(id: "recording-extra", title: "Extra title", path: "extra.m4a", eviction: .null),
            .init(id: "recording-sink", title: "Sink title", path: "sink.m4a", eviction: .null),
            .init(id: "recording-target", title: "Target title", path: "target.m4a", eviction: .null),
        ])
        defer {
            original.cleanup()
            drifted.cleanup()
        }
        let expected = try ProductionMutationResolver(snapshotURL: original.databaseURL).resolve(renameRequest())
        try ProductionMutationResolver(snapshotURL: original.databaseURL).verifySourceFingerprint(expected)
        XCTAssertThrowsError(
            try ProductionMutationResolver(snapshotURL: drifted.databaseURL).verifySourceFingerprint(expected)
        ) { error in
            assertPrivacySafe(error, ProductionMutationResolverError.sourceFingerprintDrift)
        }
    }

    func testDeleteDuplicateActiveTitleFailsClosed() throws {
        try assertResolve(
            rows: [
                .init(id: "recording-sink", title: "Sink title", path: "sink.m4a", eviction: .null),
                .init(id: "recording-other", title: "Target title", path: "other.m4a", eviction: .null),
                .init(id: "recording-target", title: "Target title", path: "target.m4a", eviction: .null),
            ],
            request: deleteRequest(),
            error: ProductionMutationResolverError.ambiguousTitle
        )
    }

    func testDeleteDuplicateRecentTitleFailsClosed() throws {
        try assertResolve(
            rows: [
                .init(id: "recording-sink", title: "Sink title", path: "sink.m4a", eviction: .null),
                .init(id: "recording-recent", title: "Target title", path: "recent.m4a", eviction: .real(1)),
                .init(id: "recording-target", title: "Target title", path: "target.m4a", eviction: .null),
            ],
            request: deleteRequest(),
            error: ProductionMutationResolverError.ambiguousTitle
        )
    }

    func testNFCAndNFDTitlesAreDistinctMutationIdentities() throws {
        XCTAssertEqual(UnicodeExactFixture.nfcEAcute, UnicodeExactFixture.nfdEAcute)
        XCTAssertFalse(utf8ExactEqual(UnicodeExactFixture.nfcEAcute, UnicodeExactFixture.nfdEAcute))
        let fixture = try library([
            .init(id: "recording-sink", title: "Sink title", path: "sink.m4a", eviction: .null),
            .init(id: "recording-nfc", title: UnicodeExactFixture.nfcEAcute, path: "nfc.m4a", eviction: .null),
            .init(id: "recording-nfd", title: UnicodeExactFixture.nfdEAcute, path: "nfd.m4a", eviction: .null),
        ])
        defer { fixture.cleanup() }
        let resolver = ProductionMutationResolver(snapshotURL: fixture.databaseURL)

        let nfc = try resolver.resolve(
            MutationRequest(id: RecordingID(value: "recording-nfc"), operation: .rename(title: "Renamed title"))
        )
        XCTAssertTrue(utf8ExactEqual(nfc.currentTitle, UnicodeExactFixture.nfcEAcute))

        let nfdLookup = MutationRequest(
            id: RecordingID(value: "recording-nfd"),
            operation: .rename(title: UnicodeExactFixture.nfcEAcute)
        )
        XCTAssertThrowsError(try resolver.resolve(nfdLookup)) { error in
            assertPrivacySafe(error, ProductionMutationResolverError.conflictingTitle)
        }

        XCTAssertThrowsError(
            try resolver.resolve(
                MutationRequest(id: RecordingID(value: "recording-nfc"), operation: .rename(title: UnicodeExactFixture.nfcEAcute))
            )
        ) { error in
            assertPrivacySafe(error, ProductionMutationResolverError.unchangedTitle)
        }
    }

    func testNFDLookupDoesNotMatchNFCRecordingID() throws {
        let fixture = try library([
            .init(id: "id-" + UnicodeExactFixture.nfcEAcute, title: "Target title", path: "target.m4a", eviction: .null),
            .init(id: "recording-sink", title: "Sink title", path: "sink.m4a", eviction: .null),
        ])
        defer { fixture.cleanup() }
        XCTAssertThrowsError(
            try ProductionMutationResolver(snapshotURL: fixture.databaseURL).resolve(
                MutationRequest(id: RecordingID(value: "id-" + UnicodeExactFixture.nfdEAcute), operation: .rename(title: "Renamed title"))
            )
        ) { error in
            assertPrivacySafe(error, ProductionRecordingAdapterError.recordingNotFound)
        }
    }

    func testRenamePostconditionRejectsCanonicalEquivalentTitle() throws {
        let pre = try library(uniqueLibrary())
        let nfcPost = try library([
            .init(id: "recording-sink", title: "Sink title", path: "sink.m4a", eviction: .null),
            .init(id: "recording-target", title: UnicodeExactFixture.nfcEAcute, path: "target.m4a", eviction: .null),
        ])
        let nfdPost = try library([
            .init(id: "recording-sink", title: "Sink title", path: "sink.m4a", eviction: .null),
            .init(id: "recording-target", title: UnicodeExactFixture.nfdEAcute, path: "target.m4a", eviction: .null),
        ])
        defer {
            pre.cleanup()
            nfcPost.cleanup()
            nfdPost.cleanup()
        }
        let expected = try ProductionMutationResolver(snapshotURL: pre.databaseURL).resolve(
            renameRequest(UnicodeExactFixture.nfcEAcute)
        )
        try ProductionMutationResolver(snapshotURL: nfcPost.databaseURL).verifyPostcondition(expected)
        XCTAssertThrowsError(try ProductionMutationResolver(snapshotURL: nfdPost.databaseURL).verifyPostcondition(expected)) { error in
            assertPrivacySafe(error, ProductionMutationResolverError.postconditionFailed)
        }
    }

    func testSourceFingerprintDoesNotCollideOnEmbeddedSeparators() throws {
        let left = try library([
            .init(id: "a", title: "x\u{1e}y", path: "left.m4a", eviction: .null),
            .init(id: "recording-sink", title: "Sink title", path: "sink.m4a", eviction: .null),
            .init(id: "recording-target", title: "Target title", path: "target.m4a", eviction: .null),
        ])
        let right = try library([
            .init(id: "a\u{1e}x", title: "y", path: "right.m4a", eviction: .null),
            .init(id: "recording-sink", title: "Sink title", path: "sink.m4a", eviction: .null),
            .init(id: "recording-target", title: "Target title", path: "target.m4a", eviction: .null),
        ])
        defer {
            left.cleanup()
            right.cleanup()
        }
        let leftFingerprint = try ProductionRecordingAdapter(snapshotURL: left.databaseURL).validatedProjection().fingerprint
        let rightFingerprint = try ProductionRecordingAdapter(snapshotURL: right.databaseURL).validatedProjection().fingerprint
        XCTAssertNotEqual(leftFingerprint, rightFingerprint)
        XCTAssertEqual(leftFingerprint.count, 64)
        XCTAssertEqual(rightFingerprint.count, 64)
    }

    func testMissingRecordingUsesStableNotFoundCode() throws {
        let fixture = try library([
            .init(id: "recording-sink", title: "Sink title", path: "sink.m4a", eviction: .null),
        ])
        defer { fixture.cleanup() }
        XCTAssertThrowsError(try ProductionMutationResolver(snapshotURL: fixture.databaseURL).resolve(renameRequest())) { error in
            assertPrivacySafe(error, ProductionRecordingAdapterError.recordingNotFound)
        }
    }
}

private func uniqueLibrary() -> [ProductionStoreFixture.Row] {
    [
        .init(id: "recording-sink", title: "Sink title", path: "sink.m4a", eviction: .null),
        .init(id: "recording-target", title: "Target title", path: "target.m4a", eviction: .null),
    ]
}

private func library(_ rows: [ProductionStoreFixture.Row]) throws -> ProductionStoreFixture {
    try ProductionStoreFixture.make(rows: rows)
}

private func renameRequest(_ title: String = "Renamed title") -> MutationRequest {
    MutationRequest(id: RecordingID(value: "recording-target"), operation: .rename(title: title))
}

private func deleteRequest() -> MutationRequest {
    MutationRequest(id: RecordingID(value: "recording-target"), operation: .moveToRecentlyDeleted)
}

private func assertResolve<E: Equatable>(
    rows: [ProductionStoreFixture.Row],
    request: MutationRequest,
    error expected: E
) throws {
    let fixture = try library(rows)
    defer { fixture.cleanup() }
    XCTAssertThrowsError(try ProductionMutationResolver(snapshotURL: fixture.databaseURL).resolve(request)) { error in
        assertPrivacySafe(error, expected)
    }
}

private func assertPrivacySafe<E: Equatable>(_ error: Error, _ expected: E) {
    XCTAssertEqual(error as? E, expected)
    let rendered: String
    if let error = error as? ProductionMutationResolverError {
        rendered = error.code + error.message
    } else if let error = error as? ProductionRecordingAdapterError {
        rendered = error.code + error.message
    } else {
        rendered = String(describing: error)
    }
    assertNoSecrets(rendered)
}

private func assertNoSecrets(_ text: String) {
    for secret in ["recording-target", "recording-sink", "Target title", "Sink title", "Renamed title", "Recent title", "Shared sink"] {
        XCTAssertFalse(text.contains(secret), "error text leaked a fixture identifier")
    }
}
