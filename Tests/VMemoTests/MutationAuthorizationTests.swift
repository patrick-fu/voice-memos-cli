import Foundation
import XCTest
@testable import VMemo

final class MutationAuthorizationTests: XCTestCase {
    func testDryRunIssuesShortLivedBoundTokenWithoutPressing() throws {
        let fixture = makeFixture()
        let request = renameRequest(title: "Renamed")

        let plan = try fixture.port.dryRun(request)

        XCTAssertEqual(plan.id, request.id)
        XCTAssertEqual(plan.operation, "rename")
        XCTAssertEqual(plan.confirmationToken, "token-1")
        XCTAssertEqual(fixture.accessibility.verificationCount, 1)
        XCTAssertEqual(fixture.accessibility.pressCount, 0)
        XCTAssertEqual(fixture.accessibility.postconditionCount, 0)
    }

    func testExecuteFreshlyVerifiesPressesOnceAndRequiresPostcondition() throws {
        let fixture = makeFixture()
        let request = renameRequest(title: "Renamed")
        let plan = try fixture.port.dryRun(request)

        let result = try fixture.port.execute(request, authorization: MutationAuthorization(token: plan.confirmationToken, confirmed: true))

        XCTAssertEqual(result.id, request.id)
        XCTAssertEqual(result.operation, "rename")
        XCTAssertEqual(fixture.accessibility.verificationCount, 2)
        XCTAssertEqual(fixture.accessibility.pressCount, 1)
        XCTAssertEqual(fixture.accessibility.postconditionCount, 1)
    }

    func testDryRunWaitsUntilInFlightExecuteReleasesSerializationBoundary() throws {
        let fixture = makeFixture()
        let request = renameRequest(title: "Renamed")
        let plan = try fixture.port.dryRun(request)
        let performStarted = DispatchSemaphore(value: 0)
        let releasePerform = DispatchSemaphore(value: 0)
        fixture.accessibility.performStarted = performStarted
        fixture.accessibility.releasePerform = releasePerform

        let executeFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { executeFinished.signal() }
            _ = try? fixture.port.execute(
                request,
                authorization: MutationAuthorization(token: plan.confirmationToken, confirmed: true)
            )
        }
        XCTAssertEqual(performStarted.wait(timeout: .now() + 1), .success)

