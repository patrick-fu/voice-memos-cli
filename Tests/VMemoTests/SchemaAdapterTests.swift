import XCTest
@testable import VMemo

final class SchemaAdapterTests: XCTestCase {
    func testListReturnsOnlyActiveRecordingsFromSupportedSyntheticRevision() throws {
        let fixture = try SyntheticSchemaFixture.make(
            revision: .macOS15,
            records: [
                .init(id: "11111111-1111-1111-1111-111111111111", title: "First", isActive: 1),
                .init(id: "22222222-2222-2222-2222-222222222222", title: "Inactive", isActive: 0),
            ]
        )
        defer { try? fixture.cleanup() }
        let read: any RecordingReadPort = SchemaAdapter(snapshotURL: fixture.databaseURL)

        XCTAssertEqual(
            try read.list(),
            [RecordingSummary(id: RecordingID(value: "11111111-1111-1111-1111-111111111111"), title: "First")]
        )
    }

    func testSearchAndShowUseTitleOnlyAsSyntheticDisplaySearchData() throws {
        let fixture = try SyntheticSchemaFixture.make(
            revision: .macOS26,
            records: [
                .init(id: "11111111-1111-1111-1111-111111111111", title: "Duplicate", isActive: 1),
                .init(id: "22222222-2222-2222-2222-222222222222", title: "Duplicate", isActive: 1),
            ]
        )
        defer { try? fixture.cleanup() }
        let read: any RecordingReadPort = SchemaAdapter(snapshotURL: fixture.databaseURL)

        XCTAssertEqual(try read.search(query: "duplicate").map(\.id.value), [
            "11111111-1111-1111-1111-111111111111",
            "22222222-2222-2222-2222-222222222222",
        ])
        XCTAssertEqual(
            try read.show(id: RecordingID(value: "22222222-2222-2222-2222-222222222222")),
            RecordingSummary(id: RecordingID(value: "22222222-2222-2222-2222-222222222222"), title: "Duplicate")
        )
        XCTAssertThrowsError(try read.show(id: RecordingID(value: "Duplicate"))) { error in
            XCTAssertEqual(error as? SchemaAdapterError, .recordingNotFound)
        }
    }

    func testUnknownSyntheticRevisionFailsClosed() throws {
        let fixture = try SyntheticSchemaFixture.make(
            records: [.init(id: "11111111-1111-1111-1111-111111111111", title: "One", isActive: 1)],
            fault: .unknownToken
        )
        defer { try? fixture.cleanup() }

        XCTAssertThrowsError(try SchemaAdapter(snapshotURL: fixture.databaseURL).list()) { error in
            XCTAssertEqual(error as? SchemaAdapterError, .unsupportedSchema)
        }
    }

    func testMalformedSyntheticSchemasFailClosed() throws {
        for fault in [
            SyntheticSchemaFixture.Fault.missingRecordingTable,
            .missingActiveColumn,
            .wrongTitleType,
            .missingAssetPolicyColumn,
            .wrongAssetPolicyType,
            .invalidAssetPolicy,
            .missingGeneratorVersionColumn,
            .wrongGeneratorVersionType,
            .invalidGeneratorVersion,
            .multipleManifestRows,
            .invalidProvenance,
            .invalidTargetOSMajor,
            .overflowTargetOSMajor,
            .invalidFixtureRevision,
            .overflowFixtureRevision,
            .invalidSearchPolicy,
        ] {
            let fixture = try SyntheticSchemaFixture.make(
                records: [.init(id: "11111111-1111-1111-1111-111111111111", title: "One", isActive: 1)],
                fault: fault
            )
            defer { try? fixture.cleanup() }

            XCTAssertThrowsError(try SchemaAdapter(snapshotURL: fixture.databaseURL).list()) { error in
                XCTAssertEqual(error as? SchemaAdapterError, .unsupportedSchema)
            }
        }
    }

    func testMalformedSyntheticRecordingValuesFailClosed() throws {
        let cases: [[SyntheticSchemaFixture.Recording]] = [
            [.init(id: nil, title: "One", isActive: 1)],
            [.init(id: "", title: "One", isActive: 1)],
            [.init(id: "not-a-synthetic-uuid", title: "One", isActive: 1)],
            [.init(id: "11111111-1111-1111-1111-111111111111", title: nil, isActive: 1)],
            [.init(id: "11111111-1111-1111-1111-111111111111", title: "", isActive: 1)],
            [.init(id: "11111111-1111-1111-1111-111111111111", title: "One", isActive: nil)],
            [.init(id: "11111111-1111-1111-1111-111111111111", title: "One", isActive: 4_294_967_296)],
            [.init(id: "11111111-1111-1111-1111-111111111111", title: "One", isActive: 4_294_967_297)],
            [
                .init(id: "11111111-1111-1111-1111-111111111111", title: "One", isActive: 1),
                .init(id: "11111111-1111-1111-1111-111111111111", title: "Two", isActive: 1),
            ],
            [
                .init(id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", title: "One", isActive: 1),
                .init(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", title: "Two", isActive: 1),
            ],
        ]

        for records in cases {
            let fixture = try SyntheticSchemaFixture.make(records: records)
            defer { try? fixture.cleanup() }

            XCTAssertThrowsError(try SchemaAdapter(snapshotURL: fixture.databaseURL).list()) { error in
                XCTAssertEqual(error as? SchemaAdapterError, .unsupportedSchema)
            }
        }
    }
}
