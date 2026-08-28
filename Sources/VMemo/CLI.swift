import ArgumentParser
import Foundation

struct VMemo: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vmemo",
        abstract: "Safely inspect and manage Voice Memos recordings.",
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
    static let configuration = CommandConfiguration(abstract: "List recordings.")
    @OptionGroup var output: OutputOptions

    func request() -> CommandRequest { .list }
}

private struct Search: RoutedCommand {
    static let configuration = CommandConfiguration(abstract: "Search recordings.")
    @Option(name: .long, help: "Search text.") var query: String
    @OptionGroup var output: OutputOptions

    func request() -> CommandRequest { .search(query: query) }
}

private struct Show: RoutedCommand {
    static let configuration = CommandConfiguration(abstract: "Show one recording.")
    @Option(name: .long, help: "Opaque recording identifier.") var id: String
    @OptionGroup var output: OutputOptions

    func request() -> CommandRequest { .show(id: RecordingID(value: id)) }
}

private struct Export: RoutedCommand {
    static let configuration = CommandConfiguration(abstract: "Export one recording.")
    @Option(name: .long, help: "Opaque recording identifier.") var id: String
    @Option(name: .long, help: "Destination owned by the caller.") var outputPath: String
    @OptionGroup var output: OutputOptions

    func request() -> CommandRequest { .export(id: RecordingID(value: id), destination: outputPath) }
}

private struct Rename: RoutedCommand {
    static let configuration = CommandConfiguration(abstract: "Rename one recording.")
    @Option(name: .long, help: "Opaque recording identifier.") var id: String
    @Option(name: .long, help: "New user-visible title.") var title: String
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
    static let configuration = CommandConfiguration(abstract: "Move one recording to Recently Deleted.")
    @Option(name: .long, help: "Opaque recording identifier.") var id: String
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
    static let configuration = CommandConfiguration(abstract: "Check adapter availability and compatibility.")
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
        write: UnconfiguredWritePort()
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
