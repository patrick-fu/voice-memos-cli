import Foundation

struct MutationCommitSink: Equatable, Sendable {
    let id: RecordingID
    let title: String
}

enum ResolvedMutationEffect: Equatable, Sendable {
    case rename(expectedTitle: String, commitSink: MutationCommitSink)
    case moveToRecentlyDeleted
}

struct ResolvedMutationTarget: Equatable, Sendable {
    let id: RecordingID
    let currentTitle: String
    let isActive: Bool
    let sourceFingerprint: String
    let effect: ResolvedMutationEffect
}

enum ProductionMutationResolverError: Error, Equatable, Sendable {
    case inactiveTarget
    case ambiguousTitle
    case invalidNewTitle
    case unchangedTitle
    case conflictingTitle
    case missingCommitSink
    case duplicateCommitSink
    case sourceFingerprintDrift
    case postconditionFailed

    var code: String {
        switch self {
        case .inactiveTarget: "inactive_mutation_target"
        case .ambiguousTitle: "ambiguous_mutation_title"
        case .invalidNewTitle: "invalid_mutation_title"
        case .unchangedTitle: "unchanged_mutation_title"
        case .conflictingTitle: "conflicting_mutation_title"
        case .missingCommitSink: "missing_commit_sink"
        case .duplicateCommitSink: "duplicate_commit_sink"
        case .sourceFingerprintDrift: "source_fingerprint_drift"
        case .postconditionFailed: "mutation_postcondition_failed"
        }
    }

    var message: String {
        switch self {
        case .inactiveTarget:
            "The mutation target is not an Active Recording."
        case .ambiguousTitle:
            "The mutation target title is not unique in the library."
        case .invalidNewTitle:
            "The new Recording title is empty."
        case .unchangedTitle:
            "The new Recording title is unchanged."
        case .conflictingTitle:
            "The new Recording title already exists in the library."
        case .missingCommitSink:
            "A distinct Active commit sink is required."
        case .duplicateCommitSink:
            "No uniquely titled Active commit sink is available."
        case .sourceFingerprintDrift:
            "The snapshot source fingerprint has changed."
        case .postconditionFailed:
            "The mutation result could not be verified against a fresh snapshot."
        }
    }

    var exitCode: Int32 { ProcessExit.safetyFailure.rawValue }
}

struct ProductionMutationResolver: Sendable {
    private let adapter: ProductionRecordingAdapter

    init(snapshotURL: URL) {
        adapter = ProductionRecordingAdapter(snapshotURL: snapshotURL)
    }

    func resolve(_ request: MutationRequest) throws -> ResolvedMutationTarget {
        try Self.resolve(request, in: adapter.validatedProjection())
    }

    func verifySourceFingerprint(_ expected: ResolvedMutationTarget) throws {
        let projection = try adapter.validatedProjection()
        guard projection.fingerprint == expected.sourceFingerprint else {
            throw ProductionMutationResolverError.sourceFingerprintDrift
        }
    }

    func verifyPostcondition(_ expected: ResolvedMutationTarget) throws {
        try Self.verifyPostcondition(expected, in: adapter.validatedProjection())
    }

    static func resolve(
        _ request: MutationRequest,
        in projection: ProductionValidatedProjection
    ) throws -> ResolvedMutationTarget {
        guard let target = projection.recordings.first(where: { utf8ExactEqual($0.id.value, request.id.value) }) else {
            throw ProductionRecordingAdapterError.recordingNotFound
        }
        guard target.isActive else {
            throw ProductionMutationResolverError.inactiveTarget
        }
        guard Self.titleCount(target.title, in: projection) == 1 else {
            throw ProductionMutationResolverError.ambiguousTitle
        }

        switch request.operation {
        case let .rename(newTitle):
            guard !newTitle.utf8.isEmpty else {
                throw ProductionMutationResolverError.invalidNewTitle
            }
            guard utf8ExactEqual(newTitle, target.title) == false else {
                throw ProductionMutationResolverError.unchangedTitle
            }
            guard Self.titleCount(newTitle, in: projection) == 0 else {
                throw ProductionMutationResolverError.conflictingTitle
            }
            let otherActives = projection.recordings.filter { $0.isActive && utf8ExactEqual($0.id.value, target.id.value) == false }
            let sinks = otherActives.filter { Self.titleCount($0.title, in: projection) == 1 }
            guard let sink = sinks.first else {
                throw otherActives.isEmpty
                    ? ProductionMutationResolverError.missingCommitSink
                    : ProductionMutationResolverError.duplicateCommitSink
            }
            return ResolvedMutationTarget(
                id: target.id,
                currentTitle: target.title,
                isActive: true,
                sourceFingerprint: projection.fingerprint,
                effect: .rename(
                    expectedTitle: newTitle,
                    commitSink: MutationCommitSink(id: sink.id, title: sink.title)
                )
            )
        case .moveToRecentlyDeleted:
            guard projection.recordings.contains(where: { $0.isActive == false && utf8ExactEqual($0.title, target.title) }) == false else {
                throw ProductionMutationResolverError.ambiguousTitle
            }
            return ResolvedMutationTarget(
                id: target.id,
                currentTitle: target.title,
                isActive: true,
                sourceFingerprint: projection.fingerprint,
                effect: .moveToRecentlyDeleted
            )
        }
    }

    static func verifyPostcondition(
        _ expected: ResolvedMutationTarget,
        in projection: ProductionValidatedProjection
    ) throws {
        guard let current = projection.recordings.first(where: { utf8ExactEqual($0.id.value, expected.id.value) }) else {
            throw ProductionMutationResolverError.postconditionFailed
        }
        switch expected.effect {
        case let .rename(expectedTitle, _):
            guard current.isActive, utf8ExactEqual(current.title, expectedTitle) else {
                throw ProductionMutationResolverError.postconditionFailed
            }
        case .moveToRecentlyDeleted:
            guard current.isActive == false else {
                throw ProductionMutationResolverError.postconditionFailed
            }
        }
    }

    private static func titleCount(_ title: String, in projection: ProductionValidatedProjection) -> Int {
        projection.recordings.reduce(0) { utf8ExactEqual($1.title, title) ? $0 + 1 : $0 }
    }
}
