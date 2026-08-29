import AppKit
import ApplicationServices
import Foundation

enum VoiceMemosAccessibilityMutation: Hashable, Sendable {
    case rename(oldTitle: String, newTitle: String, commitSinkTitle: String)
    case delete(oldTitle: String)

    var oldTitle: String {
        switch self {
        case let .rename(oldTitle, _, _): oldTitle
        case let .delete(oldTitle): oldTitle
        }
    }

    static func == (
        lhs: VoiceMemosAccessibilityMutation,
        rhs: VoiceMemosAccessibilityMutation
    ) -> Bool {
        switch (lhs, rhs) {
        case let (.rename(lhsOld, lhsNew, lhsSink), .rename(rhsOld, rhsNew, rhsSink)):
            return exactTitleBytes(lhsOld) == exactTitleBytes(rhsOld)
                && exactTitleBytes(lhsNew) == exactTitleBytes(rhsNew)
                && exactTitleBytes(lhsSink) == exactTitleBytes(rhsSink)
        case let (.delete(lhsOld), .delete(rhsOld)):
            return exactTitleBytes(lhsOld) == exactTitleBytes(rhsOld)
        default:
            return false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case let .rename(oldTitle, newTitle, commitSinkTitle):
            hasher.combine(0)
            hashTitleBytes(oldTitle, into: &hasher)
            hashTitleBytes(newTitle, into: &hasher)
            hashTitleBytes(commitSinkTitle, into: &hasher)
        case let .delete(oldTitle):
            hasher.combine(1)
            hashTitleBytes(oldTitle, into: &hasher)
        }
    }
}

private func exactTitleBytes(_ value: String) -> [UInt8] {
    Array(value.utf8)
}

private func exactTitlesEqual(
    _ lhs: String,
    _ rhs: String
) -> Bool {
    exactTitleBytes(lhs) == exactTitleBytes(rhs)
}

private func optionalExactTitlesEqual(
    _ lhs: String?,
    _ rhs: String?
) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil):
        return true
    case let (lhs?, rhs?):
        return exactTitlesEqual(lhs, rhs)
    default:
        return false
    }
}

private func hashTitleBytes(
    _ value: String,
    into hasher: inout Hasher
) {
    for byte in value.utf8 {
        hasher.combine(byte)
    }
}

struct VoiceMemosAccessibilityVerification: Equatable, Sendable {
    let targetTitle: String
    let bundleBuild: String

    static func == (
        lhs: VoiceMemosAccessibilityVerification,
        rhs: VoiceMemosAccessibilityVerification
    ) -> Bool {
        exactTitleBytes(lhs.targetTitle) == exactTitleBytes(rhs.targetTitle)
            && lhs.bundleBuild == rhs.bundleBuild
    }
}

enum VoiceMemosAXScope: Equatable, Hashable, Sendable {
    case allRecordings
    case recentlyDeleted
}

enum VoiceMemosAXFocus: Equatable, Hashable, Sendable {
    case recordingsList
    case other(String)
}

struct VoiceMemosAXApplication: Equatable, Sendable {
    let bundleIdentifier: String
    let bundleBuild: String
}

struct VoiceMemosAXRow: Equatable, Hashable, Sendable {
    var title: String
    var isVisible: Bool
    var hasNativeDeleteAction: Bool
    var hasRestoreAction: Bool

    static func == (
        lhs: VoiceMemosAXRow,
        rhs: VoiceMemosAXRow
    ) -> Bool {
        exactTitleBytes(lhs.title) == exactTitleBytes(rhs.title)
            && lhs.isVisible == rhs.isVisible
            && lhs.hasNativeDeleteAction == rhs.hasNativeDeleteAction
            && lhs.hasRestoreAction == rhs.hasRestoreAction
    }

    func hash(into hasher: inout Hasher) {
        hashTitleBytes(title, into: &hasher)
        hasher.combine(isVisible)
        hasher.combine(hasNativeDeleteAction)
        hasher.combine(hasRestoreAction)
    }
}

struct VoiceMemosAXSnapshot: Equatable, Sendable {
    var trusted: Bool
    var application: VoiceMemosAXApplication?
    var windowCount: Int
    var isMainWindowPresent: Bool
    var localeIdentifier: String
    var isUITreeSupported: Bool
    var selectedSidebar: VoiceMemosAXScope?
    var isModalPresent: Bool
    var isPopoverPresent: Bool
    var searchText: String
    var focusedElement: VoiceMemosAXFocus
    var rowsFullyRealized: Bool
    var rows: [VoiceMemosAXRow]
    var detailTitle: String?
    var isDetailTitleSettable: Bool

    static func == (
        lhs: VoiceMemosAXSnapshot,
        rhs: VoiceMemosAXSnapshot
    ) -> Bool {
        lhs.trusted == rhs.trusted
            && lhs.application == rhs.application
            && lhs.windowCount == rhs.windowCount
            && lhs.isMainWindowPresent == rhs.isMainWindowPresent
            && lhs.localeIdentifier == rhs.localeIdentifier
            && lhs.isUITreeSupported == rhs.isUITreeSupported
            && lhs.selectedSidebar == rhs.selectedSidebar
            && lhs.isModalPresent == rhs.isModalPresent
            && lhs.isPopoverPresent == rhs.isPopoverPresent
            && exactTitleBytes(lhs.searchText) == exactTitleBytes(rhs.searchText)
            && lhs.focusedElement == rhs.focusedElement
            && lhs.rowsFullyRealized == rhs.rowsFullyRealized
            && lhs.rows == rhs.rows
            && optionalExactTitlesEqual(lhs.detailTitle, rhs.detailTitle)
            && lhs.isDetailTitleSettable == rhs.isDetailTitleSettable
    }
}

