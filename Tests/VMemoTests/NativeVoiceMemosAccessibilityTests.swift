import Foundation
import XCTest
@testable import VMemo

final class NativeVoiceMemosAccessibilityTests: XCTestCase {
    func testLiveDriverRecognizesValidZhHansAllRecordingsTreeThroughNativeRuntime() throws {
        let runtime = FakeVoiceMemosAXRuntime()
        let driver = SystemVoiceMemosAXDriver(runtime: runtime)

        let snapshot = try driver.snapshot()

        XCTAssertEqual(snapshot, VoiceMemosAXSnapshot(
            trusted: true,
            application: VoiceMemosAXApplication(
                bundleIdentifier: "com.apple.VoiceMemos",
                bundleBuild: "1380"
            ),
            windowCount: 1,
            isMainWindowPresent: true,
            localeIdentifier: "zh-Hans",
            isUITreeSupported: true,
            selectedSidebar: .allRecordings,
            isModalPresent: false,
            isPopoverPresent: false,
            searchText: "",
            focusedElement: .recordingsList,
            rowsFullyRealized: true,
            rows: [
                VoiceMemosAXRow(
                    title: "Commit sink",
                    isVisible: true,
                    hasNativeDeleteAction: true,
                    hasRestoreAction: false
                ),
                VoiceMemosAXRow(
                    title: "Old exact title",
                    isVisible: true,
                    hasNativeDeleteAction: true,
                    hasRestoreAction: false
                ),
            ],
            detailTitle: "Old exact title",
            isDetailTitleSettable: true
        ))
    }

    func testLiveDriverPerformsExactTypedActionsThroughNativeRuntime() throws {
        let runtime = FakeVoiceMemosAXRuntime()
        let driver = SystemVoiceMemosAXDriver(runtime: runtime)
        let rename = VoiceMemosAccessibilityMutation.rename(
            oldTitle: "Old exact title",
            newTitle: "New exact title",
            commitSinkTitle: "Commit sink"
        )
        let renameAccessibility = NativeVoiceMemosAccessibility(driver: driver)

        _ = try renameAccessibility.verify(rename)
        try renameAccessibility.rename(rename)
        try renameAccessibility.verifyPostcondition(rename)

        XCTAssertEqual(runtime.recordedActions().map(\.action), ["AXPress", "AXPress"])
        XCTAssertEqual(runtime.recordedActions().map(\.elementID), ["target-row", "commit-row"])
        XCTAssertEqual(try driver.snapshot().rows.map(\.title), [
            "Commit sink",
            "New exact title",
        ])

        let deleteRuntime = FakeVoiceMemosAXRuntime()
        let deleteDriver = SystemVoiceMemosAXDriver(runtime: deleteRuntime)
        let delete = VoiceMemosAccessibilityMutation.delete(oldTitle: "Old exact title")
        let deleteAccessibility = NativeVoiceMemosAccessibility(driver: deleteDriver)

        _ = try deleteAccessibility.verify(delete)
        try deleteAccessibility.delete(delete)
        try deleteAccessibility.verifyPostcondition(delete)

        XCTAssertEqual(deleteRuntime.recordedActions().map(\.action), ["删除", "AXPress"])
        XCTAssertEqual(deleteRuntime.recordedActions().map(\.elementID), ["target-row", "recent"])
        XCTAssertEqual(try deleteDriver.snapshot().selectedSidebar, .recentlyDeleted)
        XCTAssertEqual(try deleteDriver.snapshot().rows, [
            VoiceMemosAXRow(
                title: "Old exact title",
                isVisible: true,
                hasNativeDeleteAction: false,
                hasRestoreAction: true
            ),
        ])
    }

    func testLiveDriverRejectsUnsafeApplicationTreeActionsAndFocusBeforeTypedMutation() throws {
        let failures: [(String, (FakeVoiceMemosAXRuntime) -> Void, VoiceMemosAccessibilityError)] = [
            ("untrusted", { $0.setTrusted(false) }, .untrusted),
            ("wrong build", { $0.setBundleBuild("1381") },
             .unsupportedApplication(bundleIdentifier: "com.apple.VoiceMemos", bundleBuild: "1381")),
            ("unknown sidebar", { runtime in
                runtime.mutateNode("all") { $0.label = "All Recordings" }
            }, .uiTreeUnsupported),
            ("duplicate semantic sidebar", { runtime in
                runtime.addChild("sidebar", id: "all-duplicate") {
                    $0.role = "AXButton"
                    $0.label = "所有录音"
                    $0.actions = ["AXPress"]
                }
            }, .uiTreeUnsupported),
            ("unknown row action", { runtime in
                runtime.mutateNode("target-row") { $0.actions = ["AXPress", "未知操作"] }
            }, .uiTreeUnsupported),
            ("virtualized row shape", { runtime in
                runtime.mutateNode("target-row") { $0.descriptionText = nil }
            }, .uiTreeUnsupported),
            ("detail not settable", { runtime in
                runtime.mutateNode("title-field") { $0.isSettable = false }
            }, .detailTitleNotSettable),
            ("permanent action visible", { runtime in
                runtime.mutateNode("target-row") { $0.actions = ["AXPress", "永久删除"] }
            }, .uiTreeUnsupported),
        ]

        for (name, arrange, expectedError) in failures {
            let runtime = FakeVoiceMemosAXRuntime()
            let driver = SystemVoiceMemosAXDriver(runtime: runtime)
            arrange(runtime)

            XCTAssertThrowsError(try driver.snapshot()) { error in
                XCTAssertEqual(error as? VoiceMemosAccessibilityError, expectedError, name)
            }
            XCTAssertTrue(runtime.recordedActions().isEmpty, name)
        }
    }

