import Foundation

enum SnapshottingRecordingReadError: Error, Equatable, Sendable {
    case snapshotCreationFailed
    case snapshotCleanupFailed

    var code: String {
        switch self {
        case .snapshotCreationFailed: "snapshot_creation_failed"
        case .snapshotCleanupFailed: "snapshot_cleanup_failed"
        }
    }

    var message: String {
        switch self {
        case .snapshotCreationFailed: "A read snapshot could not be created."
        case .snapshotCleanupFailed: "The read snapshot could not be removed."
        }
    }

    var exitCode: Int32 {
        ProcessExit.safetyFailure.rawValue
    }
}

struct SnapshottingRecordingReadPort: RecordingReadPort {
    let source: URL
    let destinationRoot: URL
    let snapshot: any SnapshotPort

    func list() throws -> [RecordingSummary] {
        try withSnapshot { try $0.list() }
    }

    func search(query: String) throws -> [RecordingSummary] {
        try withSnapshot { try $0.search(query: query) }
    }

    func show(id: RecordingID) throws -> RecordingSummary {
        try withSnapshot { try $0.show(id: id) }
    }

    private func withSnapshot<Value>(
        _ body: (SchemaAdapter) throws -> Value
    ) throws -> Value {
        let lease: any SnapshotLease
        do {
            lease = try snapshot.makeSnapshot(source: source, destinationRoot: destinationRoot)
        } catch {
            throw SnapshottingRecordingReadError.snapshotCreationFailed
        }

        let bodyResult: Result<Value, Error>
        do {
            bodyResult = .success(try body(SchemaAdapter(snapshotURL: lease.url)))
        } catch {
            bodyResult = .failure(error)
        }
        do {
            try lease.cleanup()
        } catch {
            throw SnapshottingRecordingReadError.snapshotCleanupFailed
        }
        return try bodyResult.get()
    }
}
