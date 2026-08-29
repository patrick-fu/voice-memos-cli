import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import VMemo

final class PersistentMutationTokenStoreTests: XCTestCase {
    fileprivate static let externalHelperTimeout: TimeInterval = 20

    func testIssueIsVisibleAcrossInstancesAndConsumesExactlyOnce() throws {
        let fixture = try TokenStoreFixture()
        let token = "token-fixture-not-on-disk"
        let binding = fixture.binding
        let expiresAt = fixture.now.addingTimeInterval(60)
        let first = try fixture.makeStore()
        let second = try fixture.makeStore()

        try first.issue(token: token, binding: binding, expiresAt: expiresAt)

        XCTAssertEqual(
            try second.consume(token: token, binding: binding, at: fixture.now),
            .consumed
        )
        XCTAssertEqual(
            try first.consume(token: token, binding: binding, at: fixture.now),
            .replayed
        )
        try fixture.assertSecureStoreContents(excluding: [token])
    }

    func testExpiredAndBindingMismatchedTokensRemainUnconsumed() throws {
        let fixture = try TokenStoreFixture()
        let store = try fixture.makeStore()
        try store.issue(token: "expired", binding: fixture.binding, expiresAt: fixture.now)
        try store.issue(token: "bound", binding: fixture.binding, expiresAt: fixture.now.addingTimeInterval(60))

        XCTAssertEqual(
            try store.consume(token: "expired", binding: fixture.binding, at: fixture.now),
            .expired
        )
        XCTAssertEqual(
            try store.consume(
                token: "bound",
                binding: PersistentMutationTokenBinding(
                    request: "different-request",
                    source: fixture.binding.source,
                    accessibility: fixture.binding.accessibility,
                    environment: fixture.binding.environment
                ),
                at: fixture.now
            ),
            .bindingMismatch
        )
        XCTAssertEqual(try store.consume(token: "bound", binding: fixture.binding, at: fixture.now), .consumed)
    }

    func testRejectsEmptyCapabilityToken() throws {
        let fixture = try TokenStoreFixture()

        XCTAssertThrowsError(
            try fixture.makeStore().issue(
                token: "",
                binding: fixture.binding,
                expiresAt: fixture.now.addingTimeInterval(60)
            )
        ) { error in
            XCTAssertEqual(error as? PersistentMutationTokenStoreError, .invalidInput)
        }
    }

    func testSessionLockIsNonblockingAndReleaseMakesItAvailable() throws {
        let fixture = try TokenStoreFixture()
        let first = try fixture.makeStore()
        let second = try fixture.makeStore()
        let lock = try first.acquireMutationSession()

        XCTAssertThrowsError(try second.acquireMutationSession()) { error in
            XCTAssertEqual(error as? PersistentMutationSessionLockError, .busy)
        }

        lock.release()
        let replacement = try second.acquireMutationSession()
        replacement.release()
    }

    func testConcurrentExecutorsConsumeOnlyOneCapability() throws {
        let fixture = try TokenStoreFixture()
        let token = "concurrent-token"
        try fixture.makeStore().issue(token: token, binding: fixture.binding, expiresAt: fixture.now.addingTimeInterval(60))
        let results = LockedResults<PersistentMutationTokenConsumption>()

        DispatchQueue.concurrentPerform(iterations: 2) { _ in
            let result = try? fixture.makeStore().consume(token: token, binding: fixture.binding, at: fixture.now)
            if let result { results.append(result) }
        }

        XCTAssertEqual(results.values.filter { $0 == .consumed }.count, 1)
        XCTAssertEqual(results.values.filter { $0 == .replayed }.count, 1)
    }

    func testConcurrentCallsOnTheSameStoreConsumeOnlyOneCapability() throws {
        let fixture = try TokenStoreFixture()
        let token = "same-store-concurrent-token"
        let store = try fixture.makeStore()
        try store.issue(token: token, binding: fixture.binding, expiresAt: fixture.now.addingTimeInterval(60))
        let results = LockedResults<PersistentMutationTokenConsumption>()

        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            let result = try? store.consume(token: token, binding: fixture.binding, at: fixture.now)
            if let result { results.append(result) }
        }

