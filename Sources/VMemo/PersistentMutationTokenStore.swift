import CryptoKit
import Darwin
import Foundation

/// The caller supplies canonical representations. Only their SHA-256 digests are persisted.
struct PersistentMutationTokenBinding: Equatable, Sendable {
    let request: String
    let source: String
    let accessibility: String
    let environment: String

    init(request: String, source: String, accessibility: String, environment: String) {
        self.request = request
        self.source = source
        self.accessibility = accessibility
        self.environment = environment
    }
}

enum PersistentMutationTokenConsumption: Equatable, Sendable {
    case consumed
    case missing
    case expired
    case replayed
    case bindingMismatch
}

enum PersistentMutationTokenStoreError: Error, Equatable, Sendable {
    case invalidRoot
    case insecurePath
    case corruptRecord
    case invalidInput
    case tokenAlreadyIssued
    case ioFailure
}

enum PersistentMutationSessionLockError: Error, Equatable, Sendable {
    case busy
    case unavailable
}

/// A disk-backed capability store. It intentionally does not conform to the legacy in-memory seam:
/// consumers must provide the binding again when consuming a capability.
final class PersistentMutationTokenStore: @unchecked Sendable {
    private static let storeLockName = "mutation-token-store.lock"
    private static let sessionLockName = "mutation-session.lock"
    private static let recordVersion = 1
    private static let maximumRecordBytes = 4_096
    private static let rootLocksLock = NSLock()
    nonisolated(unsafe) private static var rootLocks: [String: RootLocks] = [:]

    private let rootDirectory: URL
    private let currentUID: @Sendable () -> uid_t
    private let locks: RootLocks

    init(
        rootDirectory: URL,
        currentUID: @escaping @Sendable () -> uid_t = { geteuid() }
    ) throws {
        self.rootDirectory = rootDirectory
        self.currentUID = currentUID
        locks = Self.locks(for: rootDirectory.standardizedFileURL.resolvingSymlinksInPath().path)
        let root = try openRootDirectory()
        _ = close(root)
    }

