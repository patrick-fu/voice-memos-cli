import Foundation

/// A fresh database projection is required for every resolver operation.  This is intentionally
/// separate from the read port: mutation safety must not retain a stale snapshot.
protocol ProductionMutationResolving: Sendable {
    func resolve(_ request: MutationRequest) throws -> ResolvedMutationTarget
    func verifyPostcondition(_ expected: ResolvedMutationTarget) throws
}

protocol PersistentMutationTokenStoreFactory: Sendable {
    func makeStore() throws -> PersistentMutationTokenStore
}

struct FilePersistentMutationTokenStoreFactory: PersistentMutationTokenStoreFactory {
    let rootDirectory: URL

    func makeStore() throws -> PersistentMutationTokenStore {
        // The durable root itself is created and validated by PersistentMutationTokenStore. Its
        // application-support parent may be absent on a fresh account, so create that parent only
        // when a mutation reaches this factory.
        try FileManager.default.createDirectory(
            at: rootDirectory.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return try PersistentMutationTokenStore(rootDirectory: rootDirectory)
    }
}

enum ProductionMutationWriteError: Error, Equatable, Sendable {
    case confirmationRequired
    case tokenExpired
    case tokenReplayed
    case tokenBindingMismatch
    case tokenGenerationFailed
    case tokenStoreUnavailable
    case sessionBusy
    case sessionUnavailable
    case preflightFailed
    case postconditionFailed

    var code: String {
        switch self {
        case .confirmationRequired: "mutation_authorization_required"
        case .tokenExpired: "token_expired"
        case .tokenReplayed: "token_replayed"
        case .tokenBindingMismatch: "token_binding_mismatch"
        case .tokenGenerationFailed: "token_generation_failed"
        case .tokenStoreUnavailable: "mutation_token_store_unavailable"
        case .sessionBusy: "mutation_session_busy"
        case .sessionUnavailable: "mutation_session_unavailable"
        case .preflightFailed: "mutation_preflight_failed"
        case .postconditionFailed: "mutation_postcondition_failed"
        }
    }

    var message: String {
        switch self {
        case .confirmationRequired: "Execution requires both --token and --confirm."
        case .tokenExpired: "The mutation authorization token has expired."
        case .tokenReplayed: "The mutation authorization token has already been used."
        case .tokenBindingMismatch: "The mutation authorization token does not match this action."
        case .tokenGenerationFailed: "A unique mutation authorization token could not be created."
        case .tokenStoreUnavailable: "The mutation authorization store is unavailable."
        case .sessionBusy: "Another mutation session is in progress."
        case .sessionUnavailable: "The mutation session lock is unavailable."
        case .preflightFailed: "The mutation target could not be safely verified."
        case .postconditionFailed: "The mutation result could not be safely verified."
        }
    }

    var exitCode: Int32 { ProcessExit.safetyFailure.rawValue }
}

/// Production mutation coordinator. The session lock spans every mutable boundary and a token is
/// consumed before the UI action, so uncertainty can never make a token reusable.
final class ProductionMutationWritePort: RecordingWritePort, @unchecked Sendable {
    private let resolver: any ProductionMutationResolving
    private let accessibility: any VoiceMemosAccessibility
    private let tokenStoreFactory: any PersistentMutationTokenStoreFactory
    private let clock: any MutationClock
    private let nonceGenerator: any MutationNonceGenerator
    private let environment: any MutationEnvironmentFingerprint
    private let tokenTTL: TimeInterval

    init(
        resolver: any ProductionMutationResolving,
        accessibility: any VoiceMemosAccessibility,
        tokenStoreFactory: any PersistentMutationTokenStoreFactory,
        clock: any MutationClock,
        nonceGenerator: any MutationNonceGenerator,
        environment: any MutationEnvironmentFingerprint,
        tokenTTL: TimeInterval = 30
    ) {
        self.resolver = resolver
        self.accessibility = accessibility
        self.tokenStoreFactory = tokenStoreFactory
        self.clock = clock
        self.nonceGenerator = nonceGenerator
        self.environment = environment
        self.tokenTTL = tokenTTL
    }

