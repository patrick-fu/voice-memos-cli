import ArgumentParser
import Foundation

struct VMemo: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vmemo",
        abstract: "Safely inspect and manage Voice Memos recordings.",
        usage: "vmemo <subcommand>",
        discussion: """
        Agent-facing CLI with a stable, fail-closed contract.

        Output: human reports go to stdout; diagnostics go to stderr. Add --json for the version 1 JSON envelope (version: 1, status, and data or error).
        Exit codes: 0 success, 2 usage error, 3 operational/output error, 4 safety or adapter block, 5 partial/incomplete result.
        Recording IDs are opaque and must be passed exactly as returned. Mutations fail closed when safety or adapter checks cannot be satisfied.
        delete moves a recording to Recently Deleted; it does not permanently erase it.

        Examples:
          vmemo list --json
          vmemo show --id opaque-recording-id --json
        """,
        subcommands: [List.self, Search.self, Show.self, Export.self, Rename.self, Delete.self, Doctor.self]
    )
}

enum VMemoApplication {
    static func main() {
        do {
            var command = try VMemo.parseAsRoot()
            try command.run()
        } catch let exitCode as ExitCode {
            exit(exitCode.rawValue)
        } catch {
            if CommandLine.arguments.contains("--json") {
                let result = CommandResult.usage(message: VMemo.fullMessage(for: error))
                ProcessIO.write(result)
                exit(result.exitCode)
            }
            VMemo.exit(withError: error)
        }
    }
}

private protocol RoutedCommand: ParsableCommand {
    var output: OutputOptions { get }
    func request() -> CommandRequest
}

private extension RoutedCommand {
    func run() throws {
        let result = ProductionComposition.runner.run(request(), output: output.format)
        ProcessIO.write(result)
        guard result.exitCode == 0 else {
            throw ExitCode(result.exitCode)
        }
    }
}

private struct List: RoutedCommand {
    static let configuration = CommandConfiguration(
        abstract: "List recordings.",
        usage: "vmemo list [--json]",
        discussion: "List recordings. Example: vmemo list --json"
    )
    @OptionGroup var output: OutputOptions

    func request() -> CommandRequest { .list }
}

private struct Search: RoutedCommand {
    static let configuration = CommandConfiguration(
        abstract: "Search recordings.",
        usage: "vmemo search --query <text> [--json]",
        discussion: "Search recording titles. Example: vmemo search --query meeting --json"
    )
    @Option(name: .long, help: "Search text.") var query: String
    @OptionGroup var output: OutputOptions

    func request() -> CommandRequest { .search(query: query) }
}

private struct Show: RoutedCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show one recording.",
        usage: "vmemo show --id <opaque-recording-id> [--json]",
        discussion: "Use the opaque ID returned by list or search. Example: vmemo show --id opaque-recording-id --json"
    )
    @Option(name: .long, help: "Opaque recording identifier.") var id: String
    @OptionGroup var output: OutputOptions

    func request() -> CommandRequest { .show(id: RecordingID(value: id)) }
}

private struct Export: RoutedCommand {
    static let configuration = CommandConfiguration(
        abstract: "Export one recording.",
        usage: "vmemo export --id <opaque-recording-id> --output-path <destination> [--json]",
        discussion: "Destination must not already exist; the source recording is never modified. Example: vmemo export --id opaque-recording-id --output-path ./recording.m4a --json"
    )
    @Option(name: .long, help: "Opaque recording identifier (required).") var id: String
    @Option(name: .long, help: "Destination path; must not already exist (required).") var outputPath: String
    @OptionGroup var output: OutputOptions

    func request() -> CommandRequest { .export(id: RecordingID(value: id), destination: outputPath) }
}

private struct Rename: RoutedCommand {
    static let configuration = CommandConfiguration(
        abstract: "Rename one recording.",
        usage: "vmemo rename --id <opaque-recording-id> --title <new-title> (--dry-run | --token <token> --confirm) [--json]",
        discussion: "Two calls are required: first run --dry-run to receive a short-lived token, then rerun with the same payload and --token TOKEN --confirm. Any payload change invalidates the token. Example: vmemo rename --id opaque-recording-id --title \"New title\" --dry-run --json"
    )
    @Option(name: .long, help: "Opaque recording identifier (required).") var id: String
    @Option(name: .long, help: "New user-visible title (required).") var title: String
    @OptionGroup var mutation: MutationOptions
    @OptionGroup var output: OutputOptions

    func request() -> CommandRequest {
        .mutation(
            request: MutationRequest(id: RecordingID(value: id), operation: .rename(title: title)),
            dryRun: mutation.dryRun,
            token: mutation.token,
            confirmed: mutation.confirm
        )
    }
}

private struct Delete: RoutedCommand {
    static let configuration = CommandConfiguration(
        abstract: "Move one recording to Recently Deleted.",
        usage: "vmemo delete --id <opaque-recording-id> (--dry-run | --token <token> --confirm) [--json]",
        discussion: "delete moves the recording to Recently Deleted. Two calls are required: first run --dry-run to receive a short-lived token, then rerun with the same payload and --token TOKEN --confirm. Any payload change invalidates the token. Example: vmemo delete --id opaque-recording-id --dry-run --json"
    )
    @Option(name: .long, help: "Opaque recording identifier (required).") var id: String
    @OptionGroup var mutation: MutationOptions
    @OptionGroup var output: OutputOptions

    func request() -> CommandRequest {
        .mutation(
            request: MutationRequest(id: RecordingID(value: id), operation: .moveToRecentlyDeleted),
            dryRun: mutation.dryRun,
            token: mutation.token,
            confirmed: mutation.confirm
        )
    }
}

private struct Doctor: RoutedCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check adapter availability and compatibility.",
        usage: "vmemo doctor [--ui] [--json]",
        discussion: "Ordinary mode does not check Accessibility. Add --ui to read current Accessibility trust; it is read-only and never prompts. Example: vmemo doctor --ui --json"
    )
    @Flag(name: .long, help: "Read Accessibility trust without prompting (read-only).") var ui = false
    @OptionGroup var output: OutputOptions

    func request() -> CommandRequest { .doctor(includeUI: ui) }
}

private struct OutputOptions: ParsableArguments {
    @Flag(name: .long, help: "Write a versioned JSON envelope.")
    var json = false

    var format: OutputFormat {
        json ? .json : .human
    }
}

private struct MutationOptions: ParsableArguments {
    @Flag(name: .long, help: "Return a mutation plan without executing it.")
    var dryRun = false

    @Option(name: .long, help: "Short-lived confirmation token.")
    var token: String?

    @Flag(name: .long, help: "Explicitly authorize execution with --token.")
    var confirm = false
}

private enum ProductionComposition {
    static let runner = CommandRunner(
        read: UnconfiguredReadPort(),
        asset: UnconfiguredAssetPort(),
        write: UnconfiguredWritePort(),
        doctor: SystemDoctorPort()
    )
}

private enum ProcessIO {
    static func write(_ result: CommandResult) {
        if !result.stdout.isEmpty {
            FileHandle.standardOutput.write(Data(result.stdout.utf8))
        }
        if !result.stderr.isEmpty {
            FileHandle.standardError.write(Data(result.stderr.utf8))
        }
    }
}
