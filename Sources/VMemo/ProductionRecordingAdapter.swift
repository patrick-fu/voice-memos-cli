import CryptoKit
import Foundation
import SQLite3

enum ProductionRecordingAdapterError: Error, Equatable, Sendable {
    case unsupportedSchema
    case recordingNotFound

    var code: String { self == .unsupportedSchema ? "unsupported_schema" : "recording_not_found" }
    var message: String {
        self == .unsupportedSchema
            ? "The Voice Memos snapshot does not match the supported production schema."
            : "No Recording matches the supplied Recording ID."
    }
    var exitCode: Int32 { self == .unsupportedSchema ? ProcessExit.safetyFailure.rawValue : ProcessExit.operationalFailure.rawValue }
}

/// Reads only the exact build-1380 physical projection after the caller has isolated and
/// identity-validated its store. It deliberately has no synthetic manifest fallback.
struct ProductionRecordingAdapter: RecordingReadPort, RecordingAssetReferenceResolver {
    private let snapshotURL: URL

    init(snapshotURL: URL) { self.snapshotURL = snapshotURL }

    func list() throws -> [RecordingSummary] { try validatedProjection().active.map(\.summary) }

    func search(query: String) throws -> [RecordingSummary] {
        try validatedProjection().active.map(\.summary).filter {
            $0.title.range(of: query, options: .caseInsensitive, range: nil, locale: Locale(identifier: "en_US_POSIX")) != nil
        }
    }

    func show(id: RecordingID) throws -> RecordingSummary {
        guard let row = try validatedProjection().active.first(where: { utf8ExactEqual($0.id.value, id.value) }) else { throw ProductionRecordingAdapterError.recordingNotFound }
        return row.summary
    }

    func assetReference(for id: RecordingID) throws -> String? {
        guard let row = try validatedProjection().active.first(where: { utf8ExactEqual($0.id.value, id.value) }) else { throw ProductionRecordingAdapterError.recordingNotFound }
        guard let path = row.path else { return nil }
        guard safeProductionReference(path) != nil else { throw RecordingAssetError.pathOutsideRecordingsRoot }
        guard path.hasSuffix(".m4a") else { throw RecordingAssetError.unsupportedAssetFormat }
        return path
    }

    func validatedProjection() throws -> ProductionValidatedProjection {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(snapshotURL.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let connection else {
            sqlite3_close_v2(connection)
            throw ProductionRecordingAdapterError.unsupportedSchema
        }
        defer { sqlite3_close_v2(connection) }
        guard sqlite3_exec(connection, "BEGIN", nil, nil, nil) == SQLITE_OK else { throw ProductionRecordingAdapterError.unsupportedSchema }
        var open = true
        defer { if open { sqlite3_exec(connection, "ROLLBACK", nil, nil, nil) } }
        try validateSchema(connection)
        let loaded = try loadRows(connection)
        guard sqlite3_exec(connection, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw ProductionRecordingAdapterError.unsupportedSchema }
        open = false
        return ProductionValidatedProjection(recordings: loaded)
    }

    private func validateSchema(_ connection: OpaquePointer) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(connection, "PRAGMA table_info(ZCLOUDRECORDING)", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ProductionRecordingAdapterError.unsupportedSchema
        }
        var observed: [String] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard let name = text(statement, 1), let type = text(statement, 2) else { throw ProductionRecordingAdapterError.unsupportedSchema }
            let defaultValue: String
            switch sqlite3_column_type(statement, 4) {
            case SQLITE_NULL: defaultValue = ""
            case SQLITE_TEXT: guard let value = text(statement, 4) else { throw ProductionRecordingAdapterError.unsupportedSchema }; defaultValue = value
            default: throw ProductionRecordingAdapterError.unsupportedSchema
            }
            observed.append("\(sqlite3_column_int(statement, 0))|\(name)|\(type)|\(sqlite3_column_int(statement, 3))|\(defaultValue)|\(sqlite3_column_int(statement, 5))")
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE,
              observed == Self.canonicalSchema,
              Self.canonicalSchemaSHA256 == Self.expectedCanonicalSchemaSHA256
        else { throw ProductionRecordingAdapterError.unsupportedSchema }
    }

