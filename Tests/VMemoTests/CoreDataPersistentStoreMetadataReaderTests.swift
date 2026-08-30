import CoreData
import Foundation
import XCTest
@testable import VMemo

final class CoreDataPersistentStoreMetadataReaderTests: XCTestCase {
    func testReaderBridgesEmptySyntheticStoreMetadataAndLeavesSourceDirectoryUnchanged() throws {
        let fixture = try EmptyCoreDataStoreFixture.make()
        defer { try? fixture.cleanup() }
        let lease = try SQLiteSnapshotAdapter().makeSnapshot(
            source: fixture.storeURL,
            destinationRoot: fixture.snapshotRoot
        )
        defer { try? lease.cleanup() }
        let reader = CoreDataPersistentStoreMetadataReader(model: fixture.model)
        let before = try DirectoryAudit.capture(fixture.sourceRoot)

        let metadata = try reader.readMetadata(from: lease)
        let rawMetadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType,
            at: lease.url,
            options: [NSReadOnlyPersistentStoreOption: true]
        )

        XCTAssertEqual(try DirectoryAudit.capture(fixture.sourceRoot), before)
        XCTAssertTrue(metadata.isCompatibleWithRuntimeModel)
        guard case let .dictionary(actualHashes) = metadata.entityVersionHashes else {
            return XCTFail("Core Data metadata must bridge NSStoreModelVersionHashesKey as a dictionary.")
        }
        XCTAssertEqual(Set(actualHashes.keys), Set(fixture.model.entityVersionHashesByName.keys))
        for (entityName, expectedHash) in fixture.model.entityVersionHashesByName {
            guard case let .data(actualHash)? = actualHashes[entityName] else {
                return XCTFail("Expected Data for \(entityName).")
            }
            XCTAssertEqual(actualHash.count, 32)
            XCTAssertEqual(actualHash, expectedHash)
        }
        XCTAssertEqual(
            metadata.modelVersionChecksum,
            .string(try XCTUnwrap(rawMetadata["NSStoreModelVersionChecksumKey"] as? String))
        )
        XCTAssertEqual(
            metadata.modelVersionHashesDigest,
            .string(try XCTUnwrap(rawMetadata["NSStoreModelVersionHashesDigest"] as? String))
        )
        XCTAssertEqual(
            metadata.modelVersionHashesVersion,
            .integer(try integer(rawMetadata["NSStoreModelVersionHashesVersion"]))
        )
        XCTAssertEqual(
            metadata.persistenceFrameworkVersion,
            .integer(try integer(rawMetadata["NSPersistenceFrameworkVersion"]))
        )
        if rawMetadata.keys.contains("NSPersistenceMaximumFrameworkVersion") {
            XCTAssertEqual(
                metadata.persistenceMaximumFrameworkVersion,
                .integer(try integer(rawMetadata["NSPersistenceMaximumFrameworkVersion"]))
            )
        } else {
            XCTAssertEqual(metadata.persistenceMaximumFrameworkVersion, .unsupportedValue)
        }
        XCTAssertEqual(metadata.storeType, .string(try XCTUnwrap(rawMetadata[NSStoreTypeKey] as? String)))
        XCTAssertEqual(
            metadata.modelVersionIdentifiers,
            .array(try XCTUnwrap(rawMetadata[NSStoreModelVersionIdentifiersKey] as? [String]))
        )
    }

    func testReaderCopiesModelBeforeCallerMutatesIt() throws {
        let fixture = try EmptyCoreDataStoreFixture.make()
        defer { try? fixture.cleanup() }
        let lease = try SQLiteSnapshotAdapter().makeSnapshot(
            source: fixture.storeURL,
            destinationRoot: fixture.snapshotRoot
        )
        defer { try? lease.cleanup() }
        let callerOwnedModel = fixture.model.mutableCopy() as! NSManagedObjectModel
        let reader = CoreDataPersistentStoreMetadataReader(model: callerOwnedModel)
        callerOwnedModel.entities.append(EmptyCoreDataStoreFixture.entity(named: "CallerAddedEntity"))

        let metadata = try reader.readMetadata(from: lease)

        XCTAssertTrue(metadata.isCompatibleWithRuntimeModel)
    }

    func testIntegerValueAcceptsOnlyExactIntegerCFNumbers() {
        XCTAssertEqual(CoreDataPersistentStoreMetadataReader.integerValue(true), .unsupportedValue)
        XCTAssertEqual(CoreDataPersistentStoreMetadataReader.integerValue(false), .unsupportedValue)
        XCTAssertEqual(CoreDataPersistentStoreMetadataReader.integerValue(NSNumber(value: true)), .unsupportedValue)
        XCTAssertEqual(CoreDataPersistentStoreMetadataReader.integerValue(NSNumber(value: Double(3.0))), .unsupportedValue)
        XCTAssertEqual(CoreDataPersistentStoreMetadataReader.integerValue(NSNumber(value: Float(3.0))), .unsupportedValue)
        XCTAssertEqual(CoreDataPersistentStoreMetadataReader.integerValue(NSNumber(value: 3)), .integer(3))
        XCTAssertEqual(CoreDataPersistentStoreMetadataReader.integerValue(NSNumber(value: -7)), .integer(-7))
        XCTAssertEqual(CoreDataPersistentStoreMetadataReader.integerValue(NSNumber(value: Int.max)), .integer(Int.max))
        XCTAssertEqual(
            CoreDataPersistentStoreMetadataReader.integerValue(NSNumber(value: UInt64(Int.max) + 1)),
            .unsupportedValue
        )
    }

    private func integer(_ value: Any?) throws -> Int {
        let number = try XCTUnwrap(value as? NSNumber)
        XCTAssertEqual(CFGetTypeID(number), CFNumberGetTypeID())
        XCTAssertFalse(CFNumberIsFloatType(number))
        var int64: Int64 = 0
        XCTAssertTrue(CFNumberGetValue(number, .sInt64Type, &int64))
        return try XCTUnwrap(Int(exactly: int64))
    }
}

