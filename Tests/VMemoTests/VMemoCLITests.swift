import Foundation
import XCTest
@testable import VMemo

final class VMemoCLITests: XCTestCase {
    func testHelpDiscoversFlatCommands() throws {
        let result = try runVMemo("--help")

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stderr, "")
        for command in ["list", "search", "show", "export", "rename", "delete", "doctor"] {
            XCTAssertTrue(result.stdout.contains(command), "missing command: \(command)")
        }
    }

    func testListJSONReportsVersionedSafetyEnvelopeWhenAdapterIsUnconfigured() throws {
        let result = try runVMemo("list", "--json")

        XCTAssertEqual(result.status, 4)
        XCTAssertEqual(result.stdout, "")
        let envelope = try decodeJSON(result.stderr)
        XCTAssertEqual(envelope["version"] as? Int, 1)
        XCTAssertEqual(envelope["status"] as? String, "error")
        XCTAssertEqual((envelope["error"] as? [String: Any])?["code"] as? String, "adapter_not_configured")
    }

    func testRenameFailsClosedWhenSystemMutationAdapterIsUnconfigured() throws {
        let result = try runVMemo("rename", "--id", "opaque-recording-id", "--title", "Renamed", "--token", "fixture-token", "--confirm", "--json")

        XCTAssertEqual(result.status, 4)
        XCTAssertEqual(result.stdout, "")
        let envelope = try decodeJSON(result.stderr)
        XCTAssertEqual((envelope["error"] as? [String: Any])?["code"] as? String, "adapter_not_configured")
    }

    func testRenameAndDeleteAcceptDryRunFlagsAndFailClosedWithoutAnAdapter() throws {
        let rename = try runVMemo("rename", "--id", "opaque-recording-id", "--title", "Renamed", "--dry-run", "--json")
        let delete = try runVMemo("delete", "--id", "opaque-recording-id", "--dry-run", "--json")

        for result in [rename, delete] {
            XCTAssertEqual(result.status, 4)
            XCTAssertEqual(result.stdout, "")
            let envelope = try decodeJSON(result.stderr)
            XCTAssertEqual((envelope["error"] as? [String: Any])?["code"] as? String, "adapter_not_configured")
        }
    }

    func testJSONUsageErrorUsesVersionedEnvelopeAndUsageExit() throws {
        let result = try runVMemo("rename", "--json")

        XCTAssertEqual(result.status, 2)
        XCTAssertEqual(result.stdout, "")
        let envelope = try decodeJSON(result.stderr)
        XCTAssertEqual(envelope["version"] as? Int, 1)
        XCTAssertEqual(envelope["status"] as? String, "error")
        XCTAssertEqual((envelope["error"] as? [String: Any])?["code"] as? String, "usage_error")
    }

    func testJSONSuccessEnvelopeKeepsDataSeparateFromProtocolFields() throws {
        let text = try JSONEnvelope.success(["recordings": [String]()])
        let envelope = try decodeJSON(text)

        XCTAssertNotNil(envelope["version"] as? Int)
        XCTAssertEqual(envelope["status"] as? String, "ok")
        XCTAssertEqual((envelope["data"] as? [String: Any])?["recordings"] as? [String], [])
        XCTAssertNil(envelope["error"])
    }

    func testRecordingIDKeepsItsOpaqueValueIndependentOfTitle() {
        let id = RecordingID(value: "recording:9B59C5")
        let first = RecordingSummary(id: id, title: "Meeting")
        let renamed = RecordingSummary(id: id, title: "Renamed")

        XCTAssertEqual(first.id.description, "recording:9B59C5")
        XCTAssertEqual(first.id, renamed.id)
        XCTAssertNotEqual(first.id, RecordingID(value: first.title))
    }

    func testListWithFakeReadPortWritesSuccessEnvelopeToStandardOutput() throws {
        let recording = RecordingSummary(id: RecordingID(value: "recording:fixture"), title: "Fixture")
        let calls = CallLog()
        let runner = CommandRunner(
            read: FixtureReadPort(recordings: [recording], calls: calls),
            asset: FixtureAssetPort(calls: calls),
            write: FixtureWritePort(calls: calls)
        )

        let result = runner.run(.list, output: .json)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        let envelope = try decodeJSON(result.stdout)
        XCTAssertEqual(envelope["version"] as? Int, 1)
        XCTAssertEqual(envelope["status"] as? String, "ok")
        let recordings = try XCTUnwrap((envelope["data"] as? [String: Any])?["recordings"] as? [[String: Any]])
        XCTAssertEqual(recordings.count, 1)
        XCTAssertEqual(recordings[0]["id"] as? String, "recording:fixture")
    }

    func testCommandRunnerRoutesEveryBusinessCommandThroughItsPort() throws {
        let calls = CallLog()
        let runner = CommandRunner(
            read: FixtureReadPort(recordings: [], calls: calls),
            asset: FixtureAssetPort(calls: calls),
            write: FixtureWritePort(calls: calls)
        )
        let id = RecordingID(value: "recording:fixture")
        let rename = MutationRequest(id: id, operation: .rename(title: "Renamed"))
        let delete = MutationRequest(id: id, operation: .moveToRecentlyDeleted)

        let results = [
            runner.run(.list, output: .json),
            runner.run(.search(query: "fixture"), output: .json),
            runner.run(.show(id: id), output: .json),
            runner.run(.export(id: id, destination: "/tmp/export.m4a"), output: .json),
            runner.run(.mutation(request: rename, dryRun: true, token: nil, confirmed: false), output: .json),
            runner.run(.mutation(request: delete, dryRun: false, token: "fixture-token", confirmed: true), output: .json),
        ]

        XCTAssertEqual(results.map(\.exitCode), Array(repeating: 0, count: 6))
        XCTAssertEqual(calls.values, [
            "list",
            "search:fixture",
            "show:recording:fixture",
            "export:recording:fixture:/tmp/export.m4a",
            "dryRun:rename:recording:fixture:Renamed",
            "execute:moveToRecentlyDeleted:recording:fixture:fixture-token",
        ])
        let dryRunEnvelope = try decodeJSON(results[4].stdout)
        let dryRunData = try XCTUnwrap(dryRunEnvelope["data"] as? [String: Any])
        XCTAssertEqual(dryRunData["confirmationToken"] as? String, "fixture-token")
    }

    func testMutationAuthorizationFailuresDoNotCallWritePort() throws {
        let calls = CallLog()
        let runner = CommandRunner(
            read: FixtureReadPort(recordings: [], calls: calls),
            asset: FixtureAssetPort(calls: calls),
            write: FixtureWritePort(calls: calls)
        )
        let request = MutationRequest(
            id: RecordingID(value: "recording:fixture"),
            operation: .moveToRecentlyDeleted
        )

        let missingToken = runner.run(.mutation(request: request, dryRun: false, token: nil, confirmed: true), output: .json)
        let missingConfirmation = runner.run(.mutation(request: request, dryRun: false, token: "fixture-token", confirmed: false), output: .json)
        let mixedModes = runner.run(.mutation(request: request, dryRun: true, token: "fixture-token", confirmed: true), output: .json)

        for result in [missingToken, missingConfirmation] {
            XCTAssertEqual(result.exitCode, 4)
            XCTAssertEqual(result.stdout, "")
            let envelope = try decodeJSON(result.stderr)
            XCTAssertEqual((envelope["error"] as? [String: Any])?["code"] as? String, "mutation_authorization_required")
        }
        XCTAssertEqual(mixedModes.exitCode, 4)
        XCTAssertEqual(mixedModes.stdout, "")
        let mixedEnvelope = try decodeJSON(mixedModes.stderr)
        XCTAssertEqual((mixedEnvelope["error"] as? [String: Any])?["code"] as? String, "mutation_mode_conflict")
        XCTAssertEqual(calls.values, [])
    }

    func testSuccessEncodingFailureReturnsOperationalErrorInsteadOfEmptySuccess() throws {
        let runner = CommandRunner(
            read: FixtureReadPort(recordings: [], calls: CallLog()),
            asset: FixtureAssetPort(calls: CallLog()),
            write: FixtureWritePort(calls: CallLog()),
            encoder: FailingSuccessEncoder()
        )

        let result = runner.run(.list, output: .json)

        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(result.stdout, "")
        let envelope = try decodeJSON(result.stderr)
        XCTAssertEqual((envelope["error"] as? [String: Any])?["code"] as? String, "output_encoding_failed")
    }

    func testJSONEnvelopePropagatesThrowingEncodable() {
        XCTAssertThrowsError(try JSONEnvelope.success(ThrowingEncodable()))
    }

    func testUnknownAdapterErrorUsesOperationalEnvelopeAndExit() throws {
        let runner = CommandRunner(
            read: FailingReadPort(),
            asset: FixtureAssetPort(calls: CallLog()),
            write: FixtureWritePort(calls: CallLog())
        )

        let result = runner.run(.list, output: .json)

        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(result.stdout, "")
        let envelope = try decodeJSON(result.stderr)
        XCTAssertEqual((envelope["error"] as? [String: Any])?["code"] as? String, "adapter_operation_failed")
    }

    func testSchemaAdapterErrorsUseStableCommandFailures() throws {
        let unsupported = CommandRunner(
            read: SchemaFailingReadPort(error: .unsupportedSchema),
            asset: FixtureAssetPort(calls: CallLog()),
            write: FixtureWritePort(calls: CallLog())
        ).run(.list, output: .json)
        let notFound = CommandRunner(
            read: SchemaFailingReadPort(error: .recordingNotFound),
            asset: FixtureAssetPort(calls: CallLog()),
            write: FixtureWritePort(calls: CallLog())
        ).run(.show(id: RecordingID(value: "11111111-1111-1111-1111-111111111111")), output: .json)

        XCTAssertEqual(unsupported.exitCode, ProcessExit.safetyFailure.rawValue)
        XCTAssertEqual((try decodeJSON(unsupported.stderr)["error"] as? [String: Any])?["code"] as? String, "unsupported_schema")
        XCTAssertEqual(notFound.exitCode, ProcessExit.operationalFailure.rawValue)
        XCTAssertEqual((try decodeJSON(notFound.stderr)["error"] as? [String: Any])?["code"] as? String, "recording_not_found")
    }

    private func runVMemo(_ arguments: String...) throws -> ProcessResult {
        let binaryDirectory = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = binaryDirectory.appendingPathComponent("vmemo")
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            stderr: String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    private func decodeJSON(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}

private struct ProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

private struct FixtureReadPort: RecordingReadPort {
    let recordings: [RecordingSummary]
    let calls: CallLog

    func list() throws -> [RecordingSummary] {
        calls.append("list")
        return recordings
    }

    func search(query: String) throws -> [RecordingSummary] {
        calls.append("search:\(query)")
        return recordings
    }

    func show(id: RecordingID) throws -> RecordingSummary {
        calls.append("show:\(id)")
        return RecordingSummary(id: id, title: "Fixture")
    }
}

private struct FixtureAssetPort: RecordingAssetPort {
    let calls: CallLog

    func export(id: RecordingID, destination: String) throws -> ExportReceipt {
        calls.append("export:\(id):\(destination)")
        return ExportReceipt(id: id, destination: destination)
    }
}

private struct FixtureWritePort: RecordingWritePort {
    let calls: CallLog

    func dryRun(_ request: MutationRequest) throws -> MutationPlan {
        calls.append("dryRun:\(request.operation.description):\(request.id)\(request.operation.title.map { ":\($0)" } ?? "")")
        return MutationPlan(request: request, confirmationToken: "fixture-token")
    }

    func execute(_ request: MutationRequest, authorization: MutationAuthorization) throws -> MutationResult {
        calls.append("execute:\(request.operation.description):\(request.id):\(authorization.token)")
        return MutationResult(request: request)
    }
}

private struct FailingReadPort: RecordingReadPort {
    func list() throws -> [RecordingSummary] { throw FixtureError.failed }
    func search(query: String) throws -> [RecordingSummary] { throw FixtureError.failed }
    func show(id: RecordingID) throws -> RecordingSummary { throw FixtureError.failed }
}

private struct SchemaFailingReadPort: RecordingReadPort {
    let error: SchemaAdapterError

    func list() throws -> [RecordingSummary] { throw error }
    func search(query: String) throws -> [RecordingSummary] { throw error }
    func show(id: RecordingID) throws -> RecordingSummary { throw error }
}

private enum FixtureError: Error {
    case failed
}

private final class CallLog: @unchecked Sendable {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

private struct FailingSuccessEncoder: CommandOutputEncoder {
    func success(_ data: any Encodable) throws -> String {
        throw FixtureError.failed
    }

    func failure(code: String, message: String) throws -> String {
        try JSONEnvelope.failure(code: code, message: message)
    }
}

private struct ThrowingEncodable: Encodable {
    func encode(to encoder: Encoder) throws {
        throw FixtureError.failed
    }
}
