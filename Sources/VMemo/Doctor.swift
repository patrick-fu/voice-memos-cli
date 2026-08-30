import Foundation
import Security

protocol DoctorPort: Sendable {
    func inspect() throws -> DoctorReport
}

struct DoctorReport: Equatable, Sendable, Codable {
    let status: DoctorReportStatus
    let checks: [DoctorCheck]

    var exitCode: Int32 {
        switch status {
        case .ready: 0
        case .blocked: ProcessExit.safetyFailure.rawValue
        case .incomplete: ProcessExit.partialFailure.rawValue
        }
    }
}

enum DoctorReportStatus: String, Equatable, Sendable, Codable {
    case ready
    case blocked
    case incomplete
}

struct DoctorCheck: Equatable, Sendable, Codable {
    let id: String
    let status: DoctorCheckStatus
    let code: String
    let details: [String]
}

enum DoctorCheckStatus: String, Equatable, Sendable, Codable {
    case ready
    case blocked
    case incomplete
}

protocol DoctorEnvironment: Sendable {
    func runtime() -> DoctorRuntime
    func voiceMemosApplication() -> DoctorApplicationMetadata?
    func library() -> DoctorLibraryMetadata
    func signing() -> DoctorSigningMetadata
    func productionContext() -> DoctorProductionContext
}

extension DoctorEnvironment {
    func productionContext() -> DoctorProductionContext { .disabled }
}

protocol DoctorApplicationMetadataResolver: Sendable {
    func voiceMemosApplication() -> DoctorApplicationMetadata?
}

struct DoctorRuntime: Sendable {
    let osMajor: Int
    let architecture: String
}

struct DoctorApplicationMetadata: Sendable {
    let version: String
    let build: String

    init(version: String, build: String = "unknown") {
        self.version = version
        self.build = build
    }
}

enum DoctorSchemaProbeResult: Equatable, Sendable {
    case recognized
    case unsupported
    case snapshotCreationFailure
    case snapshotCleanupFailure
}

struct DoctorSchemaProbe: Sendable {
    let run: @Sendable () -> DoctorSchemaProbeResult
}

struct DoctorProductionContext: Sendable {
    let recordingsRoot: URL?
    let schemaProbe: DoctorSchemaProbe?
    let configurationFailure: ProductionSystemConfigurationFailure?

    init(
        recordingsRoot: URL? = nil,
        schemaProbe: DoctorSchemaProbe? = nil,
        configurationFailure: ProductionSystemConfigurationFailure? = nil
    ) {
        self.recordingsRoot = recordingsRoot
        self.schemaProbe = schemaProbe
        self.configurationFailure = configurationFailure
    }

    static let disabled = DoctorProductionContext()
}

enum DoctorLibraryMetadata: Sendable {
    case unconfigured
    case available
    case missing
    case inaccessible
}

enum DoctorSigningMetadata: Sendable {
    case available
    case unavailable
}

struct SystemDoctorPort: DoctorPort {
    private let environment: any DoctorEnvironment

    init(environment: any DoctorEnvironment = SystemDoctorEnvironment()) {
        self.environment = environment
    }

    func inspect() throws -> DoctorReport {
        let runtime = environment.runtime()
        let application = environment.voiceMemosApplication()
        let library = environment.library()
        let signing = environment.signing()
        let productionContext = environment.productionContext()

        let checks = [
            runtimeCheck(runtime),
            applicationCheck(application),
            libraryCheck(library, recordingsRoot: productionContext.recordingsRoot),
            schemaCheck(productionContext),
            signingCheck(signing),
        ]
        return DoctorReport(status: reportStatus(for: checks), checks: checks)
    }

    private func runtimeCheck(_ runtime: DoctorRuntime) -> DoctorCheck {
        guard runtime.osMajor == 26 else {
            return DoctorCheck(
                id: "runtime",
                status: .blocked,
                code: "unsupported_os",
                details: ["macOS \(runtime.osMajor)", "Supported production runtime: macOS 26.", ProductVersion.displayName]
            )
        }
        guard ["arm64", "x86_64"].contains(runtime.architecture) else {
            return DoctorCheck(
                id: "runtime",
                status: .blocked,
                code: "unsupported_architecture",
                details: [runtime.architecture, "Supported architectures: arm64, x86_64.", ProductVersion.displayName]
            )
        }
        return DoctorCheck(
            id: "runtime",
            status: .ready,
            code: "runtime_supported",
            details: ["macOS \(runtime.osMajor)", runtime.architecture, ProductVersion.displayName]
        )
    }

    private func applicationCheck(_ application: DoctorApplicationMetadata?) -> DoctorCheck {
        guard let application else {
            return DoctorCheck(
                id: "voice_memos",
                status: .blocked,
                code: "voice_memos_app_missing",
                details: ["Voice Memos application metadata was not found."]
            )
        }
        guard application.build == "1380" else {
            return DoctorCheck(
                id: "voice_memos",
                status: .blocked,
                code: "unsupported_voice_memos_build",
                details: [
                    "short version \(application.version)",
                    "build \(application.build)",
                    "Supported build: 1380.",
                ]
            )
        }
        return DoctorCheck(
            id: "voice_memos",
            status: .ready,
            code: "app_available",
            details: ["short version \(application.version)", "build \(application.build)"]
        )
    }