        XCTAssertEqual(results.values.filter { $0 == .consumed }.count, 1)
        XCTAssertEqual(results.values.filter { $0 == .replayed }.count, 15)
    }

    func testTokenIsConsumedBySeparateXCTestProcess() throws {
        let fixture = try TokenStoreFixture()
        let token = "separate-process-token"
        try fixture.makeStore().issue(token: token, binding: fixture.binding, expiresAt: fixture.now.addingTimeInterval(60))

        let child = try launchChild(root: fixture.root, token: token, mode: "consume")
        let output = try waitForChild(child)

        XCTAssertTrue(output.contains("VMEMO_TOKEN_CHILD_RESULT=consumed"), output)
        XCTAssertEqual(try fixture.makeStore().consume(token: token, binding: fixture.binding, at: fixture.now), .replayed)
    }

    func testTwoSeparateXCTestProcessesConsumeOnlyOneCapability() throws {
        let fixture = try TokenStoreFixture()
        let token = "two-process-token"
        try fixture.makeStore().issue(token: token, binding: fixture.binding, expiresAt: fixture.now.addingTimeInterval(60))
        let gate = try makeGate()
        defer { removeItemIfUnchanged(at: gate.url, expected: gate.identity) }
        let first = try launchChild(root: fixture.root, token: token, mode: "consume", gate: gate.url, worker: "one")
        let second = try launchChild(root: fixture.root, token: token, mode: "consume", gate: gate.url, worker: "two")
        XCTAssertTrue(waitForFile(gate.url.appendingPathComponent("ready-one"), timeout: Self.externalHelperTimeout))
        XCTAssertTrue(waitForFile(gate.url.appendingPathComponent("ready-two"), timeout: Self.externalHelperTimeout))
        XCTAssertTrue(FileManager.default.createFile(atPath: gate.url.appendingPathComponent("start").path, contents: Data()))

        let outputs = try [waitForChild(first), waitForChild(second)]

        XCTAssertEqual(outputs.filter { $0.contains("VMEMO_TOKEN_CHILD_RESULT=consumed") }.count, 1)
        XCTAssertEqual(outputs.filter { $0.contains("VMEMO_TOKEN_CHILD_RESULT=replayed") }.count, 1)
        XCTAssertEqual(try fixture.makeStore().consume(token: token, binding: fixture.binding, at: fixture.now), .replayed)
    }

    func testFIFORecordIsRejectedWithoutBlocking() throws {
        let fixture = try TokenStoreFixture()
        let token = "fifo-token"
        XCTAssertEqual(mkfifo(fixture.recordURL(for: token).path, 0o600), 0)
        let child = try launchChild(root: fixture.root, token: token, mode: "issue")
        let output = try waitForChild(child)

        XCTAssertTrue(output.contains("VMEMO_TOKEN_CHILD_RESULT=insecurePath"), output)
    }

    func testNewRootAndRecordsUseExactModesUnderPermissiveUmask() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vmemo-token-umask-\(UUID().uuidString)", isDirectory: true)
        var rootIdentity: FileIdentity?
        defer {
            if let rootIdentity { removeItemIfUnchanged(at: root, expected: rootIdentity) }
        }
        let child = try launchChild(root: root, token: "umask-token", mode: "umask")
        let output = try waitForChild(child)
        rootIdentity = try fileIdentity(at: root)

        XCTAssertTrue(output.contains("VMEMO_TOKEN_CHILD_RESULT=exactModes"), output)
    }

    func testExternalHelperRejectsNonTemporaryRoot() throws {
        XCTAssertThrowsError(
            try launchChild(
                root: URL(fileURLWithPath: "/dev"),
                token: "invalid-root-token",
                mode: "consume"
            )
        ) { error in
            XCTAssertEqual(error as? PersistentMutationTokenStoreError, .invalidRoot)
        }
    }

    func testFixtureCleanupDoesNotRecursivelyRemoveAReplacementDirectory() throws {
        let fixture = try TokenStoreFixture()
        let movedOriginal = FileManager.default.temporaryDirectory
            .appendingPathComponent("vmemo-token-moved-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.root, to: movedOriginal)
        let movedIdentity = try fileIdentity(at: movedOriginal)
        defer { removeItemIfUnchanged(at: movedOriginal, expected: movedIdentity) }
        try FileManager.default.createDirectory(
            at: fixture.root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let replacementIdentity = try fileIdentity(at: fixture.root)
        defer { removeItemIfUnchanged(at: fixture.root, expected: replacementIdentity) }
        let sentinel = fixture.root.appendingPathComponent("sentinel")
        XCTAssertTrue(FileManager.default.createFile(atPath: sentinel.path, contents: Data("keep".utf8)))

        fixture.cleanup()

        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func testExternalProcessConsumesFixture() throws {
        guard let root = ProcessInfo.processInfo.environment["VMEMO_TOKEN_STORE_CHILD_ROOT"],
              let token = ProcessInfo.processInfo.environment["VMEMO_TOKEN_STORE_CHILD_TOKEN"],
              let mode = ProcessInfo.processInfo.environment["VMEMO_TOKEN_STORE_CHILD_MODE"],
              let marker = ProcessInfo.processInfo.environment["VMEMO_TOKEN_STORE_CHILD_MARKER"],
              UUID(uuidString: marker) != nil,
              CommandLine.arguments.contains("-XCTest")
        else { throw XCTSkip("external helper only") }
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        guard isSystemTemporaryDirectoryChild(rootURL) else {
            throw PersistentMutationTokenStoreError.invalidRoot
        }
        if let gatePath = ProcessInfo.processInfo.environment["VMEMO_TOKEN_STORE_CHILD_GATE"],
           !isSystemTemporaryDirectoryChild(URL(fileURLWithPath: gatePath, isDirectory: true)) {
            throw PersistentMutationTokenStoreError.invalidRoot
        }
        let binding = PersistentMutationTokenBinding(
            request: "request-id-fixture",
            source: "source-title-fixture",
            accessibility: "ax-row-fixture",
            environment: "environment-fixture"
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func emit(_ result: String) {
            print("VMEMO_TOKEN_CHILD_MARKER=\(marker)")
            print("VMEMO_TOKEN_CHILD_RESULT=\(result)")
        }
        switch mode {
        case "consume":
            try waitForStartGateIfRequested()
            let store = try PersistentMutationTokenStore(rootDirectory: rootURL)
            let result = try store.consume(token: token, binding: binding, at: now)
            emit("\(result)")
        case "issue":
            let store = try PersistentMutationTokenStore(rootDirectory: rootURL)
            do {
                try store.issue(token: token, binding: binding, expiresAt: now.addingTimeInterval(60))
                emit("issued")
            } catch let error as PersistentMutationTokenStoreError {
                emit("\(error)")
            }
        case "umask":
            let previousUmask = umask(0)
            defer { _ = umask(previousUmask) }
            let store = try PersistentMutationTokenStore(rootDirectory: rootURL)
            try store.issue(token: token, binding: binding, expiresAt: now.addingTimeInterval(60))
            let rootMode = try fileMode(rootURL)
            let recordMode = try fileMode(rootURL.appendingPathComponent(tokenHash(token)))
            XCTAssertEqual(rootMode, 0o700)
            XCTAssertEqual(recordMode, 0o600)
            emit("exactModes")
        default:
            XCTFail("unexpected external mode")
        }
    }

    func testRejectsSymlinkAndHardlinkRecordsWithoutOverwritingThem() throws {
        let fixture = try TokenStoreFixture()
        let store = try fixture.makeStore()
        let symlinkToken = "symlink-token"
        let target = fixture.root.appendingPathComponent("target")
        XCTAssertTrue(FileManager.default.createFile(atPath: target.path, contents: Data("x".utf8), attributes: [.posixPermissions: 0o600]))
        try FileManager.default.createSymbolicLink(
            at: fixture.recordURL(for: symlinkToken),
            withDestinationURL: target
        )
        XCTAssertThrowsError(try store.issue(token: symlinkToken, binding: fixture.binding, expiresAt: fixture.now.addingTimeInterval(60))) { error in
            XCTAssertEqual(error as? PersistentMutationTokenStoreError, .insecurePath)
        }

        let hardlinkToken = "hardlink-token"
        let source = fixture.root.appendingPathComponent("hardlink-source")
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: Data("x".utf8), attributes: [.posixPermissions: 0o600]))
        XCTAssertEqual(link(source.path, fixture.recordURL(for: hardlinkToken).path), 0)
        XCTAssertThrowsError(try store.issue(token: hardlinkToken, binding: fixture.binding, expiresAt: fixture.now.addingTimeInterval(60))) { error in
            XCTAssertEqual(error as? PersistentMutationTokenStoreError, .insecurePath)
        }
    }

    func testRejectsOwnerAndModeMismatches() throws {
        let fixture = try TokenStoreFixture()
        XCTAssertThrowsError(try fixture.makeStore(expectedUID: geteuid() &+ 1)) { error in
            XCTAssertEqual(error as? PersistentMutationTokenStoreError, .insecurePath)
        }

        let store = try fixture.makeStore()
        let token = "mode-token"
        try store.issue(token: token, binding: fixture.binding, expiresAt: fixture.now.addingTimeInterval(60))
        XCTAssertEqual(chmod(fixture.recordURL(for: token).path, 0o644), 0)
        XCTAssertThrowsError(try store.consume(token: token, binding: fixture.binding, at: fixture.now)) { error in
            XCTAssertEqual(error as? PersistentMutationTokenStoreError, .insecurePath)
        }

        let specialModeToken = "special-mode-token"
        try store.issue(token: specialModeToken, binding: fixture.binding, expiresAt: fixture.now.addingTimeInterval(60))
        XCTAssertEqual(chmod(fixture.recordURL(for: specialModeToken).path, 0o4600), 0)
        XCTAssertThrowsError(try store.consume(token: specialModeToken, binding: fixture.binding, at: fixture.now)) { error in
            XCTAssertEqual(error as? PersistentMutationTokenStoreError, .insecurePath)
        }
    }

    func testRejectsCorruptUnknownVersionAndTamperedRecords() throws {
        let fixture = try TokenStoreFixture()
        let store = try fixture.makeStore()
        let token = "corrupt-token"
        fixture.writeRecord(
            for: token,
            contents: "{\"version\":2,\"requestSHA256\":\"not-a-hash\",\"sourceSHA256\":\"not-a-hash\",\"accessibilitySHA256\":\"not-a-hash\",\"environmentSHA256\":\"not-a-hash\",\"expiresAtMilliseconds\":1,\"consumed\":false}"
        )
        XCTAssertThrowsError(try store.consume(token: token, binding: fixture.binding, at: fixture.now)) { error in
            XCTAssertEqual(error as? PersistentMutationTokenStoreError, .corruptRecord)
        }

        let issued = "tampered-token"
        try store.issue(token: issued, binding: fixture.binding, expiresAt: fixture.now.addingTimeInterval(60))
        fixture.writeRecord(for: issued, contents: "tampered")
        XCTAssertThrowsError(try store.consume(token: issued, binding: fixture.binding, at: fixture.now)) { error in
            XCTAssertEqual(error as? PersistentMutationTokenStoreError, .corruptRecord)
        }
    }

    private func launchChild(
        root: URL,
        token: String,
        mode: String,
        gate: URL? = nil,
        worker: String? = nil
    ) throws -> ChildProcess {
        guard isSystemTemporaryDirectoryChild(root),
              gate.map(isSystemTemporaryDirectoryChild) ?? true
        else { throw PersistentMutationTokenStoreError.invalidRoot }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xctest",
            "-XCTest",
            "VMemoTests.PersistentMutationTokenStoreTests/testExternalProcessConsumesFixture",
            Bundle(for: Self.self).bundleURL.path,
        ]
        var environment = [
            "VMEMO_TOKEN_STORE_CHILD_ROOT": root.path,
            "VMEMO_TOKEN_STORE_CHILD_TOKEN": token,
            "VMEMO_TOKEN_STORE_CHILD_MODE": mode,
            "VMEMO_TOKEN_STORE_CHILD_MARKER": UUID().uuidString,
        ]
        if let developerDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] {
            environment["DEVELOPER_DIR"] = developerDirectory
        }
        if let gate, let worker {
            environment["VMEMO_TOKEN_STORE_CHILD_GATE"] = gate.path
            environment["VMEMO_TOKEN_STORE_CHILD_WORKER"] = worker
        }
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        return ChildProcess(process: process, output: output, marker: environment["VMEMO_TOKEN_STORE_CHILD_MARKER"]!)
    }

    private func waitForChild(
        _ child: ChildProcess,
        timeout: TimeInterval = PersistentMutationTokenStoreTests.externalHelperTimeout
    ) throws -> String {
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            child.process.waitUntilExit()
            finished.signal()
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            child.process.terminate()
            _ = finished.wait(timeout: .now() + 1)
            XCTFail("external helper timed out")
            return ""
        }
        let output = String(decoding: child.output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(child.process.terminationStatus, 0, output)
        XCTAssertTrue(output.contains("VMEMO_TOKEN_CHILD_MARKER=\(child.marker)"), output)
        return output
    }

    private func makeGate() throws -> TemporaryDirectoryLease {
        let gate = FileManager.default.temporaryDirectory
            .appendingPathComponent("vmemo-token-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: gate,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return try TemporaryDirectoryLease(url: gate)
    }

    private func waitForFile(_ file: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: file.path) { return true }
            usleep(1_000)
        }
        return false
    }
}