    func testLiveDriverSurfacesUnsafeShellStateAndVirtualizationForSemanticPreflight() throws {
        let modalRuntime = FakeVoiceMemosAXRuntime()
        modalRuntime.addChild("window", id: "sheet") { $0.role = "AXSheet" }
        let modalSnapshot = try SystemVoiceMemosAXDriver(runtime: modalRuntime).snapshot()
        XCTAssertTrue(modalSnapshot.isModalPresent)

        let popoverRuntime = FakeVoiceMemosAXRuntime()
        popoverRuntime.addChild("window", id: "popover") { $0.subrole = "AXPopover" }
        let popoverSnapshot = try SystemVoiceMemosAXDriver(runtime: popoverRuntime).snapshot()
        XCTAssertTrue(popoverSnapshot.isPopoverPresent)

        let searchRuntime = FakeVoiceMemosAXRuntime()
        searchRuntime.mutateNode("search") { $0.value = "Old" }
        let searchSnapshot = try SystemVoiceMemosAXDriver(runtime: searchRuntime).snapshot()
        XCTAssertEqual(searchSnapshot.searchText, "Old")

        let focusRuntime = FakeVoiceMemosAXRuntime()
        focusRuntime.setFocusedElementID("search")
        let focusSnapshot = try SystemVoiceMemosAXDriver(runtime: focusRuntime).snapshot()
        XCTAssertEqual(focusSnapshot.focusedElement, .other("AXTextField"))

        let virtualizedRuntime = FakeVoiceMemosAXRuntime()
        virtualizedRuntime.setRowsFullyRealized(false)
        let virtualizedSnapshot = try SystemVoiceMemosAXDriver(
            runtime: virtualizedRuntime
        ).snapshot()
        XCTAssertFalse(virtualizedSnapshot.rowsFullyRealized)
        XCTAssertThrowsError(
            try NativeVoiceMemosAccessibility(
                driver: SystemVoiceMemosAXDriver(runtime: virtualizedRuntime)
            ).verify(.delete(oldTitle: "Old exact title"))
        ) { error in
            XCTAssertEqual(error as? VoiceMemosAccessibilityError, .virtualizedAmbiguity)
        }
    }

    func testLiveDriverRecentlyDeletedRequiresRestoreActionAndRejectsDeleteAction() throws {
        let runtime = FakeVoiceMemosAXRuntime()
        runtime.pressSidebar(.recentlyDeleted)
        let driver = SystemVoiceMemosAXDriver(runtime: runtime)

        let snapshot = try driver.snapshot()

        XCTAssertEqual(snapshot.selectedSidebar, .recentlyDeleted)
        XCTAssertEqual(snapshot.rows.map(\.hasRestoreAction), [true])
        XCTAssertThrowsError(
            try driver.perform(.activateDelete(scope: .allRecordings, title: "Old exact title"))
        ) { error in
            XCTAssertEqual(
                error as? VoiceMemosAccessibilityError,
                .allRecordingsRequired(selected: .recentlyDeleted)
            )
        }
        XCTAssertTrue(runtime.recordedActions().isEmpty)
    }

    func testRenameSelectsExactTargetSetsExactTitleThenSelectsDistinctCommitSink() throws {
        let driver = TypedVoiceMemosAXDriver(snapshot: .readyForRename)
        let accessibility = NativeVoiceMemosAccessibility(driver: driver)
        let mutation = VoiceMemosAccessibilityMutation.rename(
            oldTitle: "Old exact title",
            newTitle: "New exact title",
            commitSinkTitle: "Commit sink"
        )

        _ = try accessibility.verify(mutation)
        try accessibility.rename(mutation)
        try accessibility.verifyPostcondition(mutation)

        XCTAssertEqual(driver.recordedActions(), [
            .refresh,
            .refresh,
            .selectRecording(scope: .allRecordings, title: "Old exact title"),
            .refresh,
            .setDetailTitle("New exact title"),
            .selectRecording(scope: .allRecordings, title: "Commit sink"),
            .refresh,
        ])
        XCTAssertEqual(driver.currentSnapshot.rows.map(\.title), ["Commit sink", "New exact title", "Unchanged recording"])
    }

    func testTitleIdentityUsesExactUTF8BytesRatherThanUnicodeCanonicalEquivalence() {
        let nfc = "Café"
        let nfd = "Cafe\u{301}"
        let nfcRename = VoiceMemosAccessibilityMutation.rename(
            oldTitle: nfc,
            newTitle: "New exact title",
            commitSinkTitle: "Commit sink"
        )
        let nfdRename = VoiceMemosAccessibilityMutation.rename(
            oldTitle: nfd,
            newTitle: "New exact title",
            commitSinkTitle: "Commit sink"
        )
        let nfcRow = VoiceMemosAXRow(
            title: nfc,
            isVisible: true,
            hasNativeDeleteAction: true,
            hasRestoreAction: false
        )
        let nfdRow = VoiceMemosAXRow(
            title: nfd,
            isVisible: true,
            hasNativeDeleteAction: true,
            hasRestoreAction: false
        )

        XCTAssertNotEqual(nfcRename, nfdRename)
        XCTAssertNotEqual(Set([nfcRename, nfdRename]).count, 1)
        XCTAssertNotEqual(nfcRow, nfdRow)
    }

    func testRenamePreflightAndMutationKeyUseExactUTF8TitleBytes() throws {
        let nfc = "Café"
        let nfd = "Cafe\u{301}"
        let mutation = VoiceMemosAccessibilityMutation.rename(
            oldTitle: nfd,
            newTitle: "New exact title",
            commitSinkTitle: "Commit sink"
        )
        let canonicalSnapshot = snapshot { snapshot in
            snapshot.rows[1].title = nfd
            snapshot.detailTitle = nfc
        }
        let driver = TypedVoiceMemosAXDriver(snapshot: canonicalSnapshot)
        let accessibility = NativeVoiceMemosAccessibility(driver: driver)

        XCTAssertThrowsError(try accessibility.verify(mutation)) { error in
            XCTAssertEqual(
                error as? VoiceMemosAccessibilityError,
                .detailTitleMismatch(expected: nfd, actual: nfc)
            )
        }

        let nfcMutation = VoiceMemosAccessibilityMutation.rename(
            oldTitle: nfc,
            newTitle: "New exact title",
            commitSinkTitle: "Commit sink"
        )
        let keyDriver = TypedVoiceMemosAXDriver(snapshot: snapshot { snapshot in
            snapshot.rows[1].title = nfd
            snapshot.detailTitle = nfd
        })
        let keyAccessibility = NativeVoiceMemosAccessibility(driver: keyDriver)
        _ = try keyAccessibility.verify(mutation)

        XCTAssertThrowsError(try keyAccessibility.verifyPostcondition(nfcMutation)) { error in
            XCTAssertEqual(error as? VoiceMemosAccessibilityError, .postconditionUnavailable)
        }
    }

    func testRenameAllowsCanonicallyEquivalentButUTF8DistinctCommitSink() throws {
        let nfc = "Café"
        let nfd = "Cafe\u{301}"
        let driver = TypedVoiceMemosAXDriver(snapshot: snapshot { snapshot in
            snapshot.rows[0].title = nfd
            snapshot.rows[1].title = nfc
            snapshot.detailTitle = nfc
        })
        let mutation = VoiceMemosAccessibilityMutation.rename(
            oldTitle: nfc,
            newTitle: "New exact title",
            commitSinkTitle: nfd
        )

        XCTAssertNoThrow(try NativeVoiceMemosAccessibility(driver: driver).verify(mutation))
    }

