import Foundation
import XCTest
@testable import VMemo

final class DoctorTests: XCTestCase {
    func testReadyReportUsesOrderedChecksAndVersionedJSONOnStandardOutput() throws {
        let port = FakeDoctorPort(report: report(status: .ready))
        let result = makeRunner(doctor: port).run(.doctor(includeUI: false), output: .json)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(port.requests, [false])
        let envelope = try decodeJSON(result.stdout)
        XCTAssertEqual(envelope["version"] as? Int, 1)
        XCTAssertEqual(envelope["status"] as? String, "ok")
        let data = try XCTUnwrap(envelope["data"] as? [String: Any])
        XCTAssertEqual(data["status"] as? String, "ready")
        XCTAssertEqual((data["checks"] as? [[String: Any]])?.map { $0["id"] as? String }, ["runtime", "voice_memos", "library", "schema", "signing"])
    }

    func testBlockedReportPreservesDataAndUsesSafetyExit() throws {
        let result = makeRunner(doctor: FakeDoctorPort(report: report(status: .blocked))).run(.doctor(includeUI: false), output: .json)

        XCTAssertEqual(result.exitCode, ProcessExit.safetyFailure.rawValue)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual((try decodeJSON(result.stdout)["data"] as? [String: Any])?["status"] as? String, "blocked")
    }

    func testIncompleteReportUsesDeterministicHumanOutputAndPartialExit() {
        let result = makeRunner(doctor: FakeDoctorPort(report: report(status: .incomplete))).run(.doctor(includeUI: false), output: .human)

        XCTAssertEqual(result.exitCode, ProcessExit.partialFailure.rawValue)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(
            result.stdout,
            "Doctor: incomplete\n"
                + "runtime\tready\truntime_supported\tmacOS 15; arm64\n"
                + "voice_memos\tready\tapp_available\tversion metadata available\n"
                + "library\tincomplete\tlibrary_not_configured\tNo library path is configured.\n"
                + "schema\tready\tschema_supported\tSynthetic schema fixture is supported.\n"
                + "signing\tready\tsigning_metadata_available\tCurrent-process signing metadata is available.\n"
        )
    }

    func testProbeFailureUsesOperationalFailureEnvelope() throws {
        let result = makeRunner(doctor: ThrowingDoctorPort()).run(.doctor(includeUI: false), output: .json)

        XCTAssertEqual(result.exitCode, ProcessExit.operationalFailure.rawValue)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual((try decodeJSON(result.stderr)["error"] as? [String: Any])?["code"] as? String, "doctor_probe_failed")
    }

    func testSystemDoctorSkipsUIProbeUnlessExplicitlyRequested() throws {
        let uiProbe = UIProbeSpy()
        let port = SystemDoctorPort(environment: ReadyDoctorEnvironment(), uiTrust: uiProbe)

        let withoutUI = try port.inspect(includeUI: false)
        XCTAssertEqual(uiProbe.callCount, 0)
        XCTAssertFalse(withoutUI.checks.contains { $0.id == "ui_accessibility" })

        let withUI = try port.inspect(includeUI: true)
        XCTAssertEqual(uiProbe.callCount, 1)
        XCTAssertEqual(withUI.checks.last?.id, "ui_accessibility")
        XCTAssertEqual(withUI.checks.last?.status, .ready)
    }

    func testSystemDoctorOnlySupportsKnownOSAndArchitectures() throws {
        let supported = try SystemDoctorPort(
            environment: DoctorEnvironmentFixture(runtimeValue: DoctorRuntime(osMajor: 26, architecture: "x86_64")),
            uiTrust: UIProbeSpy()
        ).inspect(includeUI: false)
        XCTAssertEqual(check(named: "runtime", in: supported).status, .ready)
        XCTAssertEqual(check(named: "runtime", in: supported).code, "runtime_supported")

        let futureOS = try SystemDoctorPort(
            environment: DoctorEnvironmentFixture(runtimeValue: DoctorRuntime(osMajor: 27, architecture: "arm64")),
            uiTrust: UIProbeSpy()
        ).inspect(includeUI: false)
        XCTAssertEqual(check(named: "runtime", in: futureOS).status, .blocked)
        XCTAssertEqual(check(named: "runtime", in: futureOS).code, "unsupported_os")

        let unknownArchitecture = try SystemDoctorPort(
            environment: DoctorEnvironmentFixture(runtimeValue: DoctorRuntime(osMajor: 15, architecture: "unknown")),
            uiTrust: UIProbeSpy()
        ).inspect(includeUI: false)
        XCTAssertEqual(check(named: "runtime", in: unknownArchitecture).status, .blocked)
        XCTAssertEqual(check(named: "runtime", in: unknownArchitecture).code, "unsupported_architecture")
    }

    func testApplicationResolverRejectsSameNamedApplicationsWithoutVoiceMemosBundleID() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vmemo-doctor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fakeApplication = root.appendingPathComponent("Applications/VoiceMemos.app", isDirectory: true)
        let systemApplication = root.appendingPathComponent("System/Applications/VoiceMemos.app", isDirectory: true)
        try makeApplicationBundle(at: fakeApplication, bundleIdentifier: "com.example.VoiceMemos", version: "9.9")
        try makeApplicationBundle(at: systemApplication, bundleIdentifier: "com.apple.VoiceMemos", version: "2.0")

