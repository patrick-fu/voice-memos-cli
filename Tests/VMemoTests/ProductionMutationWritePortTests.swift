import Foundation
import XCTest
@testable import VMemo

final class ProductionMutationWritePortTests: XCTestCase {
    func testDryRunFromOnePortExecutesOnceFromAnotherPort() throws {
        let fixture = try WritePortFixture()
        defer { fixture.cleanup() }
        let request = MutationRequest(id: RecordingID(value: "recording-fixture"), operation: .rename(title: "Updated"))
        let first = fixture.makePort()
        let second = fixture.makePort()

        let plan = try first.dryRun(request)
        let result = try second.execute(request, authorization: MutationAuthorization(token: plan.confirmationToken, confirmed: true))
        XCTAssertEqual(result.id, request.id)
        XCTAssertEqual(result.operation, "rename")
        XCTAssertEqual(fixture.accessibility.actions, [.rename])
        XCTAssertThrowsError(try first.execute(request, authorization: MutationAuthorization(token: plan.confirmationToken, confirmed: true))) { error in
            XCTAssertEqual(error as? ProductionMutationWriteError, .tokenReplayed)
        }
    }

    func testUnconfirmedExecutionDoesNotCreateStore() throws {
        let fixture = try WritePortFixture()
        defer { fixture.cleanup() }
        let request = MutationRequest(id: RecordingID(value: "recording-fixture"), operation: .moveToRecentlyDeleted)

        XCTAssertThrowsError(try fixture.makePort().execute(request, authorization: MutationAuthorization(token: "unused", confirmed: false))) { error in
            XCTAssertEqual(error as? ProductionMutationWriteError, .confirmationRequired)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.tokenRoot.path))
    }

    func testDeleteExecutesTheTypedDeleteActionAndVerifiesBothPostconditions() throws {
        let fixture = try WritePortFixture()
        defer { fixture.cleanup() }
        let request = MutationRequest(id: RecordingID(value: "recording-fixture"), operation: .moveToRecentlyDeleted)
        let port = fixture.makePort()

        let plan = try port.dryRun(request)
        let result = try port.execute(request, authorization: MutationAuthorization(token: plan.confirmationToken, confirmed: true))

        XCTAssertEqual(result.operation, "moveToRecentlyDeleted")
        XCTAssertEqual(fixture.accessibility.actions, [.delete])
        XCTAssertEqual(fixture.resolver.postconditionCalls, 1)
        XCTAssertEqual(fixture.accessibility.postconditionCalls, 1)
    }

    func testAXOrDatabasePostconditionFailureLeavesTokenConsumed() throws {
        let fixture = try WritePortFixture()
        defer { fixture.cleanup() }
        let request = MutationRequest(id: RecordingID(value: "recording-fixture"), operation: .moveToRecentlyDeleted)
        let port = fixture.makePort()
        let plan = try port.dryRun(request)
        fixture.resolver.postconditionError = FixtureWriteError.failed

        XCTAssertThrowsError(try port.execute(request, authorization: MutationAuthorization(token: plan.confirmationToken, confirmed: true))) { error in
            XCTAssertEqual(error as? ProductionMutationWriteError, .postconditionFailed)
        }
        XCTAssertThrowsError(try port.execute(request, authorization: MutationAuthorization(token: plan.confirmationToken, confirmed: true))) { error in
            XCTAssertEqual(error as? ProductionMutationWriteError, .tokenReplayed)
        }
    }

    func testActionTimeoutLeavesTokenConsumed() throws {
        let fixture = try WritePortFixture()
        defer { fixture.cleanup() }
        let request = MutationRequest(id: RecordingID(value: "recording-fixture"), operation: .moveToRecentlyDeleted)
        let port = fixture.makePort()
        let plan = try port.dryRun(request)
        fixture.accessibility.actionError = FixtureWriteError.failed

        XCTAssertThrowsError(try port.execute(request, authorization: MutationAuthorization(token: plan.confirmationToken, confirmed: true))) { error in
            XCTAssertEqual(error as? ProductionMutationWriteError, .postconditionFailed)
        }
        XCTAssertThrowsError(try port.execute(request, authorization: MutationAuthorization(token: plan.confirmationToken, confirmed: true))) { error in
            XCTAssertEqual(error as? ProductionMutationWriteError, .tokenReplayed)
        }
    }

    func testExpirySourceEnvironmentAndAXDriftRejectBeforeConsuming() throws {
        let fixture = try WritePortFixture()
        defer { fixture.cleanup() }
        let request = MutationRequest(id: RecordingID(value: "recording-fixture"), operation: .moveToRecentlyDeleted)

        let expired = try fixture.makePort().dryRun(request)
        fixture.clock.now = fixture.clock.now.addingTimeInterval(31)
        XCTAssertThrowsError(try fixture.makePort().execute(request, authorization: MutationAuthorization(token: expired.confirmationToken, confirmed: true))) { error in
            XCTAssertEqual(error as? ProductionMutationWriteError, .tokenExpired)
        }

        fixture.clock.now = Date(timeIntervalSince1970: 1_700_000_000)
        let source = try fixture.makePort().dryRun(request)
        fixture.resolver.sourceFingerprint = "changed-source-fingerprint"
        XCTAssertThrowsError(try fixture.makePort().execute(request, authorization: MutationAuthorization(token: source.confirmationToken, confirmed: true))) { error in
            XCTAssertEqual(error as? ProductionMutationWriteError, .tokenBindingMismatch)
        }

        fixture.resolver.sourceFingerprint = "source-fingerprint"
        let environment = try fixture.makePort().dryRun(request)
        fixture.environment.value = "changed-environment"
        XCTAssertThrowsError(try fixture.makePort().execute(request, authorization: MutationAuthorization(token: environment.confirmationToken, confirmed: true))) { error in
            XCTAssertEqual(error as? ProductionMutationWriteError, .tokenBindingMismatch)
        }

        fixture.environment.value = "environment"
        let ax = try fixture.makePort().dryRun(request)
        fixture.accessibility.bundleBuild = "different-build"
        XCTAssertThrowsError(try fixture.makePort().execute(request, authorization: MutationAuthorization(token: ax.confirmationToken, confirmed: true))) { error in
            XCTAssertEqual(error as? ProductionMutationWriteError, .tokenBindingMismatch)
        }
    }

    func testBusySessionFailsClosedAndPersistedRecordsContainOnlyHashes() throws {
        let fixture = try WritePortFixture()
        defer { fixture.cleanup() }
        let store = try PersistentMutationTokenStore(rootDirectory: fixture.tokenRoot)
        let lock = try store.acquireMutationSession()
        defer { lock.release() }
        let request = MutationRequest(id: RecordingID(value: "recording-fixture"), operation: .moveToRecentlyDeleted)

        XCTAssertThrowsError(try fixture.makePort().dryRun(request)) { error in
            XCTAssertEqual(error as? ProductionMutationWriteError, .sessionBusy)
        }
        lock.release()
        _ = try fixture.makePort().dryRun(request)
        for path in try FileManager.default.contentsOfDirectory(at: fixture.tokenRoot, includingPropertiesForKeys: nil) {
            let contents = try String(decoding: Data(contentsOf: path), as: UTF8.self)
            XCTAssertFalse(contents.contains("recording-fixture"))
            XCTAssertFalse(contents.contains("Current"))
            XCTAssertFalse(contents.contains("\"environment\""))
        }
    }
}