    func dryRun(_ request: MutationRequest) throws -> MutationPlan {
        let store = try makeStore()
        let session = try acquireSession(store)
        defer { session.release() }

        let resolved = try resolve(request)
        let mutation = try accessibilityMutation(for: resolved)
        let verification = try verify(mutation)
        let binding = binding(request: request, resolved: resolved, mutation: mutation, verification: verification)
        let token = nonceGenerator.nextNonce()
        do {
            try store.issue(token: token, binding: binding, expiresAt: clock.currentDate().addingTimeInterval(tokenTTL))
        } catch let error as PersistentMutationTokenStoreError {
            if error == .tokenAlreadyIssued { throw ProductionMutationWriteError.tokenGenerationFailed }
            throw ProductionMutationWriteError.tokenStoreUnavailable
        } catch {
            throw ProductionMutationWriteError.tokenStoreUnavailable
        }
        return MutationPlan(request: request, confirmationToken: token)
    }

    func execute(_ request: MutationRequest, authorization: MutationAuthorization) throws -> MutationResult {
        guard authorization.confirmed else { throw ProductionMutationWriteError.confirmationRequired }
        let store = try makeStore()
        let session = try acquireSession(store)
        defer { session.release() }

        let resolved = try resolve(request)
        let mutation = try accessibilityMutation(for: resolved)
        let verification = try verify(mutation)
        let binding = binding(request: request, resolved: resolved, mutation: mutation, verification: verification)
        switch try consume(store, token: authorization.token, binding: binding) {
        case .consumed:
            break
        case .missing, .bindingMismatch:
            throw ProductionMutationWriteError.tokenBindingMismatch
        case .expired:
            throw ProductionMutationWriteError.tokenExpired
        case .replayed:
            throw ProductionMutationWriteError.tokenReplayed
        }

        do {
            switch mutation {
            case .rename:
                try accessibility.rename(mutation)
            case .delete:
                try accessibility.delete(mutation)
            }
        } catch {
            throw ProductionMutationWriteError.postconditionFailed
        }
        do {
            try resolver.verifyPostcondition(resolved)
            try accessibility.verifyPostcondition(mutation)
        } catch {
            throw ProductionMutationWriteError.postconditionFailed
        }
        return MutationResult(request: request)
    }

    private func makeStore() throws -> PersistentMutationTokenStore {
        do { return try tokenStoreFactory.makeStore() }
        catch { throw ProductionMutationWriteError.tokenStoreUnavailable }
    }

    private func acquireSession(_ store: PersistentMutationTokenStore) throws -> PersistentMutationSessionLock {
        do { return try store.acquireMutationSession() }
        catch let error as PersistentMutationSessionLockError {
            throw error == .busy ? ProductionMutationWriteError.sessionBusy : .sessionUnavailable
        } catch {
            throw ProductionMutationWriteError.sessionUnavailable
        }
    }

    private func resolve(_ request: MutationRequest) throws -> ResolvedMutationTarget {
        do { return try resolver.resolve(request) }
        catch let error as ProductionMutationResolverError { throw error }
        catch let error as ProductionRecordingAdapterError { throw error }
        catch let error as SnapshottingRecordingReadError { throw error }
        catch { throw ProductionMutationWriteError.preflightFailed }
    }

    private func verify(_ mutation: VoiceMemosAccessibilityMutation) throws -> VoiceMemosAccessibilityVerification {
        do { return try accessibility.verify(mutation) }
        catch { throw ProductionMutationWriteError.preflightFailed }
    }

    private func consume(
        _ store: PersistentMutationTokenStore,
        token: String,
        binding: PersistentMutationTokenBinding
    ) throws -> PersistentMutationTokenConsumption {
        do { return try store.consume(token: token, binding: binding, at: clock.currentDate()) }
        catch { throw ProductionMutationWriteError.tokenStoreUnavailable }
    }

    private func accessibilityMutation(for resolved: ResolvedMutationTarget) throws -> VoiceMemosAccessibilityMutation {
        switch resolved.effect {
        case let .rename(expectedTitle, commitSink):
            return .rename(oldTitle: resolved.currentTitle, newTitle: expectedTitle, commitSinkTitle: commitSink.title)
        case .moveToRecentlyDeleted:
            return .delete(oldTitle: resolved.currentTitle)
        }
    }

