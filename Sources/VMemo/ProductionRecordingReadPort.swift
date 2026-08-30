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
    static func makeRunner(artifacts: any ProductionSystemArtifacts = SystemProductionArtifacts()) -> CommandRunner {
        let state = assemblyState(artifacts: artifacts)
        let doctor = SystemDoctorPort(
            environment: SystemDoctorEnvironment(
                context: state.context
            )
        )
        guard let configuration = state.configuration else {
            guard let failure = state.failure else {
                preconditionFailure("A failed production assembly must retain its failure reason.")
            }
            return CommandRunner(
                read: UnsupportedProductionReadPort(failure: failure),
                asset: UnsupportedProductionAssetPort(failure: failure),
                doctor: doctor
            )
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
            doctor: doctor
        )
    }

    static func assemble(artifacts: any ProductionSystemArtifacts = SystemProductionArtifacts()) -> ProductionSystemConfiguration? {
        assemblyState(artifacts: artifacts).configuration
    }

    static func configuration(artifacts: any ProductionSystemArtifacts = SystemProductionArtifacts()) -> (recordingsRoot: URL, identity: RealSchemaIdentity, model: NSManagedObjectModel)? {
        guard let configuration = assemble(artifacts: artifacts) else { return nil }
        return (
            configuration.recordingsRoot,
            configuration.identity,
            configuration.model
        )
    }

    static func assemblyState(artifacts: any ProductionSystemArtifacts = SystemProductionArtifacts()) -> ProductionSystemAssemblyState {
        let rootDecision = RecordingsRootPolicy.evaluate(artifacts.environment()["VMEMO_RECORDINGS_ROOT"])
        let recordingsRoot: URL
        switch rootDecision {
        case .productionDefault:
            recordingsRoot = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings", isDirectory: true)
        case let .injected(url):
            recordingsRoot = url
        case let .rejected(reason):
            let failure = ProductionSystemConfigurationFailure.invalidRecordingsRoot(reason)
            return .failed(failure, context: failureContext(failure, recordingsRoot: nil))
        }

        let osMajor = artifacts.runtimeOSMajor()
        guard osMajor == 26 else {
            let failure = ProductionSystemConfigurationFailure.unsupportedOS
            return .failed(failure, context: failureContext(failure, recordingsRoot: recordingsRoot))
        }
        let app = URL(fileURLWithPath: "/System/Applications/VoiceMemos.app", isDirectory: true)
        let modelURL = URL(fileURLWithPath: "/System/iOSSupport/System/Library/PrivateFrameworks/VoiceMemos.framework/Versions/A/Resources/VoiceMemos.momd/VoiceMemos14.mom")
        let versionURL = modelURL.deletingLastPathComponent().appendingPathComponent("VersionInfo.plist")
        guard artifacts.isReadable(app), artifacts.isReadable(modelURL), artifacts.isReadable(versionURL) else {
            let failure = ProductionSystemConfigurationFailure.missingArtifacts
            return .failed(failure, context: failureContext(failure, recordingsRoot: recordingsRoot))
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
        else {
            let failure = ProductionSystemConfigurationFailure.invalidModelEvidence
            return .failed(failure, context: failureContext(failure, recordingsRoot: recordingsRoot))
        }
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
        let configuration = ProductionSystemConfiguration(
            recordingsRoot: recordingsRoot,
            identity: identity,
            model: model,
            doctorContext: metadataProbeContext(
                recordingsRoot: recordingsRoot,
                identity: identity,
                model: model
            )
        )
        return .configured(configuration)
    }

    private static func failureContext(
        _ failure: ProductionSystemConfigurationFailure,
        recordingsRoot: URL?
    ) -> DoctorProductionContext {
        DoctorProductionContext(recordingsRoot: recordingsRoot, configurationFailure: failure)
    }

    private static func metadataProbeContext(
        recordingsRoot: URL,
        identity: RealSchemaIdentity,
        model: NSManagedObjectModel
    ) -> DoctorProductionContext {
        let source = recordingsRoot.appendingPathComponent("CloudRecordings.db", isDirectory: false)
        let destinationRoot = FileManager.default.temporaryDirectory
        let probe = SnapshottingRealSchemaRecognizer(
            source: source,
            destinationRoot: destinationRoot,
            snapshot: SQLiteSnapshotAdapter(),
            identity: identity,
            metadataReader: CoreDataPersistentStoreMetadataReader(model: model)
        )
        return DoctorProductionContext(
            recordingsRoot: recordingsRoot,
            schemaProbe: DoctorSchemaProbe {
                do {
                    return try probe.recognize() == .recognized ? .recognized : .unsupported
                } catch let error as SnapshottingRealSchemaRecognitionError {
                    switch error {
                    case .snapshotCreationFailed: return .snapshotCreationFailure
                    case .snapshotCleanupFailed: return .snapshotCleanupFailure
                    }
                } catch {
                    return .snapshotCreationFailure
                }
            }
        )
    }
}

struct ProductionSystemConfiguration {
    let recordingsRoot: URL
    let identity: RealSchemaIdentity
    let model: NSManagedObjectModel
    let doctorContext: DoctorProductionContext
}

enum ProductionSystemConfigurationFailure: Error, Equatable, Sendable {
    case invalidRecordingsRoot(String)
    case unsupportedOS
    case missingArtifacts
    case invalidModelEvidence

    var code: String {
        switch self {
        case .invalidRecordingsRoot: "invalid_recordings_root"
        case .unsupportedOS: "unsupported_os"
        case .missingArtifacts: "production_artifacts_missing"
        case .invalidModelEvidence: "invalid_model_evidence"
        }
    }

    var message: String {
        switch self {
        case let .invalidRecordingsRoot(reason): reason
        case .unsupportedOS: "The production adapter supports only macOS 26."
        case .missingArtifacts: "Required Voice Memos production artifacts are unavailable."
        case .invalidModelEvidence: "Voice Memos model evidence does not match the supported production build."
        }
    }

    var doctorDetails: [String] {
        switch self {
        case let .invalidRecordingsRoot(reason): [reason]
        case .unsupportedOS: ["Production adapter support is limited to macOS 26."]
        case .missingArtifacts: ["Required Voice Memos application or model artifacts are unavailable."]
        case .invalidModelEvidence: ["Voice Memos model evidence does not match the supported production build."]
        }
    }
}

enum ProductionSystemAssemblyState {
    case configured(ProductionSystemConfiguration)
    case failed(ProductionSystemConfigurationFailure, context: DoctorProductionContext)

    var configuration: ProductionSystemConfiguration? {
        if case let .configured(configuration) = self { return configuration }
        return nil
    }

    var failure: ProductionSystemConfigurationFailure? {
        if case let .failed(failure, _) = self { return failure }
        return nil
    }

    var context: DoctorProductionContext {
        switch self {
        case let .configured(configuration): configuration.doctorContext
        case let .failed(_, context): context
        }
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
    let failure: ProductionSystemConfigurationFailure

    func list() throws -> [RecordingSummary] { throw failure }
    func search(query: String) throws -> [RecordingSummary] { throw failure }
    func show(id: RecordingID) throws -> RecordingSummary { throw failure }
}

private struct UnsupportedProductionAssetPort: RecordingAssetPort {
    let failure: ProductionSystemConfigurationFailure

    func export(id: RecordingID, destination: String) throws -> ExportReceipt { throw failure }
}
