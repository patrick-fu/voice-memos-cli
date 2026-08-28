import CryptoKit
import Darwin
import Foundation

struct SafeRecordingAssetPort: RecordingAssetPort {
    let recordingsRoot: URL
    let resolver: any RecordingAssetReferenceResolver
    let beforePostCopyValidation: @Sendable () -> Void

    init(
        recordingsRoot: URL,
        resolver: any RecordingAssetReferenceResolver,
        beforePostCopyValidation: @escaping @Sendable () -> Void = {}
    ) {
        self.recordingsRoot = recordingsRoot
        self.resolver = resolver
        self.beforePostCopyValidation = beforePostCopyValidation
    }

    func export(id: RecordingID, destination: String) throws -> ExportReceipt {
        guard let reference = try resolver.assetReference(for: id) else {
            throw RecordingAssetError.assetUnavailable
        }
        return try copy(id: id, reference: reference, destination: destination)
    }

    private func copy(id: RecordingID, reference: String, destination: String) throws -> ExportReceipt {
        guard let sourceComponents = safeRelativeComponents(reference) else {
            throw RecordingAssetError.pathOutsideRecordingsRoot
        }
        guard isSupportedAsset(sourceComponents.last ?? "") else {
            throw RecordingAssetError.unsupportedAssetFormat
        }
        guard let destinationParts = destinationParts(destination) else {
            throw RecordingAssetError.destinationUnavailable
        }

        let root = try openRoot()
        defer { _ = close(root) }
        let source = try openRegularSource(root: root, components: sourceComponents)
        defer { _ = close(source) }
        let sourceBefore = try metadata(of: source, source: true)
        let sourceHashBefore = try hash(of: source)

        let parent = try openDirectory(absoluteComponents: destinationParts.parent, failure: .destinationUnavailable)
        defer { _ = close(parent) }
        let temporaryName = ".vmemo-export-\(UUID().uuidString)"
        let temporary = try createTemporary(in: parent, name: temporaryName)
        defer { _ = close(temporary) }

        do {
            let copiedHash = try copyBytes(from: source, to: temporary)
            guard fsync(temporary) == 0 else { throw destinationError() }
            beforePostCopyValidation()
            let sourceAfter = try metadata(of: source, source: true)
            let sourceHashAfter = try hash(of: source)
            guard sourceBefore == sourceAfter, sourceHashBefore == sourceHashAfter, copiedHash == sourceHashBefore else {
                throw RecordingAssetError.exportInconsistent
            }

            if renameatx_np(parent, temporaryName, parent, destinationParts.name, UInt32(RENAME_EXCL)) != 0 {
                if errno == EEXIST { throw RecordingAssetError.destinationExists }
                throw destinationError()
            }
        } catch {
            if !removeTemporary(in: parent, name: temporaryName) {
                throw RecordingAssetError.cleanupFailed
            }
            throw error
        }
        return ExportReceipt(id: id, destination: destination)
    }

    private func openRoot() throws -> Int32 {
        guard let components = absoluteComponents(recordingsRoot.path) else {
            throw RecordingAssetError.pathOutsideRecordingsRoot
        }
        return try openDirectory(absoluteComponents: components, failure: .pathOutsideRecordingsRoot)
    }

