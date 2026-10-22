import Foundation

// stdio ⇄ Streamable HTTP bridge, for MCP clients that launch servers as
// subprocesses (Claude Desktop and most others). Each line on stdin is one
// JSON-RPC message; each response is written as one line on stdout.
// The app must be running; it serves http://127.0.0.1:7337/mcp.

let endpoint = URL(string: ProcessInfo.processInfo.environment["SCRIPTORIUM_MCP_URL"] ?? "http://127.0.0.1:7337/mcp")!
var sessionID: String?
let session = URLSession(configuration: .ephemeral)
setvbuf(stdout, nil, _IOLBF, 0)

func log(_ s: String) { FileHandle.standardError.write(Data(("scriptorium-mcp: " + s + "\n").utf8)) }

func errorReply(for line: String, _ message: String) -> String? {
    guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let id = obj["id"] else { return nil }
    let reply: [String: Any] = ["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": message]]
    return (try? JSONSerialization.data(withJSONObject: reply)).flatMap { String(data: $0, encoding: .utf8) }
}

while let line = readLine(strippingNewline: true) {
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = 120
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
    request.httpBody = Data(line.utf8)

    let done = DispatchSemaphore(value: 0)
    var output: String?
    session.dataTask(with: request) { data, response, error in
        defer { done.signal() }
        if let error {
            output = errorReply(for: line, "Scriptorium is not reachable (\(error.localizedDescription)). Is the app running?")
            return
        }
        if let http = response as? HTTPURLResponse, let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = sid }
        if let data, !data.isEmpty { output = String(data: data, encoding: .utf8) }
    }.resume()
    done.wait()
    if let output { print(output.replacingOccurrences(of: "\n", with: " ")) }
}