        let dryRunFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? fixture.port.dryRun(request)
            dryRunFinished.signal()
        }

        XCTAssertEqual(fixture.accessibility.verificationCount, 2)
        XCTAssertEqual(dryRunFinished.wait(timeout: .now() + 0.1), .timedOut)

        releasePerform.signal()
        XCTAssertEqual(executeFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(dryRunFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(fixture.accessibility.verificationCount, 3)
    }

    func testDeleteUsesOnlyMoveToRecentlyDeleted() throws {
        let fixture = makeFixture()
        let request = MutationRequest(id: RecordingID(value: "recording:fixture"), operation: .moveToRecentlyDeleted)
        let plan = try fixture.port.dryRun(request)

        _ = try fixture.port.execute(request, authorization: MutationAuthorization(token: plan.confirmationToken, confirmed: true))

        XCTAssertEqual(fixture.accessibility.performedOperations, ["moveToRecentlyDeleted"])
    }

    func testExpiredTokenDoesNotPress() throws {
        let fixture = makeFixture()
        let request = renameRequest(title: "Renamed")
        let plan = try fixture.port.dryRun(request)
        fixture.clock.advance(by: 31)

        assertError(.tokenExpired) {
            try fixture.port.execute(request, authorization: MutationAuthorization(token: plan.confirmationToken, confirmed: true))
        }
        XCTAssertEqual(fixture.accessibility.pressCount, 0)
    }

    func testSuccessfulTokenCannotBeReplayed() throws {
        let fixture = makeFixture()
        let request = renameRequest(title: "Renamed")
        let plan = try fixture.port.dryRun(request)
        _ = try fixture.port.execute(request, authorization: MutationAuthorization(token: plan.confirmationToken, confirmed: true))

        assertError(.tokenReplayed) {
            try fixture.port.execute(request, authorization: MutationAuthorization(token: plan.confirmationToken, confirmed: true))
        }
        XCTAssertEqual(fixture.accessibility.pressCount, 1)
    }

    func testPreflightFailureDoesNotConsumeTokenButPostconditionFailureDoes() throws {
        let fixture = makeFixture()
        let request = renameRequest(title: "Renamed")
        let plan = try fixture.port.dryRun(request)
        fixture.accessibility.state = .focusDrift

        assertError(.preflightFailed) {
            try fixture.port.execute(request, authorization: MutationAuthorization(token: plan.confirmationToken, confirmed: true))
        }
        XCTAssertEqual(fixture.accessibility.pressCount, 0)

        fixture.accessibility.state = .ready
        _ = try fixture.port.execute(request, authorization: MutationAuthorization(token: plan.confirmationToken, confirmed: true))

        let postFixture = makeFixture()
        let postPlan = try postFixture.port.dryRun(request)
        postFixture.accessibility.state = .noPostcondition
        assertError(.postconditionFailed) {
            try postFixture.port.execute(request, authorization: MutationAuthorization(token: postPlan.confirmationToken, confirmed: true))
        }
        XCTAssertEqual(postFixture.accessibility.pressCount, 1)
        assertError(.tokenReplayed) {
            try postFixture.port.execute(request, authorization: MutationAuthorization(token: postPlan.confirmationToken, confirmed: true))
        }
    }

    func testTokenBindingCoversOperationIDEnvironmentAndVerificationNonce() throws {
        let fixture = makeFixture()
        let request = renameRequest(title: "Renamed")
        let plan = try fixture.port.dryRun(request)

        assertError(.tokenBindingMismatch) {
            try fixture.port.execute(renameRequest(title: "Other title"), authorization: MutationAuthorization(token: plan.confirmationToken, confirmed: true))
        }
        assertError(.tokenBindingMismatch) {
            try fixture.port.execute(
                MutationRequest(id: RecordingID(value: "recording:other"), operation: request.operation),
                authorization: MutationAuthorization(token: plan.confirmationToken, confirmed: true)
            )
        }
        fixture.environment.value = "other-environment"
        assertError(.tokenBindingMismatch) {
            try fixture.port.execute(request, authorization: MutationAuthorization(token: plan.confirmationToken, confirmed: true))
        }
        XCTAssertEqual(fixture.accessibility.pressCount, 0)

        let nonceFixture = makeFixture()
        let noncePlan = try nonceFixture.port.dryRun(request)
        nonceFixture.accessibility.forcedVerificationNonce = "proof-1"
        assertError(.tokenBindingMismatch) {
            try nonceFixture.port.execute(request, authorization: MutationAuthorization(token: noncePlan.confirmationToken, confirmed: true))
        }
        XCTAssertEqual(nonceFixture.accessibility.pressCount, 0)

        let targetFixture = makeFixture()
        let targetPlan = try targetFixture.port.dryRun(request)
        targetFixture.accessibility.forcedTargetBinding = "different-target"
        assertError(.tokenBindingMismatch) {
            try targetFixture.port.execute(request, authorization: MutationAuthorization(token: targetPlan.confirmationToken, confirmed: true))
        }
        XCTAssertEqual(targetFixture.accessibility.pressCount, 0)
    }

    func testDuplicateGeneratedTokenDoesNotOverwriteExistingAuthorization() throws {
        let clock = FixedMutationClock(now: Date(timeIntervalSince1970: 1_000))
        let accessibility = FakeAccessibilityClient(state: .ready)
        let environment = FixedEnvironmentFingerprint(value: "fixture-environment")
        let port = MutationAuthorizingWritePort(
            accessibility: accessibility,
            clock: clock,
            nonceGenerator: SequenceNonceGenerator(values: ["duplicate", "duplicate"]),
            tokenStore: InMemoryMutationTokenStore(),
            environment: environment,
            tokenTTL: 30
        )
        let firstRequest = renameRequest(title: "First")
        let first = try port.dryRun(firstRequest)

        assertError(.tokenGenerationFailed) {
            try port.dryRun(self.renameRequest(title: "Second"))
        }
        _ = try port.execute(
            firstRequest,
            authorization: MutationAuthorization(token: first.confirmationToken, confirmed: true)
        )
        XCTAssertEqual(accessibility.performedOperations, ["rename"])
    }

    func testTamperedTokenAndMissingConfirmationDoNotPress() throws {
        let fixture = makeFixture()
        let request = renameRequest(title: "Renamed")
        let plan = try fixture.port.dryRun(request)

        assertError(.confirmationRequired) {
            try fixture.port.execute(request, authorization: MutationAuthorization(token: plan.confirmationToken, confirmed: false))
        }
        assertError(.tokenBindingMismatch) {
            try fixture.port.execute(request, authorization: MutationAuthorization(token: "tampered", confirmed: true))
        }
        XCTAssertEqual(fixture.accessibility.pressCount, 0)
    }

    func testAccessibilityPreflightStateFailuresNeverPress() throws {
        for state in [
            FakeAccessibilityClient.State.untrusted,
            .appMissing,
            .windowMissing,
            .ambiguous,
            .modal,
            .focusDrift,
            .timeout,
        ] {
            let fixture = makeFixture(state: state)
            assertError(.preflightFailed) {
                try fixture.port.dryRun(renameRequest(title: "Renamed"))
            }
            XCTAssertEqual(fixture.accessibility.pressCount, 0, "state: \(state)")
        }
    }

    func testPressTimeoutConsumesTokenAndReturnsPostconditionFailure() throws {
        let fixture = makeFixture()
        let request = renameRequest(title: "Renamed")
        let plan = try fixture.port.dryRun(request)
        fixture.accessibility.state = .pressTimeout

        assertError(.postconditionFailed) {
            try fixture.port.execute(request, authorization: MutationAuthorization(token: plan.confirmationToken, confirmed: true))
        }
        XCTAssertEqual(fixture.accessibility.pressCount, 1)
        assertError(.tokenReplayed) {
            try fixture.port.execute(request, authorization: MutationAuthorization(token: plan.confirmationToken, confirmed: true))
        }
    }

    func testCommandRunnerPreservesMutationAuthorizationFailureCodes() throws {
        let fixture = makeFixture()
        let request = renameRequest(title: "Renamed")
        let plan = try fixture.port.dryRun(request)
        fixture.clock.advance(by: 31)
        let runner = CommandRunner(
            read: UnconfiguredReadPort(),
            asset: UnconfiguredAssetPort(),
            write: fixture.port
        )

        let result = runner.run(
            .mutation(request: request, dryRun: false, token: plan.confirmationToken, confirmed: true),
            output: .json
        )

        XCTAssertEqual(result.exitCode, ProcessExit.safetyFailure.rawValue)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stderr.utf8)) as? [String: Any])
        XCTAssertEqual((envelope["error"] as? [String: Any])?["code"] as? String, "token_expired")
    }

    private func renameRequest(title: String) -> MutationRequest {
        MutationRequest(id: RecordingID(value: "recording:fixture"), operation: .rename(title: title))
    }

    private func makeFixture(state: FakeAccessibilityClient.State = .ready) -> Fixture {
        let clock = FixedMutationClock(now: Date(timeIntervalSince1970: 1_000))
        let accessibility = FakeAccessibilityClient(state: state)
        let environment = FixedEnvironmentFingerprint(value: "fixture-environment")
        return Fixture(
            clock: clock,
            accessibility: accessibility,
            environment: environment,
            port: MutationAuthorizingWritePort(
                accessibility: accessibility,
                clock: clock,
                nonceGenerator: SequenceNonceGenerator(values: ["token-1", "token-2"]),
                tokenStore: InMemoryMutationTokenStore(),
                environment: environment,
                tokenTTL: 30
            )
        )
    }

    private func assertError<Result>(_ expected: MutationAuthorizationError, operation: () throws -> Result) {
        XCTAssertThrowsError(try operation()) { error in
            XCTAssertEqual(error as? MutationAuthorizationError, expected)
        }
    }
}