    func testPreflightRejectsUnsafeUIShellBeforeAnyMutationAction() throws {
        let failures: [(String, (inout VoiceMemosAXSnapshot) -> Void, VoiceMemosAccessibilityError)] = [
            ("untrusted", { $0.trusted = false }, .untrusted),
            ("app missing", { $0.application = nil }, .appMissing),
            ("wrong bundle", { $0.application = VoiceMemosAXApplication(bundleIdentifier: "com.example", bundleBuild: "1380") },
             .unsupportedApplication(bundleIdentifier: "com.example", bundleBuild: "1380")),
            ("wrong build", { $0.application = VoiceMemosAXApplication(bundleIdentifier: "com.apple.VoiceMemos", bundleBuild: "1381") },
             .unsupportedApplication(bundleIdentifier: "com.apple.VoiceMemos", bundleBuild: "1381")),
            ("no window", { $0.windowCount = 0 }, .windowMissing),
            ("multiple windows", { $0.windowCount = 2 }, .ambiguousMainWindow),
            ("no main window", { $0.isMainWindowPresent = false }, .windowMissing),
            ("unsupported locale", { $0.localeIdentifier = "en-US" }, .unsupportedLocale("en-US")),
            ("unsupported tree", { $0.isUITreeSupported = false }, .uiTreeUnsupported),
            ("Recently Deleted selected", { $0.selectedSidebar = .recentlyDeleted },
             .allRecordingsRequired(selected: .recentlyDeleted)),
            ("sidebar unknown", { $0.selectedSidebar = nil }, .allRecordingsRequired(selected: nil)),
            ("modal", { $0.isModalPresent = true }, .modalPresent),
            ("popover", { $0.isPopoverPresent = true }, .popoverPresent),
            ("search", { $0.searchText = "Old" }, .searchActive("Old")),
            ("focus drift", { $0.focusedElement = .other("sidebar") }, .focusDrift(.other("sidebar"))),
            ("virtualized rows", { $0.rowsFullyRealized = false }, .virtualizedAmbiguity),
        ]

        for (name, mutate, expectedError) in failures {
            let driver = TypedVoiceMemosAXDriver(snapshot: snapshot(mutate))
            let accessibility = NativeVoiceMemosAccessibility(driver: driver)

            XCTAssertThrowsError(
                try accessibility.verify(.rename(oldTitle: "Old exact title", newTitle: "New exact title", commitSinkTitle: "Commit sink"))
            ) { error in
                XCTAssertEqual(error as? VoiceMemosAccessibilityError, expectedError, name)
            }
            XCTAssertEqual(driver.recordedActions(), [.refresh], name)
        }
    }

    func testRenamePreflightRequiresExactUniqueTargetNewTitleDetailAndDistinctSink() throws {
        let failures: [(String, (inout VoiceMemosAXSnapshot) -> Void, VoiceMemosAccessibilityError)] = [
            ("duplicate old title", { snapshot in
                snapshot.rows.append(VoiceMemosAXRow(title: "Old exact title", isVisible: true, hasNativeDeleteAction: true, hasRestoreAction: false))
            }, .ambiguousTarget(title: "Old exact title")),
            ("old title missing", { snapshot in
                snapshot.rows[1].title = "Different exact title"
                snapshot.detailTitle = "Different exact title"
            }, .targetMissing(title: "Old exact title")),
            ("old title hidden", { $0.rows[1].isVisible = false }, .targetNotVisible(title: "Old exact title")),
            ("new title already active", { snapshot in
                snapshot.rows[2] = VoiceMemosAXRow(title: "New exact title", isVisible: true, hasNativeDeleteAction: true, hasRestoreAction: false)
            }, .newTitleConflict(title: "New exact title")),
            ("detail title mismatch", { $0.detailTitle = "Different exact title" },
             .detailTitleMismatch(expected: "Old exact title", actual: "Different exact title")),
            ("detail title read-only", { $0.isDetailTitleSettable = false }, .detailTitleNotSettable),
            ("commit sink missing", { $0.rows.remove(at: 0) }, .commitSinkMissing(title: "Commit sink")),
            ("commit sink hidden", { $0.rows[0].isVisible = false }, .targetNotVisible(title: "Commit sink")),
            ("duplicate commit sink", { snapshot in
                snapshot.rows.append(VoiceMemosAXRow(title: "Commit sink", isVisible: true, hasNativeDeleteAction: true, hasRestoreAction: false))
            }, .ambiguousTarget(title: "Commit sink")),
        ]

        for (name, mutate, expectedError) in failures {
            let driver = TypedVoiceMemosAXDriver(snapshot: snapshot(mutate))
            let accessibility = NativeVoiceMemosAccessibility(driver: driver)
            let mutation = VoiceMemosAccessibilityMutation.rename(
                oldTitle: "Old exact title",
                newTitle: "New exact title",
                commitSinkTitle: "Commit sink"
            )

            XCTAssertThrowsError(try accessibility.verify(mutation)) { error in
                XCTAssertEqual(error as? VoiceMemosAccessibilityError, expectedError, name)
            }
            XCTAssertEqual(driver.recordedActions(), [.refresh], name)
        }
    }

    func testDeletePreflightRequiresExactUniqueActiveRowWithNativeDeleteAction() throws {
        let failures: [(String, (inout VoiceMemosAXSnapshot) -> Void, VoiceMemosAccessibilityError)] = [
            ("duplicate target", { snapshot in
                snapshot.rows.append(VoiceMemosAXRow(title: "Old exact title", isVisible: true, hasNativeDeleteAction: true, hasRestoreAction: false))
            }, .ambiguousTarget(title: "Old exact title")),
            ("target missing", { $0.rows.remove(at: 1) }, .targetMissing(title: "Old exact title")),
            ("target hidden", { $0.rows[1].isVisible = false }, .targetNotVisible(title: "Old exact title")),
            ("native delete missing", { $0.rows[1].hasNativeDeleteAction = false },
             .deleteActionMissing(title: "Old exact title")),
        ]

        for (name, mutate, expectedError) in failures {
            let driver = TypedVoiceMemosAXDriver(snapshot: snapshot { snapshot in
                snapshot.detailTitle = nil
                mutate(&snapshot)
            })
            let accessibility = NativeVoiceMemosAccessibility(driver: driver)

            XCTAssertThrowsError(
                try accessibility.verify(.delete(oldTitle: "Old exact title"))
            ) { error in
                XCTAssertEqual(error as? VoiceMemosAccessibilityError, expectedError, name)
            }
            XCTAssertEqual(driver.recordedActions(), [.refresh], name)
        }
    }

