import Foundation
import XCTest
@testable import VMemo

final class RecordingAssetExportTests: XCTestCase {
    func testExportCopiesSyntheticM4ABytesForOpaqueRecordingID() throws {
        let fixture = try AssetFixture()
        defer { fixture.cleanup() }
        let sourceBytes = Data([0, 1, 2, 3, 4, 5])
        try fixture.writeAsset("clip.m4a", bytes: sourceBytes)
        let destination = fixture.destinationRoot.appendingPathComponent("copy.m4a")
        let id = RecordingID(value: "recording:opaque-fixture")
        let port = SafeRecordingAssetPort(
            recordingsRoot: fixture.recordingsRoot,
            resolver: FixtureAssetResolver(references: [id: "clip.m4a"])
        )

        let receipt = try port.export(id: id, destination: destination.path)

        XCTAssertEqual(receipt, ExportReceipt(id: id, destination: destination.path))
        XCTAssertEqual(try Data(contentsOf: destination), sourceBytes)
        XCTAssertEqual(try permissions(of: destination), 0o600)
    }

    func testExportRejectsSourceAncestorSymlinkAsOutsideRecordingsRoot() throws {
        let fixture = try AssetFixture()
        defer { fixture.cleanup() }
        try fixture.writeOutsideAsset("outside.m4a", bytes: Data([9, 9, 9]))
        try FileManager.default.createSymbolicLink(
            at: fixture.recordingsRoot.appendingPathComponent("linked"),
            withDestinationURL: fixture.outsideRoot
        )

        XCTAssertThrowsError(
            try fixture.export(reference: "linked/outside.m4a", id: RecordingID(value: "recording:opaque-fixture"))
        ) { error in
            XCTAssertEqual(error as? RecordingAssetError, .pathOutsideRecordingsRoot)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destinationRoot.path), [])
    }

    func testExportCopiesSyntheticQTABytes() throws {
        let fixture = try AssetFixture()
        defer { fixture.cleanup() }
        let bytes = Data([0x66, 0x74, 0x79, 0x70, 0x71, 0x74])
        try fixture.writeAsset("clip.qta", bytes: bytes)

        let receipt = try fixture.export(reference: "clip.qta", id: RecordingID(value: "recording:qta"))

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: receipt.destination)), bytes)
    }

    func testExportRejectsMissingAndUnsupportedAssets() throws {
        let fixture = try AssetFixture()
        defer { fixture.cleanup() }
        try fixture.writeAsset("clip.wav", bytes: Data([1]))

        XCTAssertAssetError(.assetUnavailable) {
            try fixture.export(reference: "missing.m4a", id: RecordingID(value: "recording:missing"))
        }
        XCTAssertAssetError(.unsupportedAssetFormat) {
            try fixture.export(reference: "clip.wav", id: RecordingID(value: "recording:wav"))
        }
    }

    func testExportRejectsAbsoluteAndTraversalReferences() throws {
        let fixture = try AssetFixture()
        defer { fixture.cleanup() }

        for reference in ["/private/tmp/outside.m4a", "../outside.m4a", "nested/../../outside.m4a"] {
            XCTAssertAssetError(.pathOutsideRecordingsRoot) {
                try fixture.export(reference: reference, id: RecordingID(value: "recording:path"))
            }
        }
    }

    func testExportRejectsEmbeddedNULBeforeExtensionCheck() throws {
        let fixture = try AssetFixture()
        defer { fixture.cleanup() }
        try fixture.writeAsset("secret.sqlite", bytes: Data([0xde, 0xad]))

        XCTAssertAssetError(.pathOutsideRecordingsRoot) {
            try fixture.export(reference: "secret.sqlite\0.m4a", id: RecordingID(value: "recording:nul"))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destinationRoot.path), [])
    }

    func testExportRejectsFinalSymlinkDirectoryAndFIFOWithoutBlocking() throws {
        let fixture = try AssetFixture()
        defer { fixture.cleanup() }
        try fixture.writeOutsideAsset("outside.m4a", bytes: Data([9]))
        try FileManager.default.createSymbolicLink(
            at: fixture.recordingsRoot.appendingPathComponent("linked.m4a"),
            withDestinationURL: fixture.outsideRoot.appendingPathComponent("outside.m4a")
        )
        try FileManager.default.createDirectory(
            at: fixture.recordingsRoot.appendingPathComponent("directory.m4a"),
            withIntermediateDirectories: false
        )
        let fifo = fixture.recordingsRoot.appendingPathComponent("pipe.m4a")
        XCTAssertEqual(mkfifo(fifo.path, S_IRUSR | S_IWUSR), 0)

        XCTAssertAssetError(.pathOutsideRecordingsRoot) {
            try fixture.export(reference: "linked.m4a", id: RecordingID(value: "recording:link"))
        }
        for reference in ["directory.m4a", "pipe.m4a"] {
            XCTAssertAssetError(.notRegularFile) {
                try fixture.export(reference: reference, id: RecordingID(value: "recording:special"))
            }
        }
    }

    func testExportRejectsSymlinkedRecordingsRootAndDestinationParent() throws {
        let fixture = try AssetFixture()
        defer { fixture.cleanup() }
        try fixture.writeAsset("clip.m4a", bytes: Data([1]))
        let linkedRoot = fixture.root.appendingPathComponent("linked-recordings")
        let linkedDestination = fixture.root.appendingPathComponent("linked-exports")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: fixture.recordingsRoot)
        try FileManager.default.createSymbolicLink(at: linkedDestination, withDestinationURL: fixture.destinationRoot)
        let id = RecordingID(value: "recording:root-link")

        XCTAssertAssetError(.pathOutsideRecordingsRoot) {
            try SafeRecordingAssetPort(
                recordingsRoot: linkedRoot,
                resolver: FixtureAssetResolver(references: [id: "clip.m4a"])
            ).export(id: id, destination: fixture.destinationRoot.appendingPathComponent("copy.m4a").path)
        }
        XCTAssertAssetError(.destinationUnavailable) {
            try SafeRecordingAssetPort(
                recordingsRoot: fixture.recordingsRoot,
                resolver: FixtureAssetResolver(references: [id: "clip.m4a"])
            ).export(id: id, destination: linkedDestination.appendingPathComponent("copy.m4a").path)
        }
    }

    func testExportReportsWhenPermissionRacePreventsPartialCleanup() throws {
        let fixture = try AssetFixture()
        defer { fixture.cleanup() }
        try fixture.writeAsset("clip.m4a", bytes: Data([1, 2, 3]))
        let id = RecordingID(value: "recording:cleanup")
        let destinationRoot = fixture.destinationRoot
        let port = SafeRecordingAssetPort(
            recordingsRoot: fixture.recordingsRoot,
            resolver: FixtureAssetResolver(references: [id: "clip.m4a"]),
            beforePostCopyValidation: {
                try! FileManager.default.setAttributes(
                    [.posixPermissions: 0o500],
                    ofItemAtPath: destinationRoot.path
                )
            }
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: fixture.destinationRoot.path
            )
        }

        XCTAssertAssetError(.cleanupFailed) {
            try port.export(
                id: id,
                destination: fixture.destinationRoot.appendingPathComponent("copy.m4a").path
            )
        }
    }

    func testExportDoesNotOverwriteDestinationOrLeaveTemporaryFiles() throws {
        let fixture = try AssetFixture()
        defer { fixture.cleanup() }
        try fixture.writeAsset("clip.m4a", bytes: Data([1, 2, 3]))
        let destination = fixture.destinationRoot.appendingPathComponent("copy.m4a")
        XCTAssertTrue(FileManager.default.createFile(atPath: destination.path, contents: Data([8, 8])))

        XCTAssertAssetError(.destinationExists) {
            try fixture.export(reference: "clip.m4a", id: RecordingID(value: "recording:collision"))
        }
        XCTAssertEqual(try Data(contentsOf: destination), Data([8, 8]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destinationRoot.path), ["copy.m4a"])
    }

    func testExportFailsClosedAndRemovesTemporaryFileWhenSourceChanges() throws {
        let fixture = try AssetFixture()
        defer { fixture.cleanup() }
        let source = fixture.recordingsRoot.appendingPathComponent("clip.m4a")
        try fixture.writeAsset("clip.m4a", bytes: Data(repeating: 7, count: 4096))
        let id = RecordingID(value: "recording:changing")
        let port = SafeRecordingAssetPort(
            recordingsRoot: fixture.recordingsRoot,
            resolver: FixtureAssetResolver(references: [id: "clip.m4a"]),
            beforePostCopyValidation: {
                let handle = try! FileHandle(forWritingTo: source)
                try! handle.seekToEnd()
                try! handle.write(contentsOf: Data([1]))
                try! handle.close()
            }
        )
        let destination = fixture.destinationRoot.appendingPathComponent("copy.m4a")

        XCTAssertAssetError(.exportInconsistent) {
            try port.export(id: id, destination: destination.path)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destinationRoot.path), [])
    }
}