    private func loadRows(_ connection: OpaquePointer) throws -> [ProductionValidatedRecording] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT ZUNIQUEID, ZCUSTOMLABELFORSORTING, ZENCRYPTEDTITLE, ZPATH, ZEVICTIONDATE FROM ZCLOUDRECORDING ORDER BY ZUNIQUEID COLLATE BINARY"
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw ProductionRecordingAdapterError.unsupportedSchema }
        var ids = Set<Data>()
        var result: [ProductionValidatedRecording] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard sqlite3_column_type(statement, 0) == SQLITE_TEXT,
                  sqlite3_column_type(statement, 1) == SQLITE_TEXT,
                  sqlite3_column_type(statement, 2) == SQLITE_TEXT,
                  let id = text(statement, 0), !id.utf8.isEmpty,
                  let sortingTitle = text(statement, 1), !sortingTitle.utf8.isEmpty,
                  let encryptedTitle = text(statement, 2), !encryptedTitle.utf8.isEmpty,
                  utf8ExactEqual(sortingTitle, encryptedTitle),
                  ids.insert(Data(id.utf8)).inserted
            else { throw ProductionRecordingAdapterError.unsupportedSchema }
            let path: String?
            switch sqlite3_column_type(statement, 3) {
            case SQLITE_NULL: path = nil
            case SQLITE_TEXT: guard let value = text(statement, 3) else { throw ProductionRecordingAdapterError.unsupportedSchema }; path = value
            default: throw ProductionRecordingAdapterError.unsupportedSchema
            }
            let active: Bool
            switch sqlite3_column_type(statement, 4) {
            case SQLITE_NULL: active = true
            case SQLITE_FLOAT: active = false
            default: throw ProductionRecordingAdapterError.unsupportedSchema
            }
            result.append(ProductionValidatedRecording(id: RecordingID(value: id), title: sortingTitle, path: path, isActive: active))
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw ProductionRecordingAdapterError.unsupportedSchema }
        return result
    }

    private static let canonicalSchema = [
        "0|Z_PK|INTEGER|0||1", "1|Z_ENT|INTEGER|0||0", "2|Z_OPT|INTEGER|0||0", "3|ZAUDIOFUTUREFLAGS|INTEGER|0||0", "4|ZFLAGS|INTEGER|0||0", "5|ZSHAREDFLAGS|INTEGER|0||0", "6|ZSILENCEREMOVERENABLED|INTEGER|0||0", "7|ZSKIPSILENCEENABLED|INTEGER|0||0", "8|ZSTUDIOMIXENABLED|INTEGER|0||0", "9|ZFOLDER|INTEGER|0||0", "10|ZDATE|TIMESTAMP|0||0", "11|ZDURATION|FLOAT|0||0", "12|ZEVICTIONDATE|TIMESTAMP|0||0", "13|ZLOCALDURATION|FLOAT|0||0", "14|ZMTLAYERMIX|FLOAT|0||0", "15|ZPLAYBACKPOSITION|FLOAT|0||0", "16|ZPLAYBACKRATE|FLOAT|0||0", "17|ZPLAYBACKSPEED|FLOAT|0||0", "18|ZSTUDIOMIXLEVEL|FLOAT|0||0", "19|ZCUSTOMLABEL|VARCHAR|0||0", "20|ZCUSTOMLABELFORSORTING|VARCHAR|0||0", "21|ZENCRYPTEDTITLE|VARCHAR|0||0", "22|ZPATH|VARCHAR|0||0", "23|ZUNIQUEID|VARCHAR|0||0", "24|ZAUDIOFUTUREUUIDS|BLOB|0||0", "25|ZAUDIODIGEST|BLOB|0||0", "26|ZAUDIOFUTURE|BLOB|0||0", "27|ZMTAUDIOFUTURE|BLOB|0||0", "28|ZVERSIONEDAUDIOFUTURE|BLOB|0||0",
    ]
    private static let expectedCanonicalSchemaSHA256 = "9f3c4d7a46bb8ef37028fefdaf30ef1da7d0e93b9494877e3871fdae40a9a511"
    private static let canonicalSchemaSHA256 = SHA256.hash(data: Data((canonicalSchema.joined(separator: "\n") + "\n").utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}

private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
    guard let pointer = sqlite3_column_text(statement, index) else { return nil }
    return String(bytes: UnsafeBufferPointer(start: pointer, count: Int(sqlite3_column_bytes(statement, index))), encoding: .utf8)
}


func utf8ExactEqual(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.elementsEqual(rhs.utf8)
}

private func safeProductionReference(_ path: String) -> [String]? {
    guard !path.isEmpty, !path.contains("\0"), !path.hasPrefix("/"), !path.hasPrefix("\\") else { return nil }
    let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
    return parts
}

struct ProductionValidatedRecording: Equatable, Sendable {
    let id: RecordingID
    let title: String
    let path: String?
    let isActive: Bool
    var summary: RecordingSummary { RecordingSummary(id: id, title: title) }

    static func == (lhs: Self, rhs: Self) -> Bool {
        utf8ExactEqual(lhs.id.value, rhs.id.value)
            && utf8ExactEqual(lhs.title, rhs.title)
            && lhs.path == rhs.path
            && lhs.isActive == rhs.isActive
    }
}

struct ProductionValidatedProjection: Equatable, Sendable {
    let recordings: [ProductionValidatedRecording]
    let fingerprint: String

    init(recordings: [ProductionValidatedRecording]) {
        self.recordings = recordings
        fingerprint = Self.fingerprint(for: recordings)
    }

    var active: [ProductionValidatedRecording] { recordings.filter(\.isActive) }

    private static let fingerprintVersion = Data("VMEMO-SRC-FP-1".utf8)

    private static func fingerprint(for recordings: [ProductionValidatedRecording]) -> String {
        var payload = fingerprintVersion
        appendUInt32(&payload, UInt32(recordings.count))
        for recording in recordings {
            let id = Data(recording.id.value.utf8)
            let title = Data(recording.title.utf8)
            appendUInt32(&payload, UInt32(id.count))
            payload.append(id)
            appendUInt32(&payload, UInt32(title.count))
            payload.append(title)
            payload.append(recording.isActive ? 1 : 0)
        }
        return SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
}
