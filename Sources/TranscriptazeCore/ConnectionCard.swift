import Foundation

/// One paste-able block that tells any LLM (or the person setting it up)
/// where the guardian MCP server is and what to do once connected.
public enum ConnectionCard {
    public static func text(endpoint: URL, bridgePath: String) -> String {
        let url = endpoint.absoluteString
        return """
        # Transcriptaze guardian — MCP server

        Transcriptaze is a dictation editor running on this Mac. Connect to its MCP server and act as the guardian of the open note.

        Streamable HTTP (no auth, localhost only): \(url)
        stdio bridge (for clients that launch servers): \(bridgePath)

        Claude Code:
            claude mcp add --transport http transcriptaze \(url)

        mcpServers config (HTTP clients):
            "transcriptaze": { "type": "http", "url": "\(url)" }

        mcpServers config (stdio clients, e.g. Claude Desktop):
            "transcriptaze": { "command": "\(bridgePath)" }

        Once connected, loop:
        1. wait_for_dictation — returns the note numbered ¶paragraph [sentence]; • marks freshly dictated text.
        2. Carry out spoken commands (e.g. "go to paragraph 2, sentence 2 and change flow for fleur"), then delete the command words. Fix clearly misheard words and punctuation. Never rephrase the author.
        3. finish_review with the review_token. Repeat.
        Full instructions arrive with the server's initialize response.
        """
    }
}