enum VoiceMemosAXAction: Equatable, Sendable {
    case refresh
    case selectSidebar(scope: VoiceMemosAXScope)
    case selectRecording(scope: VoiceMemosAXScope, title: String)
    case setDetailTitle(String)
    case activateDelete(scope: VoiceMemosAXScope, title: String)

    static func == (
        lhs: VoiceMemosAXAction,
        rhs: VoiceMemosAXAction
    ) -> Bool {
        switch (lhs, rhs) {
        case (.refresh, .refresh):
            return true
        case let (.selectSidebar(lhsScope), .selectSidebar(rhsScope)):
            return lhsScope == rhsScope
        case let (.selectRecording(lhsScope, lhsTitle), .selectRecording(rhsScope, rhsTitle)):
            return lhsScope == rhsScope && exactTitleBytes(lhsTitle) == exactTitleBytes(rhsTitle)
        case let (.setDetailTitle(lhsTitle), .setDetailTitle(rhsTitle)):
            return exactTitleBytes(lhsTitle) == exactTitleBytes(rhsTitle)
        case let (.activateDelete(lhsScope, lhsTitle), .activateDelete(rhsScope, rhsTitle)):
            return lhsScope == rhsScope && exactTitleBytes(lhsTitle) == exactTitleBytes(rhsTitle)
        default:
            return false
        }
    }
}

protocol VoiceMemosAXDriver: Sendable {
    func snapshot() throws -> VoiceMemosAXSnapshot
    func perform(_ action: VoiceMemosAXAction) throws
}

private enum VoiceMemosAXManifest {
    static let bundleBuild = "1380"
    static let localeIdentifier = "zh-Hans"
    static let allRecordingsLabel = "所有录音"
    static let recentlyDeletedLabel = "最近删除"
    static let deleteAction = "删除"
    static let restoreAction = "恢复"
    static let pressAction = "AXPress"
    static let rowDescriptionSeparator = " · "
}

struct VoiceMemosAXElementAttributes: Sendable {
    var role: String?
    var subrole: String?
    var label: String?
    var value: String?
    var descriptionText: String?
    var isSelected: Bool?
    var isVisible: Bool?
    var isModal = false
    var isPopover = false
}

struct VoiceMemosAXRuntimeApplication: Sendable {
    var bundleIdentifier: String
    var bundleBuild: String
    var windowHandles: [VoiceMemosAXElementHandle]
    var mainWindowHandle: VoiceMemosAXElementHandle?
    var focusedElementHandle: VoiceMemosAXElementHandle?
    var rowsFullyRealized: Bool
}

protocol VoiceMemosAXRuntime: Sendable {
    func isProcessTrusted() -> Bool
    func runningApplication(bundleIdentifier: String) throws -> VoiceMemosAXRuntimeApplication
    func attributes(of element: VoiceMemosAXElementHandle) throws -> VoiceMemosAXElementAttributes
    func children(of element: VoiceMemosAXElementHandle) throws -> [VoiceMemosAXElementHandle]
    func actionNames(of element: VoiceMemosAXElementHandle) throws -> [String]
    func isAttributeSettable(
        _ attribute: String,
        of element: VoiceMemosAXElementHandle
    ) throws -> Bool
    func performAction(
        _ action: String,
        on element: VoiceMemosAXElementHandle
    ) throws
    func setValue(
        _ value: String,
        for attribute: String,
        of element: VoiceMemosAXElementHandle
    ) throws
    func isSameElement(
        _ lhs: VoiceMemosAXElementHandle,
        _ rhs: VoiceMemosAXElementHandle
    ) -> Bool
}

final class VoiceMemosAXElementHandle: @unchecked Sendable {
    let nativeElement: AXUIElement?
    let fixtureID: String?

    init(nativeElement: AXUIElement) {
        self.nativeElement = nativeElement
        fixtureID = nil
    }

    init(fixtureID: String) {
        nativeElement = nil
        self.fixtureID = fixtureID
    }
}

private struct ApplicationServicesVoiceMemosAXRuntime: VoiceMemosAXRuntime {
    private static let messagingTimeout: Float = 1

    func isProcessTrusted() -> Bool {
        AXIsProcessTrustedWithOptions(nil)
    }

