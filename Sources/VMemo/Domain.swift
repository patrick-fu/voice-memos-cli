import Foundation

struct RecordingID: Hashable, Sendable, Codable, CustomStringConvertible {
    let value: String

    init(value: String) {
        self.value = value
    }

    var description: String {
        value
    }

    init(from decoder: Decoder) throws {
        value = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

struct RecordingSummary: Equatable, Sendable, Codable {
    let id: RecordingID
    let title: String
}

struct ExportReceipt: Equatable, Sendable, Codable {
    let id: RecordingID
    let destination: String
}

protocol RecordingReadPort: Sendable {
    func list() throws -> [RecordingSummary]
    func search(query: String) throws -> [RecordingSummary]
    func show(id: RecordingID) throws -> RecordingSummary
}

protocol RecordingAssetPort: Sendable {
    func export(id: RecordingID, destination: String) throws -> ExportReceipt
}

protocol RecordingWritePort: Sendable {
    func dryRun(_ request: MutationRequest) throws -> MutationPlan
    func execute(_ request: MutationRequest, authorization: MutationAuthorization) throws -> MutationResult
}

enum MutationOperation: Sendable {
    case rename(title: String)
    case moveToRecentlyDeleted

    var description: String {
        switch self {
        case .rename:
            "rename"
        case .moveToRecentlyDeleted:
            "moveToRecentlyDeleted"
        }
    }

    var title: String? {
        guard case let .rename(title) = self else { return nil }
        return title
    }
}

struct MutationRequest: Sendable {
    let id: RecordingID
    let operation: MutationOperation
}

struct MutationAuthorization: Sendable {
    let token: String
}

struct MutationPlan: Sendable, Codable {
    let id: RecordingID
    let operation: String
    let confirmationToken: String

    init(request: MutationRequest, confirmationToken: String) {
        id = request.id
        operation = request.operation.description
        self.confirmationToken = confirmationToken
    }
}

struct MutationResult: Sendable, Codable {
    let id: RecordingID
    let operation: String

    init(request: MutationRequest) {
        id = request.id
        operation = request.operation.description
    }
}

enum VMemoError: Error {
    case adapterNotConfigured(operation: String)

    var code: String {
        switch self {
        case .adapterNotConfigured:
            "adapter_not_configured"
        }
    }

    var message: String {
        switch self {
        case let .adapterNotConfigured(operation):
            "No production adapter is configured for \(operation)."
        }
    }
}

struct UnconfiguredReadPort: RecordingReadPort {
    func list() throws -> [RecordingSummary] {
        throw VMemoError.adapterNotConfigured(operation: "list")
    }

    func search(query: String) throws -> [RecordingSummary] {
        throw VMemoError.adapterNotConfigured(operation: "search")
    }

    func show(id: RecordingID) throws -> RecordingSummary {
        throw VMemoError.adapterNotConfigured(operation: "show")
    }
}

struct UnconfiguredAssetPort: RecordingAssetPort {
    func export(id: RecordingID, destination: String) throws -> ExportReceipt {
        throw VMemoError.adapterNotConfigured(operation: "export")
    }
}

struct UnconfiguredWritePort: RecordingWritePort {
    func dryRun(_ request: MutationRequest) throws -> MutationPlan {
        throw VMemoError.adapterNotConfigured(operation: request.operation.description)
    }

    func execute(_ request: MutationRequest, authorization: MutationAuthorization) throws -> MutationResult {
        throw VMemoError.adapterNotConfigured(operation: request.operation.description)
    }
}
