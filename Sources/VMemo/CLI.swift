import ArgumentParser
import Foundation

struct VMemo: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vmemo",
        abstract: "Inspect Voice Memos recordings.",
        usage: "vmemo <subcommand>",
        discussion: """
        Agent-facing CLI with a stable, fail-closed contract.

        Output: human reports go to stdout; diagnostics go to stderr. Add --json for the version 1 JSON envelope (version: 1, status, and data or error).
        Exit codes: 0 success, 2 usage error, 3 operational/output error, 4 safety or adapter block, 5 partial/incomplete result.
        Recording IDs are opaque and must be passed exactly as returned.

        Examples:
          vmemo list --json
          vmemo show --id opaque-recording-id --json
        """,
        version: ProductVersion.current,
        subcommands: [List.self, Search.self, Show.self, Export.self, Doctor.self]
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
            if VMemo.exitCode(for: error).isSuccess {
                VMemo.exit(withError: error)
            }
            if CommandLine.arguments.contains("--json") {
                let result = CommandResult.usage(message: VMemo.fullMessage(for: error))
                ProcessIO.write(result)
                exit(result.exitCode)
            }
            let result = CommandResult(
                exitCode: ProcessExit.usage.rawValue,
                stdout: "",
                stderr: "error: \(VMemo.message(for: error))\nUsage: vmemo <subcommand>\n"
            )
            ProcessIO.write(result)
            exit(result.exitCode)
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
        discussion: "Search titles only; recording content is not searched. Example: vmemo search --query meeting --json"
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

private struct Doctor: RoutedCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check adapter availability and compatibility.",
        usage: "vmemo doctor [--json]",
        discussion: "Check runtime, application, library, schema, and signing readiness. Example: vmemo doctor --json"
    )
    @OptionGroup var output: OutputOptions

    func request() -> CommandRequest { .doctor }
}

private struct OutputOptions: ParsableArguments {
    @Flag(name: .long, help: "Write a versioned JSON envelope.")
    var json = false

    var format: OutputFormat {
        json ? .json : .human
    }
}

private enum ProductionComposition {
    static let runner = SystemProductionAdapterFactory.makeRunner()
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
