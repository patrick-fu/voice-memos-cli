import Foundation

enum RecordingsRootDecision: Equatable, Sendable {
    case productionDefault
    case injected(URL)
    case rejected(String)
}

enum RecordingsRootPolicy {
    static var isReleaseBuild: Bool {
#if DEBUG
        false
#else
        true
#endif
    }

    static func evaluate(
        _ rawValue: String?,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        isReleaseBuild: Bool = RecordingsRootPolicy.isReleaseBuild
    ) -> RecordingsRootDecision {
        guard let rawValue else { return .productionDefault }
        guard isReleaseBuild == false else {
            return .rejected("Recordings root overrides are disabled in release builds.")
        }
        guard !rawValue.isEmpty, !rawValue.contains("\0"), rawValue.hasPrefix("/") else {
            return .rejected("The recordings root override is not a valid path.")
        }

        let rawTemporary = temporaryDirectory.standardizedFileURL
        let resolvedTemporary = canonicalPath(rawTemporary)
        let injected = URL(fileURLWithPath: rawValue, isDirectory: true).standardizedFileURL
        guard injected.isFileURL,
              resolvedTemporary.isFileURL,
              !rawValue.split(separator: "/", omittingEmptySubsequences: false).contains("..")
        else {
            return .rejected("The recordings root override must be a descendant of the system temporary directory.")
        }

        let validatedAncestor: URL
        if isStrictDescendant(injected, of: rawTemporary) {
            validatedAncestor = rawTemporary
        } else if isStrictDescendant(injected, of: resolvedTemporary) {
            validatedAncestor = resolvedTemporary
        } else {
            return .rejected("The recordings root override must be a descendant of the system temporary directory.")
        }

        let resolvedInjected = canonicalPath(injected)
        guard isStrictDescendant(resolvedInjected, of: resolvedTemporary),
              !containsSymbolicLink(from: validatedAncestor, to: injected)
        else {
            return .rejected("The recordings root override must be a descendant of the system temporary directory.")
        }
        return .injected(injected)
    }

    private static func isStrictDescendant(_ candidate: URL, of ancestor: URL) -> Bool {
        candidate.path != ancestor.path && candidate.path.hasPrefix(ancestor.path + "/")
    }

    private static func canonicalPath(_ url: URL) -> URL {
        var pending: [String] = Array(url.pathComponents.dropFirst(1))
        var resolved: [String] = []
        var linksFollowed = 0

        while let component = pending.first {
            pending.removeFirst()
            switch component {
            case "", ".":
                continue
            case "..":
                if !resolved.isEmpty { resolved.removeLast() }
            default:
                let candidate = "/" + (resolved + [component]).joined(separator: "/")
                guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate) else {
                    resolved.append(component)
                    continue
                }
                linksFollowed += 1
                guard linksFollowed <= 40 else { return url.standardizedFileURL }
                let target = destination.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
                if destination.hasPrefix("/") { resolved = [] }
                pending = target + pending
            }
        }

        return URL(fileURLWithPath: "/" + resolved.joined(separator: "/"), isDirectory: url.hasDirectoryPath)
            .standardizedFileURL
    }

    /// Reject links rather than resolving through them: a caller can otherwise replace an
    /// ancestor after validation and redirect a debug-only override outside the temp tree.
    private static func containsSymbolicLink(from ancestor: URL, to descendant: URL) -> Bool {
        let ancestorComponents = ancestor.pathComponents
        let descendantComponents = descendant.pathComponents
        var current = ancestor

        for component in descendantComponents.dropFirst(ancestorComponents.count) {
            current.appendPathComponent(component, isDirectory: true)
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) != nil {
                return true
            }
        }
        return false
    }
}
