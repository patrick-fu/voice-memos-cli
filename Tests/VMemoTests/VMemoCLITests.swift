import Foundation
import XCTest
@testable import VMemo

final class VMemoCLITests: XCTestCase {
    func testVersionPrintsExactReleaseVersionAndSucceeds() throws {
        let result = try runVMemo("--version")

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "0.1.0\n")
        XCTAssertEqual(result.stderr, "")
    }

    func testHelpDiscoversFlatCommands() throws {
        let result = try runVMemo("--help")

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stderr, "")
        for command in ["list", "search", "show", "export", "doctor"] {
            XCTAssertTrue(result.stdout.contains(command), "missing command: \(command)")
        }
    }

    func testHelpIsSelfContainedForAgents() throws {
        let root = try runVMemo("--help")
        let rootHelp = normalizedHelp(root.stdout)
        XCTAssertTrue(rootHelp.contains("Output: human reports go to stdout; diagnostics go to stderr."))
        XCTAssertTrue(rootHelp.contains("version 1 JSON envelope"))
        XCTAssertTrue(rootHelp.contains("Exit codes: 0 success, 2 usage error, 3 operational/output error, 4 safety or adapter block, 5 partial/incomplete result."))
        XCTAssertTrue(rootHelp.contains("Recording IDs are opaque"))
        for forbidden in ["rename", "delete", "mutation", "token", "confirm", "accessibility"] {
            XCTAssertFalse(rootHelp.localizedCaseInsensitiveContains(forbidden), "forbidden term in help: \(forbidden)")
        }

        let helpCases: [(String, [String])] = [
            ("export", ["USAGE: vmemo export", "must not already exist", "source recording is never modified", "Example: vmemo export"]),
            ("doctor", ["USAGE: vmemo doctor", "Check runtime, application, library, schema, and signing readiness.", "Example: vmemo doctor"]),
        ]
        for (command, sections) in helpCases {
            let result = try runVMemo(command, "--help")
            XCTAssertEqual(result.status, 0, command)
            let help = normalizedHelp(result.stdout)
            for section in sections {
                XCTAssertTrue(help.contains(section), "missing \(section) in \(command) help")
            }
        }
    }

    func testSearchHelpStatesThatSearchIsTitleOnly() throws {
        let result = try runVMemo("search", "--help")

        XCTAssertEqual(result.status, 0)
        let help = normalizedHelp(result.stdout).lowercased()
        XCTAssertTrue(
            help.contains("titles only") || help.contains("title only") || help.contains("title-only"),
            "search help must explicitly limit matching to titles"
        )
    }

    func testHelpExamplesReachAdapterLayerInsteadOfUsageErrors() throws {
        let examples: [[String]] = [
            ["list", "--json"],
            ["search", "--query", "meeting", "--json"],
            ["show", "--id", "opaque-recording-id", "--json"],
            ["export", "--id", "opaque-recording-id", "--output-path", "/tmp/vmemo-example.m4a", "--json"],
            ["doctor", "--json"],
        ]
        for arguments in examples {
            let result = try runVMemo(arguments)
            XCTAssertNotEqual(result.status, 2, "example parsed as usage error: \(arguments.joined(separator: " "))")
        }
    }

    func testListJSONReportsVersionedSafetyEnvelopeWhenFixtureRootHasNoStore() throws {
        let result = try runVMemo("list", "--json")

        XCTAssertEqual(result.status, 4)
        XCTAssertEqual(result.stdout, "")
        let envelope = try decodeJSON(result.stderr)
        XCTAssertEqual(envelope["version"] as? Int, 1)
        XCTAssertEqual(envelope["status"] as? String, "error")
        let expectedCode = ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26
            ? "snapshot_creation_failed"
            : "unsupported_os"
        XCTAssertEqual((envelope["error"] as? [String: Any])?["code"] as? String, expectedCode)
    }

    func testDoctorSubprocessWritesAReportForHumanAndJSONModes() throws {
        let human = try runVMemo("doctor")
        XCTAssertEqual(human.stderr, "")
        XCTAssertTrue(human.stdout.hasPrefix("Doctor: "))
        XCTAssertTrue([0, 4, 5].contains(human.status))

        let json = try runVMemo("doctor", "--json")
        XCTAssertEqual(json.stderr, "")
        let jsonReport = try doctorReport(from: json)
        XCTAssertEqual(jsonReport.checks, ["runtime", "voice_memos", "library", "schema", "signing"])
        XCTAssertEqual(json.status, exitStatus(for: jsonReport.status))

    }

    func testRemovedWriteAndUICommandsUseVersionedUsageError() throws {
        let argumentCases = [
            ["unknown-command", "--json"],
            ["rename", "--json"],
            ["delete", "--json"],
            ["doctor", "--ui", "--json"],
        ]

        for arguments in argumentCases {
            let result = try runVMemo(arguments)
            XCTAssertEqual(result.status, 2, "arguments: \(arguments)")
            XCTAssertEqual(result.stdout, "", "arguments: \(arguments)")
            let envelope = try decodeJSON(result.stderr)
            XCTAssertEqual(envelope["version"] as? Int, 1, "arguments: \(arguments)")
            XCTAssertEqual(envelope["status"] as? String, "error", "arguments: \(arguments)")
            XCTAssertEqual((envelope["error"] as? [String: Any])?["code"] as? String, "usage_error", "arguments: \(arguments)")
        }
    }

    func testRemovedWriteAndUICommandsUseHumanUsageError() throws {
        let argumentCases = [
            ["unknown-command"],
            ["rename"],
            ["delete"],
            ["doctor", "--ui"],
        ]

        for arguments in argumentCases {
            let result = try runVMemo(arguments)
            XCTAssertEqual(result.status, 2, "arguments: \(arguments)")
            XCTAssertEqual(result.stdout, "", "arguments: \(arguments)")
            XCTAssertTrue(result.stderr.contains("error:"), "arguments: \(arguments)")
        }
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
        let updatedTitle = RecordingSummary(id: id, title: "Updated")

        XCTAssertEqual(first.id.description, "recording:9B59C5")
        XCTAssertEqual(first.id, updatedTitle.id)
        XCTAssertNotEqual(first.id, RecordingID(value: first.title))
    }

    func testListWithFakeReadPortWritesSuccessEnvelopeToStandardOutput() throws {
        let recording = RecordingSummary(id: RecordingID(value: "recording:fixture"), title: "Fixture")
        let calls = CallLog()
        let runner = CommandRunner(
            read: FixtureReadPort(recordings: [recording], calls: calls),
            asset: FixtureAssetPort(calls: calls)
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

    func testCommandRunnerRoutesEveryReadOnlyCommandThroughItsPort() throws {
        let calls = CallLog()
        let runner = CommandRunner(
            read: FixtureReadPort(recordings: [], calls: calls),
            asset: FixtureAssetPort(calls: calls)
        )
        let id = RecordingID(value: "recording:fixture")

        let results = [
            runner.run(.list, output: .json),
            runner.run(.search(query: "fixture"), output: .json),
            runner.run(.show(id: id), output: .json),
            runner.run(.export(id: id, destination: "/tmp/export.m4a"), output: .json)
        ]

        XCTAssertEqual(results.map(\.exitCode), Array(repeating: 0, count: 4))
        XCTAssertEqual(calls.values, [
            "list",
            "search:fixture",
            "show:recording:fixture",
            "export:recording:fixture:/tmp/export.m4a"
        ])
    }

    func testHumanExportReceiptIncludesDestination() {
        let destination = "/tmp/export-receipt.m4a"
        let runner = CommandRunner(
            read: FixtureReadPort(recordings: [], calls: CallLog()),
            asset: FixtureAssetPort(calls: CallLog())
        )

        let result = runner.run(
            .export(id: RecordingID(value: "recording:fixture"), destination: destination),
            output: .human
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertTrue(result.stdout.contains(destination))
    }

    func testSuccessEncodingFailureReturnsOperationalErrorInsteadOfEmptySuccess() throws {
        let runner = CommandRunner(
            read: FixtureReadPort(recordings: [], calls: CallLog()),
            asset: FixtureAssetPort(calls: CallLog()),
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
            asset: FixtureAssetPort(calls: CallLog())
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
            asset: FixtureAssetPort(calls: CallLog())
        ).run(.list, output: .json)
        let notFound = CommandRunner(
            read: SchemaFailingReadPort(error: .recordingNotFound),
            asset: FixtureAssetPort(calls: CallLog())
        ).run(.show(id: RecordingID(value: "11111111-1111-1111-1111-111111111111")), output: .json)

        XCTAssertEqual(unsupported.exitCode, ProcessExit.safetyFailure.rawValue)
        XCTAssertEqual((try decodeJSON(unsupported.stderr)["error"] as? [String: Any])?["code"] as? String, "unsupported_schema")
        XCTAssertEqual(notFound.exitCode, ProcessExit.operationalFailure.rawValue)
        XCTAssertEqual((try decodeJSON(notFound.stderr)["error"] as? [String: Any])?["code"] as? String, "recording_not_found")
    }

    func testAssetErrorsUseStableCommandFailures() throws {
        let result = CommandRunner(
            read: FixtureReadPort(recordings: [], calls: CallLog()),
            asset: FailingAssetPort(error: .pathOutsideRecordingsRoot)
        ).run(
            .export(id: RecordingID(value: "recording:fixture"), destination: "/tmp/export.m4a"),
            output: .json
        )

        XCTAssertEqual(result.exitCode, ProcessExit.safetyFailure.rawValue)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(
            (try decodeJSON(result.stderr)["error"] as? [String: Any])?["code"] as? String,
            "path_outside_recordings_root"
        )
    }

    private func runVMemo(_ arguments: String...) throws -> ProcessResult {
        try runVMemo(Array(arguments))
    }

    private func runVMemo(_ arguments: [String]) throws -> ProcessResult {
        let binaryDirectory = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let fixtureRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vmemo-subprocess-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = binaryDirectory.appendingPathComponent("vmemo")
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["VMEMO_RECORDINGS_ROOT"] = fixtureRoot.path
        process.environment = environment
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

    private func normalizedHelp(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private func doctorReport(from result: ProcessResult) throws -> (status: String, checks: [String]) {
        let envelope = try decodeJSON(result.stdout)
        XCTAssertEqual(envelope["version"] as? Int, 1)
        XCTAssertEqual(envelope["status"] as? String, "ok")
        let data = try XCTUnwrap(envelope["data"] as? [String: Any])
        let status = try XCTUnwrap(data["status"] as? String)
        let checks = try XCTUnwrap(data["checks"] as? [[String: Any]]).compactMap { $0["id"] as? String }
        return (status, checks)
    }

    private func exitStatus(for doctorStatus: String) -> Int32 {
        switch doctorStatus {
        case "ready": 0
        case "blocked": 4
        case "incomplete": 5
        default: -1
        }
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

private struct FailingReadPort: RecordingReadPort {
    func list() throws -> [RecordingSummary] { throw FixtureError.failed }
    func search(query: String) throws -> [RecordingSummary] { throw FixtureError.failed }
    func show(id: RecordingID) throws -> RecordingSummary { throw FixtureError.failed }
}

private struct FailingAssetPort: RecordingAssetPort {
    let error: RecordingAssetError

    func export(id: RecordingID, destination: String) throws -> ExportReceipt {
        throw error
    }
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