private final class TokenStoreFixture: @unchecked Sendable {
    let root: URL
    private let rootIdentity: FileIdentity
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let binding = PersistentMutationTokenBinding(
        request: "request-id-fixture",
        source: "source-title-fixture",
        accessibility: "ax-row-fixture",
        environment: "environment-fixture"
    )

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vmemo-persistent-token-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        rootIdentity = try fileIdentity(at: root)
    }

    deinit {
        cleanup()
    }

    func cleanup() {
        removeItemIfUnchanged(at: root, expected: rootIdentity)
    }

    func makeStore(expectedUID: uid_t = geteuid()) throws -> PersistentMutationTokenStore {
        try PersistentMutationTokenStore(rootDirectory: root, currentUID: { expectedUID })
    }

    func recordURL(for token: String) -> URL {
        root.appendingPathComponent(SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined())
    }

    func writeRecord(for token: String, contents: String) {
        let url = recordURL(for: token)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data(contents.utf8), attributes: [.posixPermissions: 0o600]))
        XCTAssertEqual(chmod(url.path, 0o600), 0)
    }

    func assertSecureStoreContents(excluding plaintext: [String]) throws {
        let rootAttributes = try FileManager.default.attributesOfItem(atPath: root.path)
        XCTAssertEqual(rootAttributes[.posixPermissions] as? NSNumber, 0o700)

        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(names.isEmpty)
        for name in names {
            if name != "mutation-token-store.lock", name != "mutation-session.lock" {
                XCTAssertEqual(name.count, 64)
                XCTAssertTrue(name.unicodeScalars.allSatisfy {
                    (48...57).contains($0.value) || (97...102).contains($0.value)
                })
            }
            let url = root.appendingPathComponent(name)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, 0o600)
            let bytes = try Data(contentsOf: url)
            for value in plaintext + [binding.request, binding.source, binding.accessibility, binding.environment] {
                XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(value))
            }
        }
    }
}

