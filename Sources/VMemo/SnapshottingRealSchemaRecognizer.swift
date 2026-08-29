import Foundation

enum SnapshottingRealSchemaRecognitionError: Error, Equatable, Sendable {
    case snapshotCreationFailed
    case snapshotCleanupFailed

    var code: String {
        switch self {
        case .snapshotCreationFailed: "snapshot_creation_failed"
        case .snapshotCleanupFailed: "snapshot_cleanup_failed"
        }
    }
}

/// The recommended production entry for schema recognition.
///
/// It obtains an isolated snapshot before invoking the metadata-only recognizer and always
/// cleans that snapshot exactly once. Recognition authorizes only the subsequent physical and
/// row gates; it never by itself projects a recording.
struct SnapshottingRealSchemaRecognizer: Sendable {
    private let source: URL
    private let destinationRoot: URL
    private let snapshot: any SnapshotPort
    private let recognizer: RealSchemaRecognizer

    init(
        source: URL,
        destinationRoot: URL,
        snapshot: any SnapshotPort,
        identity: RealSchemaIdentity,
        metadataReader: any PersistentStoreMetadataReading
    ) {
        self.source = source
        self.destinationRoot = destinationRoot
        self.snapshot = snapshot
        self.recognizer = RealSchemaRecognizer(identity: identity, metadataReader: metadataReader)
    }

    func recognize() throws -> RealSchemaRecognition {
        let lease: any SnapshotLease
        do {
            lease = try snapshot.makeSnapshot(source: source, destinationRoot: destinationRoot)
        } catch {
            throw SnapshottingRealSchemaRecognitionError.snapshotCreationFailed
        }

        let recognition = recognizer.recognize(snapshot: lease)
        do {
            try lease.cleanup()
        } catch {
            throw SnapshottingRealSchemaRecognitionError.snapshotCleanupFailed
        }
        return recognition
    }
}