private final class WritePortFixture: @unchecked Sendable {
    let root: URL
    let tokenRoot: URL
    let resolver = FixtureMutationResolver()
    let accessibility = FixtureAccessibility()
    let clock = FixtureClock()
    let environment = FixtureEnvironment()
    let nonceGenerator = FixtureNonceGenerator()

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vmemo-write-port-\(UUID().uuidString)", isDirectory: true)
        tokenRoot = root.appendingPathComponent("tokens", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    func makePort() -> ProductionMutationWritePort {
        ProductionMutationWritePort(
            resolver: resolver,
            accessibility: accessibility,
            tokenStoreFactory: FilePersistentMutationTokenStoreFactory(rootDirectory: tokenRoot),
            clock: clock,
            nonceGenerator: nonceGenerator,
            environment: environment,
            tokenTTL: 30
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private final class FixtureMutationResolver: ProductionMutationResolving, @unchecked Sendable {
    var postconditionError: Error?
    var sourceFingerprint = "source-fingerprint"
    private(set) var postconditionCalls = 0
    func resolve(_ request: MutationRequest) throws -> ResolvedMutationTarget {
        ResolvedMutationTarget(
            id: request.id,
            currentTitle: "Current",
            isActive: true,
            sourceFingerprint: sourceFingerprint,
            effect: request.operation.title.map { .rename(expectedTitle: $0, commitSink: MutationCommitSink(id: RecordingID(value: "sink"), title: "Sink")) } ?? .moveToRecentlyDeleted
        )
    }
    func verifyPostcondition(_ expected: ResolvedMutationTarget) throws {
        postconditionCalls += 1
        if let postconditionError { throw postconditionError }
    }
}

private final class FixtureAccessibility: VoiceMemosAccessibility, @unchecked Sendable {
    enum Action: Equatable { case rename, delete }
    var actions: [Action] = []
    var bundleBuild = "1380"
    var actionError: Error?
    private(set) var postconditionCalls = 0
    func verify(_ mutation: VoiceMemosAccessibilityMutation) throws -> VoiceMemosAccessibilityVerification { .init(targetTitle: mutation.oldTitle, bundleBuild: bundleBuild) }
    func rename(_ mutation: VoiceMemosAccessibilityMutation) throws {
        actions.append(.rename)
        if let actionError { throw actionError }
    }
    func delete(_ mutation: VoiceMemosAccessibilityMutation) throws {
        actions.append(.delete)
        if let actionError { throw actionError }
    }
    func verifyPostcondition(_ mutation: VoiceMemosAccessibilityMutation) throws { postconditionCalls += 1 }
}

private final class FixtureClock: MutationClock, @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_700_000_000)
    func currentDate() -> Date { now }
}
private final class FixtureNonceGenerator: MutationNonceGenerator, @unchecked Sendable {
    private var next = 0
    func nextNonce() -> String {
        next += 1
        return "fixture-token-\(next)"
    }
}
private final class FixtureEnvironment: MutationEnvironmentFingerprint, @unchecked Sendable {
    var value = "environment"
    func currentFingerprint() -> String { value }
}
private enum FixtureWriteError: Error { case failed }