    private func binding(
        request: MutationRequest,
        resolved: ResolvedMutationTarget,
        mutation: VoiceMemosAccessibilityMutation,
        verification: VoiceMemosAccessibilityVerification
    ) -> PersistentMutationTokenBinding {
        PersistentMutationTokenBinding(
            request: canonicalRequest(request),
            source: canonicalSource(resolved),
            accessibility: canonicalAccessibility(mutation, verification: verification),
            environment: environment.currentFingerprint()
        )
    }

    private func canonicalRequest(_ request: MutationRequest) -> String {
        switch request.operation {
        case let .rename(title): "v1|rename|\(field(request.id.value))|\(field(title))"
        case .moveToRecentlyDeleted: "v1|delete|\(field(request.id.value))"
        }
    }

    private func canonicalSource(_ resolved: ResolvedMutationTarget) -> String {
        let effect: String
        switch resolved.effect {
        case let .rename(expectedTitle, sink): effect = "rename|\(field(expectedTitle))|\(field(sink.id.value))|\(field(sink.title))"
        case .moveToRecentlyDeleted: effect = "delete"
        }
        return "v1|\(field(resolved.id.value))|\(field(resolved.currentTitle))|\(field(resolved.sourceFingerprint))|\(effect)"
    }

    private func canonicalAccessibility(
        _ mutation: VoiceMemosAccessibilityMutation,
        verification: VoiceMemosAccessibilityVerification
    ) -> String {
        let action: String
        switch mutation {
        case let .rename(oldTitle, newTitle, commitSinkTitle): action = "rename|\(field(oldTitle))|\(field(newTitle))|\(field(commitSinkTitle))"
        case let .delete(oldTitle): action = "delete|\(field(oldTitle))"
        }
        return "v1|\(action)|\(field(verification.targetTitle))|\(field(verification.bundleBuild))"
    }

    private func field(_ value: String) -> String { "\(value.utf8.count):\(value)" }
}

/// Freshly snapshots and validates the exact recognized schema for every call.
struct FreshProductionMutationResolver: ProductionMutationResolving {
    let source: URL
    let destinationRoot: URL
    let snapshot: any SnapshotPort
    let identity: RealSchemaIdentity
    let metadataReader: any PersistentStoreMetadataReading

    func resolve(_ request: MutationRequest) throws -> ResolvedMutationTarget {
        try withResolver { try $0.resolve(request) }
    }

    func verifyPostcondition(_ expected: ResolvedMutationTarget) throws {
        try withResolver { try $0.verifyPostcondition(expected) }
    }

    private func withResolver<Value>(_ body: (ProductionMutationResolver) throws -> Value) throws -> Value {
        let lease: any SnapshotLease
        do { lease = try snapshot.makeSnapshot(source: source, destinationRoot: destinationRoot) }
        catch { throw SnapshottingRecordingReadError.snapshotCreationFailed }
        let result: Result<Value, Error>
        if RealSchemaRecognizer(identity: identity, metadataReader: metadataReader).recognize(snapshot: lease) == .recognized {
            result = Result { try body(ProductionMutationResolver(snapshotURL: lease.url)) }
        } else {
            result = .failure(ProductionRecordingAdapterError.unsupportedSchema)
        }
        do { try lease.cleanup() }
        catch { throw SnapshottingRecordingReadError.snapshotCleanupFailed }
        return try result.get()
    }
}

struct SystemMutationClock: MutationClock { func currentDate() -> Date { Date() } }
struct SystemMutationNonceGenerator: MutationNonceGenerator { func nextNonce() -> String { UUID().uuidString } }
struct SystemMutationEnvironmentFingerprint: MutationEnvironmentFingerprint {
    func currentFingerprint() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        // This must be stable across the dry-run and confirmed CLI processes. UI state itself is
        // bound by the fresh AX semantic verification immediately before consume.
        let executable = ProcessInfo.processInfo.arguments.first ?? ""
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "v1|macos|\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)|exe|\(field(executable))|home|\(field(home))"
    }

    private func field(_ value: String) -> String { "\(value.utf8.count):\(value)" }
}