    func testRenameRefreshesSelectedTargetBeforeSettingTitleAndNeverWritesAfterWrongSelection() throws {
        let driver = TypedVoiceMemosAXDriver(snapshot: .readyForRename)
        driver.setSelectResultSnapshot(snapshot { $0.detailTitle = "Commit sink" })
        let accessibility = NativeVoiceMemosAccessibility(driver: driver)
        let mutation = VoiceMemosAccessibilityMutation.rename(
            oldTitle: "Old exact title",
            newTitle: "New exact title",
            commitSinkTitle: "Commit sink"
        )

        _ = try accessibility.verify(mutation)

        XCTAssertThrowsError(try accessibility.rename(mutation)) { error in
            XCTAssertEqual(
                error as? VoiceMemosAccessibilityError,
                .detailTitleMismatch(expected: "Old exact title", actual: "Commit sink")
            )
        }
        XCTAssertEqual(driver.recordedActions(), [
            .refresh,
            .refresh,
            .selectRecording(scope: .allRecordings, title: "Old exact title"),
            .refresh,
        ])
        XCTAssertEqual(driver.currentSnapshot.rows.map(\.title), [
            "Commit sink",
            "Old exact title",
            "Unchanged recording",
        ])
    }

    func testDeleteProvesAllAbsenceThenSwitchesToRecentlyDeletedForFreshRestoreProof() throws {
        let driver = TypedVoiceMemosAXDriver(snapshot: snapshot { $0.detailTitle = nil })
        let accessibility = NativeVoiceMemosAccessibility(driver: driver)
        let mutation = VoiceMemosAccessibilityMutation.delete(oldTitle: "Old exact title")

        _ = try accessibility.verify(mutation)
        try accessibility.delete(mutation)
        driver.setRecentlyDeletedSnapshot(.readyForRecentlyDeleted)
        try accessibility.verifyPostcondition(mutation)

        XCTAssertEqual(driver.recordedActions(), [
            .refresh,
            .refresh,
            .activateDelete(scope: .allRecordings, title: "Old exact title"),
            .refresh,
            .selectSidebar(scope: .recentlyDeleted),
            .refresh,
        ])
        XCTAssertEqual(driver.currentSnapshot.selectedSidebar, .recentlyDeleted)
        XCTAssertEqual(driver.currentSnapshot.rows.map(\.title), ["Already deleted", "Old exact title"])
        XCTAssertEqual(driver.currentSnapshot.rows.last?.hasRestoreAction, true)
    }

    func testDeletePostconditionUsesSeparateAllAndRecentlyDeletedFreshSnapshots() throws {
        let failures: [(String, VoiceMemosAXSnapshot, VoiceMemosAXSnapshot, VoiceMemosAccessibilityError)] = [
            ("target remains active", snapshot(), .readyForRecentlyDeleted,
             .postconditionFailed("old title remains in All Recordings")),
            ("other active row changed", snapshot {
                $0.rows.remove(at: 1)
                $0.rows[1].title = "Changed recording"
            }, .readyForRecentlyDeleted,
             .postconditionFailed("other All Recordings rows changed")),
            ("Recent not selected", snapshot { $0.rows.remove(at: 1) }, recentSnapshot { $0.selectedSidebar = .allRecordings },
             .recentlyDeletedRequired),
            ("Recent virtualized", snapshot { $0.rows.remove(at: 1) }, recentSnapshot { $0.rowsFullyRealized = false },
             .virtualizedAmbiguity),
            ("target missing from Recent", snapshot { $0.rows.remove(at: 1) }, recentSnapshot { $0.rows.removeLast() },
             .targetMissing(title: "Old exact title")),
            ("target duplicated in Recent", snapshot { $0.rows.remove(at: 1) }, recentSnapshot {
                $0.rows.append($0.rows.last!)
            }, .ambiguousTarget(title: "Old exact title")),
            ("target hidden in Recent", snapshot { $0.rows.remove(at: 1) }, recentSnapshot { $0.rows[1].isVisible = false },
             .targetNotVisible(title: "Old exact title")),
            ("target not restorable", snapshot { $0.rows.remove(at: 1) }, recentSnapshot { $0.rows[1].hasRestoreAction = false },
             .postconditionFailed("deleted row is not restorable")),
        ]

        for (name, allSnapshot, recentSnapshot, expectedError) in failures {
            let driver = TypedVoiceMemosAXDriver(snapshot: snapshot { $0.detailTitle = nil })
            let accessibility = NativeVoiceMemosAccessibility(driver: driver)
            let mutation = VoiceMemosAccessibilityMutation.delete(oldTitle: "Old exact title")
            _ = try accessibility.verify(mutation)
            try accessibility.delete(mutation)
            driver.setPostViewSnapshots(all: allSnapshot, recent: recentSnapshot)

            XCTAssertThrowsError(try accessibility.verifyPostcondition(mutation)) { error in
                XCTAssertEqual(error as? VoiceMemosAccessibilityError, expectedError, name)
            }
            let expectedOtherRows = snapshot { $0.rows.remove(at: 1) }.rows
            let expectedTail: [VoiceMemosAXAction] = allSnapshot.rows != expectedOtherRows
                ? [.refresh]
                : [.refresh, .selectSidebar(scope: .recentlyDeleted), .refresh]
            XCTAssertEqual(Array(driver.recordedActions().dropFirst(3)), expectedTail, name)
        }
    }

    func testRenameRejectsCommitSinkMatchingOldOrNewTitle() throws {
        let driver = TypedVoiceMemosAXDriver(snapshot: .readyForRename)
        let accessibility = NativeVoiceMemosAccessibility(driver: driver)

        XCTAssertThrowsError(
            try accessibility.verify(.rename(
                oldTitle: "Old exact title",
                newTitle: "New exact title",
                commitSinkTitle: "Old exact title"
            ))
        ) { error in
            XCTAssertEqual(
                error as? VoiceMemosAccessibilityError,
                .invalidCommitSink(title: "Old exact title")
            )
        }
        XCTAssertThrowsError(
            try accessibility.verify(.rename(
                oldTitle: "Old exact title",
                newTitle: "New exact title",
                commitSinkTitle: "New exact title"
            ))
        ) { error in
            XCTAssertEqual(
                error as? VoiceMemosAccessibilityError,
                .invalidCommitSink(title: "New exact title")
            )
        }
        XCTAssertEqual(driver.recordedActions(), [.refresh, .refresh])
    }