    func runningApplication(bundleIdentifier: String) throws -> VoiceMemosAXRuntimeApplication {
        let applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        )
        guard let application = applications.first else {
            throw VoiceMemosAccessibilityError.appMissing
        }
        guard applications.count == 1 else {
            throw VoiceMemosAccessibilityError.ambiguousApplication
        }
        guard let bundleURL = application.bundleURL,
              let bundle = Bundle(url: bundleURL),
              bundle.bundleIdentifier == bundleIdentifier,
              let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        else {
            throw VoiceMemosAccessibilityError.unsupportedApplication(
                bundleIdentifier: application.bundleIdentifier,
                bundleBuild: nil
            )
        }

        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        let messagingResult = AXUIElementSetMessagingTimeout(
            applicationElement,
            Self.messagingTimeout
        )
        guard messagingResult == .success else {
            throw VoiceMemosAccessibilityError.timeout
        }
        let windows = try copyElements(applicationElement, attribute: kAXWindowsAttribute)
        return VoiceMemosAXRuntimeApplication(
            bundleIdentifier: bundleIdentifier,
            bundleBuild: build,
            windowHandles: windows,
            mainWindowHandle: try copyElement(
                applicationElement,
                attribute: kAXMainWindowAttribute
            ),
            focusedElementHandle: try copyElement(
                applicationElement,
                attribute: "AXFocusedElement"
            ),
            rowsFullyRealized: false
        )
    }

    func attributes(of element: VoiceMemosAXElementHandle) throws -> VoiceMemosAXElementAttributes {
        guard let nativeElement = element.nativeElement else {
            throw VoiceMemosAccessibilityError.uiTreeUnsupported
        }
        return VoiceMemosAXElementAttributes(
            role: try copyString(nativeElement, attribute: kAXRoleAttribute),
            subrole: try copyString(nativeElement, attribute: kAXSubroleAttribute),
            label: try copyString(nativeElement, attribute: kAXTitleAttribute),
            value: try copyString(nativeElement, attribute: kAXValueAttribute),
            descriptionText: try copyString(nativeElement, attribute: kAXDescriptionAttribute),
            isSelected: try copyBool(nativeElement, attribute: kAXSelectedAttribute),
            isVisible: try copyBool(nativeElement, attribute: "AXVisible"),
            isModal: try copyBool(nativeElement, attribute: kAXModalAttribute) ?? false,
            isPopover: try copyString(nativeElement, attribute: kAXSubroleAttribute) == "AXPopover",
        )
    }

    func actionNames(of element: VoiceMemosAXElementHandle) throws -> [String] {
        guard let nativeElement = element.nativeElement else {
            throw VoiceMemosAccessibilityError.uiTreeUnsupported
        }
        var value: CFArray?
        let result = AXUIElementCopyActionNames(nativeElement, &value)
        switch result {
        case .success:
            guard let value else { return [] }
            let actions = unsafeDowncast(value, to: NSArray.self)
            var names: [String] = []
            for index in 0..<actions.count {
                if let name = actions[index] as? String { names.append(name) }
            }
            return names
        case .cannotComplete:
            throw VoiceMemosAccessibilityError.timeout
        case .actionUnsupported:
            return []
        default:
            throw VoiceMemosAccessibilityError.uiTreeUnsupported
        }
    }

    func children(of element: VoiceMemosAXElementHandle) throws -> [VoiceMemosAXElementHandle] {
        guard let nativeElement = element.nativeElement else {
            throw VoiceMemosAccessibilityError.uiTreeUnsupported
        }
        return try copyElements(nativeElement, attribute: kAXChildrenAttribute)
    }

    func isAttributeSettable(
        _ attribute: String,
        of element: VoiceMemosAXElementHandle
    ) throws -> Bool {
        guard let nativeElement = element.nativeElement else {
            throw VoiceMemosAccessibilityError.uiTreeUnsupported
        }
        var settable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(
            nativeElement,
            attribute as CFString,
            &settable
        )
        switch result {
        case .success: return settable.boolValue
        case .cannotComplete: throw VoiceMemosAccessibilityError.timeout
        case .attributeUnsupported: return false
        default: throw VoiceMemosAccessibilityError.uiTreeUnsupported
        }
    }

    func performAction(
        _ action: String,
        on element: VoiceMemosAXElementHandle
    ) throws {
        guard let nativeElement = element.nativeElement else {
            throw VoiceMemosAccessibilityError.uiTreeUnsupported
        }
        let result = AXUIElementPerformAction(nativeElement, action as CFString)
        switch result {
        case .success: return
        case .cannotComplete: throw VoiceMemosAccessibilityError.timeout
        case .actionUnsupported, .noValue:
            throw VoiceMemosAccessibilityError.unknownAction(action)
        default: throw VoiceMemosAccessibilityError.uiTreeUnsupported
        }
    }

    func setValue(
        _ value: String,
        for attribute: String,
        of element: VoiceMemosAXElementHandle
    ) throws {
        guard let nativeElement = element.nativeElement else {
            throw VoiceMemosAccessibilityError.uiTreeUnsupported
        }
        let result = AXUIElementSetAttributeValue(
            nativeElement,
            attribute as CFString,
            value as CFTypeRef
        )
        switch result {
        case .success: return
        case .cannotComplete: throw VoiceMemosAccessibilityError.timeout
        default: throw VoiceMemosAccessibilityError.detailTitleNotSettable
        }
    }

    func isSameElement(
        _ lhs: VoiceMemosAXElementHandle,
        _ rhs: VoiceMemosAXElementHandle
    ) -> Bool {
        guard let lhsElement = lhs.nativeElement,
              let rhsElement = rhs.nativeElement
        else { return false }
        return CFEqual(lhsElement, rhsElement)
    }

    private func copyElement(
        _ element: AXUIElement,
        attribute: String
    ) throws -> VoiceMemosAXElementHandle? {
        guard let value = try copyValue(element, attribute: attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return VoiceMemosAXElementHandle(nativeElement: unsafeDowncast(value, to: AXUIElement.self))
    }

    private func copyElements(
        _ element: AXUIElement,
        attribute: String
    ) throws -> [VoiceMemosAXElementHandle] {
        guard let value = try copyValue(element, attribute: attribute),
              CFGetTypeID(value) == CFArrayGetTypeID()
        else { return [] }
        let elements = unsafeDowncast(value, to: NSArray.self)
        var handles: [VoiceMemosAXElementHandle] = []
        for index in 0..<elements.count {
            let element = elements[index]
            guard CFGetTypeID(element as CFTypeRef) == AXUIElementGetTypeID() else { continue }
            handles.append(VoiceMemosAXElementHandle(nativeElement: element as! AXUIElement))
        }
        return handles
    }

    private func copyString(
        _ element: AXUIElement,
        attribute: String
    ) throws -> String? {
        guard let value = try copyValue(element, attribute: attribute) else { return nil }
        return value as? String
    }

    private func copyBool(
        _ element: AXUIElement,
        attribute: String
    ) throws -> Bool? {
        guard let value = try copyValue(element, attribute: attribute) else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private func copyValue(
        _ element: AXUIElement,
        attribute: String
    ) throws -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        )
        switch result {
        case .success: return value
        case .attributeUnsupported: return nil
        case .cannotComplete: throw VoiceMemosAccessibilityError.timeout
        default: throw VoiceMemosAccessibilityError.uiTreeUnsupported
        }
    }
}

