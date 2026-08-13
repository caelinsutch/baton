import BatonCore
import Foundation

/// MCP over stdio. Messages are newline-delimited JSON-RPC 2.0.
///
/// Every agent process spawns its own copy of this binary. They all share one
/// SQLite file, so nothing here needs to know about the other processes or
/// about the app.
final class MCPServer {
    private let store: TaskStore
    private let tools: ToolHandlers
    private let output = FileHandle.standardOutput
    private let outputLock = NSLock()
    /// Tracks in-flight tool calls, so the process answers them before it exits
    /// when stdin closes.
    private let inFlight = DispatchGroup()
    private var isInitialized = false

    init(store: TaskStore) {
        self.store = store
        self.tools = ToolHandlers(store: store)
    }

    func run() {
        Log.write("baton-mcp started, db=\(BatonPaths.databaseURL.path)")
        do {
            try store.prepare()
        } catch {
            Log.write("store failed to open: \(error)")
            // Report the failure on the wire instead of dying silently. The
            // agent then sees a real error rather than a dead pipe.
        }

        var buffer = Data()
        while true {
            let chunk = FileHandle.standardInput.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = buffer[buffer.index(after: newline)...]
                handle(line: Data(line))
            }
        }
        Log.write("baton-mcp stdin closed, draining in-flight calls")
        // A blocking ask_human may still be waiting. Give it a bounded chance to
        // answer so the client sees a result instead of a dropped request.
        _ = inFlight.wait(timeout: .now() + Guardrails.maxBlockingWait)
        Log.write("baton-mcp exiting")
    }

    // MARK: - Dispatch

    private func handle(line: Data) {
        guard !line.isEmpty else { return }
        guard let message = try? JSONValue.parse(line), let object = message.objectValue else {
            send(error: -32700, message: "Parse error", id: .null)
            return
        }

        let id = object["id"] ?? .null
        guard let method = object["method"]?.stringValue else {
            // A response to something we sent. This server sends no requests.
            return
        }
        let params = object["params"] ?? .object([:])
        let isNotification = object["id"] == nil

        switch method {
        case "initialize":
            isInitialized = true
            send(result: initializeResult(clientParams: params), id: id)

        case "notifications/initialized", "initialized":
            break

        case "ping":
            send(result: .object([:]), id: id)

        case "tools/list":
            send(result: .object(["tools": .array(ToolCatalog.all.map(\.descriptor))]), id: id)

        case "tools/call":
            handleToolCall(params: params, id: id)

        case "resources/list":
            send(result: .object(["resources": .array([])]), id: id)

        case "prompts/list":
            send(result: .object(["prompts": .array([])]), id: id)

        default:
            if isNotification { return }
            send(error: -32601, message: "Unknown method: \(method)", id: id)
        }
    }

    private func initializeResult(clientParams: JSONValue) -> JSONValue {
        // Echo the client's protocol version when it sends one. Falls back to
        // the version this server was written against.
        let version = clientParams["protocolVersion"]?.stringValue ?? "2025-06-18"
        return .object([
            "protocolVersion": .string(version),
            "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
            "serverInfo": .object([
                "name": "baton",
                "title": "Baton",
                "version": .string(BatonVersion.current),
            ]),
            "instructions": .string(ToolCatalog.serverInstructions),
        ])
    }

    private func handleToolCall(params: JSONValue, id: JSONValue) {
        guard let name = params["name"]?.stringValue else {
            send(error: -32602, message: "tools/call needs a name", id: id)
            return
        }
        let arguments = params["arguments"] ?? .object([:])

        // A blocking tool must not stall the read loop, or the client cannot
        // cancel and a second call would queue behind the first.
        inFlight.enter()
        // Capture strongly. A weak capture that fails would skip `leave()` and
        // hang the drain on exit.
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { inFlight.leave() }
            do {
                let value = try tools.call(name: name, arguments: arguments)
                send(result: Self.toolSuccess(value), id: id)
            } catch {
                send(result: Self.toolFailure(error), id: id)
            }
        }
    }

    // MARK: - Tool result envelopes

    /// MCP wants tool output as content blocks. Send readable text plus the
    /// structured value, because clients differ in what they surface.
    private static func toolSuccess(_ value: JSONValue) -> JSONValue {
        .object([
            "content": .array([.object(["type": "text", "text": .string(value.prettyString())])]),
            "structuredContent": value,
            "isError": .bool(false),
        ])
    }

    private static func toolFailure(_ error: Swift.Error) -> JSONValue {
        let text = String(describing: error)
        return .object([
            "content": .array([.object(["type": "text", "text": .string(text)])]),
            "isError": .bool(true),
        ])
    }

    // MARK: - Transport

    private func send(result: JSONValue, id: JSONValue) {
        guard !id.isNull else { return }
        write(.object(["jsonrpc": "2.0", "id": id, "result": result]))
    }

    private func send(error code: Int, message: String, id: JSONValue) {
        write(.object([
            "jsonrpc": "2.0",
            "id": id,
            "error": .object(["code": .number(Double(code)), "message": .string(message)]),
        ]))
    }

    private func write(_ value: JSONValue) {
        var data = value.serialized()
        data.append(0x0A)
        outputLock.lock()
        defer { outputLock.unlock() }
        // stdout is the protocol channel. Never print anything else to it.
        try? output.write(contentsOf: data)
    }
}

enum BatonVersion {
    static let current = "0.1.0"
}

/// File logging. stdout belongs to the protocol, and stderr can confuse a host.
enum Log {
    private static let lock = NSLock()
    private static let enabled = ProcessInfo.processInfo.environment["BATON_LOG"] != "0"

    static func write(_ message: String) {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        BatonPaths.ensureSupportDirectory()
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] pid=\(getpid()) \(message)\n"
        let url = BatonPaths.logURL
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
