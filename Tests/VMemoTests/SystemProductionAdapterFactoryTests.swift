import CoreData
import Foundation
import XCTest
@testable import VMemo

final class SystemProductionAdapterFactoryTests: XCTestCase {
    func testUnsupportedOSReturnsNilBeforeTouchingBundleModelOrArtifactData() {
        let artifacts = FactoryArtifacts(osMajor: 15, readable: [true, true, true])

        XCTAssertNil(SystemProductionAdapterFactory.configuration(artifacts: artifacts))
        XCTAssertEqual(artifacts.readableCalls, 0)
        XCTAssertEqual(artifacts.bundleCalls, 0)
        XCTAssertEqual(artifacts.modelCalls, 0)
        XCTAssertEqual(artifacts.dataCalls, 0)
    }

    func testMissingModelArtifactReturnsNilBeforeLoadingBundleOrModel() {
        let artifacts = FactoryArtifacts(osMajor: 26, readable: [true, false])

        XCTAssertNil(SystemProductionAdapterFactory.configuration(artifacts: artifacts))
        XCTAssertEqual(artifacts.readableCalls, 2)
        XCTAssertEqual(artifacts.bundleCalls, 0)
        XCTAssertEqual(artifacts.modelCalls, 0)
        XCTAssertEqual(artifacts.dataCalls, 0)
    }

    func testFactoryFailureReasonsReachCommandsAsDistinctSafetyFailures() throws {
        let cases: [(FactoryArtifacts, String, String)] = [
            (FactoryArtifacts(osMajor: 15, readable: [true, true, true]), "unsupported_os", "macOS 26"),
            (FactoryArtifacts(osMajor: 26, readable: [true, false]), "production_artifacts_missing", "artifacts"),
            (FactoryArtifacts(osMajor: 26, readable: [true, true, true], environment: ["VMEMO_RECORDINGS_ROOT": "relative"]), "invalid_recordings_root", "valid path"),
            (FactoryArtifacts(osMajor: 26, readable: [true, true, true]), "invalid_model_evidence", "model evidence"),
        ]

        for (artifacts, expectedCode, expectedMessageFragment) in cases {
            let result = SystemProductionAdapterFactory.makeRunner(artifacts: artifacts).run(.list, output: .json)

            XCTAssertEqual(result.exitCode, ProcessExit.safetyFailure.rawValue)
            let error = try XCTUnwrap((try decodeJSON(result.stderr)["error"] as? [String: Any]))
            XCTAssertEqual(error["code"] as? String, expectedCode)
            XCTAssertTrue((error["message"] as? String)?.localizedCaseInsensitiveContains(expectedMessageFragment) == true)
        }
    }

    func testInvalidRootFailureIsExposedByDoctorSchemaCheck() throws {
        let artifacts = FactoryArtifacts(
            osMajor: 26,
            readable: [true, true, true],
            environment: ["VMEMO_RECORDINGS_ROOT": "relative"]
        )

        let report = try SystemProductionAdapterFactory.makeRunner(artifacts: artifacts).doctor.inspect()

        let schema = try XCTUnwrap(report.checks.first(where: { $0.id == "schema" }))
        XCTAssertEqual(schema.status, .blocked)
        XCTAssertEqual(schema.code, "invalid_recordings_root")
        XCTAssertTrue(schema.details.joined(separator: " ").contains("valid path"))
    }

    func testEachFactoryFailureIsRetainedInAssemblyStateForDiagnostics() {
        let cases: [(FactoryArtifacts, ExpectedFactoryFailure)] = [
            (FactoryArtifacts(osMajor: 15, readable: [true, true, true]), .unsupportedOS),
            (FactoryArtifacts(osMajor: 26, readable: [true, false]), .missingArtifacts),
            (FactoryArtifacts(osMajor: 26, readable: [true, true, true], environment: ["VMEMO_RECORDINGS_ROOT": "relative"]), .invalidRecordingsRoot),
            (FactoryArtifacts(osMajor: 26, readable: [true, true, true]), .invalidModelEvidence),
        ]

        for (artifacts, expected) in cases {
            guard case let .failed(actual, _) = SystemProductionAdapterFactory.assemblyState(artifacts: artifacts) else {
                return XCTFail("unsupported production configuration must retain a failure reason")
            }
            XCTAssertEqual(ExpectedFactoryFailure(actual), expected)
        }
    }

    private func decodeJSON(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}

private enum ExpectedFactoryFailure: Equatable {
    case invalidRecordingsRoot
    case unsupportedOS
    case missingArtifacts
    case invalidModelEvidence

    init(_ failure: ProductionSystemConfigurationFailure) {
        switch failure {
        case .invalidRecordingsRoot: self = .invalidRecordingsRoot
        case .unsupportedOS: self = .unsupportedOS
        case .missingArtifacts: self = .missingArtifacts
        case .invalidModelEvidence: self = .invalidModelEvidence
        }
    }
}

private final class FactoryArtifacts: ProductionSystemArtifacts {
    let osMajor: Int
    private var readable: [Bool]
    private let environmentValues: [String: String]
    private(set) var readableCalls = 0
    private(set) var bundleCalls = 0
    private(set) var modelCalls = 0
    private(set) var dataCalls = 0

    init(osMajor: Int, readable: [Bool], environment: [String: String] = [:]) {
        self.osMajor = osMajor
        self.readable = readable
        self.environmentValues = environment
    }
    func runtimeOSMajor() -> Int { osMajor }
    func environment() -> [String: String] { environmentValues }
    func isReadable(_ url: URL) -> Bool { readableCalls += 1; return readable.removeFirst() }
    func bundle(at url: URL) -> Bundle? { bundleCalls += 1; return nil }
    func model(at url: URL) -> NSManagedObjectModel? { modelCalls += 1; return nil }
    func data(at url: URL) throws -> Data { dataCalls += 1; return Data() }
}
