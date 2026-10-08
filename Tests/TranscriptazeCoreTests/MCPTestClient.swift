import Foundation
@testable import TranscriptazeCore

/// A minimal MCP client over Streamable HTTP, for exercising the server in tests.
public final class MCPClient: @unchecked Sendable {
    public struct Tool { public let name: String; public let description: String; public let inputSchema: [String: Any] }

    let endpoint: URL
    private var sessionID: String?
    private var nextID = 1
    private let session: URLSession

    public init(endpoint: URL) {
        self.endpoint = endpoint
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 90
        self.session = URLSession(configuration: config)
    }

    private func rpc(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let id = nextID; nextID += 1
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = sid }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw OperationError("Bad MCP response") }
        if let error = json["error"] as? [String: Any] { throw OperationError("MCP error: \(error["message"] ?? "")") }
        return json["result"] as? [String: Any] ?? [:]
    }

    public func initialize() async throws {
        _ = try await rpc("initialize", [
            "protocolVersion": MCPHandler.supportedVersions[0],
            "capabilities": [:],
            "clientInfo": ["name": "transcriptaze-guardian", "version": "1.0.0"],
        ])
    }

    public func listTools() async throws -> [Tool] {
        let result = try await rpc("tools/list", [:])
        return (result["tools"] as? [[String: Any]] ?? []).compactMap {
            guard let name = $0["name"] as? String else { return nil }
            return Tool(name: name, description: $0["description"] as? String ?? "", inputSchema: $0["inputSchema"] as? [String: Any] ?? [:])
        }
    }

    /// Returns the tool's text; a tool-level error comes back as text with isError, which the model should see.
    public func callTool(_ name: String, arguments: [String: Any]) async throws -> (text: String, isError: Bool) {
        let result = try await rpc("tools/call", ["name": name, "arguments": arguments])
        let text = (result["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
        return (text, result["isError"] as? Bool ?? false)
    }
}