    /// Atomically creates a new token record. Existing records, including hostile ones, are never overwritten.
    func issue(token: String, binding: PersistentMutationTokenBinding, expiresAt: Date) throws {
        guard !token.isEmpty, let record = makeRecord(binding: binding, expiresAt: expiresAt) else {
            throw PersistentMutationTokenStoreError.invalidInput
        }
        let name = tokenFileName(token)

        try withStoreLock { root in
            let descriptor = openat(root, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            if descriptor >= 0 {
                defer { _ = close(descriptor) }
                _ = try validatedRecord(from: descriptor)
                throw PersistentMutationTokenStoreError.tokenAlreadyIssued
            }
            guard errno == ENOENT else { throw classifiedPathError() }

            let output = openat(
                root,
                name,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(S_IRUSR | S_IWUSR)
            )
            guard output >= 0 else {
                if errno == EEXIST { throw PersistentMutationTokenStoreError.tokenAlreadyIssued }
                throw classifiedPathError()
            }
            defer { _ = close(output) }
            guard fchmod(output, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
                throw PersistentMutationTokenStoreError.ioFailure
            }
            try validateSecureRegularFile(output)
            try writeRecord(record, to: output)
            guard fsync(root) == 0 else { throw PersistentMutationTokenStoreError.ioFailure }
        }
    }

    /// Validates binding, expiry and replay state under the interprocess lock, then durably consumes before action.
    func consume(
        token: String,
        binding: PersistentMutationTokenBinding,
        at date: Date
    ) throws -> PersistentMutationTokenConsumption {
        guard !token.isEmpty, let expected = makeRecord(binding: binding, expiresAt: date) else {
            throw PersistentMutationTokenStoreError.invalidInput
        }
        let name = tokenFileName(token)

        return try withStoreLock { root in
            let descriptor = openat(root, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else {
                if errno == ENOENT { return .missing }
                throw classifiedPathError()
            }
            let record: DiskRecord
            do {
                record = try validatedRecord(from: descriptor)
                _ = close(descriptor)
            } catch {
                _ = close(descriptor)
                throw error
            }

            guard record.requestSHA256 == expected.requestSHA256,
                  record.sourceSHA256 == expected.sourceSHA256,
                  record.accessibilitySHA256 == expected.accessibilitySHA256,
                  record.environmentSHA256 == expected.environmentSHA256
            else { return .bindingMismatch }
            if record.consumed { return .replayed }
            guard let now = milliseconds(for: date) else { throw PersistentMutationTokenStoreError.invalidInput }
            if record.expiresAtMilliseconds <= now { return .expired }

            var consumed = record
            consumed.consumed = true
            try atomicRewrite(consumed, named: name, in: root)
            return .consumed
        }
    }

    /// Nonblocking, process-wide protection for resolver → AX → consume → action → postcondition.
    func acquireMutationSession() throws -> PersistentMutationSessionLock {
        let root = try openRootDirectory()
        defer { _ = close(root) }
        guard locks.session.try() else { throw PersistentMutationSessionLockError.busy }
        let descriptor: Int32
        do {
            descriptor = try openSecureLock(named: Self.sessionLockName, in: root)
        } catch {
            locks.session.unlock()
            throw PersistentMutationSessionLockError.unavailable
        }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            _ = close(descriptor)
            locks.session.unlock()
            if errno == EWOULDBLOCK || errno == EAGAIN { throw PersistentMutationSessionLockError.busy }
            throw PersistentMutationSessionLockError.unavailable
        }
        return PersistentMutationSessionLock(descriptor: descriptor, inProcessLock: locks.session)
    }

    private func withStoreLock<Result>(_ body: (Int32) throws -> Result) throws -> Result {
        locks.store.lock()
        defer { locks.store.unlock() }
        let root = try openRootDirectory()
        defer { _ = close(root) }
        let lock = try openSecureLock(named: Self.storeLockName, in: root)
        defer { _ = close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw PersistentMutationTokenStoreError.ioFailure }
        defer { _ = flock(lock, LOCK_UN) }
        return try body(root)
    }

    private func openRootDirectory() throws -> Int32 {
        let path = rootDirectory.path
        guard !path.isEmpty, path.hasPrefix("/"), !path.contains("\0") else {
            throw PersistentMutationTokenStoreError.invalidRoot
        }
        let created = mkdir(path, mode_t(S_IRUSR | S_IWUSR | S_IXUSR)) == 0
        if !created, errno != EEXIST {
            throw PersistentMutationTokenStoreError.invalidRoot
        }
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw PersistentMutationTokenStoreError.insecurePath }
        do {
            if created, fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR | S_IXUSR)) != 0 {
                throw PersistentMutationTokenStoreError.ioFailure
            }
            try validateSecureDirectory(descriptor)
            return descriptor
        } catch {
            _ = close(descriptor)
            throw error
        }
    }

    private func openSecureLock(named name: String, in root: Int32) throws -> Int32 {
        let created = openat(
            root,
            name,
            O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
            mode_t(S_IRUSR | S_IWUSR)
        )
        let descriptor: Int32
        if created >= 0 {
            descriptor = created
            guard fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
                _ = close(descriptor)
                throw PersistentMutationTokenStoreError.ioFailure
            }
        } else {
            guard errno == EEXIST else { throw classifiedPathError() }
            descriptor = openat(root, name, O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else { throw classifiedPathError() }
        }
        do {
            try validateSecureRegularFile(descriptor)
            return descriptor
        } catch {
            _ = close(descriptor)
            throw error
        }
    }

    private func atomicRewrite(_ record: DiskRecord, named name: String, in root: Int32) throws {
        let temporaryName = ".mutation-token-\(UUID().uuidString)"
        let temporary = openat(
            root,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard temporary >= 0 else { throw classifiedPathError() }
        var shouldRemoveTemporary = true
        defer {
            _ = close(temporary)
            if shouldRemoveTemporary { _ = unlinkat(root, temporaryName, 0) }
        }
        guard fchmod(temporary, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw PersistentMutationTokenStoreError.ioFailure
        }
        try validateSecureRegularFile(temporary)
        try writeRecord(record, to: temporary)

        let current = openat(root, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard current >= 0 else { throw classifiedPathError() }
        defer { _ = close(current) }
        let currentRecord = try validatedRecord(from: current)
        guard currentRecord == record.withConsumed(false), !currentRecord.consumed else {
            throw PersistentMutationTokenStoreError.corruptRecord
        }

        guard renameat(root, temporaryName, root, name) == 0 else { throw PersistentMutationTokenStoreError.ioFailure }
        shouldRemoveTemporary = false
        guard fsync(root) == 0 else { throw PersistentMutationTokenStoreError.ioFailure }
    }

    private func writeRecord(_ record: DiskRecord, to descriptor: Int32) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(record)
        } catch {
            throw PersistentMutationTokenStoreError.ioFailure
        }
        try writeAll(data, to: descriptor)
        guard fsync(descriptor) == 0 else { throw PersistentMutationTokenStoreError.ioFailure }
    }

    private func validatedRecord(from descriptor: Int32) throws -> DiskRecord {
        try validateSecureRegularFile(descriptor)
        let data = try readAll(from: descriptor)
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == DiskRecord.allowedKeys
            else { throw PersistentMutationTokenStoreError.corruptRecord }
            let record = try JSONDecoder().decode(DiskRecord.self, from: data)
            guard record.version == Self.recordVersion,
                  isSHA256(record.requestSHA256),
                  isSHA256(record.sourceSHA256),
                  isSHA256(record.accessibilitySHA256),
                  isSHA256(record.environmentSHA256),
                  record.expiresAtMilliseconds >= 0
            else { throw PersistentMutationTokenStoreError.corruptRecord }
            return record
        } catch let error as PersistentMutationTokenStoreError {
            throw error
        } catch {
            throw PersistentMutationTokenStoreError.corruptRecord
        }
    }

    private func validateSecureDirectory(_ descriptor: Int32) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == currentUID(),
              (status.st_mode & 0o7777) == 0o700,
              status.st_nlink >= 1
        else { throw PersistentMutationTokenStoreError.insecurePath }
    }

    private func validateSecureRegularFile(_ descriptor: Int32) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == currentUID(),
              (status.st_mode & 0o7777) == 0o600,
              status.st_nlink == 1
        else { throw PersistentMutationTokenStoreError.insecurePath }
    }

    private func readAll(from descriptor: Int32) throws -> Data {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_size >= 0,
              status.st_size <= off_t(Self.maximumRecordBytes),
              lseek(descriptor, 0, SEEK_SET) >= 0
        else { throw PersistentMutationTokenStoreError.corruptRecord }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count == 0 { return data }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw PersistentMutationTokenStoreError.corruptRecord }
            data.append(buffer, count: Int(count))
            if data.count > Self.maximumRecordBytes { throw PersistentMutationTokenStoreError.corruptRecord }
        }
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes {
                write(descriptor, $0.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw PersistentMutationTokenStoreError.ioFailure }
            offset += count
        }
    }

    private func makeRecord(binding: PersistentMutationTokenBinding, expiresAt: Date) -> DiskRecord? {
        guard !binding.request.isEmpty,
              !binding.source.isEmpty,
              !binding.accessibility.isEmpty,
              !binding.environment.isEmpty,
              let milliseconds = milliseconds(for: expiresAt)
        else { return nil }
        return DiskRecord(
            version: Self.recordVersion,
            requestSHA256: sha256(binding.request),
            sourceSHA256: sha256(binding.source),
            accessibilitySHA256: sha256(binding.accessibility),
            environmentSHA256: sha256(binding.environment),
            expiresAtMilliseconds: milliseconds,
            consumed: false
        )
    }

    private func milliseconds(for date: Date) -> Int64? {
        let value = date.timeIntervalSince1970 * 1_000
        guard value.isFinite, value >= 0, value <= Double(Int64.max) else { return nil }
        return Int64(value.rounded(.towardZero))
    }

    private func tokenFileName(_ token: String) -> String {
        sha256(token)
    }

    private func classifiedPathError() -> PersistentMutationTokenStoreError {
        (errno == ELOOP || errno == ENOTDIR || errno == EISDIR || errno == EACCES || errno == EPERM || errno == ENXIO)
            ? .insecurePath
            : .ioFailure
    }

    private static func locks(for path: String) -> RootLocks {
        rootLocksLock.lock()
        defer { rootLocksLock.unlock() }
        if let locks = rootLocks[path] { return locks }
        let locks = RootLocks()
        rootLocks[path] = locks
        return locks
    }
}

