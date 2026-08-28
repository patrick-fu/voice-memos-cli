import Darwin
import Foundation
import SQLite3

protocol SnapshotPort: Sendable {
    func makeSnapshot(source: URL, destinationRoot: URL) throws -> SnapshotHandle
}

struct SnapshotHandle: Sendable {
    let url: URL

    fileprivate let directory: SnapshotDirectory

    func cleanup() throws {
        try directory.remove()
    }
}

enum SQLiteSnapshotError: Error, Equatable {
    case invalidSource
    case invalidDestinationRoot
    case destinationCreationFailed
    case sqliteFailure(code: Int32)
    case backupDidNotConverge
    case cleanupFailed
}

struct SQLiteSnapshotAdapter: SnapshotPort {
    private static let pagesPerStep: Int32 = 128
    private static let maxBusyRetries = 5
    private static let maxSteps = 10_000
    private static let deadline: Duration = .seconds(2)

    func makeSnapshot(source: URL, destinationRoot: URL) throws -> SnapshotHandle {
        guard isValidatedRegularFile(source), let sourceURI = readOnlyURI(for: source) else {
            throw SQLiteSnapshotError.invalidSource
        }
        guard isValidatedDirectory(destinationRoot) else {
            throw SQLiteSnapshotError.invalidDestinationRoot
        }

        let directory = try makeSnapshotDirectory(in: destinationRoot)
        do {
            let snapshotURL = try createSnapshot(sourceURI: sourceURI, in: directory)
            return SnapshotHandle(url: snapshotURL, directory: directory)
        } catch {
            do {
                try directory.remove()
            } catch {
                throw SQLiteSnapshotError.cleanupFailed
            }
            if let snapshotError = error as? SQLiteSnapshotError {
                throw snapshotError
            }
            throw SQLiteSnapshotError.destinationCreationFailed
        }
    }

    private func createSnapshot(sourceURI: String, in directory: SnapshotDirectory) throws -> URL {
        let snapshotURL = directory.url.appendingPathComponent("snapshot.sqlite", isDirectory: false)
        let snapshotDescriptor = open(snapshotURL.path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard snapshotDescriptor >= 0 else {
            throw SQLiteSnapshotError.destinationCreationFailed
        }
        guard close(snapshotDescriptor) == 0 else {
            throw SQLiteSnapshotError.destinationCreationFailed
        }

        var sourceConnection: OpaquePointer?
        var destinationConnection: OpaquePointer?
        defer {
            if let sourceConnection {
                sqlite3_close_v2(sourceConnection)
            }
            if let destinationConnection {
                sqlite3_close_v2(destinationConnection)
            }
        }

        let sourceStatus = sqlite3_open_v2(
            sourceURI,
            &sourceConnection,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_URI,
            nil
        )
        guard sourceStatus == SQLITE_OK else {
            throw SQLiteSnapshotError.sqliteFailure(code: sourceStatus)
        }
        guard sqlite3_busy_timeout(sourceConnection, 100) == SQLITE_OK else {
            throw SQLiteSnapshotError.sqliteFailure(code: sqlite3_errcode(sourceConnection))
        }

        let destinationStatus = sqlite3_open_v2(
            snapshotURL.path,
            &destinationConnection,
            SQLITE_OPEN_READWRITE,
            nil
        )
        guard destinationStatus == SQLITE_OK else {
            throw SQLiteSnapshotError.sqliteFailure(code: destinationStatus)
        }
        guard sqlite3_busy_timeout(destinationConnection, 100) == SQLITE_OK else {
            throw SQLiteSnapshotError.sqliteFailure(code: sqlite3_errcode(destinationConnection))
        }

        var backup = sqlite3_backup_init(destinationConnection, "main", sourceConnection, "main")
        guard backup != nil else {
            throw SQLiteSnapshotError.sqliteFailure(code: sqlite3_errcode(destinationConnection))
        }
        defer {
            if let backup {
                sqlite3_backup_finish(backup)
            }
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.deadline)
        var busyRetries = 0
        var steps = 0
        while true {
            guard clock.now < deadline, steps < Self.maxSteps else {
                throw SQLiteSnapshotError.backupDidNotConverge
            }
            steps += 1
            let status = sqlite3_backup_step(backup, Self.pagesPerStep)
            switch status {
            case SQLITE_DONE:
                let finishStatus = sqlite3_backup_finish(backup)
                backup = nil
                guard finishStatus == SQLITE_OK else {
                    throw SQLiteSnapshotError.sqliteFailure(code: finishStatus)
                }
                guard sqlite3_exec(destinationConnection, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else {
                    throw SQLiteSnapshotError.sqliteFailure(code: sqlite3_errcode(destinationConnection))
                }
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshotURL.path)
                return snapshotURL
            case SQLITE_OK:
                continue
            case SQLITE_BUSY:
                guard busyRetries < Self.maxBusyRetries else {
                    throw SQLiteSnapshotError.sqliteFailure(code: SQLITE_BUSY)
                }
                busyRetries += 1
                usleep(useconds_t(busyRetries * 10_000))
            default:
                throw SQLiteSnapshotError.sqliteFailure(code: status)
            }
        }
    }

    private func makeSnapshotDirectory(in root: URL) throws -> SnapshotDirectory {
        let template = root.appendingPathComponent("snapshot.XXXXXX", isDirectory: true).path
        var buffer = Array(template.utf8CString)
        guard mkdtemp(&buffer) != nil else {
            throw SQLiteSnapshotError.destinationCreationFailed
        }
        let path = String(decoding: buffer.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        guard let snapshotDirectory = SnapshotDirectory(url: directory) else {
            throw SQLiteSnapshotError.cleanupFailed
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            return snapshotDirectory
        } catch {
            do {
                try snapshotDirectory.remove()
            } catch {
                throw SQLiteSnapshotError.cleanupFailed
            }
            throw SQLiteSnapshotError.destinationCreationFailed
        }
    }

    private func readOnlyURI(for source: URL) -> String? {
        guard isSafeFileURL(source), var components = URLComponents(url: source, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "mode", value: "ro")]
        return components.string
    }

    private func isSafeFileURL(_ url: URL) -> Bool {
        guard url.isFileURL, url.query == nil, url.fragment == nil else { return false }
        guard let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host else { return true }
        return host.isEmpty || host == "localhost"
    }

    private func isValidatedRegularFile(_ url: URL) -> Bool {
        guard isSafeFileURL(url), fileIdentity(at: url, type: S_IFREG) != nil else { return false }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return false }
        return close(descriptor) == 0
    }

    private func isValidatedDirectory(_ url: URL) -> Bool {
        guard isSafeFileURL(url), fileIdentity(at: url, type: S_IFDIR) != nil else { return false }
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { return false }
        return close(descriptor) == 0
    }
}

private struct SnapshotDirectory: Sendable {
    let url: URL
    let identity: FileIdentity

    init?(url: URL) {
        guard let identity = fileIdentity(at: url, type: S_IFDIR) else { return nil }
        self.url = url
        self.identity = identity
    }

    func remove() throws {
        guard fileIdentity(at: url, type: S_IFDIR) == identity else {
            throw SQLiteSnapshotError.cleanupFailed
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw SQLiteSnapshotError.cleanupFailed
        }
    }
}

private struct FileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
}

private func fileIdentity(at url: URL, type: mode_t) -> FileIdentity? {
    var information = stat()
    guard lstat(url.path, &information) == 0, information.st_mode & S_IFMT == type else {
        return nil
    }
    return FileIdentity(device: UInt64(information.st_dev), inode: UInt64(information.st_ino))
}
