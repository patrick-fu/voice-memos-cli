import CoreData
import CoreFoundation
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
    case recognized
    case unsupportedSchema

    var code: String {
        switch self {
        case .recognized: "recognized_schema"
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
    var modelVersionChecksum: PersistentStoreMetadataString
    var modelVersionHashesDigest: PersistentStoreMetadataString
    var modelVersionHashesVersion: PersistentStoreMetadataInteger
    var persistenceFrameworkVersion: PersistentStoreMetadataInteger
    var persistenceMaximumFrameworkVersion: PersistentStoreMetadataInteger
    var storeType: PersistentStoreMetadataString
    var modelVersionIdentifiers: PersistentStoreMetadataStringArray
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

enum PersistentStoreMetadataString: Equatable, Sendable {
    case string(String)
    case unsupportedValue
}

enum PersistentStoreMetadataInteger: Equatable, Sendable {
    case integer(Int)
    case unsupportedValue
}

enum PersistentStoreMetadataStringArray: Equatable, Sendable {
    case array([String])
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
            modelVersionChecksum: stringValue(in: metadata, forKey: "NSStoreModelVersionChecksumKey"),
            modelVersionHashesDigest: stringValue(in: metadata, forKey: "NSStoreModelVersionHashesDigest"),
            modelVersionHashesVersion: integerValue(in: metadata, forKey: "NSStoreModelVersionHashesVersion"),
            persistenceFrameworkVersion: integerValue(in: metadata, forKey: "NSPersistenceFrameworkVersion"),
            persistenceMaximumFrameworkVersion: integerValue(in: metadata, forKey: "NSPersistenceMaximumFrameworkVersion"),
            storeType: stringValue(in: metadata, forKey: NSStoreTypeKey),
            modelVersionIdentifiers: stringArrayValue(in: metadata, forKey: NSStoreModelVersionIdentifiersKey),
            isCompatibleWithRuntimeModel: model.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata)
        )
    }

    private func stringValue(in metadata: [String: Any], forKey key: String) -> PersistentStoreMetadataString {
        guard let value = metadata[key] as? String else { return .unsupportedValue }
        return .string(value)
    }

    private func integerValue(in metadata: [String: Any], forKey key: String) -> PersistentStoreMetadataInteger {
        Self.integerValue(metadata[key])
    }

    static func integerValue(_ value: Any?) -> PersistentStoreMetadataInteger {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFNumberGetTypeID()
        else {
            return .unsupportedValue
        }
        let cfNumber = number as CFNumber
        guard !CFNumberIsFloatType(cfNumber) else {
            return .unsupportedValue
        }
        if number.compare(0) == .orderedAscending {
            var int64: Int64 = 0
            guard CFNumberGetValue(cfNumber, .sInt64Type, &int64),
                  let integer = Int(exactly: int64)
            else {
                return .unsupportedValue
            }
            return .integer(integer)
        }
        // Unsigned CFNumbers above Int.max wrap when read as SInt64.
        guard let integer = Int(exactly: number.uint64Value) else {
            return .unsupportedValue
        }
        return .integer(integer)
    }

    private func stringArrayValue(in metadata: [String: Any], forKey key: String) -> PersistentStoreMetadataStringArray {
        guard let values = metadata[key] as? [Any],
              values.allSatisfy({ $0 is String })
        else {
            return .unsupportedValue
        }
        return .array(values.compactMap { $0 as? String })
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
              hasExactObservedStoreManifest(metadata)
        else {
            return .unsupportedSchema
        }
        return .recognized
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

    private func hasExactObservedStoreManifest(_ metadata: PersistentStoreMetadata) -> Bool {
        guard case let .dictionary(storeHashes) = metadata.entityVersionHashes,
              Set(storeHashes.keys) == Set(DocumentedRealSchema.observedStoreEntityVersionHashesByName.keys),
              metadata.modelVersionChecksum == .string(DocumentedRealSchema.observedStoreModelVersionChecksum),
              metadata.modelVersionHashesDigest == .string(DocumentedRealSchema.observedStoreModelVersionHashesDigest),
              metadata.modelVersionHashesVersion == .integer(DocumentedRealSchema.observedStoreModelVersionHashesVersion),
              metadata.persistenceFrameworkVersion == .integer(DocumentedRealSchema.persistenceFrameworkVersion),
              metadata.persistenceMaximumFrameworkVersion == .integer(DocumentedRealSchema.persistenceMaximumFrameworkVersion),
              metadata.storeType == .string(NSSQLiteStoreType),
              metadata.modelVersionIdentifiers == .array([""])
        else {
            return false
        }
        for (entityName, expectedHash) in DocumentedRealSchema.observedStoreEntityVersionHashesByName {
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
    static let observedStoreEntityVersionHashesByName: [String: Data] = [
        "CloudRecording": data("wzISBP+96pkUsBpdE2V3vJH08CnDBpBi8U/vSlVVosQ="),
        "DatabaseProperty": data("DdeyItMrmgzYUVyA8NUAc8cS1Sr4LwwTo+KneZZrPBI="),
        "EntityRevision": data("MCYSLwlQNrzkytEuk0Paa2vv7h+rbxnn3DWtIuHpxa0="),
        "Folder": data("BTuJxZB4F1ci2UMqAPo0Fx2Oif08rXM0z+/UQoivHc0="),
        "Migration": data("C9+RC8Owb0OTnIogkfdqVeaZV1hChUC6VuqvEwC0DUU="),
        "Recording": data("l+6Nf+h4pgpvs9n/EqyKB5n5y0F2UwNh6/6d/evM+L8="),
    ]
    static let observedStoreModelVersionChecksum = "n+kk0f+uLXPDvdioHyMqmLay6VQ65HLL8r1c4DUtcII="
    static let observedStoreModelVersionHashesDigest = "8aTQVFaRoWcJjSrfUWGNhWxyl4H+gmCjrDT9k9CLVmm9OnpUALJH6sPZWbA1xKKrPOrD6x93sSkxLvIrC13PCA=="
    static let observedStoreModelVersionHashesVersion = 3
    static let persistenceFrameworkVersion = 1526
    static let persistenceMaximumFrameworkVersion = 1526

    private static func data(_ base64: String) -> Data {
        guard let data = Data(base64Encoded: base64), data.count == entityHashLength else {
            preconditionFailure("Documented entity hash must be exactly 32 bytes.")
        }
        return data
    }
}
