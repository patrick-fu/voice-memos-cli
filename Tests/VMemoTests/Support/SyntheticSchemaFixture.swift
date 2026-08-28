import Darwin
import Foundation
import SQLite3

struct SyntheticSchemaFixture {
    enum Revision {
        case macOS15
        case macOS26

        var targetOSMajor: Int64 {
            switch self {
            case .macOS15: 15
            case .macOS26: 26
            }
        }

        var schemaToken: String {
            switch self {
            case .macOS15: "synthetic.core-data-recordings.macos15.r1"
            case .macOS26: "synthetic.core-data-recordings.macos26.r1"
            }
        }
    }

    enum Fault {
        case unknownToken
        case missingRecordingTable
        case missingActiveColumn
        case wrongTitleType
        case missingAssetPolicyColumn
        case wrongAssetPolicyType
        case invalidAssetPolicy
        case missingGeneratorVersionColumn
        case wrongGeneratorVersionType
        case invalidGeneratorVersion
        case multipleManifestRows
        case invalidProvenance
        case invalidTargetOSMajor
        case overflowTargetOSMajor
        case invalidFixtureRevision
        case overflowFixtureRevision
        case invalidSearchPolicy
    }

    struct Recording {
        let id: String?
        let title: String?
        let isActive: Int64?
    }

    let databaseURL: URL
    private let root: URL

    static func make(
        revision: Revision = .macOS15,
        records: [Recording],
        fault: Fault? = nil
    ) throws -> SyntheticSchemaFixture {
        var template = Array("/tmp/vmemo-schema-fixture.XXXXXX".utf8CString)
        guard mkdtemp(&template) != nil else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        let root = URL(fileURLWithPath: String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self))
        let databaseURL = root.appendingPathComponent("fixture.sqlite")
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try createDatabase(at: databaseURL, revision: revision, records: records, fault: fault)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
            return SyntheticSchemaFixture(databaseURL: databaseURL, root: root)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func cleanup() throws {
        try FileManager.default.removeItem(at: root)
    }

    private static func createDatabase(
        at databaseURL: URL,
        revision: Revision,
        records: [Recording],
        fault: Fault?
    ) throws {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let connection
        else {
            throw FixtureFailure.sqlite
        }
        defer { sqlite3_close_v2(connection) }

        let titleType = fault == .wrongTitleType ? "BLOB" : "TEXT"
        let activeColumn = fault == .missingActiveColumn ? "" : ", ZVMEMO_SYNTHETIC_ACTIVE INTEGER"
        let assetPolicyType = fault == .wrongAssetPolicyType ? "BLOB" : "TEXT"
        let assetPolicyColumn = fault == .missingAssetPolicyColumn ? "" : ", ZASSETPOLICY \(assetPolicyType)"
        let generatorVersionType = fault == .wrongGeneratorVersionType ? "BLOB" : "TEXT"
        let generatorVersionColumn = fault == .missingGeneratorVersionColumn ? "" : ", ZGENERATORVERSION \(generatorVersionType)"
        let recordingTable = fault == .missingRecordingTable ? "" : """
        CREATE TABLE ZCLOUDRECORDING (
            Z_PK INTEGER PRIMARY KEY,
            ZUNIQUEID TEXT,
            ZVMEMO_SYNTHETIC_TITLE \(titleType),
            ZENCRYPTEDTITLE BLOB,
            ZTRANSCRIPT TEXT,
            ZPATH TEXT\(activeColumn)
        );
        """
        let ddl = """
        CREATE TABLE VMEMO_SYNTHETIC_MANIFEST (
            ZSCHEMATOKEN TEXT,
            ZPROVENANCE TEXT,
            ZTARGETOSMAJOR INTEGER,
            ZFIXTUREREVISION INTEGER,
            ZSEARCHPOLICY TEXT\(assetPolicyColumn)\(generatorVersionColumn)
        );
        \(recordingTable)
        """
        guard sqlite3_exec(connection, ddl, nil, nil, nil) == SQLITE_OK else {
            throw FixtureFailure.sqlite
        }

        try insertManifest(connection, revision: revision, fault: fault)
        if fault == .multipleManifestRows {
            try insertManifest(connection, revision: revision, fault: nil)
        }
        if fault != .missingRecordingTable {
            for record in records {
                try insertRecording(connection, record: record, includesActiveColumn: fault != .missingActiveColumn)
            }
        }
    }

