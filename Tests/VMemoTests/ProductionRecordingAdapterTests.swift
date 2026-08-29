import Foundation
import SQLite3
import XCTest
@testable import VMemo

final class ProductionRecordingAdapterTests: XCTestCase {
    func testExactSchemaProjectsOnlyActiveRowsAndUsesOpaqueIDs() throws {
        let fixture = try ProductionStoreFixture.make(rows: [
            .init(id: "opaque-active", title: "Fixture title", path: "audio.m4a", eviction: .null),
            .init(id: "opaque-deleted", title: "Deleted title", path: "deleted.m4a", eviction: .real(1)),
        ])
        defer { fixture.cleanup() }
        let adapter = ProductionRecordingAdapter(snapshotURL: fixture.databaseURL)

        XCTAssertEqual(try adapter.list(), [RecordingSummary(id: RecordingID(value: "opaque-active"), title: "Fixture title")])
        XCTAssertEqual(try adapter.search(query: "FIXTURE").count, 1)
        XCTAssertEqual(try adapter.assetReference(for: RecordingID(value: "opaque-active")), "audio.m4a")
        XCTAssertThrowsError(try adapter.show(id: RecordingID(value: "opaque-deleted"))) { error in
            XCTAssertEqual(error as? ProductionRecordingAdapterError, .recordingNotFound)
        }
        XCTAssertThrowsError(try adapter.assetReference(for: RecordingID(value: "opaque-deleted"))) { error in
            XCTAssertEqual(error as? ProductionRecordingAdapterError, .recordingNotFound)
        }
    }

    func testSchemaAndRowContractFailClosed() throws {
        let cases: [ProductionStoreFixture.Fault] = [
            .missingColumn, .extraColumn, .reorderedColumn, .wrongType, .defaultValue, .notNull, .wrongPrimaryKey,
            .duplicateID, .emptyID, .invalidUTF8ID,
            .titleMismatch, .emptyTitle,
            .integerEviction, .textEviction,
        ]
        for fault in cases {
            let fixture = try ProductionStoreFixture.make(rows: [.init(id: "opaque", title: "Fixture title", path: "audio.m4a", eviction: .null)], fault: fault)
            defer { fixture.cleanup() }
            XCTAssertThrowsError(try ProductionRecordingAdapter(snapshotURL: fixture.databaseURL).list()) { error in
                XCTAssertEqual(error as? ProductionRecordingAdapterError, .unsupportedSchema)
            }
        }
    }

    func testProductionAssetsOnlyAcceptRelativeM4A() throws {
        let cases: [(String, RecordingAssetError)] = [
            ("audio.qta", .unsupportedAssetFormat),
            ("/audio.m4a", .pathOutsideRecordingsRoot),
            ("../audio.m4a", .pathOutsideRecordingsRoot),
            ("nested/../../audio.m4a", .pathOutsideRecordingsRoot),
        ]
        for (path, expected) in cases {
            let fixture = try ProductionStoreFixture.make(rows: [.init(id: "opaque", title: "Fixture title", path: path, eviction: .null)])
            defer { fixture.cleanup() }
            XCTAssertThrowsError(try ProductionRecordingAdapter(snapshotURL: fixture.databaseURL).assetReference(for: RecordingID(value: "opaque"))) { error in
                XCTAssertEqual(error as? RecordingAssetError, expected)
            }
        }
    }

    func testDeletedExportReturnsStableNotFoundCode() throws {
        let fixture = try ProductionStoreFixture.make(rows: [.init(id: "opaque-deleted", title: "Fixture title", path: "deleted.m4a", eviction: .real(1.5))])
        defer { fixture.cleanup() }
        let adapter = ProductionRecordingAdapter(snapshotURL: fixture.databaseURL)
        let result = CommandRunner(
            read: adapter,
            asset: SafeRecordingAssetPort(recordingsRoot: fixture.root, resolver: adapter),
            write: UnconfiguredWritePort()
        ).run(.export(id: RecordingID(value: "opaque-deleted"), destination: "/tmp/vmemo-production-export.m4a"), output: .json)

        XCTAssertEqual(result.exitCode, ProcessExit.operationalFailure.rawValue)
        XCTAssertTrue(result.stderr.contains("recording_not_found"))
    }
}