        let resolver = SystemVoiceMemosApplicationMetadataResolver(candidateURLs: [fakeApplication, systemApplication])

        XCTAssertEqual(resolver.voiceMemosApplication()?.version, "2.0")
    }

    func testDoctorNeverRoutesThroughRecordingPorts() {
        let calls = RecordingPortCallSpy()
        let runner = CommandRunner(
            read: RecordingReadSpy(calls: calls),
            asset: RecordingAssetSpy(calls: calls),
            write: RecordingWriteSpy(calls: calls),
            doctor: FakeDoctorPort(report: report(status: .ready))
        )

        let result = runner.run(.doctor(includeUI: false), output: .json)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(calls.values, [])
    }

    private func makeRunner(doctor: any DoctorPort) -> CommandRunner {
        CommandRunner(
            read: UnconfiguredReadPort(),
            asset: UnconfiguredAssetPort(),
            write: UnconfiguredWritePort(),
            doctor: doctor
        )
    }

    private func report(status: DoctorReportStatus) -> DoctorReport {
        let libraryStatus: DoctorCheckStatus
        let libraryCode: String
        switch status {
        case .ready:
            libraryStatus = .ready
            libraryCode = "library_accessible"
        case .blocked:
            libraryStatus = .blocked
            libraryCode = "library_path_inaccessible"
        case .incomplete:
            libraryStatus = .incomplete
            libraryCode = "library_not_configured"
        }
        return DoctorReport(
            status: status,
            checks: [
                DoctorCheck(id: "runtime", status: .ready, code: "runtime_supported", details: ["macOS 15", "arm64"]),
                DoctorCheck(id: "voice_memos", status: .ready, code: "app_available", details: ["version metadata available"]),
                DoctorCheck(id: "library", status: libraryStatus, code: libraryCode, details: ["No library path is configured."]),
                DoctorCheck(id: "schema", status: .ready, code: "schema_supported", details: ["Synthetic schema fixture is supported."]),
                DoctorCheck(id: "signing", status: .ready, code: "signing_metadata_available", details: ["Current-process signing metadata is available."]),
            ]
        )
    }

    private func decodeJSON(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func check(named id: String, in report: DoctorReport) -> DoctorCheck {
        report.checks.first(where: { $0.id == id })!
    }

    private func makeApplicationBundle(at url: URL, bundleIdentifier: String, version: String) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let metadata: [String: String] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleShortVersionString": version,
            "CFBundlePackageType": "APPL",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }
}

private final class FakeDoctorPort: DoctorPort, @unchecked Sendable {
    let report: DoctorReport
    private(set) var requests: [Bool] = []

    init(report: DoctorReport) {
        self.report = report
    }

    func inspect(includeUI: Bool) throws -> DoctorReport {
        requests.append(includeUI)
        return report
    }
}

private struct ThrowingDoctorPort: DoctorPort {
    func inspect(includeUI: Bool) throws -> DoctorReport {
        throw FixtureDoctorError.failed
    }
}

private enum FixtureDoctorError: Error {
    case failed
}

private struct ReadyDoctorEnvironment: DoctorEnvironment {
    func runtime() -> DoctorRuntime { DoctorRuntime(osMajor: 15, architecture: "arm64") }
    func voiceMemosApplication() -> DoctorApplicationMetadata? { DoctorApplicationMetadata(version: "2.0") }
    func library() -> DoctorLibraryMetadata { .unconfigured }
    func signing() -> DoctorSigningMetadata { .available }
}

private struct DoctorEnvironmentFixture: DoctorEnvironment {
    let runtimeValue: DoctorRuntime

    init(runtimeValue: DoctorRuntime = DoctorRuntime(osMajor: 15, architecture: "arm64")) {
        self.runtimeValue = runtimeValue
    }

    func runtime() -> DoctorRuntime { runtimeValue }
    func voiceMemosApplication() -> DoctorApplicationMetadata? { DoctorApplicationMetadata(version: "2.0") }
    func library() -> DoctorLibraryMetadata { .unconfigured }
    func signing() -> DoctorSigningMetadata { .available }
}

private final class UIProbeSpy: DoctorUITrustPort, @unchecked Sendable {
    private(set) var callCount = 0

    func isTrusted() -> Bool {
        callCount += 1
        return true
    }
}

private final class RecordingPortCallSpy: @unchecked Sendable {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

private struct RecordingReadSpy: RecordingReadPort {
    let calls: RecordingPortCallSpy

    func list() throws -> [RecordingSummary] { calls.append("list"); return [] }
    func search(query: String) throws -> [RecordingSummary] { calls.append("search"); return [] }
    func show(id: RecordingID) throws -> RecordingSummary { calls.append("show"); return RecordingSummary(id: id, title: "unused") }
}

private struct RecordingAssetSpy: RecordingAssetPort {
    let calls: RecordingPortCallSpy

    func export(id: RecordingID, destination: String) throws -> ExportReceipt {
        calls.append("export")
        return ExportReceipt(id: id, destination: destination)
    }
}

private struct RecordingWriteSpy: RecordingWritePort {
    let calls: RecordingPortCallSpy

    func dryRun(_ request: MutationRequest) throws -> MutationPlan {
        calls.append("dryRun")
        return MutationPlan(request: request, confirmationToken: "unused")
    }

    func execute(_ request: MutationRequest, authorization: MutationAuthorization) throws -> MutationResult {
        calls.append("execute")
        return MutationResult(request: request)
    }
}