/// Holds a `flock` until explicitly released or deinitialized.
final class PersistentMutationSessionLock: @unchecked Sendable {
    private let stateLock = NSLock()
    private var descriptor: Int32
    private var inProcessLock: NSLock?

    fileprivate init(descriptor: Int32, inProcessLock: NSLock) {
        self.descriptor = descriptor
        self.inProcessLock = inProcessLock
    }

    func release() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
        descriptor = -1
        inProcessLock?.unlock()
        inProcessLock = nil
    }

    deinit {
        release()
    }
}

private final class RootLocks: @unchecked Sendable {
    let store = NSLock()
    let session = NSLock()
}

private struct DiskRecord: Codable, Equatable {
    static let allowedKeys: Set<String> = [
        "version",
        "requestSHA256",
        "sourceSHA256",
        "accessibilitySHA256",
        "environmentSHA256",
        "expiresAtMilliseconds",
        "consumed",
    ]

    let version: Int
    let requestSHA256: String
    let sourceSHA256: String
    let accessibilitySHA256: String
    let environmentSHA256: String
    let expiresAtMilliseconds: Int64
    var consumed: Bool

    func withConsumed(_ consumed: Bool) -> DiskRecord {
        DiskRecord(
            version: version,
            requestSHA256: requestSHA256,
            sourceSHA256: sourceSHA256,
            accessibilitySHA256: accessibilitySHA256,
            environmentSHA256: environmentSHA256,
            expiresAtMilliseconds: expiresAtMilliseconds,
            consumed: consumed
        )
    }
}

private func sha256(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func isSHA256(_ value: String) -> Bool {
    value.count == 64 && value.unicodeScalars.allSatisfy {
        (48...57).contains($0.value) || (97...102).contains($0.value)
    }
}