private struct VoiceMemosAXRecognizedNode {
    let handle: VoiceMemosAXElementHandle
    let attributes: VoiceMemosAXElementAttributes
    let children: [VoiceMemosAXRecognizedNode]
}

private struct VoiceMemosAXRecognizedRow {
    let node: VoiceMemosAXRecognizedNode
    let title: String
    let duration: String
    let actionNames: [String]
}

private struct VoiceMemosAXRecognizedTree {
    let root: VoiceMemosAXRecognizedNode
    let allSidebar: VoiceMemosAXRecognizedNode
    let recentSidebar: VoiceMemosAXRecognizedNode
    let selectedSidebar: VoiceMemosAXScope
    let recordingsList: VoiceMemosAXRecognizedNode
    let rows: [VoiceMemosAXRecognizedRow]
    let selectedRow: VoiceMemosAXRecognizedRow?
    let detailTitleHandle: VoiceMemosAXElementHandle?
    let detailTitle: String?
    let isDetailTitleSettable: Bool
    let searchText: String
    let isModalPresent: Bool
    let isPopoverPresent: Bool
    let focusedElementHandle: VoiceMemosAXElementHandle?
}

/// The native system adapter exposes a semantic tree only after an exact build/locale
/// manifest, unique semantic anchors, valid row shapes, and safe native actions are recognized.
struct SystemVoiceMemosAXDriver: VoiceMemosAXDriver {
    private static let bundleIdentifier = "com.apple.VoiceMemos"

    private let runtime: any VoiceMemosAXRuntime

    init(runtime: any VoiceMemosAXRuntime = ApplicationServicesVoiceMemosAXRuntime()) {
        self.runtime = runtime
    }

    func snapshot() throws -> VoiceMemosAXSnapshot {
        guard runtime.isProcessTrusted() else { throw VoiceMemosAccessibilityError.untrusted }
        let application = try runtime.runningApplication(bundleIdentifier: Self.bundleIdentifier)
        try validateApplication(application)
        let tree = try recognize(application)
        return VoiceMemosAXSnapshot(
            trusted: true,
            application: VoiceMemosAXApplication(
                bundleIdentifier: application.bundleIdentifier,
                bundleBuild: application.bundleBuild
            ),
            windowCount: application.windowHandles.count,
            isMainWindowPresent: true,
            localeIdentifier: VoiceMemosAXManifest.localeIdentifier,
            isUITreeSupported: true,
            selectedSidebar: tree.selectedSidebar,
            isModalPresent: tree.isModalPresent,
            isPopoverPresent: tree.isPopoverPresent,
            searchText: tree.searchText,
            focusedElement: focusedElement(in: tree),
            rowsFullyRealized: application.rowsFullyRealized,
            rows: tree.rows.map { row in
                VoiceMemosAXRow(
                    title: row.title,
                    isVisible: row.node.attributes.isVisible == true,
                    hasNativeDeleteAction: row.actionNames.contains(
                        VoiceMemosAXManifest.deleteAction
                    ),
                    hasRestoreAction: row.actionNames.contains(
                        VoiceMemosAXManifest.restoreAction
                    )
                )
            },
            detailTitle: tree.detailTitle,
            isDetailTitleSettable: tree.isDetailTitleSettable
        )
    }

    func perform(_ action: VoiceMemosAXAction) throws {
        switch action {
        case .refresh:
            _ = try snapshot()
        case let .selectSidebar(scope):
            let tree = try recognizeCurrentApplication()
            let sidebar = scope == .allRecordings ? tree.allSidebar : tree.recentSidebar
            try runtime.performAction(VoiceMemosAXManifest.pressAction, on: sidebar.handle)
        case let .selectRecording(scope, title):
            let row = try requireRow(title: title, scope: scope)
            try requireRowAction(VoiceMemosAXManifest.pressAction, on: row)
            try runtime.performAction(VoiceMemosAXManifest.pressAction, on: row.node.handle)
        case let .setDetailTitle(title):
            let tree = try recognizeCurrentApplication()
            guard let selectedRow = tree.selectedRow,
                  let detailTitle = tree.detailTitle,
                  let detailHandle = tree.detailTitleHandle,
                  tree.isDetailTitleSettable,
                  exactBytes(detailTitle) == exactBytes(selectedRow.title)
            else { throw VoiceMemosAccessibilityError.detailTitleNotSettable }
            try runtime.setValue(
                title,
                for: kAXValueAttribute,
                of: detailHandle
            )
        case let .activateDelete(scope, title):
            guard scope == .allRecordings else {
                throw VoiceMemosAccessibilityError.allRecordingsRequired(selected: scope)
            }
            let row = try requireRow(title: title, scope: .allRecordings)
            try requireNativeDeleteAction(on: row, title: title)
            let freshTree = try recognizeCurrentApplication()
            guard freshTree.selectedSidebar == .allRecordings else {
                throw VoiceMemosAccessibilityError.allRecordingsRequired(
                    selected: freshTree.selectedSidebar
                )
            }
            let freshRow = try uniqueRow(title: title, in: freshTree)
            guard runtime.isSameElement(freshRow.node.handle, row.node.handle) else {
                throw VoiceMemosAccessibilityError.uiTreeUnsupported
            }
            try requireNativeDeleteAction(on: freshRow, title: title)
            try runtime.performAction(
                VoiceMemosAXManifest.deleteAction,
                on: freshRow.node.handle
            )
        }
    }