private final class LockedResults<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: Value) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private final class ChildProcess: @unchecked Sendable {
    let process: Process
    let output: Pipe
    let marker: String

    init(process: Process, output: Pipe, marker: String) {
        self.process = process
        self.output = output
        self.marker = marker
    }
}

private struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
}

private struct TemporaryDirectoryLease {
    let url: URL
    let identity: FileIdentity

    init(url: URL) throws {
        self.url = url
        identity = try fileIdentity(at: url)
    }
}

private func tokenHash(_ token: String) -> String {
    SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func fileMode(_ url: URL) throws -> mode_t {
    var status = stat()
    guard lstat(url.path, &status) == 0 else { throw POSIXError(.ENOENT) }
    return status.st_mode & 0o7777
}

private func fileIdentity(at url: URL) throws -> FileIdentity {
    var status = stat()
    guard lstat(url.path, &status) == 0 else { throw POSIXError(.ENOENT) }
    return FileIdentity(device: status.st_dev, inode: status.st_ino)
}

private func removeItemIfUnchanged(at url: URL, expected: FileIdentity) {
    guard (try? fileIdentity(at: url)) == expected else { return }
    try? FileManager.default.removeItem(at: url)
}

private func isSystemTemporaryDirectoryChild(_ url: URL) -> Bool {
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .standardizedFileURL
        .resolvingSymlinksInPath()
    let candidate = url.standardizedFileURL.resolvingSymlinksInPath()
    return candidate.path != temporaryDirectory.path
        && candidate.deletingLastPathComponent().path == temporaryDirectory.path
}

private func waitForStartGateIfRequested() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let gatePath = environment["VMEMO_TOKEN_STORE_CHILD_GATE"],
          let worker = environment["VMEMO_TOKEN_STORE_CHILD_WORKER"]
    else { return }
    let gate = URL(fileURLWithPath: gatePath, isDirectory: true)
    let ready = gate.appendingPathComponent("ready-\(worker)")
    guard FileManager.default.createFile(atPath: ready.path, contents: Data()) else {
        throw PersistentMutationTokenStoreError.ioFailure
    }
    let start = gate.appendingPathComponent("start")
    let deadline = Date().addingTimeInterval(PersistentMutationTokenStoreTests.externalHelperTimeout)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: start.path) { return }
        usleep(1_000)
    }
    throw PersistentMutationTokenStoreError.ioFailure
}
