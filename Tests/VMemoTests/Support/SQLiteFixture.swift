import Foundation
import SQLite3

struct SQLiteFixture {
    static func walURL(for databaseURL: URL) -> URL {
        URL(fileURLWithPath: databaseURL.path + "-wal")
    }

    static func shmURL(for databaseURL: URL) -> URL {
        URL(fileURLWithPath: databaseURL.path + "-shm")
    }

    final class ActiveWALDatabase {
        private var connection: OpaquePointer?

        fileprivate init(connection: OpaquePointer) {
            self.connection = connection
        }

        func close() {
            if let connection {
                sqlite3_close_v2(connection)
            }
            connection = nil
        }

        deinit {
            close()
        }
    }

    static func cleanCloseDatabase(at path: URL, value: String) throws {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(path.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            let error = fixtureError(connection)
            sqlite3_close(connection)
            throw error
        }
        defer { sqlite3_close(connection) }

        let sql = """
        CREATE TABLE fixture(value TEXT);
        INSERT INTO fixture(value) VALUES('\(value)');
        """
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            throw fixtureError(connection)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    static func textValue(at path: URL, query: String) throws -> String {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(path.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let error = fixtureError(connection)
            sqlite3_close(connection)
            throw error
        }
        defer { sqlite3_close(connection) }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(connection, query, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0)
        else {
            throw fixtureError(connection)
        }
        return String(cString: text)
    }

    static func activeWALDatabase(at path: URL, value: String) throws -> ActiveWALDatabase {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(path.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let connection
        else {
            let error = fixtureError(connection)
            sqlite3_close(connection)
            throw error
        }
        guard sqlite3_exec(connection, "PRAGMA journal_mode=WAL; CREATE TABLE fixture(value TEXT);", nil, nil, nil) == SQLITE_OK else {
            let error = fixtureError(connection)
            sqlite3_close_v2(connection)
            throw error
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, "INSERT INTO fixture(value) VALUES(?);", -1, &statement, nil) == SQLITE_OK,
              sqlite3_bind_text(statement, 1, value, -1, sqliteTransient) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE
        else {
            let error = fixtureError(connection)
            sqlite3_finalize(statement)
            sqlite3_close_v2(connection)
            throw error
        }
        sqlite3_finalize(statement)
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: walURL(for: path).path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: shmURL(for: path).path)
        } catch {
            sqlite3_close_v2(connection)
            throw error
        }
        return ActiveWALDatabase(connection: connection)
    }

    private static func fixtureError(_ connection: OpaquePointer?) -> Error {
        guard let connection else {
            return FixtureError.sqlite("SQLite did not return a connection handle.")
        }
        return FixtureError.sqlite(String(cString: sqlite3_errmsg(connection)))
    }
}

private enum FixtureError: Error {
    case sqlite(String)
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
