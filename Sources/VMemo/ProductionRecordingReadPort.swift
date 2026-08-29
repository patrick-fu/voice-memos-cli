import CoreData
import CryptoKit
import Foundation

/// Production coordinator. Every operation gets a fresh SQLite backup, runs the existing exact
/// identity + persistent-store-manifest gate on that backup, then opens only that backup.
struct ProductionRecordingReadPort: RecordingReadPort, RecordingAssetReferenceResolver {
    let source: URL
    let destinationRoot: URL
    let snapshot: any SnapshotPort
    let identity: RealSchemaIdentity
    let metadataReader: any PersistentStoreMetadataReading

    func list() throws -> [RecordingSummary] { try withAdapter { try $0.list() } }
    func search(query: String) throws -> [RecordingSummary] { try withAdapter { try $0.search(query: query) } }
    func show(id: RecordingID) throws -> RecordingSummary { try withAdapter { try $0.show(id: id) } }
    func assetReference(for id: RecordingID) throws -> String? { try withAdapter { try $0.assetReference(for: id) } }

    private func withAdapter<Value>(_ body: (ProductionRecordingAdapter) throws -> Value) throws -> Value {
        let lease: any SnapshotLease
        do { lease = try snapshot.makeSnapshot(source: source, destinationRoot: destinationRoot) }
        catch { throw SnapshottingRecordingReadError.snapshotCreationFailed }
        let result: Result<Value, Error>
        if RealSchemaRecognizer(identity: identity, metadataReader: metadataReader).recognize(snapshot: lease) == .recognized {
            result = Result { try body(ProductionRecordingAdapter(snapshotURL: lease.url)) }
        } else {
            result = .failure(ProductionRecordingAdapterError.unsupportedSchema)
        }
        do { try lease.cleanup() }
        catch { throw SnapshottingRecordingReadError.snapshotCleanupFailed }
        return try result.get()
    }
}

enum SystemProductionAdapterFactory {
    static func makeRunner() -> CommandRunner {
        guard let configuration = configuration() else {
            return CommandRunner(read: UnsupportedProductionReadPort(), asset: UnsupportedProductionAssetPort(), write: UnconfiguredWritePort(), doctor: SystemDoctorPort())
        }
        let read = ProductionRecordingReadPort(
            source: configuration.recordingsRoot.appendingPathComponent("CloudRecordings.db"),
            destinationRoot: FileManager.default.temporaryDirectory,
            snapshot: SQLiteSnapshotAdapter(),
            identity: configuration.identity,
            metadataReader: CoreDataPersistentStoreMetadataReader(model: configuration.model)
        )
        return CommandRunner(
            read: read,
            asset: SafeRecordingAssetPort(recordingsRoot: configuration.recordingsRoot, resolver: read),
            write: UnconfiguredWritePort(),
            doctor: SystemDoctorPort()
        )
    }

    static func configuration(artifacts: any ProductionSystemArtifacts = SystemProductionArtifacts()) -> (recordingsRoot: URL, identity: RealSchemaIdentity, model: NSManagedObjectModel)? {
        let osMajor = artifacts.runtimeOSMajor()
        guard osMajor == 26 else { return nil }
        let app = URL(fileURLWithPath: "/System/Applications/VoiceMemos.app", isDirectory: true)
        let modelURL = URL(fileURLWithPath: "/System/iOSSupport/System/Library/PrivateFrameworks/VoiceMemos.framework/Versions/A/Resources/VoiceMemos.momd/VoiceMemos14.mom")
        let versionURL = modelURL.deletingLastPathComponent().appendingPathComponent("VersionInfo.plist")
        guard artifacts.isReadable(app), artifacts.isReadable(modelURL), artifacts.isReadable(versionURL) else { return nil }

        let environment = artifacts.environment()
        let root: URL
        if let injected = environment["VMEMO_RECORDINGS_ROOT"], !injected.isEmpty {
            root = URL(fileURLWithPath: injected, isDirectory: true)
        } else {
            root = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings", isDirectory: true)
        }
        guard let bundle = artifacts.bundle(at: app),
              let model = artifacts.model(at: modelURL),
              let modelData = try? artifacts.data(at: modelURL),
              let versionData = try? artifacts.data(at: versionURL),
              let versionInfo = try? PropertyListSerialization.propertyList(from: versionData, format: nil) as? [String: Any],
              versionInfo["NSManagedObjectModel_CurrentVersionName"] as? String == "VoiceMemos14",
              let checksums = versionInfo["NSManagedObjectModel_VersionChecksums"] as? [String: Any],
              checksums["VoiceMemos14"] as? String == "f2VnefWShYEiB9Sc058A/GWR/33tzv6vFKYxARhArH0=",
              SHA256.hash(data: modelData).map({ String(format: "%02x", $0) }).joined() == "551215bc009cf2ca2282c3876fb8d454d526fb5c0158c5a2818a9c2243cbe052"
        else { return nil }
        let identity = RealSchemaIdentity(
            osMajor: osMajor,
            bundleIdentifier: bundle.bundleIdentifier ?? "",
            bundleBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            hasModelArtifact: true,
            hasVersionInfoArtifact: true,
            currentModelName: "VoiceMemos14",
            archivedModelChecksum: "f2VnefWShYEiB9Sc058A/GWR/33tzv6vFKYxARhArH0=",
            modelSHA256: "551215bc009cf2ca2282c3876fb8d454d526fb5c0158c5a2818a9c2243cbe052",
            // The exact value is additionally tied to the on-disk model SHA above. Asking Core
            // Data for this while its model remains editable emits diagnostics to stderr.
            runtimeModelVersionChecksum: "Rzot3jLpeh6rB1e94kW4C0J/n0J243OW8MgFMbjWzE4=",
            runtimeEntityVersionHashesByName: model.entitiesByName.mapValues(\.versionHash)
        )
        return (root, identity, model)
    }
}

protocol ProductionSystemArtifacts {
    func runtimeOSMajor() -> Int
    func environment() -> [String: String]
    func isReadable(_ url: URL) -> Bool
    func bundle(at url: URL) -> Bundle?
    func model(at url: URL) -> NSManagedObjectModel?
    func data(at url: URL) throws -> Data
}

struct SystemProductionArtifacts: ProductionSystemArtifacts {
    func runtimeOSMajor() -> Int { ProcessInfo.processInfo.operatingSystemVersion.majorVersion }
    func environment() -> [String: String] { ProcessInfo.processInfo.environment }
    func isReadable(_ url: URL) -> Bool { FileManager.default.isReadableFile(atPath: url.path) }
    func bundle(at url: URL) -> Bundle? { Bundle(url: url) }
    func model(at url: URL) -> NSManagedObjectModel? { NSManagedObjectModel(contentsOf: url) }
    func data(at url: URL) throws -> Data { try Data(contentsOf: url) }
}

private struct UnsupportedProductionReadPort: RecordingReadPort {
    func list() throws -> [RecordingSummary] { throw ProductionRecordingAdapterError.unsupportedSchema }
    func search(query: String) throws -> [RecordingSummary] { throw ProductionRecordingAdapterError.unsupportedSchema }
    func show(id: RecordingID) throws -> RecordingSummary { throw ProductionRecordingAdapterError.unsupportedSchema }
}

private struct UnsupportedProductionAssetPort: RecordingAssetPort {
    func export(id: RecordingID, destination: String) throws -> ExportReceipt { throw ProductionRecordingAdapterError.unsupportedSchema }
}
