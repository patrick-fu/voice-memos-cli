import Foundation

enum CommandRequest {
    case list
    case search(query: String)
    case show(id: RecordingID)
    case export(id: RecordingID, destination: String)
    case mutation(request: MutationRequest, dryRun: Bool, token: String?, confirmed: Bool)
    case doctor
}

enum OutputFormat {
    case human
    case json
}

struct CommandResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    static func usage(message: String) -> CommandResult {
        let stderr = (try? JSONEnvelope.failure(code: "usage_error", message: message) + "\n")
            ?? "error: \(message)\n"
        return CommandResult(exitCode: ProcessExit.usage.rawValue, stdout: "", stderr: stderr)
    }
}

struct CommandRunner: Sendable {
    let read: any RecordingReadPort
    let asset: any RecordingAssetPort
    let write: any RecordingWritePort
    let encoder: any CommandOutputEncoder

    init(
        read: any RecordingReadPort,
        asset: any RecordingAssetPort,
        write: any RecordingWritePort,
        encoder: any CommandOutputEncoder = JSONOutputEncoder()
    ) {
        self.read = read
        self.asset = asset
        self.write = write
        self.encoder = encoder
    }

    func run(_ request: CommandRequest, output: OutputFormat) -> CommandResult {
        do {
            switch request {
            case .list:
                let recordings = try read.list()
                return success(RecordingsPayload(recordings: recordings), human: render(recordings), output: output)
            case let .search(query):
                let recordings = try read.search(query: query)
                return success(RecordingsPayload(recordings: recordings), human: render(recordings), output: output)
            case let .show(id):
                let recording = try read.show(id: id)
                return success(recording, human: render(recording), output: output)
            case let .export(id, destination):
                let receipt = try asset.export(id: id, destination: destination)
                return success(receipt, human: "Exported \(receipt.id).\n", output: output)
            case let .mutation(request, dryRun, token, confirmed):
                return runMutation(request, dryRun: dryRun, token: token, confirmed: confirmed, output: output)
            case .doctor:
                return failure(
                    code: "adapter_not_configured",
                    message: "No production adapter is configured for doctor.",
                    exitCode: ProcessExit.safetyFailure.rawValue,
                    output: output
                )
            }
        } catch let error as VMemoError {
            return failure(error, exitCode: ProcessExit.safetyFailure.rawValue, output: output)
        } catch let error as SchemaAdapterError {
            return failure(code: error.code, message: error.message, exitCode: error.exitCode, output: output)
        } catch {
            return failure(
                code: "adapter_operation_failed",
                message: "The \(request.operation) adapter failed.",
                exitCode: ProcessExit.operationalFailure.rawValue,
                output: output
            )
        }
    }

    private func success<Payload: Encodable>(_ payload: Payload, human: String, output: OutputFormat) -> CommandResult {
        switch output {
        case .human:
            return CommandResult(exitCode: 0, stdout: human, stderr: "")
        case .json:
            do {
                return CommandResult(exitCode: 0, stdout: try encoder.success(payload) + "\n", stderr: "")
            } catch {
                return failure(
                    code: "output_encoding_failed",
                    message: "Unable to encode command output.",
                    exitCode: ProcessExit.operationalFailure.rawValue,
                    output: output
                )
            }
        }
    }

    private func failure(_ error: VMemoError, exitCode: Int32, output: OutputFormat) -> CommandResult {
        failure(code: error.code, message: error.message, exitCode: exitCode, output: output)
    }

    private func failure(code: String, message: String, exitCode: Int32, output: OutputFormat) -> CommandResult {
        let stderr: String
        switch output {
        case .human:
            stderr = "error: \(message)\n"
        case .json:
            stderr = (try? encoder.failure(code: code, message: message) + "\n") ?? "error: \(message)\n"
        }
        return CommandResult(exitCode: exitCode, stdout: "", stderr: stderr)
    }

    private func runMutation(
        _ request: MutationRequest,
        dryRun: Bool,
        token: String?,
        confirmed: Bool,
        output: OutputFormat
    ) -> CommandResult {
        if dryRun {
            guard token == nil, !confirmed else {
                return failure(
                    code: "mutation_mode_conflict",
                    message: "--dry-run cannot be combined with --token or --confirm.",
                    exitCode: ProcessExit.safetyFailure.rawValue,
                    output: output
                )
            }
            do {
                let plan = try write.dryRun(request)
                return success(
                    plan,
                    human: "Planned \(plan.operation) for \(plan.id).\nConfirmation token: \(plan.confirmationToken)\n",
                    output: output
                )
            } catch {
                return adapterFailure(error, operation: request.operation.description, output: output)
            }
        }

        guard let token, confirmed else {
            return failure(
                code: "mutation_authorization_required",
                message: "Execution requires both --token and --confirm.",
                exitCode: ProcessExit.safetyFailure.rawValue,
                output: output
            )
        }
        do {
            let result = try write.execute(request, authorization: MutationAuthorization(token: token))
            return success(result, human: "Completed \(result.operation) for \(result.id).\n", output: output)
        } catch {
            return adapterFailure(error, operation: request.operation.description, output: output)
        }
    }

    private func adapterFailure(_ error: Error, operation: String, output: OutputFormat) -> CommandResult {
        if let error = error as? VMemoError {
            return failure(error, exitCode: ProcessExit.safetyFailure.rawValue, output: output)
        }
        if let error = error as? SchemaAdapterError {
            return failure(code: error.code, message: error.message, exitCode: error.exitCode, output: output)
        }
        return failure(
            code: "adapter_operation_failed",
            message: "The \(operation) adapter failed.",
            exitCode: ProcessExit.operationalFailure.rawValue,
            output: output
        )
    }
}

private extension CommandRequest {
    var operation: String {
        switch self {
        case .list: "list"
        case .search: "search"
        case .show: "show"
        case .export: "export"
        case let .mutation(request, _, _, _): request.operation.description
        case .doctor: "doctor"
        }
    }
}

private func render(_ recordings: [RecordingSummary]) -> String {
    recordings.isEmpty ? "No recordings.\n" : recordings.map(render).joined()
}

private func render(_ recording: RecordingSummary) -> String {
    "\(recording.id)\t\(recording.title)\n"
}

private struct RecordingsPayload: Encodable {
    let recordings: [RecordingSummary]
}

enum ProcessExit: Int32 {
    case usage = 2
    case operationalFailure = 3
    case safetyFailure = 4
    case partialFailure = 5
}

protocol CommandOutputEncoder: Sendable {
    func success(_ data: any Encodable) throws -> String
    func failure(code: String, message: String) throws -> String
}

struct JSONOutputEncoder: CommandOutputEncoder {
    func success(_ data: any Encodable) throws -> String {
        try JSONEnvelope.success(data)
    }

    func failure(code: String, message: String) throws -> String {
        try JSONEnvelope.failure(code: code, message: message)
    }
}

enum JSONEnvelope {
    static func success<Payload: Encodable>(_ data: Payload) throws -> String {
        try encode(Success(data: data))
    }

    static func failure(code: String, message: String) throws -> String {
        try encode(Failure(error: ErrorDetail(code: code, message: message)))
    }

    private static func encode<Envelope: Encodable>(_ envelope: Envelope) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(envelope), as: UTF8.self)
    }

    private struct Success<Payload: Encodable>: Encodable {
        let version = 1
        let status = "ok"
        let data: Payload
    }

    private struct Failure: Encodable {
        let version = 1
        let status = "error"
        let error: ErrorDetail
    }

    private struct ErrorDetail: Encodable {
        let code: String
        let message: String
    }
}