private struct Fixture {
    let clock: FixedMutationClock
    let accessibility: FakeAccessibilityClient
    let environment: FixedEnvironmentFingerprint
    let port: MutationAuthorizingWritePort
}

private final class FixedMutationClock: MutationClock, @unchecked Sendable {
    private(set) var now: Date

    init(now: Date) {
        self.now = now
    }

    func currentDate() -> Date {
        now
    }

    func advance(by interval: TimeInterval) {
        now.addTimeInterval(interval)
    }
}

private final class SequenceNonceGenerator: MutationNonceGenerator, @unchecked Sendable {
    private var values: [String]

    init(values: [String]) {
        self.values = values
    }

    func nextNonce() -> String {
        values.removeFirst()
    }
}

private final class FixedEnvironmentFingerprint: MutationEnvironmentFingerprint, @unchecked Sendable {
    var value: String

    init(value: String) {
        self.value = value
    }

    func currentFingerprint() -> String {
        value
    }
}

private final class FakeAccessibilityClient: AccessibilityClient, @unchecked Sendable {
    enum State: CustomStringConvertible {
        case ready
        case untrusted
        case appMissing
        case windowMissing
        case ambiguous
        case modal
        case focusDrift
        case timeout
        case pressTimeout
        case noPostcondition

        var description: String {
            switch self {
            case .ready: "ready"
            case .untrusted: "untrusted"
            case .appMissing: "appMissing"
            case .windowMissing: "windowMissing"
            case .ambiguous: "ambiguous"
            case .modal: "modal"
            case .focusDrift: "focusDrift"
            case .timeout: "timeout"
            case .pressTimeout: "pressTimeout"
            case .noPostcondition: "noPostcondition"
            }
        }
    }