    func testRenamePostconditionRequiresFreshUniqueNewTitleOldAbsenceAndUnchangedOtherRows() throws {
        let failures: [(String, (inout VoiceMemosAXSnapshot) -> Void, VoiceMemosAccessibilityError)] = [
            ("old title remains", { snapshot in
                snapshot.rows[1].title = "New exact title"
                snapshot.rows.append(VoiceMemosAXRow(title: "Old exact title", isVisible: true, hasNativeDeleteAction: true, hasRestoreAction: false))
            }, .postconditionFailed("old title remains in All Recordings")),
            ("new title missing", { snapshot in
                snapshot.rows[1].title = "Missing new title"
            }, .targetMissing(title: "New exact title")),
            ("new title duplicated", { snapshot in
                snapshot.rows[1].title = "New exact title"
                snapshot.rows.append(VoiceMemosAXRow(title: "New exact title", isVisible: true, hasNativeDeleteAction: true, hasRestoreAction: false))
            }, .ambiguousTarget(title: "New exact title")),
            ("commit sink changed", { snapshot in
                snapshot.rows[1].title = "New exact title"
                let index = snapshot.rows.firstIndex { $0.title == "Commit sink" }!
                snapshot.rows[index].hasNativeDeleteAction = false
            }, .postconditionFailed("commit sink changed")),
            ("other recording changed", { snapshot in
                snapshot.rows[1].title = "New exact title"
                snapshot.rows[2].title = "Changed recording"
            }, .postconditionFailed("All Recordings rows other than the target changed")),
        ]

        for (name, mutate, expectedError) in failures {
            let driver = TypedVoiceMemosAXDriver(snapshot: .readyForRename)
            let accessibility = NativeVoiceMemosAccessibility(driver: driver)
            let mutation = VoiceMemosAccessibilityMutation.rename(
                oldTitle: "Old exact title",
                newTitle: "New exact title",
                commitSinkTitle: "Commit sink"
            )
            _ = try accessibility.verify(mutation)
            try accessibility.rename(mutation)
            driver.setPostRefreshSnapshot(snapshot(mutate))

            XCTAssertThrowsError(try accessibility.verifyPostcondition(mutation)) { error in
                XCTAssertEqual(error as? VoiceMemosAccessibilityError, expectedError, name)
            }
            XCTAssertEqual(driver.recordedActions().dropFirst(2).dropLast(), [
                .selectRecording(scope: .allRecordings, title: "Old exact title"),
                .refresh,
                .setDetailTitle("New exact title"),
                .selectRecording(scope: .allRecordings, title: "Commit sink"),
            ], name)
        }
    }

    func testDriverTimeoutAndUnknownActionFailClosedBeforeLaterMutationActions() throws {
        let timeoutDriver = TypedVoiceMemosAXDriver(snapshot: .readyForRename)
        timeoutDriver.setFailingAction(.setDetailTitle("New exact title"))
        let timeoutAccessibility = NativeVoiceMemosAccessibility(driver: timeoutDriver)
        let rename = VoiceMemosAccessibilityMutation.rename(
            oldTitle: "Old exact title",
            newTitle: "New exact title",
            commitSinkTitle: "Commit sink"
        )
        _ = try timeoutAccessibility.verify(rename)

        XCTAssertThrowsError(try timeoutAccessibility.rename(rename)) { error in
            XCTAssertEqual(error as? VoiceMemosAccessibilityError, .timeout)
        }
        XCTAssertEqual(timeoutDriver.recordedActions(), [
            .refresh,
            .refresh,
            .selectRecording(scope: .allRecordings, title: "Old exact title"),
            .refresh,
            .setDetailTitle("New exact title"),
        ])

        let unknownDriver = TypedVoiceMemosAXDriver(snapshot: snapshot { $0.detailTitle = nil })
        let unknownAccessibility = NativeVoiceMemosAccessibility(driver: unknownDriver)
        let delete = VoiceMemosAccessibilityMutation.delete(oldTitle: "Old exact title")
        _ = try unknownAccessibility.verify(delete)
        unknownDriver.setUnknownActionName("unrecognized native action")

        XCTAssertThrowsError(try unknownAccessibility.delete(delete)) { error in
            XCTAssertEqual(error as? VoiceMemosAccessibilityError, .unknownAction("unrecognized native action"))
        }
        XCTAssertEqual(unknownDriver.recordedActions(), [.refresh, .refresh])
    }

    func testLiveDriverTreatsNFCAndNFDTitlesAsDistinctExactRows() throws {
        let nfc = "Café"
        let nfd = "Cafe\u{301}"
        let runtime = FakeVoiceMemosAXRuntime()
        runtime.mutateNode("commit-row") {
            $0.descriptionText = "\(nfc) · 2026-08-29 20:00"
        }
        runtime.mutateNode("target-row") {
            $0.descriptionText = "\(nfd) · 2026-08-29 20:01"
        }
        runtime.mutateNode("title-field") { $0.value = nfd }
        let driver = SystemVoiceMemosAXDriver(runtime: runtime)

        let snapshot = try driver.snapshot()
        XCTAssertEqual(snapshot.rows.map { Array($0.title.utf8) }, [
            Array(nfc.utf8),
            Array(nfd.utf8),
        ])
        XCTAssertNotEqual(snapshot.rows[0], snapshot.rows[1])

        try driver.perform(.selectRecording(scope: .allRecordings, title: nfd))
        XCTAssertEqual(runtime.recordedActions().map(\.elementID), ["target-row"])
        XCTAssertThrowsError(
            try driver.perform(.selectRecording(scope: .allRecordings, title: "Cafe"))
        ) { error in
            XCTAssertEqual(
                error as? VoiceMemosAccessibilityError,
                .targetMissing(title: "Cafe")
            )
        }
    }

    func testLiveDriverNeverUsesRowValueAsTitleAndFailsClosedOnAmbiguousDescription() throws {
        let emptyTitleRuntime = FakeVoiceMemosAXRuntime()
        emptyTitleRuntime.mutateNode("target-row") {
            $0.descriptionText = " · 2026-08-29 20:01"
            $0.value = "Old exact title"
        }
        XCTAssertThrowsError(
            try SystemVoiceMemosAXDriver(runtime: emptyTitleRuntime).snapshot()
        ) { error in
            XCTAssertEqual(error as? VoiceMemosAccessibilityError, .uiTreeUnsupported)
        }
        XCTAssertTrue(emptyTitleRuntime.recordedActions().isEmpty)

        let ambiguousRuntime = FakeVoiceMemosAXRuntime()
        ambiguousRuntime.mutateNode("target-row") {
            $0.descriptionText = "Old · exact title · 2026-08-29 20:01"
            $0.value = "Old exact title"
        }
        XCTAssertThrowsError(
            try SystemVoiceMemosAXDriver(runtime: ambiguousRuntime).snapshot()
        ) { error in
            XCTAssertEqual(error as? VoiceMemosAccessibilityError, .uiTreeUnsupported)
        }
        XCTAssertTrue(ambiguousRuntime.recordedActions().isEmpty)
    }