    private func validateApplication(
        _ application: VoiceMemosAXRuntimeApplication
    ) throws {
        guard application.bundleIdentifier == Self.bundleIdentifier,
              application.bundleBuild == VoiceMemosAXManifest.bundleBuild
        else {
            throw VoiceMemosAccessibilityError.unsupportedApplication(
                bundleIdentifier: application.bundleIdentifier,
                bundleBuild: application.bundleBuild
            )
        }
        let windowCount = application.windowHandles.count
        guard windowCount == 1 else {
            throw windowCount == 0
                ? VoiceMemosAccessibilityError.windowMissing
                : VoiceMemosAccessibilityError.ambiguousMainWindow
        }
        guard application.mainWindowHandle != nil else {
            throw VoiceMemosAccessibilityError.windowMissing
        }
    }

    private func recognizeCurrentApplication() throws -> VoiceMemosAXRecognizedTree {
        guard runtime.isProcessTrusted() else { throw VoiceMemosAccessibilityError.untrusted }
        let application = try runtime.runningApplication(bundleIdentifier: Self.bundleIdentifier)
        try validateApplication(application)
        return try recognize(application)
    }

    private func requireRow(
        title: String,
        scope: VoiceMemosAXScope
    ) throws -> VoiceMemosAXRecognizedRow {
        let tree = try recognizeCurrentApplication()
        guard tree.selectedSidebar == scope else {
            throw scope == .allRecordings
                ? VoiceMemosAccessibilityError.allRecordingsRequired(selected: tree.selectedSidebar)
                : VoiceMemosAccessibilityError.recentlyDeletedRequired
        }
        return try uniqueRow(title: title, in: tree)
    }

    private func uniqueRow(
        title: String,
        in tree: VoiceMemosAXRecognizedTree
    ) throws -> VoiceMemosAXRecognizedRow {
        let expectedTitle = exactBytes(title)
        let exactRows = tree.rows.filter { exactBytes($0.title) == expectedTitle }
        guard exactRows.count == 1, let row = exactRows.first else {
            throw exactRows.isEmpty
                ? VoiceMemosAccessibilityError.targetMissing(title: title)
                : VoiceMemosAccessibilityError.ambiguousTarget(title: title)
        }
        return row
    }

    private func requireRowAction(
        _ action: String,
        on row: VoiceMemosAXRecognizedRow
    ) throws {
        guard row.actionNames.contains(action) else {
            throw VoiceMemosAccessibilityError.unknownAction(action)
        }
    }

    private func requireNativeDeleteAction(
        on row: VoiceMemosAXRecognizedRow,
        title: String
    ) throws {
        guard row.actionNames.contains(VoiceMemosAXManifest.deleteAction),
              !row.actionNames.contains(VoiceMemosAXManifest.restoreAction)
        else {
            throw VoiceMemosAccessibilityError.deleteActionMissing(title: title)
        }
    }

    private func recognize(
        _ application: VoiceMemosAXRuntimeApplication
    ) throws -> VoiceMemosAXRecognizedTree {
        var visited: [VoiceMemosAXElementHandle] = []
        let root = try makeNode(
            application.mainWindowHandle!,
            visited: &visited
        )
        let nodes = flatten(root)

        let sidebarRole = ["AXButton", "AXRadioButton"]
        let allSidebars = nodes.filter { node in
            sidebarRole.contains(node.attributes.role ?? "")
                && node.attributes.label == VoiceMemosAXManifest.allRecordingsLabel
        }
        let recentSidebars = nodes.filter { node in
            sidebarRole.contains(node.attributes.role ?? "")
                && node.attributes.label == VoiceMemosAXManifest.recentlyDeletedLabel
        }
        guard allSidebars.count == 1,
              recentSidebars.count == 1,
              let allSidebar = allSidebars.first,
              let recentSidebar = recentSidebars.first
        else { throw VoiceMemosAccessibilityError.uiTreeUnsupported }

        let selectedSidebars = [allSidebar, recentSidebar].filter {
            $0.attributes.isSelected == true
        }
        guard let selectedSidebar = selectedSidebars.first, selectedSidebars.count == 1 else {
            throw VoiceMemosAccessibilityError.uiTreeUnsupported
        }
        let scope: VoiceMemosAXScope
        if runtime.isSameElement(selectedSidebar.handle, allSidebar.handle) {
            scope = .allRecordings
        } else if runtime.isSameElement(selectedSidebar.handle, recentSidebar.handle) {
            scope = .recentlyDeleted
        } else {
            throw VoiceMemosAccessibilityError.uiTreeUnsupported
        }

        let rowNodes = nodes.filter { $0.attributes.role == "AXRow" }
        let listNodes = nodes.filter {
            $0.attributes.role == "AXTable" || $0.attributes.role == "AXList"
        }
        let listsWithRows = listNodes.filter { list in
            flatten(list).contains { $0.attributes.role == "AXRow" }
        }
        guard listsWithRows.count == 1, let recordingsList = listsWithRows.first else {
            throw VoiceMemosAccessibilityError.uiTreeUnsupported
        }

        var recognizedRows: [VoiceMemosAXRecognizedRow] = []
        for row in rowNodes {
            recognizedRows.append(try validateRow(row, scope: scope))
        }
        let selectedRows = recognizedRows.filter { $0.node.attributes.isSelected == true }
        guard selectedRows.count <= 1 else {
            throw VoiceMemosAccessibilityError.uiTreeUnsupported
        }
        let selectedRow = selectedRows.first

        let searchFields = nodes.filter {
            $0.attributes.role == "AXTextField"
                && $0.attributes.subrole == "AXSearchField"
        }
        guard searchFields.count <= 1 else { throw VoiceMemosAccessibilityError.uiTreeUnsupported }
        let searchText = searchFields.first?.attributes.value ?? ""

        var detailTitleHandle: VoiceMemosAXElementHandle?
        var detailTitle: String?
        var isDetailTitleSettable = false
        if let selectedRow {
            let selectedTitle = selectedRow.title
            let expectedTitle = exactBytes(selectedTitle)
            let candidates = nodes.filter { node in
                node.attributes.role == "AXTextField"
                    && node.attributes.subrole != "AXSearchField"
                    && exactBytes(node.attributes.value ?? "") == expectedTitle
            }
            guard candidates.count == 1, let candidate = candidates.first else {
                throw VoiceMemosAccessibilityError.uiTreeUnsupported
            }
            let settable = try runtime.isAttributeSettable(
                kAXValueAttribute,
                of: candidate.handle
            )
            guard settable else { throw VoiceMemosAccessibilityError.detailTitleNotSettable }
            detailTitleHandle = candidate.handle
            detailTitle = selectedTitle
            isDetailTitleSettable = true
        }

        return VoiceMemosAXRecognizedTree(
            root: root,
            allSidebar: allSidebar,
            recentSidebar: recentSidebar,
            selectedSidebar: scope,
            recordingsList: recordingsList,
            rows: recognizedRows,
            selectedRow: selectedRow,
            detailTitleHandle: detailTitleHandle,
            detailTitle: detailTitle,
            isDetailTitleSettable: isDetailTitleSettable,
            searchText: searchText,
            isModalPresent: nodes.contains { $0.attributes.isModal },
            isPopoverPresent: nodes.contains { $0.attributes.isPopover },
            focusedElementHandle: application.focusedElementHandle
        )
    }