private struct FixtureAssetResolver: RecordingAssetReferenceResolver {
    let references: [RecordingID: String]

    func assetReference(for id: RecordingID) throws -> String? {
        references[id]
    }
}

private final class AssetFixture {
    let root: URL
    let recordingsRoot: URL
    let destinationRoot: URL
    let outsideRoot: URL

    init() throws {
        let template = "/private/tmp/vmemo-assets.XXXXXX"
        var path = Array(template.utf8CString)
        guard mkdtemp(&path) != nil else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        root = URL(fileURLWithPath: String(decoding: path.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self))
        recordingsRoot = root.appendingPathComponent("recordings", isDirectory: true)
        destinationRoot = root.appendingPathComponent("exports", isDirectory: true)
        outsideRoot = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: recordingsRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    func writeAsset(_ reference: String, bytes: Data) throws {
        let url = recordingsRoot.appendingPathComponent(reference)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: bytes, attributes: [.posixPermissions: 0o600]))
    }

    func writeOutsideAsset(_ name: String, bytes: Data) throws {
        let url = outsideRoot.appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: bytes, attributes: [.posixPermissions: 0o600]))
    }

    func export(reference: String, id: RecordingID) throws -> ExportReceipt {
        let port = SafeRecordingAssetPort(
            recordingsRoot: recordingsRoot,
            resolver: FixtureAssetResolver(references: [id: reference])
        )
        let destination = destinationRoot.appendingPathComponent("copy.\((reference as NSString).pathExtension)")
        return try port.export(id: id, destination: destination.path)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func permissions(of url: URL) throws -> UInt16 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try XCTUnwrap((attributes[.posixPermissions] as? NSNumber)?.uint16Value) & 0o777
}

private func XCTAssertAssetError<Result>(
    _ expected: RecordingAssetError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ operation: () throws -> Result
) {
    XCTAssertThrowsError(try operation(), file: file, line: line) { error in
        XCTAssertEqual(error as? RecordingAssetError, expected, file: file, line: line)
    }
}
