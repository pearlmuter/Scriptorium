import Foundation

/// One paste-able block that tells any LLM (or the person setting it up)
/// where the guardian MCP server is and what to do once connected.
public enum ConnectionCard {
    public static func text(endpoint: URL, bridgePath: String) -> String {
        let url = endpoint.absoluteString
        return """
        # Scriptorium guardian — MCP server

        Scriptorium is a dictation editor running on this Mac. Connect to its MCP server and act as the guardian of the open note.

        Streamable HTTP (no auth, localhost only): \(url)
        stdio bridge (for clients that launch servers): \(bridgePath)

        MCP servers are loaded when a session starts, so add it, then start a new session:

        Claude Code (desktop app or CLI), in the project's .mcp.json:
            { "mcpServers": { "scriptorium": { "type": "http", "url": "\(url)" } } }
        or, with the claude CLI installed:
            claude mcp add --transport http scriptorium \(url)

        Claude Desktop and other stdio clients (mcpServers):
            "scriptorium": { "command": "\(bridgePath)" }

        Already in a session that can run shell commands? You can be the guardian now,
        without adding anything: call the tools as JSON-RPC over HTTP, e.g.
            curl -s \(url) -H 'Content-Type: application/json' \\
              -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}'
            curl -s \(url) -H 'Content-Type: application/json' \\
              -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"wait_for_dictation","arguments":{"timeout_seconds":50}}}'
        (initialize returns the full instructions; tools/list lists every tool.)

        Once connected, loop:
        1. wait_for_dictation — returns the note numbered ¶paragraph [sentence]; • marks freshly dictated text; new chat messages appear under CHAT.
        2. Carry out spoken commands (e.g. "go to paragraph 2, sentence 2 and change flow for fleur"), then delete the command words. Fix clearly misheard words and punctuation. Never rephrase the author unasked.
        3. Answer chat messages with reply_in_chat. Highlight with highlight_text (green = confirmed, yellow = partly true, pink = false).
        4. finish_review with the review_token. Repeat.
        Full instructions arrive with the server's initialize response.
        """
    }
}
