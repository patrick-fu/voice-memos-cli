import Foundation
import SQLite3

enum SchemaAdapterError: Error, Equatable, Sendable {
    case unsupportedSchema
    case recordingNotFound

    var code: String {
        switch self {
        case .unsupportedSchema: "unsupported_schema"
        case .recordingNotFound: "recording_not_found"
        }
    }

    var message: String {
        switch self {
        case .unsupportedSchema: "The snapshot does not match a supported synthetic schema."
        case .recordingNotFound: "No Recording matches the supplied Recording ID."
        }
    }

    var exitCode: Int32 {
        switch self {
        case .unsupportedSchema: ProcessExit.safetyFailure.rawValue
        case .recordingNotFound: ProcessExit.operationalFailure.rawValue
        }
    }
}

/// Reads only explicitly supported synthetic fixture schemas from a snapshot.
struct SchemaAdapter: RecordingReadPort {
    private let snapshotURL: URL

    init(snapshot: SnapshotHandle) {
        self.init(snapshotURL: snapshot.url)
    }

    init(snapshotURL: URL) {
        self.snapshotURL = snapshotURL
    }

    func list() throws -> [RecordingSummary] {
        try withValidatedSnapshot { connection, _ in
            try loadRecordings(connection)
        }
    }

    func search(query: String) throws -> [RecordingSummary] {
        try withValidatedSnapshot { connection, _ in
            try loadRecordings(connection).filter { recording in
                recording.title.range(
                    of: query,
                    options: [.caseInsensitive],
                    range: nil,
                    locale: Locale(identifier: "en_US_POSIX")
                ) != nil
            }
        }
    }

    func show(id: RecordingID) throws -> RecordingSummary {
        try withValidatedSnapshot { connection, _ in
            guard let recording = try loadRecordings(connection).first(where: { $0.id == id }) else {
                throw SchemaAdapterError.recordingNotFound
            }
            return recording
        }
    }

    private func withValidatedSnapshot<Result>(
        _ body: (OpaquePointer, SupportedSyntheticSchema) throws -> Result
    ) throws -> Result {
        try withReadConnection { connection in
            guard sqlite3_exec(connection, SQL.beginReadTransaction, nil, nil, nil) == SQLITE_OK else {
                throw SchemaAdapterError.unsupportedSchema
            }
            var transactionOpen = true
            defer {
                if transactionOpen {
                    sqlite3_exec(connection, SQL.rollbackReadTransaction, nil, nil, nil)
                }
            }
            try validateRequiredColumns(connection, table: SQL.manifestTable, columns: SQL.manifestColumns)
            try validateRequiredColumns(connection, table: SQL.recordingTable, columns: SQL.recordingColumns)
            let schema = try loadSchema(connection)
            let result = try body(connection, schema)
            guard sqlite3_exec(connection, SQL.commitReadTransaction, nil, nil, nil) == SQLITE_OK else {
                throw SchemaAdapterError.unsupportedSchema
            }
            transactionOpen = false
            return result
        }
    }