    private static func insertManifest(_ connection: OpaquePointer, revision: Revision, fault: Fault?) throws {
        let token = fault == .unknownToken ? "synthetic.core-data-recordings.forward.r1" : revision.schemaToken
        let provenance = fault == .invalidProvenance ? "observed" : "synthetic"
        let targetOSMajor: Int64
        switch fault {
        case .invalidTargetOSMajor: targetOSMajor = 14
        case .overflowTargetOSMajor: targetOSMajor = 4_294_967_296
        default: targetOSMajor = revision.targetOSMajor
        }
        let fixtureRevision: Int64
        switch fault {
        case .invalidFixtureRevision: fixtureRevision = 2
        case .overflowFixtureRevision: fixtureRevision = 4_294_967_297
        default: fixtureRevision = 1
        }
        let searchPolicy = fault == .invalidSearchPolicy ? "synthetic-exact-match-v1" : "synthetic-case-insensitive-contains-v1"
        let assetPolicy = fault == .invalidAssetPolicy ? "synthetic-assets-allowed-v1" : "synthetic-no-assets-v1"
        let generatorVersion = fault == .invalidGeneratorVersion ? "vmemo-synthetic-fixture-generator-v2" : "vmemo-synthetic-fixture-generator-v1"
        var columns = ["ZSCHEMATOKEN", "ZPROVENANCE", "ZTARGETOSMAJOR", "ZFIXTUREREVISION", "ZSEARCHPOLICY"]
        var values: [SQLiteValue] = [.text(token), .text(provenance), .integer(targetOSMajor), .integer(fixtureRevision), .text(searchPolicy)]
        if fault != .missingAssetPolicyColumn {
            columns.append("ZASSETPOLICY")
            values.append(.text(assetPolicy))
        }
        if fault != .missingGeneratorVersionColumn {
            columns.append("ZGENERATORVERSION")
            values.append(.text(generatorVersion))
        }
        try execute(
            connection,
            sql: "INSERT INTO VMEMO_SYNTHETIC_MANIFEST (\(columns.joined(separator: ", "))) VALUES (\(Array(repeating: "?", count: columns.count).joined(separator: ", ")))",
            values: values
        )
    }

    private static func insertRecording(_ connection: OpaquePointer, record: Recording, includesActiveColumn: Bool) throws {
        let sql: String
        let values: [SQLiteValue]
        if includesActiveColumn {
            sql = "INSERT INTO ZCLOUDRECORDING (ZUNIQUEID, ZVMEMO_SYNTHETIC_TITLE, ZVMEMO_SYNTHETIC_ACTIVE, ZENCRYPTEDTITLE, ZTRANSCRIPT, ZPATH) VALUES (?, ?, ?, ?, ?, ?)"
            values = [
                .optionalText(record.id), .optionalText(record.title), .optionalInteger(record.isActive),
                .text("fixture-encrypted-title"), .text("fixture-transcript"), .text("fixture-path")
            ]
        } else {
            sql = "INSERT INTO ZCLOUDRECORDING (ZUNIQUEID, ZVMEMO_SYNTHETIC_TITLE, ZENCRYPTEDTITLE, ZTRANSCRIPT, ZPATH) VALUES (?, ?, ?, ?, ?)"
            values = [
                .optionalText(record.id), .optionalText(record.title),
                .text("fixture-encrypted-title"), .text("fixture-transcript"), .text("fixture-path")
            ]
        }
        try execute(connection, sql: sql, values: values)
    }

    private static func execute(_ connection: OpaquePointer, sql: String, values: [SQLiteValue]) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw FixtureFailure.sqlite
        }
        for (index, value) in values.enumerated() {
            guard value.bind(to: statement, at: Int32(index + 1)) == SQLITE_OK else {
                throw FixtureFailure.sqlite
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw FixtureFailure.sqlite
        }
    }
}

private enum SQLiteValue {
    case text(String)
    case optionalText(String?)
    case integer(Int64)
    case optionalInteger(Int64?)

    func bind(to statement: OpaquePointer, at index: Int32) -> Int32 {
        switch self {
        case let .text(value): sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
        case let .optionalText(value):
            value.map { sqlite3_bind_text(statement, index, $0, -1, sqliteTransient) } ?? sqlite3_bind_null(statement, index)
        case let .integer(value): sqlite3_bind_int64(statement, index, value)
        case let .optionalInteger(value):
            value.map { sqlite3_bind_int64(statement, index, $0) } ?? sqlite3_bind_null(statement, index)
        }
    }
}

private enum FixtureFailure: Error {
    case sqlite
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
