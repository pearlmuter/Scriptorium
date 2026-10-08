# Transcriptaze

A minimalist macOS writing app for dictation. You speak, Kyutai STT streams words onto the page at your cursor, and a **guardian**, any LLM you connect through **MCP**, reads along and edits the note while you keep talking. It fixes misheard words and carries out spoken commands. The app runs no LLM of its own: the guardian should be one that already knows your work.

Notes are plain `.md` files in `~/Documents/Transcriptaze`. They export as Markdown or plain text.

## The page

- **Book layout** by default: justified and hyphenated, first-line indents instead of gaps between paragraphs, ~65-character measure, New York serif with old-style figures. *Manuscript* (ragged, spaced) is the alternative.
- **Chapter and verse.** Every paragraph is numbered in the margin (¶). Every sentence from the second on gets a small raised vermilion numeral, as verses do in a printed Bible. The numbers are drawn, not typed, so the file stays clean Markdown. Toggle with ⇧⌘L or the ¶ button.
- **Two cursors.** Yours is ink. The guardian's is a lapis bar with a diamond cap, and it washes the text it has just changed.
- **Wet ink.** Dictated text is drawn lighter until the guardian has read it.
- **WriteRoom manners.** The format bar fades while you type or speak and returns when you move the mouse. Focus mode (⌃⇧⌘F) hides everything but the page.
- **Highlights** in three inks: yellow, green and pink. Select text and three swatches appear in the right margin beside it; click one (or ⌥⌘1–3, ⌥⌘0 to remove). A click on a highlight wipes it away (⌘Z brings it back), and any edit inside one dismisses it. The guardian highlights too. Its highlights carry a small lapis diamond and a note you can read on hover. For fact-checking the convention is green = confirmed, yellow = partly true, pink = false. Highlights live beside the note in `.transcriptaze/<note>.json`, never in the Markdown.
- Markdown formatting: ⌘B ⌘I ⌘K, ⌘1–3 headings, ⌘0 body, plus quote, lists, code and strike from the bar or the Format menu. Return continues a list.

## The chat

Between the notes and the page is a conversation with the guardian (⌃⌘C shows or hides it, ⇧⌘M jumps to it, Esc returns to the page). When you click into it, your caret stays on the page as a **ghost**: a thin bar with a ring, or a dotted underline under a selection. Each message carries what the ghost points at, so "is this right?" needs no explaining. It also works by voice alone: while dictating on the page, say "Guardian, …" and ask; the guardian moves your words into the chat and answers there. In the chat field, end with "send it" and pause. The guardian's edits appear in the conversation as quiet one-line notes. The chat is saved per note, with the highlights.

## Voice

⇧⌘D starts and stops dictation. The model is **Kyutai `stt-1b-en_fr-candle`**, run through Pendragon's Rust bridge (`Vendor/KyutaiKit`, Metal, about 26 ms per 80 ms frame on an M1 Max). The weights are reused from `~/Library/Application Support/Pendragon/Models/Kyutai`. You can also place them in `~/Library/Application Support/Transcriptaze/Models/Kyutai` or set `TRANSCRIPTAZE_STT_DIR`.

Dictation goes wherever you are writing: the page, or the chat field. "New paragraph" and "new line" act **instantly**: the words never reach the page. Everything else is left to the guardian. *Voice › Dictate from Audio File…* plays a recording through the same pipeline in real time.

## The guardian

The app serves MCP over Streamable HTTP at `http://127.0.0.1:7337/mcp`, on loopback only. **Any MCP-capable LLM can be the guardian.**

| Tool | What it does |
|---|---|
| `read_document` | The numbered note: `¶n [s] …`, fresh dictation marked `•`, your cursor, a `review_token` |
| `replace_text`, `rewrite_sentence`, `delete_text`, `insert_text` | Address by ¶ (and optionally sentence) plus an exact quote, so edits are safe while you keep talking |
| `split_paragraph`, `merge_paragraphs`, `insert_paragraph`, `delete_paragraph` | Paragraph structure |
| `format_text` | bold, italic, code, strike, heading1–3, quote, bullet, numbered, plain |
| `highlight_text`, `clear_highlights` | Yellow, green or pink, with an optional note shown on hover |
| `reply_in_chat`, `read_chat` | The conversation beside the note. New messages arrive in `wait_for_dictation`, with where the user's ghost cursor points |
| `scroll_to` | "Scroll to paragraph 3": shows it without moving your cursor |
| `move_user_cursor`, `focus` | Move your dictation cursor ("go to the end of paragraph 3"), or the guardian's own |
| `list_notes`, `read_note` | Other notes, for names and context |
| `wait_for_dictation`, `finish_review` | The loop for external guardians: block until fresh text or a chat message arrives, edit, then acknowledge |

**Connecting a guardian.** Click *Copy for LLM*, in the guardian panel (click "Guardian" in the footer), in Settings, or with ⌥⇧⌘C. It copies one block containing the address, ready-made config for HTTP and stdio clients, and the working loop. The server sends the full guardian instructions on `initialize`. The footer shows whether a guardian is connected and what it last changed.

For example, Claude Code:

```bash
claude mcp add --transport http transcriptaze http://127.0.0.1:7337/mcp
```

Claude Desktop and other stdio clients use the bundled bridge, `Transcriptaze.app/Contents/MacOS/transcriptaze-mcp`.

## The manual

*Help › Transcriptaze Manual* (⌘?) opens `Manual.pdf` in its own window. It is typeset from `Resources/Manual/manual.html` by `swift Scripts/make_manual.swift`, which also warns when a page overflows (`--preview <dir>` writes each page as PNG). Rebuild it after changing the app.

## Build and test

```bash
bash Scripts/build_app.sh --open      # release build → build/Transcriptaze.app
swift test                            # unit, MCP-over-HTTP, real Kyutai model
```

- **Real-model tests** skip when the weights are absent.
- `TRANSCRIPTAZE_NOTES_DIR` points the app at another notes folder (for test runs). `Scripts/dev_run.sh` launches with `TRANSCRIPTAZE_DEBUG=1`, which adds `/debug/*` routes (type, dictate a file, snapshot the window). Those routes are what the screenshots were taken with. They are off in normal use.
- Rebuild the Rust archive with `Vendor/KyutaiKit` and Pendragon's `Scripts/build_stt.sh`.
- `swift Scripts/make_icon.swift` regenerates the icon.

## Layout

- `Sources/TranscriptazeCore`: outline (¶/sentence numbering), Markdown conversion, text operations, dictation reflex, guardian toolbox and instructions, MCP server, note store, Kyutai wrapper. No AppKit.
- `Sources/Transcriptaze`: the SwiftUI and AppKit app: editor (TextKit 1 `NSTextView` drawing the numbers and the guardian's cursor), styler, dictation engine, guardian activity monitor, settings.
- `Sources/transcriptaze-mcp`: the stdio ⇄ HTTP bridge.

Transcription by Kyutai: stt-1b-en_fr, weights licensed CC-BY 4.0.