    func testLiveDriverRejectsDeleteWhenFreshScopeDriftsBeforeAction() throws {
        let runtime = FakeVoiceMemosAXRuntime()
        let driver = SystemVoiceMemosAXDriver(runtime: runtime)
        let accessibility = NativeVoiceMemosAccessibility(driver: driver)
        let mutation = VoiceMemosAccessibilityMutation.delete(oldTitle: "Old exact title")

        _ = try accessibility.verify(mutation)
        runtime.pressSidebar(.recentlyDeleted)

        XCTAssertThrowsError(try accessibility.delete(mutation)) { error in
            XCTAssertEqual(
                error as? VoiceMemosAccessibilityError,
                .allRecordingsRequired(selected: .recentlyDeleted)
            )
        }
        XCTAssertTrue(runtime.recordedActions().isEmpty)

        XCTAssertThrowsError(
            try driver.perform(.activateDelete(scope: .recentlyDeleted, title: "Old exact title"))
        ) { error in
            XCTAssertEqual(
                error as? VoiceMemosAccessibilityError,
                .allRecordingsRequired(selected: .recentlyDeleted)
            )
        }
        XCTAssertTrue(runtime.recordedActions().isEmpty)
    }

    func testLiveDriverOnlyQueriesSystemStateAndFailsClosedWhenSemanticTreeIsUnvalidated() throws {
        let source = try productionSource()

        XCTAssertTrue(source.contains("AXIsProcessTrustedWithOptions(nil)"))
        XCTAssertTrue(source.contains("NSRunningApplication.runningApplications"))
        XCTAssertTrue(source.contains("withBundleIdentifier:"))
        XCTAssertTrue(source.contains("kAXMainWindowAttribute"))
        XCTAssertTrue(source.contains("AXUIElementGetTypeID()"))
        XCTAssertTrue(source.contains("AXUIElementCopyActionNames"))
        XCTAssertTrue(source.contains("CFEqual"))
        XCTAssertTrue(source.contains("func isSameElement("))
        XCTAssertTrue(source.contains("rowsFullyRealized: false"))
        XCTAssertFalse(source.contains("NSWorkspace"))
        XCTAssertFalse(source.contains(".activate("))
        XCTAssertFalse(source.contains("kAXTrustedCheckOptionPrompt"))
        XCTAssertFalse(source.contains("launchApplication"))
        XCTAssertFalse(source.contains("openApplication"))
        XCTAssertFalse(source.contains("kAXActionsAttribute"))
        XCTAssertFalse(source.contains("\"AXActions\""))
        XCTAssertFalse(source.contains("handle ==="))
        XCTAssertFalse(source.contains(".nativeElement ==="))
        XCTAssertFalse(source.contains("ObjectIdentifier(handle)"))

        let runtime = FakeVoiceMemosAXRuntime()
        runtime.mutateNode("recordings") { $0.children = [] }
        let driver = SystemVoiceMemosAXDriver(runtime: runtime)
        XCTAssertThrowsError(
            try driver.perform(.selectRecording(scope: .allRecordings, title: "Old exact title"))
        ) { error in
            XCTAssertEqual(error as? VoiceMemosAccessibilityError, .uiTreeUnsupported)
        }
        XCTAssertTrue(runtime.recordedActions().isEmpty)
    }

    func testLiveDriverUsesRuntimeElementIdentityToRejectNativeTreeCycles() {
        let runtime = FakeVoiceMemosAXRuntime()
        runtime.mutateNode("recordings") { $0.children.append("window") }

        XCTAssertThrowsError(
            try SystemVoiceMemosAXDriver(runtime: runtime).snapshot()
        ) { error in
            XCTAssertEqual(error as? VoiceMemosAccessibilityError, .uiTreeUnsupported)
        }
        XCTAssertTrue(runtime.recordedActions().isEmpty)
    }

    func testMutationSurfaceHasNoPermanentOrBulkDeleteAction() throws {
        let source = try productionSource()

        XCTAssertTrue(source.contains("case activateDelete(scope: VoiceMemosAXScope, title: String)"))
        for forbidden in [
            "Permanent Delete",
            "永久删除",
            "Delete All",
            "全部删除",
            "Empty Recently Deleted",
            "清空最近删除",
        ] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
    }
}

private func productionSource() throws -> String {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(contentsOf: packageRoot
        .appendingPathComponent("Sources/VMemo/NativeVoiceMemosAccessibility.swift"), encoding: .utf8)
}

private func snapshot(_ mutate: (inout VoiceMemosAXSnapshot) -> Void = { _ in }) -> VoiceMemosAXSnapshot {
    var value = VoiceMemosAXSnapshot.readyForRename
    mutate(&value)
    return value
}

private func recentSnapshot(_ mutate: (inout VoiceMemosAXSnapshot) -> Void = { _ in }) -> VoiceMemosAXSnapshot {
    var value = VoiceMemosAXSnapshot.readyForRecentlyDeleted
    mutate(&value)
    return value
}

private extension VoiceMemosAXSnapshot {
    static var readyForRename: VoiceMemosAXSnapshot {
        VoiceMemosAXSnapshot(
            trusted: true,
            application: VoiceMemosAXApplication(
                bundleIdentifier: "com.apple.VoiceMemos",
                bundleBuild: "1380"
            ),
            windowCount: 1,
            isMainWindowPresent: true,
            localeIdentifier: "zh-Hans",
            isUITreeSupported: true,
            selectedSidebar: .allRecordings,
            isModalPresent: false,
            isPopoverPresent: false,
            searchText: "",
            focusedElement: .recordingsList,
            rowsFullyRealized: true,
            rows: [
                VoiceMemosAXRow(title: "Commit sink", isVisible: true, hasNativeDeleteAction: true, hasRestoreAction: false),
                VoiceMemosAXRow(title: "Old exact title", isVisible: true, hasNativeDeleteAction: true, hasRestoreAction: false),
                VoiceMemosAXRow(title: "Unchanged recording", isVisible: true, hasNativeDeleteAction: true, hasRestoreAction: false),
            ],
            detailTitle: "Old exact title",
            isDetailTitleSettable: true
        )
    }

    static var readyForRecentlyDeleted: VoiceMemosAXSnapshot {
        VoiceMemosAXSnapshot(
            trusted: true,
            application: VoiceMemosAXApplication(
                bundleIdentifier: "com.apple.VoiceMemos",
                bundleBuild: "1380"
            ),
            windowCount: 1,
            isMainWindowPresent: true,
            localeIdentifier: "zh-Hans",
            isUITreeSupported: true,
            selectedSidebar: .recentlyDeleted,
            isModalPresent: false,
            isPopoverPresent: false,
            searchText: "",
            focusedElement: .recordingsList,
            rowsFullyRealized: true,
            rows: [
                VoiceMemosAXRow(title: "Already deleted", isVisible: true, hasNativeDeleteAction: false, hasRestoreAction: true),
                VoiceMemosAXRow(title: "Old exact title", isVisible: true, hasNativeDeleteAction: false, hasRestoreAction: true),
            ],
            detailTitle: nil,
            isDetailTitleSettable: false
        )
    }
}