    private func libraryCheck(_ library: DoctorLibraryMetadata, recordingsRoot: URL?) -> DoctorCheck {
        let rootDetail = recordingsRoot.map { ["Configured recordings root: \($0.path)."] } ?? []
        switch library {
        case .unconfigured:
            return DoctorCheck(id: "library", status: .incomplete, code: "library_not_configured", details: ["No library path is configured."])
        case .available:
            return DoctorCheck(id: "library", status: .ready, code: "library_accessible", details: rootDetail)
        case .missing:
            return DoctorCheck(id: "library", status: .blocked, code: "library_path_missing", details: rootDetail)
        case .inaccessible:
            return DoctorCheck(id: "library", status: .blocked, code: "library_path_inaccessible", details: rootDetail)
        }
    }

    private func signingCheck(_ signing: DoctorSigningMetadata) -> DoctorCheck {
        switch signing {
        case .available:
            DoctorCheck(id: "signing", status: .ready, code: "signing_metadata_available", details: ["Current-process signing metadata is available."])
        case .unavailable:
            DoctorCheck(id: "signing", status: .incomplete, code: "signing_metadata_unavailable", details: ["Current-process signing metadata is unavailable."])
        }
    }

    private func schemaCheck(_ context: DoctorProductionContext) -> DoctorCheck {
        if let failure = context.configurationFailure {
            return DoctorCheck(
                id: "schema",
                status: .blocked,
                code: failure.code,
                details: failure.doctorDetails
            )
        }
        let probe = context.schemaProbe
        guard let probe else {
            return DoctorCheck(
                id: "schema",
                status: .blocked,
                code: "schema_not_configured",
                details: ["Production schema evidence was not configured."]
            )
        }
        switch probe.run() {
        case .recognized:
            return DoctorCheck(
                id: "schema",
                status: .ready,
                code: "schema_recognized",
                details: ["Exact production store schema was recognized from metadata only."]
            )
        case .unsupported:
            return DoctorCheck(
                id: "schema",
                status: .blocked,
                code: "unsupported_schema",
                details: ["The production store metadata does not match the supported schema."]
            )
        case .snapshotCreationFailure:
            return DoctorCheck(
                id: "schema",
                status: .blocked,
                code: "snapshot_creation_failed",
                details: ["A metadata-only production schema snapshot could not be created."]
            )
        case .snapshotCleanupFailure:
            return DoctorCheck(
                id: "schema",
                status: .blocked,
                code: "snapshot_cleanup_failed",
                details: ["A metadata-only production schema snapshot could not be removed."]
            )
        }
    }

    private func reportStatus(for checks: [DoctorCheck]) -> DoctorReportStatus {
        if checks.contains(where: { $0.status == .blocked }) { return .blocked }
        if checks.contains(where: { $0.status == .incomplete }) { return .incomplete }
        return .ready
    }
}

struct SystemDoctorEnvironment: DoctorEnvironment {
    private let context: DoctorProductionContext
    private let libraryURL: URL?
    private let applicationResolver: any DoctorApplicationMetadataResolver

    init(
        libraryURL: URL? = nil,
        context: DoctorProductionContext = .disabled,
        applicationResolver: any DoctorApplicationMetadataResolver = SystemVoiceMemosApplicationMetadataResolver()
    ) {
        self.context = context
        self.libraryURL = context.recordingsRoot ?? libraryURL
        self.applicationResolver = applicationResolver
    }

    func runtime() -> DoctorRuntime {
        DoctorRuntime(
            osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            architecture: architecture
        )
    }

    func voiceMemosApplication() -> DoctorApplicationMetadata? {
        applicationResolver.voiceMemosApplication()
    }

    func library() -> DoctorLibraryMetadata {
        guard let libraryURL else { return .unconfigured }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: libraryURL.path, isDirectory: &isDirectory) else { return .missing }
        guard isDirectory.boolValue, FileManager.default.isReadableFile(atPath: libraryURL.path) else { return .inaccessible }
        do {
            _ = try FileManager.default.attributesOfItem(atPath: libraryURL.path)
            return .available
        } catch {
            return .inaccessible
        }
    }

    func signing() -> DoctorSigningMetadata {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return .unavailable }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return .unavailable }
        var information: CFDictionary?
        return SecCodeCopySigningInformation(staticCode, SecCSFlags(), &information) == errSecSuccess ? .available : .unavailable
    }

    private var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    func productionContext() -> DoctorProductionContext { context }
}

struct SystemVoiceMemosApplicationMetadataResolver: DoctorApplicationMetadataResolver {
    private let candidateURLs: [URL]

    init(candidateURLs: [URL] = [
        URL(fileURLWithPath: "/System/Applications/VoiceMemos.app", isDirectory: true),
        URL(fileURLWithPath: "/System/Applications/Voice Memos.app", isDirectory: true),
    ]) {
        self.candidateURLs = candidateURLs
    }

    func voiceMemosApplication() -> DoctorApplicationMetadata? {
        for url in candidateURLs {
            guard let bundle = Bundle(url: url), bundle.bundleIdentifier == "com.apple.VoiceMemos" else { continue }
            let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
            return DoctorApplicationMetadata(version: stableMetadataValue(version), build: stableMetadataValue(build))
        }
        return nil
    }

    private func stableMetadataValue(_ value: String) -> String {
        value.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }
}