    private func openRegularSource(root: Int32, components: [String]) throws -> Int32 {
        var directory = root
        var ownedDirectory: Int32?
        defer { if let ownedDirectory { _ = close(ownedDirectory) } }
        for component in components.dropLast() {
            var status = stat()
            guard fstatat(directory, component, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw sourceError()
            }
            if isSymbolicLink(status) {
                throw RecordingAssetError.pathOutsideRecordingsRoot
            }
            guard isDirectory(status) else { throw RecordingAssetError.notRegularFile }
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard next >= 0 else {
                if errno == ELOOP {
                    throw RecordingAssetError.pathOutsideRecordingsRoot
                }
                throw sourceError()
            }
            if let ownedDirectory { _ = close(ownedDirectory) }
            ownedDirectory = next
            directory = next
        }
        guard let name = components.last else { throw RecordingAssetError.pathOutsideRecordingsRoot }
        var status = stat()
        guard fstatat(directory, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else { throw sourceError() }
        if isSymbolicLink(status) { throw RecordingAssetError.pathOutsideRecordingsRoot }
        guard isRegular(status) else { throw RecordingAssetError.notRegularFile }
        let descriptor = openat(directory, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ELOOP { throw RecordingAssetError.pathOutsideRecordingsRoot }
            throw sourceError()
        }
        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0 else {
            _ = close(descriptor)
            throw sourceError()
        }
        guard isRegular(openedStatus) else {
            _ = close(descriptor)
            throw RecordingAssetError.notRegularFile
        }
        return descriptor
    }

    private func openDirectory(absoluteComponents: [String], failure: RecordingAssetError) throws -> Int32 {
        let root = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard root >= 0 else { throw failure }
        var directory = root
        for component in absoluteComponents {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            if next < 0 {
                _ = close(directory)
                throw failure
            }
            _ = close(directory)
            directory = next
        }
        return directory
    }

    private func createTemporary(in parent: Int32, name: String) throws -> Int32 {
        let descriptor = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw destinationError() }
        return descriptor
    }

    private func copyBytes(from source: Int32, to destination: Int32) throws -> Data {
        try seekToStart(source)
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw sourceError() }
            let chunk = Data(buffer.prefix(Int(count)))
            hasher.update(data: chunk)
            var written = 0
            while written < Int(count) {
                let result = chunk.withUnsafeBytes { write(destination, $0.baseAddress!.advanced(by: written), Int(count) - written) }
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw destinationError() }
                written += result
            }
        }
        return Data(hasher.finalize())
    }

    private func hash(of descriptor: Int32) throws -> Data {
        try seekToStart(descriptor)
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw sourceError() }
            hasher.update(data: Data(buffer.prefix(Int(count))))
        }
        return Data(hasher.finalize())
    }

    private func seekToStart(_ descriptor: Int32) throws {
        while lseek(descriptor, 0, SEEK_SET) < 0 {
            if errno == EINTR { continue }
            throw sourceError()
        }
    }

    private func removeTemporary(in parent: Int32, name: String) -> Bool {
        while unlinkat(parent, name, 0) != 0 {
            if errno == EINTR { continue }
            return errno == ENOENT
        }
        return true
    }

    private func metadata(of descriptor: Int32, source: Bool) throws -> FileMetadata {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw source ? sourceError() : destinationError() }
        return FileMetadata(size: status.st_size, mtimeSeconds: status.st_mtimespec.tv_sec, mtimeNanoseconds: status.st_mtimespec.tv_nsec)
    }

    private func sourceError() -> RecordingAssetError {
        (errno == EACCES || errno == EPERM) ? .accessDeniedUnattributed : .assetUnavailable
    }

    private func destinationError() -> RecordingAssetError {
        (errno == EACCES || errno == EPERM) ? .accessDeniedUnattributed : .destinationUnavailable
    }
}

private struct FileMetadata: Equatable {
    let size: off_t
    let mtimeSeconds: Int
    let mtimeNanoseconds: Int
}

private func safeRelativeComponents(_ path: String) -> [String]? {
    guard !path.isEmpty, !path.contains("\0"), !path.hasPrefix("/"), !path.hasPrefix("\\") else { return nil }
    let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
    return components
}

private func absoluteComponents(_ path: String) -> [String]? {
    guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
    let components = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
    return components
}

private func destinationParts(_ path: String) -> (parent: [String], name: String)? {
    guard let components = absoluteComponents(path), let name = components.last else { return nil }
    return (Array(components.dropLast()), name)
}

private func isSupportedAsset(_ name: String) -> Bool {
    let extensionStart = name.lastIndex(of: ".")
    let fileExtension = extensionStart.map { String(name[$0...]).lowercased() }
    return fileExtension == ".m4a" || fileExtension == ".qta"
}

private func isRegular(_ status: stat) -> Bool {
    (status.st_mode & S_IFMT) == S_IFREG
}

private func isDirectory(_ status: stat) -> Bool {
    (status.st_mode & S_IFMT) == S_IFDIR
}

private func isSymbolicLink(_ status: stat) -> Bool {
    (status.st_mode & S_IFMT) == S_IFLNK
}
