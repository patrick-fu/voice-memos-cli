import Foundation

protocol MutationClock: Sendable {
    func currentDate() -> Date
}

protocol MutationNonceGenerator: Sendable {
    func nextNonce() -> String
}

protocol MutationEnvironmentFingerprint: Sendable {
    func currentFingerprint() -> String
}

/// A semantic seam for verified Voice Memos UI operations. Production remains unconfigured.
protocol AccessibilityClient: Sendable {
    func verifyTarget(_ request: MutationRequest) throws -> AccessibilityVerification
    func perform(_ request: MutationRequest) throws
    func verifyPostcondition(_ request: MutationRequest) throws
}

struct AccessibilityVerification: Equatable, Sendable {
    let targetBinding: String
    let nonce: String
}

enum AccessibilityClientError: Error, Equatable, Sendable {
    case untrusted
    case appMissing
    case windowMissing
    case ambiguousTarget
    case modalPresent
    case focusDrift
    case timeout
    case noPostcondition
}

struct MutationTokenBinding: Equatable, Sendable {
    let request: MutationRequest
    let environment: String
    let targetBinding: String
    let verificationNonce: String
}

struct MutationTokenRecord: Sendable {
    let binding: MutationTokenBinding
    let expiresAt: Date
    let consumed: Bool
}

enum MutationTokenConsumption: Sendable {
    case consumed
    case missing
    case expired
    case replayed
}

protocol MutationTokenStore: Sendable {
    func issue(token: String, binding: MutationTokenBinding, expiresAt: Date) -> Bool
    func record(for token: String) -> MutationTokenRecord?
    func consume(token: String, at date: Date) -> MutationTokenConsumption
}

final class InMemoryMutationTokenStore: MutationTokenStore, @unchecked Sendable {
    private struct StoredToken {
        let binding: MutationTokenBinding
        let expiresAt: Date
        var consumed = false
    }

    private let lock = NSLock()
    private var tokens: [String: StoredToken] = [:]

    func issue(token: String, binding: MutationTokenBinding, expiresAt: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard tokens[token] == nil else { return false }
        tokens[token] = StoredToken(binding: binding, expiresAt: expiresAt)
        return true
    }

    func record(for token: String) -> MutationTokenRecord? {
        lock.lock()
        defer { lock.unlock() }
        guard let token = tokens[token] else { return nil }
        return MutationTokenRecord(binding: token.binding, expiresAt: token.expiresAt, consumed: token.consumed)
    }

    func consume(token: String, at date: Date) -> MutationTokenConsumption {
        lock.lock()
        defer { lock.unlock() }
        guard var stored = tokens[token] else { return .missing }
        if stored.consumed { return .replayed }
        if stored.expiresAt <= date { return .expired }
        stored.consumed = true
        tokens[token] = stored
        return .consumed
    }
}

enum MutationAuthorizationError: Error, Equatable, Sendable {
    case confirmationRequired
    case tokenExpired
    case tokenReplayed
    case tokenBindingMismatch
    case tokenGenerationFailed
    case preflightFailed
    case postconditionFailed

    var code: String {
        switch self {
        case .confirmationRequired: "mutation_authorization_required"
        case .tokenExpired: "token_expired"
        case .tokenReplayed: "token_replayed"
        case .tokenBindingMismatch: "token_binding_mismatch"
        case .tokenGenerationFailed: "token_generation_failed"
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
        case .preflightFailed: "The mutation target could not be safely verified."
        case .postconditionFailed: "The mutation result could not be safely verified."
        }
    }

    var exitCode: Int32 { ProcessExit.safetyFailure.rawValue }
}

/// Authorization decorator for a future Accessibility-backed write port.
/// It deliberately does not import or invoke macOS Accessibility APIs.
final class MutationAuthorizingWritePort: RecordingWritePort, @unchecked Sendable {
    private let accessibility: any AccessibilityClient
    private let clock: any MutationClock
    private let nonceGenerator: any MutationNonceGenerator
    private let tokenStore: any MutationTokenStore
    private let environment: any MutationEnvironmentFingerprint
    private let tokenTTL: TimeInterval
    private let executionLock = NSLock()

    init(
        accessibility: any AccessibilityClient,
        clock: any MutationClock,
        nonceGenerator: any MutationNonceGenerator,
        tokenStore: any MutationTokenStore,
        environment: any MutationEnvironmentFingerprint,
        tokenTTL: TimeInterval
    ) {
        self.accessibility = accessibility
        self.clock = clock
        self.nonceGenerator = nonceGenerator
        self.tokenStore = tokenStore
        self.environment = environment
        self.tokenTTL = tokenTTL
    }

    func dryRun(_ request: MutationRequest) throws -> MutationPlan {
        let verification: AccessibilityVerification
        do {
            verification = try accessibility.verifyTarget(request)
        } catch {
            throw MutationAuthorizationError.preflightFailed
        }

        let token = nonceGenerator.nextNonce()
        let now = clock.currentDate()
        guard tokenStore.issue(
            token: token,
            binding: MutationTokenBinding(
                request: request,
                environment: environment.currentFingerprint(),
                targetBinding: verification.targetBinding,
                verificationNonce: verification.nonce
            ),
            expiresAt: now.addingTimeInterval(tokenTTL)
        ) else {
            throw MutationAuthorizationError.tokenGenerationFailed
        }
        return MutationPlan(request: request, confirmationToken: token)
    }

    func execute(_ request: MutationRequest, authorization: MutationAuthorization) throws -> MutationResult {
        executionLock.lock()
        defer { executionLock.unlock() }

        guard authorization.confirmed else {
            throw MutationAuthorizationError.confirmationRequired
        }
        let now = clock.currentDate()
        guard let record = tokenStore.record(for: authorization.token) else {
            throw MutationAuthorizationError.tokenBindingMismatch
        }
        if record.consumed {
            throw MutationAuthorizationError.tokenReplayed
        }
        if record.expiresAt <= now {
            throw MutationAuthorizationError.tokenExpired
        }
        guard record.binding.request == request,
              record.binding.environment == environment.currentFingerprint()
        else {
            throw MutationAuthorizationError.tokenBindingMismatch
        }

        do {
            let verification = try accessibility.verifyTarget(request)
            guard verification.targetBinding == record.binding.targetBinding,
                  verification.nonce != record.binding.verificationNonce
            else {
                throw MutationAuthorizationError.tokenBindingMismatch
            }
        } catch let error as MutationAuthorizationError {
            throw error
        } catch {
            throw MutationAuthorizationError.preflightFailed
        }
        guard record.binding.environment == environment.currentFingerprint() else {
            throw MutationAuthorizationError.tokenBindingMismatch
        }

        switch tokenStore.consume(token: authorization.token, at: clock.currentDate()) {
        case .consumed:
            break
        case .missing:
            throw MutationAuthorizationError.tokenBindingMismatch
        case .expired:
            throw MutationAuthorizationError.tokenExpired
        case .replayed:
            throw MutationAuthorizationError.tokenReplayed
        }

        do {
            try accessibility.perform(request)
        } catch {
            throw MutationAuthorizationError.postconditionFailed
        }
        do {
            try accessibility.verifyPostcondition(request)
        } catch {
            throw MutationAuthorizationError.postconditionFailed
        }
        return MutationResult(request: request)
    }
}