    private func makeNode(
        _ handle: VoiceMemosAXElementHandle,
        visited: inout [VoiceMemosAXElementHandle]
    ) throws -> VoiceMemosAXRecognizedNode {
        guard !visited.contains(where: { runtime.isSameElement($0, handle) }) else {
            throw VoiceMemosAccessibilityError.uiTreeUnsupported
        }
        visited.append(handle)
        let attributes = try runtime.attributes(of: handle)
        let children = try runtime.children(of: handle).map {
            try makeNode($0, visited: &visited)
        }
        return VoiceMemosAXRecognizedNode(
            handle: handle,
            attributes: attributes,
            children: children
        )
    }

    private func flatten(
        _ node: VoiceMemosAXRecognizedNode
    ) -> [VoiceMemosAXRecognizedNode] {
        [node] + node.children.flatMap(flatten)
    }

    private func validateRow(
        _ row: VoiceMemosAXRecognizedNode,
        scope: VoiceMemosAXScope
    ) throws -> VoiceMemosAXRecognizedRow {
        let requiredAction = scope == .allRecordings
            ? VoiceMemosAXManifest.deleteAction
            : VoiceMemosAXManifest.restoreAction
        let forbiddenAction = scope == .allRecordings
            ? VoiceMemosAXManifest.restoreAction
            : VoiceMemosAXManifest.deleteAction
        let actionNames = try runtime.actionNames(of: row.handle)
        let actions = Set(actionNames)
        guard actions == [VoiceMemosAXManifest.pressAction, requiredAction],
              !actions.contains(forbiddenAction),
              let duration = row.attributes.value,
              !duration.utf8.isEmpty,
              row.attributes.isSelected != nil,
              row.attributes.isVisible != nil
        else { throw VoiceMemosAccessibilityError.uiTreeUnsupported }
        let (title, time) = try parseRowDescription(row.attributes.descriptionText)
        guard !exactBytes(title).isEmpty,
              !exactBytes(time).isEmpty
        else { throw VoiceMemosAccessibilityError.uiTreeUnsupported }
        return VoiceMemosAXRecognizedRow(
            node: row,
            title: title,
            duration: duration,
            actionNames: actionNames
        )
    }

    private func parseRowDescription(
        _ description: String?
    ) throws -> (title: String, time: String) {
        guard let description else {
            throw VoiceMemosAccessibilityError.uiTreeUnsupported
        }
        let separator = VoiceMemosAXManifest.rowDescriptionSeparator
        let parts = description.components(separatedBy: separator)
        guard parts.count == 2 else {
            throw VoiceMemosAccessibilityError.uiTreeUnsupported
        }
        let title = parts[0]
        let time = parts[1]
        guard !title.utf8.isEmpty, !time.utf8.isEmpty else {
            throw VoiceMemosAccessibilityError.uiTreeUnsupported
        }
        return (title, time)
    }

    private func focusedElement(
        in tree: VoiceMemosAXRecognizedTree
    ) -> VoiceMemosAXFocus {
        guard let focused = tree.focusedElementHandle else {
            return .other("unknown")
        }
        if runtime.isSameElement(focused, tree.recordingsList.handle) {
            return .recordingsList
        }
        let node = flatten(tree.root).first { runtime.isSameElement($0.handle, focused) }
        return .other(node?.attributes.role ?? "unknown")
    }

    private func exactBytes(_ value: String) -> [UInt8] {
        Array(value.utf8)
    }
}

protocol VoiceMemosAccessibility: Sendable {
    func verify(_ mutation: VoiceMemosAccessibilityMutation) throws -> VoiceMemosAccessibilityVerification
    func rename(_ mutation: VoiceMemosAccessibilityMutation) throws
    func delete(_ mutation: VoiceMemosAccessibilityMutation) throws
    func verifyPostcondition(_ mutation: VoiceMemosAccessibilityMutation) throws
}

