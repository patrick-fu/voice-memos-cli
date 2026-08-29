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
}

private final class FactoryArtifacts: ProductionSystemArtifacts {
    let osMajor: Int
    private var readable: [Bool]
    private(set) var readableCalls = 0
    private(set) var bundleCalls = 0
    private(set) var modelCalls = 0
    private(set) var dataCalls = 0

    init(osMajor: Int, readable: [Bool]) { self.osMajor = osMajor; self.readable = readable }
    func runtimeOSMajor() -> Int { osMajor }
    func environment() -> [String: String] { [:] }
    func isReadable(_ url: URL) -> Bool { readableCalls += 1; return readable.removeFirst() }
    func bundle(at url: URL) -> Bundle? { bundleCalls += 1; return nil }
    func model(at url: URL) -> NSManagedObjectModel? { modelCalls += 1; return nil }
    func data(at url: URL) throws -> Data { dataCalls += 1; return Data() }
}
