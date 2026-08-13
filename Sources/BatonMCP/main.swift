import BatonCore
import Foundation

/// Entry point. Default behaviour is the MCP server on stdio. The extra
/// subcommands let you exercise the whole loop from a shell with no agent.
let arguments = Array(CommandLine.arguments.dropFirst())
let store = TaskStore()

switch arguments.first {
case nil, "serve", "mcp":
    MCPServer(store: store).run()

case "submit":
    CLI.submit(store: store, arguments: Array(arguments.dropFirst()))

case "list":
    CLI.list(store: store, arguments: Array(arguments.dropFirst()))

case "respond":
    CLI.respond(store: store, arguments: Array(arguments.dropFirst()))

case "watch":
    CLI.watch(store: store, arguments: Array(arguments.dropFirst()))

case "tools":
    print(JSONValue.array(ToolCatalog.all.map(\.descriptor)).prettyString())

case "doctor":
    CLI.doctor(store: store)

case "--version", "version":
    print(BatonVersion.current)

case "--help", "-h", "help":
    print(CLI.usage)

default:
    FileHandle.standardError.write(Data("Unknown command: \(arguments[0])\n\n\(CLI.usage)\n".utf8))
    exit(2)
}
