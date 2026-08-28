import CoreData
import Foundation

/// The system and bundle evidence required to recognize the documented macOS 26 model.
/// This is deliberately data-only so callers can collect it outside the recognizer.
struct RealSchemaIdentity: Equatable, Sendable {
    var osMajor: Int
    var bundleIdentifier: String
    var bundleBuild: String
    var hasModelArtifact: Bool
    var hasVersionInfoArtifact: Bool
    var currentModelName: String
    var archivedModelChecksum: String
    var modelSHA256: String
    var runtimeModelVersionChecksum: String
    var runtimeEntityVersionHashesByName: [String: Data]
}

enum RealSchemaRecognition: Equatable, Sendable {
    case needsDisposableValidation
    case unsupportedSchema

    var code: String {
        switch self {
        case .needsDisposableValidation: "needs_disposable_validation"
        case .unsupportedSchema: "unsupported_schema"
        }
    }
}

/// A metadata-only boundary for a snapshot that was already isolated by `SnapshotPort`.
/// This is a caller-owned low-level seam for tests; production callers use
/// `SnapshottingRealSchemaRecognizer`. It intentionally offers no API for reading recording
/// rows or executing SQLite SQL.
protocol PersistentStoreMetadataReading: Sendable {
    func readMetadata(from isolatedSnapshot: any SnapshotLease) throws -> PersistentStoreMetadata
}

struct PersistentStoreMetadata: Equatable, Sendable {
    var entityVersionHashes: PersistentStoreEntityVersionHashes
    var isCompatibleWithRuntimeModel: Bool
}

enum PersistentStoreEntityVersionHashes: Equatable, Sendable {
    case dictionary([String: PersistentStoreMetadataValue])
    case unsupportedRepresentation
}

enum PersistentStoreMetadataValue: Equatable, Sendable {
    case data(Data)
    case unsupportedValue
}

/// Reads only Core Data persistent-store metadata from a previously isolated snapshot.
/// It neither opens a live store nor uses SQLite row-reading APIs.
///
/// `NSManagedObjectModel` is not Sendable. This type is `@unchecked Sendable` only because it
/// makes a private copy at initialization and serializes every use of that copy with `lock`.
struct CoreDataPersistentStoreMetadataReader: PersistentStoreMetadataReading, @unchecked Sendable {
    private let model: NSManagedObjectModel
    private let lock = NSLock()

    init(model: NSManagedObjectModel) {
        self.model = model.copy() as! NSManagedObjectModel
    }

    func readMetadata(from isolatedSnapshot: any SnapshotLease) throws -> PersistentStoreMetadata {
        lock.lock()
        defer { lock.unlock() }
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType,
            at: isolatedSnapshot.url,
            options: [NSReadOnlyPersistentStoreOption: true]
        )
        let entityVersionHashes: PersistentStoreEntityVersionHashes
        if let hashes = metadata[NSStoreModelVersionHashesKey] as? [String: Any] {
            entityVersionHashes = .dictionary(hashes.mapValues { value in
                guard let data = value as? Data else { return .unsupportedValue }
                return .data(data)
            })
        } else {
            entityVersionHashes = .unsupportedRepresentation
        }
        return PersistentStoreMetadata(
            entityVersionHashes: entityVersionHashes,
            isCompatibleWithRuntimeModel: model.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata)
        )
    }
}

/// Recognizes only the documented model identity and store metadata contract.
/// This is a caller-owned low-level seam for tests; production callers use
/// `SnapshottingRealSchemaRecognizer`. Recognition never authorizes recording projection,
/// search, display, or export.
struct RealSchemaRecognizer: Sendable {
    private let identity: RealSchemaIdentity
    private let metadataReader: any PersistentStoreMetadataReading

    init(identity: RealSchemaIdentity, metadataReader: any PersistentStoreMetadataReading) {
        self.identity = identity
        self.metadataReader = metadataReader
    }