private struct FakeAXNode {
    var role: String?
    var subrole: String?
    var label: String?
    var value: String?
    var descriptionText: String?
    var isSelected: Bool?
    var isVisible: Bool?
    var isSettable = false
    var actions: [String] = []
    var children: [String] = []
}

private final class FakeVoiceMemosAXRuntime: VoiceMemosAXRuntime, @unchecked Sendable {
    private let lock = NSLock()
    private var nodes: [String: FakeAXNode]
    private var selectedSidebarID: String
    private var selectedRowID: String?
    private var titleFieldID: String
    private var trusted = true
    private var bundleBuild = "1380"
    private var focusedElementID = "recordings"
    private var rowsFullyRealized = true
    private var unknownActionName: String?
    private var performedActions: [(action: String, elementID: String)] = []

    init() {
        var initialNodes: [String: FakeAXNode] = [
            "window": FakeAXNode(role: "AXWindow", children: ["sidebar", "recordings", "detail"]),
            "sidebar": FakeAXNode(role: "AXGroup", children: ["all", "recent"]),
            "all": FakeAXNode(
                role: "AXButton",
                label: "所有录音",
                isSelected: true,
                actions: ["AXPress"]
            ),
            "recent": FakeAXNode(
                role: "AXButton",
                label: "最近删除",
                isSelected: false,
                actions: ["AXPress"]
            ),
            "recordings": FakeAXNode(role: "AXTable", children: ["commit-row", "target-row"]),
            "commit-row": FakeAXNode(
                role: "AXRow",
                value: "0:30",
                descriptionText: "Commit sink · 2026-08-29 20:00",
                isSelected: false,
                isVisible: true,
                actions: ["AXPress", "删除"]
            ),
            "target-row": FakeAXNode(
                role: "AXRow",
                value: "0:31",
                descriptionText: "Old exact title · 2026-08-29 20:01",
                isSelected: true,
                isVisible: true,
                actions: ["AXPress", "删除"]
            ),
            "detail": FakeAXNode(role: "AXGroup", children: ["title-field"]),
            "title-field": FakeAXNode(
                role: "AXTextField",
                value: "Old exact title",
                isVisible: true,
                isSettable: true
            ),
        ]
        initialNodes["window"]?.children.append("search")
        initialNodes["search"] = FakeAXNode(
            role: "AXTextField",
            subrole: "AXSearchField",
            value: "",
            isVisible: true
        )
        nodes = initialNodes
        selectedSidebarID = "all"
        selectedRowID = "target-row"
        titleFieldID = "title-field"
    }

    func recordedActions() -> [(action: String, elementID: String)] {
        lock.lock()
        defer { lock.unlock() }
        return performedActions
    }

    func setTrusted(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        trusted = value
    }

    func setBundleBuild(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        bundleBuild = value
    }

    func setFocusedElementID(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        focusedElementID = value
    }

    func setRowsFullyRealized(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        rowsFullyRealized = value
    }

    func addChild(
        _ parentID: String,
        id: String,
        configure: (inout FakeAXNode) -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }
        var node = FakeAXNode()
        configure(&node)
        nodes[id] = node
        nodes[parentID]?.children.append(id)
    }

    func setUnknownActionName(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        unknownActionName = value
    }

    func mutateNode(_ id: String, _ mutate: (inout FakeAXNode) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        mutate(&nodes[id]!)
    }

    func pressSidebar(_ scope: VoiceMemosAXScope) {
        lock.lock()
        defer { lock.unlock() }
        transitionSidebar(scope)
    }

    func isProcessTrusted() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return trusted
    }

    func runningApplication(bundleIdentifier: String) throws -> VoiceMemosAXRuntimeApplication {
        lock.lock()
        defer { lock.unlock() }
        return VoiceMemosAXRuntimeApplication(
            bundleIdentifier: "com.apple.VoiceMemos",
            bundleBuild: bundleBuild,
            windowHandles: [handle("window")],
            mainWindowHandle: handle("window"),
            focusedElementHandle: handle(focusedElementID),
            rowsFullyRealized: rowsFullyRealized
        )
    }

    func attributes(of element: VoiceMemosAXElementHandle) throws -> VoiceMemosAXElementAttributes {
        lock.lock()
        defer { lock.unlock() }
        guard let id = element.fixtureID, let node = nodes[id] else {
            throw VoiceMemosAccessibilityError.uiTreeUnsupported
        }
        return VoiceMemosAXElementAttributes(
            role: node.role,
            subrole: node.subrole,
            label: node.label,
            value: node.value,
            descriptionText: node.descriptionText,
            isSelected: node.isSelected,
            isVisible: node.isVisible,
            isModal: node.role == "AXSheet",
            isPopover: node.subrole == "AXPopover"
        )
    }

    func actionNames(of element: VoiceMemosAXElementHandle) throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard let id = element.fixtureID, let node = nodes[id] else {
            throw VoiceMemosAccessibilityError.uiTreeUnsupported
        }
        return node.actions
    }

    func isSameElement(
        _ lhs: VoiceMemosAXElementHandle,
        _ rhs: VoiceMemosAXElementHandle
    ) -> Bool {
        lhs.fixtureID != nil && lhs.fixtureID == rhs.fixtureID
    }

    private func handle(_ id: String) -> VoiceMemosAXElementHandle {
        VoiceMemosAXElementHandle(fixtureID: id)
    }

    func children(of element: VoiceMemosAXElementHandle) throws -> [VoiceMemosAXElementHandle] {
        lock.lock()
        defer { lock.unlock() }
        guard let id = element.fixtureID, let node = nodes[id] else {
            throw VoiceMemosAccessibilityError.uiTreeUnsupported
        }
        return node.children.map(handle)
    }

    func isAttributeSettable(
        _ attribute: String,
        of element: VoiceMemosAXElementHandle
    ) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let id = element.fixtureID, let node = nodes[id] else {
            throw VoiceMemosAccessibilityError.uiTreeUnsupported
        }
        return node.isSettable
    }

    func performAction(
        _ action: String,
        on element: VoiceMemosAXElementHandle
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let id = element.fixtureID, nodes[id] != nil else {
            throw VoiceMemosAccessibilityError.uiTreeUnsupported
        }
        if let unknownActionName {
            throw VoiceMemosAccessibilityError.unknownAction(unknownActionName)
        }
        performedActions.append((action, id))
        switch (action, id) {
        case ("AXPress", "all"):
            selectedSidebarID = "all"
            transitionSidebar(.allRecordings)
        case ("AXPress", "recent"):
            selectedSidebarID = "recent"
            transitionSidebar(.recentlyDeleted)
        case ("AXPress", let rowID) where nodes[rowID]?.role == "AXRow":
            if let selectedRowID {
                nodes[selectedRowID]?.isSelected = false
            }
            selectedRowID = rowID
            nodes[rowID]?.isSelected = true
            let selectedTitle = nodes[rowID].flatMap { rowTitle(from: rowID, node: $0) }
            nodes["title-field"]?.value = selectedTitle
        case ("删除", let rowID) where nodes[rowID]?.role == "AXRow":
            nodes[rowID] = nil
            if selectedRowID == rowID {
                selectedRowID = nil
                nodes["title-field"]?.value = nil
            }
            nodes["recordings"]?.children.removeAll { $0 == rowID }
        default:
            throw VoiceMemosAccessibilityError.unknownAction(action)
        }
    }

    private func transitionSidebar(_ scope: VoiceMemosAXScope) {
        selectedRowID = nil
        if scope == .recentlyDeleted {
            nodes["all"]?.isSelected = false
            nodes["recent"]?.isSelected = true
            nodes["recent-target-row"] = FakeAXNode(
                role: "AXRow",
                value: "0:31",
                descriptionText: "Old exact title · 2026-08-29 20:01",
                isSelected: false,
                isVisible: true,
                actions: ["AXPress", "恢复"]
            )
            nodes["recordings"]?.children = ["recent-target-row"]
            nodes["title-field"]?.value = nil
        } else {
            nodes["all"]?.isSelected = true
            nodes["recent"]?.isSelected = false
            nodes["recent-target-row"] = nil
            let activeRows = nodes.keys
                .filter { $0.hasSuffix("-row") && $0 != "recent-target-row" }
                .sorted()
            nodes["recordings"]?.children = activeRows
            if let firstRow = activeRows.first {
                nodes[firstRow]?.isSelected = true
                let selectedTitle = nodes[firstRow].flatMap { rowTitle(from: firstRow, node: $0) }
                nodes["title-field"]?.value = selectedTitle
                selectedRowID = firstRow
            }
        }
    }

    private func rowTitle(from id: String, node: FakeAXNode) -> String? {
        node.descriptionText?.components(
            separatedBy: " · "
        ).first
    }

    func setValue(
        _ value: String,
        for attribute: String,
        of element: VoiceMemosAXElementHandle
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let id = element.fixtureID,
              nodes[id]?.isSettable == true,
              let selectedRowID
        else { throw VoiceMemosAccessibilityError.detailTitleNotSettable }
        nodes[id]?.value = value
        nodes[selectedRowID]?.descriptionText =
            "\(value) · 2026-08-29 20:01"
    }
}

