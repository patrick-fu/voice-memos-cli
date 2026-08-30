import Foundation
import SQLite3
import XCTest
@testable import VMemo

final class ProductionRecordingAdapterTests: XCTestCase {
    func testExactSchemaProjectsOnlyActiveRowsAndUsesOpaqueIDs() throws {
        let fixture = try ProductionStoreFixture.make(rows: [
            .init(id: "opaque-active", title: "Fixture title", path: "audio.m4a", eviction: .null),
            .init(id: "opaque-inactive", title: "Inactive title", path: "inactive.m4a", eviction: .real(1)),
        ])
        defer { fixture.cleanup() }
        let adapter = ProductionRecordingAdapter(snapshotURL: fixture.databaseURL)

        XCTAssertEqual(try adapter.list(), [RecordingSummary(id: RecordingID(value: "opaque-active"), title: "Fixture title")])
        XCTAssertEqual(try adapter.search(query: "FIXTURE").count, 1)
        XCTAssertEqual(try adapter.assetReference(for: RecordingID(value: "opaque-active")), "audio.m4a")
        XCTAssertThrowsError(try adapter.show(id: RecordingID(value: "opaque-inactive"))) { error in
            XCTAssertEqual(error as? ProductionRecordingAdapterError, .recordingNotFound)
        }
        XCTAssertThrowsError(try adapter.assetReference(for: RecordingID(value: "opaque-inactive"))) { error in
            XCTAssertEqual(error as? ProductionRecordingAdapterError, .recordingNotFound)
        }

        let projection = try adapter.validatedProjection()
        XCTAssertEqual(projection.recordings.map(\.id.value), ["opaque-active", "opaque-inactive"])
        XCTAssertEqual(projection.recordings.map(\.isActive), [true, false])
        XCTAssertEqual(projection.fingerprint.count, 64)
        XCTAssertFalse(projection.fingerprint.contains("opaque-active"))
        XCTAssertFalse(projection.fingerprint.contains("Fixture title"))
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

    func testSortingAndEncryptedTitlesRejectCanonicalOnlyEquality() throws {
        XCTAssertEqual(UnicodeExactFixture.nfcEAcute, UnicodeExactFixture.nfdEAcute)
        XCTAssertFalse(utf8ExactEqual(UnicodeExactFixture.nfcEAcute, UnicodeExactFixture.nfdEAcute))
        let fixture = try ProductionStoreFixture.make(rows: [
            .init(
                id: "opaque",
                title: UnicodeExactFixture.nfcEAcute,
                path: "audio.m4a",
                eviction: .null,
                encryptedTitle: UnicodeExactFixture.nfdEAcute
            )
        ])
        defer { fixture.cleanup() }
        XCTAssertThrowsError(try ProductionRecordingAdapter(snapshotURL: fixture.databaseURL).list()) { error in
            XCTAssertEqual(error as? ProductionRecordingAdapterError, .unsupportedSchema)
        }
    }

    func testNFCAndNFDRecordingIDsAreDistinctByteIdentities() throws {
        let fixture = try ProductionStoreFixture.make(rows: [
            .init(id: "id-" + UnicodeExactFixture.nfcEAcute, title: "First title", path: "first.m4a", eviction: .null),
            .init(id: "id-" + UnicodeExactFixture.nfdEAcute, title: "Second title", path: "second.m4a", eviction: .null),
        ])
        defer { fixture.cleanup() }
        let adapter = ProductionRecordingAdapter(snapshotURL: fixture.databaseURL)
        let projection = try adapter.validatedProjection()
        XCTAssertEqual(projection.recordings.count, 2)
        let nfc = try adapter.show(id: RecordingID(value: "id-" + UnicodeExactFixture.nfcEAcute))
        let nfd = try adapter.show(id: RecordingID(value: "id-" + UnicodeExactFixture.nfdEAcute))
        XCTAssertTrue(utf8ExactEqual(nfc.id.value, "id-" + UnicodeExactFixture.nfcEAcute))
        XCTAssertTrue(utf8ExactEqual(nfd.id.value, "id-" + UnicodeExactFixture.nfdEAcute))
        XCTAssertTrue(utf8ExactEqual(nfc.title, "First title"))
        XCTAssertTrue(utf8ExactEqual(nfd.title, "Second title"))
    }

    func testInactiveExportReturnsStableNotFoundCode() throws {
        let fixture = try ProductionStoreFixture.make(rows: [.init(id: "opaque-inactive", title: "Fixture title", path: "inactive.m4a", eviction: .real(1.5))])
        defer { fixture.cleanup() }
        let adapter = ProductionRecordingAdapter(snapshotURL: fixture.databaseURL)
        let result = CommandRunner(
            read: adapter,
            asset: SafeRecordingAssetPort(recordingsRoot: fixture.root, resolver: adapter)
        ).run(.export(id: RecordingID(value: "opaque-inactive"), destination: "/tmp/vmemo-production-export.m4a"), output: .json)

        XCTAssertEqual(result.exitCode, ProcessExit.operationalFailure.rawValue)
        XCTAssertTrue(result.stderr.contains("recording_not_found"))
    }
}

struct ProductionStoreFixture {
    enum Fault { case missingColumn, extraColumn, reorderedColumn, wrongType, defaultValue, notNull, wrongPrimaryKey, duplicateID, emptyID, invalidUTF8ID, titleMismatch, emptyTitle, integerEviction, textEviction }
    enum Eviction: Equatable { case null, real(Double), integer }
    struct Row {
        let id: String
        let title: String
        let path: String
        let eviction: Eviction
        let encryptedTitle: String
        init(id: String, title: String, path: String, eviction: Eviction, encryptedTitle: String? = nil) {
            self.id = id
            self.title = title
            self.path = path
            self.eviction = eviction
            self.encryptedTitle = encryptedTitle ?? title
        }
    }
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
        let insertSQL = "INSERT INTO ZCLOUDRECORDING VALUES (?, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0.0, ?, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 'x', ?, ?, ?, ?, NULL, NULL, NULL, NULL, NULL)"
        for (index, row) in inserted.enumerated() {
            if fault == .invalidUTF8ID {
                let sql = "INSERT INTO ZCLOUDRECORDING VALUES (\(index + 1), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0.0, NULL, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 'x', '\(row.title)', '\(row.title)', '\(row.path)', CAST(X'ff' AS TEXT), NULL, NULL, NULL, NULL, NULL)"
                guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw FixtureError.failed }
                continue
            }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, insertSQL, -1, &statement, nil) == SQLITE_OK, let statement else { throw FixtureError.failed }
            defer { sqlite3_finalize(statement) }
            let sortingTitle = fault == .emptyTitle ? "" : row.title
            let encryptedTitle = fault == .titleMismatch ? "Other title" : row.encryptedTitle
            guard sqlite3_bind_int64(statement, 1, sqlite3_int64(index + 1)) == SQLITE_OK else { throw FixtureError.failed }
            switch fault {
            case .integerEviction:
                guard sqlite3_bind_int(statement, 2, 1) == SQLITE_OK else { throw FixtureError.failed }
            case .textEviction:
                guard bindUTF8(statement, 2, "invalid") == SQLITE_OK else { throw FixtureError.failed }
            default:
                switch row.eviction {
                case .null:
                    guard sqlite3_bind_null(statement, 2) == SQLITE_OK else { throw FixtureError.failed }
                case .real:
                    guard sqlite3_bind_double(statement, 2, 1.5) == SQLITE_OK else { throw FixtureError.failed }
                case .integer:
                    guard sqlite3_bind_int(statement, 2, 1) == SQLITE_OK else { throw FixtureError.failed }
                }
            }
            guard bindUTF8(statement, 3, sortingTitle) == SQLITE_OK,
                  bindUTF8(statement, 4, encryptedTitle) == SQLITE_OK,
                  bindUTF8(statement, 5, row.path) == SQLITE_OK,
                  bindUTF8(statement, 6, row.id) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_DONE
            else { throw FixtureError.failed }
        }

        return Self(root: root, databaseURL: databaseURL)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    private enum FixtureError: Error { case failed }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func bindUTF8(_ statement: OpaquePointer, _ index: Int32, _ value: String) -> Int32 {
    Array(value.utf8).withUnsafeBufferPointer { buffer in
        sqlite3_bind_text(
            statement,
            index,
            buffer.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
            Int32(buffer.count),
            sqliteTransient
        )
    }
}

enum UnicodeExactFixture {
    static let nfcEAcute = String(bytes: [0xC3, 0xA9], encoding: .utf8)!
    static let nfdEAcute = String(bytes: [0x65, 0xCC, 0x81], encoding: .utf8)!
}