private struct ProductionStoreFixture {
    enum Fault { case missingColumn, extraColumn, reorderedColumn, wrongType, defaultValue, notNull, wrongPrimaryKey, duplicateID, emptyID, invalidUTF8ID, titleMismatch, emptyTitle, integerEviction, textEviction }
    enum Eviction: Equatable { case null, real(Double) }
    struct Row { let id: String; let title: String; let path: String; let eviction: Eviction }
    let root: URL
    let databaseURL: URL

    static func make(rows: [Row], fault: Fault? = nil) throws -> Self {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vmemo-production-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let databaseURL = root.appendingPathComponent("fixture.sqlite")
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let db else { throw FixtureError.failed }
        defer { sqlite3_close_v2(db) }
        var columns = ["Z_PK INTEGER PRIMARY KEY", "Z_ENT INTEGER", "Z_OPT INTEGER", "ZAUDIOFUTUREFLAGS INTEGER", "ZFLAGS INTEGER", "ZSHAREDFLAGS INTEGER", "ZSILENCEREMOVERENABLED INTEGER", "ZSKIPSILENCEENABLED INTEGER", "ZSTUDIOMIXENABLED INTEGER", "ZFOLDER INTEGER", "ZDATE TIMESTAMP", "ZDURATION FLOAT", "ZEVICTIONDATE TIMESTAMP", "ZLOCALDURATION FLOAT", "ZMTLAYERMIX FLOAT", "ZPLAYBACKPOSITION FLOAT", "ZPLAYBACKRATE FLOAT", "ZPLAYBACKSPEED FLOAT", "ZSTUDIOMIXLEVEL FLOAT", "ZCUSTOMLABEL VARCHAR", "ZCUSTOMLABELFORSORTING VARCHAR", "ZENCRYPTEDTITLE VARCHAR", "ZPATH VARCHAR", "ZUNIQUEID VARCHAR", "ZAUDIOFUTUREUUIDS BLOB", "ZAUDIODIGEST BLOB", "ZAUDIOFUTURE BLOB", "ZMTAUDIOFUTURE BLOB", "ZVERSIONEDAUDIOFUTURE BLOB"]
        switch fault {
        case .missingColumn: columns.removeLast()
        case .extraColumn: columns.append("ZEXTRA TEXT")
        case .reorderedColumn: columns.swapAt(0, 1)
        case .wrongType: columns[11] = "ZDURATION INTEGER NOT NULL"
        case .defaultValue: columns[1] = "Z_ENT INTEGER DEFAULT 0"
        case .notNull: columns[1] = "Z_ENT INTEGER NOT NULL"
        case .wrongPrimaryKey: columns[0] = "Z_PK INTEGER"
        default: break
        }
        guard sqlite3_exec(db, "CREATE TABLE ZCLOUDRECORDING (\(columns.joined(separator: ", ")))", nil, nil, nil) == SQLITE_OK else { throw FixtureError.failed }
        var inserted = rows
        if fault == .duplicateID { inserted.append(rows[0]) }
        if fault == .emptyID { inserted[0] = Row(id: "", title: rows[0].title, path: rows[0].path, eviction: rows[0].eviction) }
        if fault == .titleMismatch { inserted[0] = Row(id: rows[0].id, title: rows[0].title, path: rows[0].path, eviction: rows[0].eviction) }
        if fault == .missingColumn || fault == .extraColumn || fault == .reorderedColumn || fault == .wrongType || fault == .defaultValue || fault == .notNull || fault == .wrongPrimaryKey {
            return Self(root: root, databaseURL: databaseURL)
        }
        for (index, row) in inserted.enumerated() {
            let sortingTitle = fault == .emptyTitle ? "" : row.title
            let encryptedTitle = fault == .titleMismatch ? "Other title" : sortingTitle
            let eviction: String
            switch fault {
            case .integerEviction: eviction = "1"
            case .textEviction: eviction = "'invalid'"
            default: eviction = row.eviction == .null ? "NULL" : "1.5"
            }
            let id = fault == .invalidUTF8ID ? "CAST(X'ff' AS TEXT)" : "'\(row.id)'"
            let sql = "INSERT INTO ZCLOUDRECORDING VALUES (\(index + 1), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0.0, \(eviction), 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 'x', '\(sortingTitle)', '\(encryptedTitle)', '\(row.path)', \(id), NULL, NULL, NULL, NULL, NULL)"
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw FixtureError.failed }
        }
        return Self(root: root, databaseURL: databaseURL)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    private enum FixtureError: Error { case failed }
}
