import Foundation
import Network

/// Model Context Protocol over JSON-RPC: initialize, tools/list, tools/call.
@MainActor
public final class MCPHandler {
    public static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    let toolbox: GuardianToolbox
    /// Called for every tool call, for the app's activity log.
    public var onToolCall: ((String, [String: Any], Result<String, Error>) -> Void)?

    public init(toolbox: GuardianToolbox) { self.toolbox = toolbox }

    /// Sent on initialize, so any connecting LLM knows its job and its loop.
    public static let instructions = GuardianInstructions.text

    /// Handles one JSON-RPC message (or batch). Returns nil for notifications.
    public func handle(_ data: Data) async -> Data? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        if let batch = json as? [[String: Any]] {
            var responses: [[String: Any]] = []
            for message in batch { if let r = await respond(message) { responses.append(r) } }
            return responses.isEmpty ? nil : try? JSONSerialization.data(withJSONObject: responses)
        }
        guard let message = json as? [String: Any] else { return nil }
        return await respond(message).flatMap(encode)
    }

    private func encode(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object)
    }

    func respond(_ message: [String: Any]) async -> [String: Any]? {
        guard let method = message["method"] as? String else { return nil } // a response; we send no requests
        guard let id = message["id"] else { return nil } // notification
        let params = message["params"] as? [String: Any] ?? [:]
        func ok(_ result: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": result] }
        func fail(_ code: Int, _ msg: String) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": msg]] }

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            let version = Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[0]
            return ok([
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "scriptorium", "version": "1.0.0"],
                "instructions": Self.instructions,
            ])
        case "ping":
            return ok([:])
        case "tools/list":
            return ok(["tools": GuardianToolbox.specs.map {
                ["name": $0.name, "description": $0.description, "inputSchema": $0.inputSchema] as [String: Any]
            }])
        case "tools/call":
            guard let name = params["name"] as? String else { return fail(-32602, "Missing tool name") }
            guard GuardianToolbox.specs.contains(where: { $0.name == name }) else { return fail(-32602, "Unknown tool: \(name)") }
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                let text = try await toolbox.call(name, arguments: args)
                onToolCall?(name, args, .success(text))
                return ok(["content": [["type": "text", "text": text]], "isError": false])
            } catch {
                onToolCall?(name, args, .failure(error))
                return ok(["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
            }
        case "resources/list": return ok(["resources": []])
        case "prompts/list": return ok(["prompts": []])
        default:
            return fail(-32601, "Method not found: \(method)")
        }
    }
}

/// Streamable-HTTP transport on loopback only. JSON responses, no SSE: every
/// tool returns one result, and the long-poll tool simply holds its request.
public final class MCPHTTPServer: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "mcp.http")
    private let handler: MCPHandler
    public private(set) var port: UInt16
    public var onStateChange: (@Sendable (String) -> Void)?
    /// Optional plain-text routes under /debug/, for test automation. Nil in normal use.
    public var debugHandler: (@MainActor (String, [String: String]) -> String)?

    public init(handler: MCPHandler, port: UInt16) {
        self.handler = handler
        self.port = port
    }

    public func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onStateChange?("listening")
            case .failed(let e): self?.onStateChange?("failed: \(e)")
            default: break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = HTTPRequest.parse(&buffer) {
                let rest = buffer
                self.serve(request, on: connection) {
                    if request.keepAlive { self.receive(on: connection, buffer: rest) } else { connection.cancel() }
                }
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func serve(_ request: HTTPRequest, on connection: NWConnection, then: @escaping @Sendable () -> Void) {
        func send(_ status: String, _ body: Data = Data(), headers: [String: String] = [:]) {
            var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\n"
            for (k, v) in headers { head += "\(k): \(v)\r\n" }
            head += request.keepAlive ? "Connection: keep-alive\r\n\r\n" : "Connection: close\r\n\r\n"
            var payload = Data(head.utf8)
            payload.append(body)
            connection.send(content: payload, completion: .contentProcessed { _ in then() })
        }
        // DNS-rebinding defence: a browser origin must itself be local.
        if let origin = request.headers["origin"], !(origin.contains("://127.0.0.1") || origin.contains("://localhost") || origin == "null") {
            send("403 Forbidden"); return
        }
        if request.path.hasPrefix("/debug/"), let debug = debugHandler {
            let comps = URLComponents(string: request.path.replacingOccurrences(of: "+", with: "%20"))
            var query: [String: String] = [:]
            for item in comps?.queryItems ?? [] { query[item.name] = item.value ?? "" }
            let path = comps?.path ?? request.path
            Task { @MainActor in send("200 OK", Data(debug(path, query).utf8), headers: ["Content-Type": "text/plain; charset=utf-8"]) }
            return
        }
        guard request.path.hasPrefix("/mcp") else { send("404 Not Found"); return }
        switch request.method {
        case "POST":
            let body = request.body
            let session = request.headers["mcp-session-id"] ?? UUID().uuidString
            let handler = self.handler
            Task { @MainActor in
                let response = await handler.handle(body)
                let headers = ["Content-Type": "application/json", "Mcp-Session-Id": session]
                if let response { send("200 OK", response, headers: headers) } else { send("202 Accepted", headers: headers) }
            }
        case "DELETE":
            send("200 OK")
        case "GET":
            send("405 Method Not Allowed", headers: ["Allow": "POST, DELETE"])
        default:
            send("405 Method Not Allowed")
        }
    }
}

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
    var keepAlive: Bool { headers["connection"]?.lowercased() != "close" }

    /// Consumes one complete request from the buffer, if present.
    static func parse(_ buffer: inout Data) -> HTTPRequest? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return nil }
        let bodyEnd = buffer.index(bodyStart, offsetBy: length)
        let body = Data(buffer[bodyStart..<bodyEnd])
        buffer = Data(buffer[bodyEnd...])
        return HTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers, body: body)
    }
}