private struct EmptyCoreDataStoreFixture {
    let root: URL
    let sourceRoot: URL
    let snapshotRoot: URL
    let storeURL: URL
    let model: NSManagedObjectModel

    static func make() throws -> EmptyCoreDataStoreFixture {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("vmemo-coredata-metadata-\(UUID().uuidString)", isDirectory: true)
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        let snapshotRoot = root.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: snapshotRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let storeURL = sourceRoot.appendingPathComponent("synthetic-empty.sqlite")
        let model = NSManagedObjectModel()
        model.entities = [entity(named: "SyntheticMetadataOnly")]
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let store = try coordinator.addPersistentStore(
            ofType: NSSQLiteStoreType,
            configurationName: nil,
            at: storeURL,
            options: [NSSQLitePragmasOption: ["journal_mode": "DELETE"]]
        )
        try coordinator.remove(store)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
        return EmptyCoreDataStoreFixture(
            root: root,
            sourceRoot: sourceRoot,
            snapshotRoot: snapshotRoot,
            storeURL: storeURL,
            model: model
        )
    }

    static func entity(named name: String) -> NSEntityDescription {
        let identifier = NSAttributeDescription()
        identifier.name = "identifier"
        identifier.attributeType = .stringAttributeType
        identifier.isOptional = true
        let entity = NSEntityDescription()
        entity.name = name
        entity.managedObjectClassName = "NSManagedObject"
        entity.properties = [identifier]
        return entity
    }

    func cleanup() throws {
        try FileManager.default.removeItem(at: root)
    }
}

private struct DirectoryAudit: Equatable {
    struct Entry: Equatable {
        let name: String
        let fileSize: UInt64
        let modificationDate: Date
    }

    let entries: [Entry]

    static func capture(_ directory: URL) throws -> DirectoryAudit {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        return DirectoryAudit(entries: try names.map { name in
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
            return Entry(
                name: name,
                fileSize: try XCTUnwrap(attributes[.size] as? UInt64),
                modificationDate: try XCTUnwrap(attributes[.modificationDate] as? Date)
            )
        })
    }
}
