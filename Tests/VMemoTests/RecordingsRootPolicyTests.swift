import Foundation
import XCTest
@testable import VMemo

final class RecordingsRootPolicyTests: XCTestCase {
    func testMissingOverrideUsesProductionDefault() {
        let decision = RecordingsRootPolicy.evaluate(nil, temporaryDirectory: FileManager.default.temporaryDirectory, isReleaseBuild: false)

        guard case .productionDefault = decision else {
            return XCTFail("an absent override must preserve the production default")
        }

        guard case .productionDefault = RecordingsRootPolicy.evaluate(nil, temporaryDirectory: FileManager.default.temporaryDirectory, isReleaseBuild: true) else {
            return XCTFail("release mode must still use the production default when no override is supplied")
        }
    }

    func testDebugOverrideAcceptsOnlyARealDescendantOfTemporaryDirectory() throws {
        let fixture = try RootPolicyFixture.make()
        defer { fixture.cleanup() }

        let decision = RecordingsRootPolicy.evaluate(fixture.allowed.path, temporaryDirectory: fixture.temporaryRoot, isReleaseBuild: false)

        guard case let .injected(url) = decision else {
            return XCTFail("debug/test mode should allow an isolated temporary descendant")
        }
        XCTAssertEqual(url.standardizedFileURL, fixture.allowed.standardizedFileURL)
    }

    func testSystemTemporaryDirectoryAcceptsBothRawAndResolvedAliases() throws {
        let rawTemporary = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).standardizedFileURL
        XCTAssertTrue(rawTemporary.path.hasPrefix("/var/"))

        let name = "vmemo-root-policy-alias-\(UUID().uuidString)"
        let rawChild = rawTemporary.appendingPathComponent(name, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rawChild) }
        try FileManager.default.createDirectory(at: rawChild, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])

        for candidate in [rawChild.path, "/private" + rawChild.path] {
            guard case .injected = RecordingsRootPolicy.evaluate(
                candidate,
                temporaryDirectory: rawTemporary,
                isReleaseBuild: false
            ) else {
                return XCTFail("A system temporary-directory alias must remain usable: \(candidate)")
            }
        }
    }

    func testTemporaryRootItselfAndTraversalEscapeAreRejectedWithoutFallback() throws {
        let fixture = try RootPolicyFixture.make()
        defer { fixture.cleanup() }

        let candidates = [
            fixture.temporaryRoot.path,
            fixture.allowed.appendingPathComponent("../../\(fixture.external.lastPathComponent)").path,
            fixture.external.path,
            "",
        ]

        for candidate in candidates {
            let decision = RecordingsRootPolicy.evaluate(candidate, temporaryDirectory: fixture.temporaryRoot, isReleaseBuild: false)
            guard case .rejected = decision else {
                return XCTFail("unsafe override must be rejected, not treated as production default: \(candidate)")
            }
        }
    }

    func testSymlinkEscapeIsRejected() throws {
        let fixture = try RootPolicyFixture.make()
        defer { fixture.cleanup() }
        let link = fixture.allowed.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.external)

        let decision = RecordingsRootPolicy.evaluate(link.appendingPathComponent("recordings").path, temporaryDirectory: fixture.temporaryRoot, isReleaseBuild: false)

        guard case .rejected = decision else {
            return XCTFail("a symlink that leaves the temporary tree must be rejected")
        }
    }

    func testSymlinkWithinTemporaryDirectoryIsRejectedEvenWhenItResolvesInside() throws {
        let fixture = try RootPolicyFixture.make()
        defer { fixture.cleanup() }
        let linkedDirectory = fixture.temporaryRoot.appendingPathComponent("linked", isDirectory: true)
        let recordings = fixture.allowed.appendingPathComponent("recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: fixture.allowed)

        guard case .rejected = RecordingsRootPolicy.evaluate(
            linkedDirectory.appendingPathComponent("recordings").path,
            temporaryDirectory: fixture.temporaryRoot,
            isReleaseBuild: false
        ) else {
            return XCTFail("temporary descendants must not traverse symlinks, even when the target remains temporary")
        }
    }

    func testReleaseModeRejectsTemporaryOverride() throws {
        let fixture = try RootPolicyFixture.make()
        defer { fixture.cleanup() }

        let decision = RecordingsRootPolicy.evaluate(fixture.allowed.path, temporaryDirectory: fixture.temporaryRoot, isReleaseBuild: true)

        guard case .rejected = decision else {
            return XCTFail("release builds must not accept injected recording roots")
        }
    }
}

private struct RootPolicyFixture {
    let temporaryRoot: URL
    let allowed: URL
    let external: URL

    static func make() throws -> Self {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("vmemo-root-policy-\(UUID().uuidString)", isDirectory: true)
        let allowed = temporaryRoot.appendingPathComponent("fixture", isDirectory: true)
        let external = temporaryRoot.deletingLastPathComponent()
            .appendingPathComponent("vmemo-root-policy-external-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(
            at: external.appendingPathComponent("recordings", isDirectory: true),
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return Self(temporaryRoot: temporaryRoot, allowed: allowed, external: external)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: temporaryRoot)
        try? FileManager.default.removeItem(at: external)
    }
}