enum VoiceMemosAccessibilityError: Error, Equatable, Sendable {
    case untrusted
    case appMissing
    case ambiguousApplication
    case unsupportedApplication(bundleIdentifier: String?, bundleBuild: String?)
    case windowMissing
    case ambiguousMainWindow
    case unsupportedLocale(String)
    case uiTreeUnsupported
    case allRecordingsRequired(selected: VoiceMemosAXScope?)
    case recentlyDeletedRequired
    case modalPresent
    case popoverPresent
    case searchActive(String)
    case focusDrift(VoiceMemosAXFocus)
    case virtualizedAmbiguity
    case targetMissing(title: String)
    case ambiguousTarget(title: String)
    case targetNotVisible(title: String)
    case detailTitleMismatch(expected: String, actual: String?)
    case detailTitleNotSettable
    case commitSinkMissing(title: String)
    case invalidCommitSink(title: String)
    case newTitleConflict(title: String)
    case deleteActionMissing(title: String)
    case preflightUnavailable
    case postconditionUnavailable
    case postconditionFailed(String)
    case timeout
    case unknownAction(String)
}

final class NativeVoiceMemosAccessibility: VoiceMemosAccessibility, @unchecked Sendable {
    private static let expectedBundleIdentifier = "com.apple.VoiceMemos"
    private static let expectedBundleBuild = "1380"
    private static let expectedLocale = "zh-Hans"

    private let driver: any VoiceMemosAXDriver
    private let operationLock = NSLock()
    private let stateLock = NSLock()
    private var verifiedSnapshots: [VoiceMemosAccessibilityMutation: VoiceMemosAXSnapshot] = [:]

    init(driver: any VoiceMemosAXDriver) {
        self.driver = driver
    }

    func verify(_ mutation: VoiceMemosAccessibilityMutation) throws -> VoiceMemosAccessibilityVerification {
        operationLock.lock()
        defer { operationLock.unlock() }

        try driver.perform(.refresh)
        let snapshot = try driver.snapshot()
        try verifySnapshot(snapshot, for: mutation)
        stateLock.lock()
        defer { stateLock.unlock() }
        verifiedSnapshots[mutation] = snapshot
        return VoiceMemosAccessibilityVerification(
            targetTitle: mutation.oldTitle,
            bundleBuild: Self.expectedBundleBuild
        )
    }

    func rename(_ mutation: VoiceMemosAccessibilityMutation) throws {
        operationLock.lock()
        defer { operationLock.unlock() }

        guard case let .rename(oldTitle, newTitle, commitSinkTitle) = mutation else {
            throw VoiceMemosAccessibilityError.unknownAction("rename requires a rename mutation")
        }
        try driver.perform(.refresh)
        let snapshot = try driver.snapshot()
        try verifySnapshot(snapshot, for: mutation)
        storeVerifiedSnapshot(snapshot, for: mutation)

        try driver.perform(.selectRecording(scope: .allRecordings, title: oldTitle))
        try driver.perform(.refresh)
        let selectedSnapshot = try driver.snapshot()
        try verifySnapshot(selectedSnapshot, for: mutation)
        try driver.perform(.setDetailTitle(newTitle))
        try driver.perform(.selectRecording(scope: .allRecordings, title: commitSinkTitle))
    }

    func delete(_ mutation: VoiceMemosAccessibilityMutation) throws {
        operationLock.lock()
        defer { operationLock.unlock() }

        guard case let .delete(oldTitle) = mutation else {
            throw VoiceMemosAccessibilityError.unknownAction("delete requires a delete mutation")
        }
        try driver.perform(.refresh)
        let snapshot = try driver.snapshot()
        try verifySnapshot(snapshot, for: mutation)
        storeVerifiedSnapshot(snapshot, for: mutation)

        try driver.perform(.activateDelete(scope: .allRecordings, title: oldTitle))
    }

    func verifyPostcondition(_ mutation: VoiceMemosAccessibilityMutation) throws {
        operationLock.lock()
        defer { operationLock.unlock() }

        guard let before = verifiedSnapshot(for: mutation) else {
            throw VoiceMemosAccessibilityError.postconditionUnavailable
        }
        try driver.perform(.refresh)
        let allAfter = try driver.snapshot()
        try verifyStableShell(allAfter, requiredScope: .allRecordings)

        switch mutation {
        case let .rename(oldTitle, newTitle, commitSinkTitle):
            try requireUniqueVisibleRow(newTitle, in: allAfter.rows)
            guard !allAfter.rows.contains(where: { exactTitlesEqual($0.title, oldTitle) }) else {
                throw VoiceMemosAccessibilityError.postconditionFailed("old title remains in All Recordings")
            }
            let sinkBefore = before.rows.first { exactTitlesEqual($0.title, commitSinkTitle) }
            let sinkAfter = allAfter.rows.first { exactTitlesEqual($0.title, commitSinkTitle) }
            guard sinkBefore == sinkAfter else {
                throw VoiceMemosAccessibilityError.postconditionFailed("commit sink changed")
            }
            let expectedRows = before.rows.map { row in
                exactTitlesEqual(row.title, oldTitle)
                    ? VoiceMemosAXRow(
                        title: newTitle,
                        isVisible: row.isVisible,
                        hasNativeDeleteAction: row.hasNativeDeleteAction,
                        hasRestoreAction: row.hasRestoreAction
                    )
                    : row
            }
            guard expectedRows == allAfter.rows else {
                throw VoiceMemosAccessibilityError.postconditionFailed("All Recordings rows other than the target changed")
            }
        case let .delete(oldTitle):
            guard !allAfter.rows.contains(where: { exactTitlesEqual($0.title, oldTitle) }) else {
                throw VoiceMemosAccessibilityError.postconditionFailed("old title remains in All Recordings")
            }
            guard before.rows.filter({ !exactTitlesEqual($0.title, oldTitle) }) == allAfter.rows else {
                throw VoiceMemosAccessibilityError.postconditionFailed("other All Recordings rows changed")
            }

            try driver.perform(.selectSidebar(scope: .recentlyDeleted))
            try driver.perform(.refresh)
            let recentAfter = try driver.snapshot()
            try verifyStableShell(recentAfter, requiredScope: .recentlyDeleted)
            try requireUniqueVisibleRow(oldTitle, in: recentAfter.rows)
            guard let deletedRow = recentAfter.rows.first(where: { exactTitlesEqual($0.title, oldTitle) }),
                  deletedRow.hasRestoreAction
            else {
                throw VoiceMemosAccessibilityError.postconditionFailed("deleted row is not restorable")
            }
        }
    }