    func recognize(snapshot: any SnapshotLease) -> RealSchemaRecognition {
        guard isDocumentedIdentity(identity) else { return .unsupportedSchema }
        guard let metadata = try? metadataReader.readMetadata(from: snapshot),
              hasExactRuntimeEntityHashes(metadata, runtimeHashes: identity.runtimeEntityVersionHashesByName),
              metadata.isCompatibleWithRuntimeModel
        else {
            return .unsupportedSchema
        }
        return .needsDisposableValidation
    }

    private func isDocumentedIdentity(_ identity: RealSchemaIdentity) -> Bool {
        identity.osMajor == 26
            && identity.bundleIdentifier == DocumentedRealSchema.bundleIdentifier
            && identity.bundleBuild == DocumentedRealSchema.bundleBuild
            && identity.hasModelArtifact
            && identity.hasVersionInfoArtifact
            && identity.currentModelName == DocumentedRealSchema.currentModelName
            && identity.archivedModelChecksum == DocumentedRealSchema.archivedModelChecksum
            && identity.modelSHA256 == DocumentedRealSchema.modelSHA256
            && identity.runtimeModelVersionChecksum == DocumentedRealSchema.runtimeModelVersionChecksum
            && identity.runtimeEntityVersionHashesByName == DocumentedRealSchema.runtimeEntityVersionHashesByName
    }

    private func hasExactRuntimeEntityHashes(
        _ metadata: PersistentStoreMetadata,
        runtimeHashes: [String: Data]
    ) -> Bool {
        guard case let .dictionary(storeHashes) = metadata.entityVersionHashes,
              Set(storeHashes.keys) == Set(runtimeHashes.keys)
        else {
            return false
        }
        for (entityName, expectedHash) in runtimeHashes {
            guard expectedHash.count == DocumentedRealSchema.entityHashLength,
                  case let .data(storeHash)? = storeHashes[entityName],
                  storeHash.count == DocumentedRealSchema.entityHashLength,
                  storeHash == expectedHash
            else {
                return false
            }
        }
        return true
    }
}

private enum DocumentedRealSchema {
    static let bundleIdentifier = "com.apple.VoiceMemos"
    static let bundleBuild = "1380"
    static let currentModelName = "VoiceMemos14"
    static let archivedModelChecksum = "f2VnefWShYEiB9Sc058A/GWR/33tzv6vFKYxARhArH0="
    static let modelSHA256 = "551215bc009cf2ca2282c3876fb8d454d526fb5c0158c5a2818a9c2243cbe052"
    static let runtimeModelVersionChecksum = "Rzot3jLpeh6rB1e94kW4C0J/n0J243OW8MgFMbjWzE4="
    static let entityHashLength = 32
    static let runtimeEntityVersionHashesByName: [String: Data] = [
        "CloudRecording": data("Q5vgte0JyNzGeRWTSQMvMe/yCVv4FqwlLinaPgrxQpw="),
        "DatabaseProperty": data("DdeyItMrmgzYUVyA8NUAc8cS1Sr4LwwTo+KneZZrPBI="),
        "EntityRevision": data("MCYSLwlQNrzkytEuk0Paa2vv7h+rbxnn3DWtIuHpxa0="),
        "Folder": data("BTuJxZB4F1ci2UMqAPo0Fx2Oif08rXM0z+/UQoivHc0="),
        "Migration": data("C9+RC8Owb0OTnIogkfdqVeaZV1hChUC6VuqvEwC0DUU="),
        "Recording": data("l+6Nf+h4pgpvs9n/EqyKB5n5y0F2UwNh6/6d/evM+L8="),
    ]

    private static func data(_ base64: String) -> Data {
        guard let data = Data(base64Encoded: base64), data.count == entityHashLength else {
            preconditionFailure("Documented entity hash must be exactly 32 bytes.")
        }
        return data
    }
}