    private func loadSchema(_ connection: OpaquePointer) throws -> SupportedSyntheticSchema {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(connection, SQL.selectManifest, -1, &statement, nil) == SQLITE_OK,
              let statement,
              sqlite3_step(statement) == SQLITE_ROW,
              let token = textColumn(statement, at: 0),
              let provenance = textColumn(statement, at: 1),
              sqlite3_column_type(statement, 2) == SQLITE_INTEGER,
              sqlite3_column_type(statement, 3) == SQLITE_INTEGER,
              let searchPolicy = textColumn(statement, at: 4),
              let assetPolicy = textColumn(statement, at: 5),
              let generatorVersion = textColumn(statement, at: 6)
        else {
            throw SchemaAdapterError.unsupportedSchema
        }

        let targetOSMajor = sqlite3_column_int64(statement, 2)
        let fixtureRevision = sqlite3_column_int64(statement, 3)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SchemaAdapterError.unsupportedSchema
        }
        guard let schema = SupportedSyntheticSchema(
            token: token,
            provenance: provenance,
            targetOSMajor: targetOSMajor,
            fixtureRevision: fixtureRevision,
            searchPolicy: searchPolicy,
            assetPolicy: assetPolicy,
            generatorVersion: generatorVersion
        ) else {
            throw SchemaAdapterError.unsupportedSchema
        }
        return schema
    }

    private func loadRecordings(_ connection: OpaquePointer) throws -> [RecordingSummary] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(connection, SQL.selectSyntheticRecordings, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw SchemaAdapterError.unsupportedSchema
        }

        var activeRecordings: [RecordingSummary] = []
        var identifiers = Set<UUID>()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let identifier = textColumn(statement, at: 0),
                  let canonicalIdentifier = UUID(uuidString: identifier),
                  let title = textColumn(statement, at: 1),
                  !title.isEmpty,
                  sqlite3_column_type(statement, 2) == SQLITE_INTEGER
            else {
                throw SchemaAdapterError.unsupportedSchema
            }

            let id = RecordingID(value: identifier)
            guard identifiers.insert(canonicalIdentifier).inserted else {
                throw SchemaAdapterError.unsupportedSchema
            }

            switch sqlite3_column_int64(statement, 2) {
            case 0:
                continue
            case 1:
                activeRecordings.append(RecordingSummary(id: id, title: title))
            default:
                throw SchemaAdapterError.unsupportedSchema
            }
        }

        guard isCompletedRead(connection) else {
            throw SchemaAdapterError.unsupportedSchema
        }
        return activeRecordings
    }

    private func withReadConnection<Result>(_ body: (OpaquePointer) throws -> Result) throws -> Result {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(snapshotURL.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let connection
        else {
            sqlite3_close_v2(connection)
            throw SchemaAdapterError.unsupportedSchema
        }
        defer { sqlite3_close_v2(connection) }
        return try body(connection)
    }

    private func validateRequiredColumns(
        _ connection: OpaquePointer,
        table: String,
        columns: [String: String]
    ) throws {
        let sql: String
        switch table {
        case SQL.manifestTable: sql = SQL.manifestTableInfo
        case SQL.recordingTable: sql = SQL.recordingTableInfo
        default: throw SchemaAdapterError.unsupportedSchema
        }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw SchemaAdapterError.unsupportedSchema
        }

        var found: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = textColumn(statement, at: 1), let type = textColumn(statement, at: 2) else {
                throw SchemaAdapterError.unsupportedSchema
            }
            found[name] = type.uppercased()
        }
        guard isCompletedRead(connection),
              columns.allSatisfy({ found[$0.key] == $0.value })
        else {
            throw SchemaAdapterError.unsupportedSchema
        }
    }

    private func textColumn(_ statement: OpaquePointer, at index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) == SQLITE_TEXT,
              let value = sqlite3_column_text(statement, index)
        else {
            return nil
        }
        return String(
            bytes: UnsafeBufferPointer(start: value, count: Int(sqlite3_column_bytes(statement, index))),
            encoding: .utf8
        )
    }

    private func isCompletedRead(_ connection: OpaquePointer) -> Bool {
        let code = sqlite3_errcode(connection)
        return code == SQLITE_OK || code == SQLITE_DONE
    }
}

private struct SupportedSyntheticSchema {
    init?(
        token: String,
        provenance: String,
        targetOSMajor: Int64,
        fixtureRevision: Int64,
        searchPolicy: String,
        assetPolicy: String,
        generatorVersion: String
    ) {
        guard provenance == "synthetic",
              fixtureRevision == 1,
              searchPolicy == "synthetic-case-insensitive-contains-v1",
              assetPolicy == "synthetic-no-assets-v1",
              generatorVersion == "vmemo-synthetic-fixture-generator-v1"
        else {
            return nil
        }

        switch (token, targetOSMajor) {
        case ("synthetic.core-data-recordings.macos15.r1", 15),
             ("synthetic.core-data-recordings.macos26.r1", 26):
            self.searchPolicy = searchPolicy
        default:
            return nil
        }
    }

    let searchPolicy: String
}

private enum SQL {
    static let manifestTable = "VMEMO_SYNTHETIC_MANIFEST"
    static let recordingTable = "ZCLOUDRECORDING"

    static let manifestColumns = [
        "ZSCHEMATOKEN": "TEXT",
        "ZPROVENANCE": "TEXT",
        "ZTARGETOSMAJOR": "INTEGER",
        "ZFIXTUREREVISION": "INTEGER",
        "ZSEARCHPOLICY": "TEXT",
        "ZASSETPOLICY": "TEXT",
        "ZGENERATORVERSION": "TEXT",
    ]
    static let recordingColumns = [
        "ZUNIQUEID": "TEXT",
        "ZVMEMO_SYNTHETIC_TITLE": "TEXT",
        "ZVMEMO_SYNTHETIC_ACTIVE": "INTEGER",
    ]

    static let manifestTableInfo = "PRAGMA table_info(\"VMEMO_SYNTHETIC_MANIFEST\")"
    static let recordingTableInfo = "PRAGMA table_info(\"ZCLOUDRECORDING\")"
    static let beginReadTransaction = "BEGIN"
    static let commitReadTransaction = "COMMIT"
    static let rollbackReadTransaction = "ROLLBACK"
    static let selectManifest = "SELECT ZSCHEMATOKEN, ZPROVENANCE, ZTARGETOSMAJOR, ZFIXTUREREVISION, ZSEARCHPOLICY, ZASSETPOLICY, ZGENERATORVERSION FROM VMEMO_SYNTHETIC_MANIFEST"
    static let selectSyntheticRecordings = "SELECT ZUNIQUEID, ZVMEMO_SYNTHETIC_TITLE, ZVMEMO_SYNTHETIC_ACTIVE FROM ZCLOUDRECORDING ORDER BY ZUNIQUEID COLLATE BINARY"
}