    private func verifiedSnapshot(for mutation: VoiceMemosAccessibilityMutation) -> VoiceMemosAXSnapshot? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return verifiedSnapshots[mutation]
    }

    private func storeVerifiedSnapshot(
        _ snapshot: VoiceMemosAXSnapshot,
        for mutation: VoiceMemosAccessibilityMutation
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }
        verifiedSnapshots[mutation] = snapshot
    }

    private func verifySnapshot(
        _ snapshot: VoiceMemosAXSnapshot,
        for mutation: VoiceMemosAccessibilityMutation
    ) throws {
        try verifyStableShell(snapshot, requiredScope: .allRecordings)

        switch mutation {
        case let .rename(oldTitle, newTitle, commitSinkTitle):
            try requireUniqueVisibleRow(oldTitle, in: snapshot.rows)
            if snapshot.rows.contains(where: { exactTitlesEqual($0.title, newTitle) }) {
                throw VoiceMemosAccessibilityError.newTitleConflict(title: newTitle)
            }
            guard !exactTitlesEqual(commitSinkTitle, oldTitle),
                  !exactTitlesEqual(commitSinkTitle, newTitle)
            else {
                throw VoiceMemosAccessibilityError.invalidCommitSink(title: commitSinkTitle)
            }
            guard snapshot.rows.contains(where: { exactTitlesEqual($0.title, commitSinkTitle) }) else {
                throw VoiceMemosAccessibilityError.commitSinkMissing(title: commitSinkTitle)
            }
            if snapshot.rows.filter({ exactTitlesEqual($0.title, commitSinkTitle) }).count > 1 {
                throw VoiceMemosAccessibilityError.ambiguousTarget(title: commitSinkTitle)
            }
            guard let detailTitle = snapshot.detailTitle,
                  exactTitlesEqual(detailTitle, oldTitle)
            else {
                throw VoiceMemosAccessibilityError.detailTitleMismatch(
                    expected: oldTitle,
                    actual: snapshot.detailTitle
                )
            }
            guard snapshot.isDetailTitleSettable else {
                throw VoiceMemosAccessibilityError.detailTitleNotSettable
            }
            try requireUniqueVisibleRow(commitSinkTitle, in: snapshot.rows)
        case let .delete(oldTitle):
            try requireUniqueVisibleRow(oldTitle, in: snapshot.rows)
            guard let row = snapshot.rows.first(where: { exactTitlesEqual($0.title, oldTitle) }),
                  row.hasNativeDeleteAction
            else {
                throw VoiceMemosAccessibilityError.deleteActionMissing(title: oldTitle)
            }
        }

    }

    private func verifyStableShell(
        _ snapshot: VoiceMemosAXSnapshot,
        requiredScope: VoiceMemosAXScope
    ) throws {
        guard snapshot.trusted else { throw VoiceMemosAccessibilityError.untrusted }
        guard let application = snapshot.application else {
            throw VoiceMemosAccessibilityError.appMissing
        }
        guard application.bundleIdentifier == Self.expectedBundleIdentifier,
              application.bundleBuild == Self.expectedBundleBuild
        else {
            throw VoiceMemosAccessibilityError.unsupportedApplication(
                bundleIdentifier: application.bundleIdentifier,
                bundleBuild: application.bundleBuild
            )
        }
        guard snapshot.windowCount == 1 else {
            throw snapshot.windowCount == 0
                ? VoiceMemosAccessibilityError.windowMissing
                : VoiceMemosAccessibilityError.ambiguousMainWindow
        }
        guard snapshot.isMainWindowPresent else { throw VoiceMemosAccessibilityError.windowMissing }
        guard snapshot.localeIdentifier == Self.expectedLocale else {
            throw VoiceMemosAccessibilityError.unsupportedLocale(snapshot.localeIdentifier)
        }
        guard snapshot.isUITreeSupported else { throw VoiceMemosAccessibilityError.uiTreeUnsupported }
        guard snapshot.selectedSidebar == requiredScope else {
            if requiredScope == .allRecordings {
                throw VoiceMemosAccessibilityError.allRecordingsRequired(selected: snapshot.selectedSidebar)
            }
            throw VoiceMemosAccessibilityError.recentlyDeletedRequired
        }
        guard !snapshot.isModalPresent else { throw VoiceMemosAccessibilityError.modalPresent }
        guard !snapshot.isPopoverPresent else { throw VoiceMemosAccessibilityError.popoverPresent }
        guard snapshot.searchText.isEmpty else {
            throw VoiceMemosAccessibilityError.searchActive(snapshot.searchText)
        }
        guard snapshot.focusedElement == .recordingsList else {
            throw VoiceMemosAccessibilityError.focusDrift(snapshot.focusedElement)
        }
        guard snapshot.rowsFullyRealized else {
            throw VoiceMemosAccessibilityError.virtualizedAmbiguity
        }
    }

    private func requireUniqueVisibleRow(
        _ title: String,
        in rows: [VoiceMemosAXRow]
    ) throws {
        let exactMatches = rows.filter { exactTitlesEqual($0.title, title) }
        guard exactMatches.count == 1 else {
            throw exactMatches.isEmpty
                ? VoiceMemosAccessibilityError.targetMissing(title: title)
                : VoiceMemosAccessibilityError.ambiguousTarget(title: title)
        }
        guard exactMatches[0].isVisible else {
            throw VoiceMemosAccessibilityError.targetNotVisible(title: title)
        }
    }
}