private final class TypedVoiceMemosAXDriver: VoiceMemosAXDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var storedSnapshot: VoiceMemosAXSnapshot
    private var actions: [VoiceMemosAXAction] = []
    private var postRefreshSnapshots: [VoiceMemosAXSnapshot] = []
    private var recentlyDeletedSnapshot: VoiceMemosAXSnapshot?
    private var targetSelectResultSnapshot: VoiceMemosAXSnapshot?
    private var failingAction: VoiceMemosAXAction?
    private var unknownActionName: String?

    init(snapshot: VoiceMemosAXSnapshot) {
        storedSnapshot = snapshot
    }

    var currentSnapshot: VoiceMemosAXSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return storedSnapshot
    }

    func recordedActions() -> [VoiceMemosAXAction] {
        lock.lock()
        defer { lock.unlock() }
        return actions
    }

    func setPostRefreshSnapshot(_ snapshot: VoiceMemosAXSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        postRefreshSnapshots = [snapshot]
    }

    func setPostViewSnapshots(all: VoiceMemosAXSnapshot, recent: VoiceMemosAXSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        postRefreshSnapshots = [all]
        recentlyDeletedSnapshot = recent
    }

    func setRecentlyDeletedSnapshot(_ snapshot: VoiceMemosAXSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        recentlyDeletedSnapshot = snapshot
    }

    func setSelectResultSnapshot(_ snapshot: VoiceMemosAXSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        targetSelectResultSnapshot = snapshot
    }

    func setFailingAction(_ action: VoiceMemosAXAction) {
        lock.lock()
        defer { lock.unlock() }
        failingAction = action
    }

    func setUnknownActionName(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        unknownActionName = name
    }

    func snapshot() throws -> VoiceMemosAXSnapshot {
        currentSnapshot
    }

    func perform(_ action: VoiceMemosAXAction) throws {
        lock.lock()
        defer { lock.unlock() }
        var snapshot = storedSnapshot
        actions.append(action)
        if let unknownActionName {
            throw VoiceMemosAccessibilityError.unknownAction(unknownActionName)
        }
        if action == failingAction {
            throw VoiceMemosAccessibilityError.timeout
        }
        switch action {
        case .refresh:
            if !postRefreshSnapshots.isEmpty {
                storedSnapshot = postRefreshSnapshots.removeFirst()
            }
            return
        case let .selectSidebar(scope):
            guard scope == .recentlyDeleted else { return }
            guard let recentlyDeletedSnapshot else {
                throw VoiceMemosAccessibilityError.uiTreeUnsupported
            }
            storedSnapshot = recentlyDeletedSnapshot
            return
        case let .selectRecording(scope, title):
            if let targetSelectResultSnapshot {
                storedSnapshot = targetSelectResultSnapshot
                self.targetSelectResultSnapshot = nil
                return
            }
            guard snapshot.selectedSidebar == scope,
                  snapshot.rows.filter({ $0.title == title }).count == 1
            else {
                throw VoiceMemosAccessibilityError.targetMissing(title: title)
            }
            snapshot.detailTitle = title
        case let .setDetailTitle(title):
            guard snapshot.isDetailTitleSettable,
                  let oldTitle = snapshot.detailTitle,
                  snapshot.rows.filter({ $0.title == oldTitle }).count == 1,
                  let index = snapshot.rows.firstIndex(where: { $0.title == oldTitle })
            else {
                throw VoiceMemosAccessibilityError.detailTitleNotSettable
            }
            var rows = snapshot.rows
            rows[index] = VoiceMemosAXRow(
                title: title,
                isVisible: rows[index].isVisible,
                hasNativeDeleteAction: rows[index].hasNativeDeleteAction,
                hasRestoreAction: rows[index].hasRestoreAction
            )
            snapshot.rows = rows
            snapshot.detailTitle = title
        case let .activateDelete(scope, title):
            guard scope == .allRecordings else {
                throw VoiceMemosAccessibilityError.allRecordingsRequired(selected: scope)
            }
            guard snapshot.selectedSidebar == .allRecordings,
                  snapshot.rows.filter({ $0.title == title }).count == 1,
                  let index = snapshot.rows.firstIndex(where: { $0.title == title })
            else {
                throw VoiceMemosAccessibilityError.targetMissing(title: title)
            }
            snapshot.rows.remove(at: index)
            snapshot.detailTitle = nil
        }
        storedSnapshot = snapshot
    }
}