    var state: State
    var forcedVerificationNonce: String?
    var forcedTargetBinding: String?
    private(set) var verificationCount = 0
    private(set) var pressCount = 0
    private(set) var postconditionCount = 0
    private(set) var performedOperations: [String] = []
    var performStarted: DispatchSemaphore?
    var releasePerform: DispatchSemaphore?

    init(state: State) {
        self.state = state
    }

    func verifyTarget(_ request: MutationRequest) throws -> AccessibilityVerification {
        verificationCount += 1
        switch state {
        case .ready, .pressTimeout, .noPostcondition:
            return AccessibilityVerification(
                targetBinding: forcedTargetBinding ?? request.id.value,
                nonce: forcedVerificationNonce ?? "proof-\(verificationCount)"
            )
        case .untrusted:
            throw AccessibilityClientError.untrusted
        case .appMissing:
            throw AccessibilityClientError.appMissing
        case .windowMissing:
            throw AccessibilityClientError.windowMissing
        case .ambiguous:
            throw AccessibilityClientError.ambiguousTarget
        case .modal:
            throw AccessibilityClientError.modalPresent
        case .focusDrift:
            throw AccessibilityClientError.focusDrift
        case .timeout:
            throw AccessibilityClientError.timeout
        }
    }

    func perform(_ request: MutationRequest) throws {
        pressCount += 1
        performedOperations.append(request.operation.description)
        performStarted?.signal()
        if let releasePerform {
            _ = releasePerform.wait(timeout: .now() + 1)
        }
        if state == .pressTimeout {
            throw AccessibilityClientError.timeout
        }
    }

    func verifyPostcondition(_ request: MutationRequest) throws {
        postconditionCount += 1
        if state == .noPostcondition {
            throw AccessibilityClientError.noPostcondition
        }
    }
}
