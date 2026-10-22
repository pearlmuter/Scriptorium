import XCTest
@testable import ScriptoriumCore

final class OutlineTests: XCTestCase {
    func testNumbersParagraphsAndSentences() {
        let text = "# Title\nThe flow is calm. It runs south.\n\n- A list item. Two.\n> Quoted."
        let o = Outline(text: text)
        XCTAssertEqual(o.paragraphs.count, 4)
        XCTAssertEqual(o.blocks[0].kind, .heading(level: 1))
        XCTAssertEqual(o.blocks[0].number, 1)
        XCTAssertEqual((text as NSString).substring(with: o.paragraph(1)!.sentences[0].range), "Title")
        let p1 = o.paragraph(2)!
        XCTAssertEqual(p1.sentences.count, 2)
        let ns = text as NSString
        XCTAssertEqual(ns.substring(with: p1.sentences[1].range), "It runs south.")
        XCTAssertEqual(o.paragraph(3)!.kind, .listItem)
        XCTAssertEqual(ns.substring(with: o.paragraph(3)!.sentences[0].range), "A list item.")
        XCTAssertEqual(o.paragraph(4)!.kind, .quote)
    }

    func testAbbreviationsDoNotSplitSentences() {
        let o = Outline(text: "Dr. Smith met Mr. Jones at 3 p.m. on Friday. Then they left.")
        XCTAssertEqual(o.paragraph(1)!.sentences.count, 2)
    }

    func testCodeFencesAreNotNumbered() {
        let o = Outline(text: "Intro.\n```\nlet x = 1. y\n```\nOutro.")
        XCTAssertEqual(o.paragraphs.count, 2)
        XCTAssertEqual(o.paragraph(2)!.range.location, ("Intro.\n```\nlet x = 1. y\n```\n" as NSString).length)
    }

    func testAddressOfOffset() {
        let text = "One. Two.\nThree."
        let o = Outline(text: text)
        XCTAssertEqual(o.address(of: 6)?.paragraph, 1)
        XCTAssertEqual(o.address(of: 6)?.sentence, 2)
        XCTAssertEqual(o.address(of: (text as NSString).length)?.paragraph, 2)
    }
}

final class MarkdownTests: XCTestCase {
    func testRoundTrip() {
        let editor = "# Heading\nFirst paragraph. With **bold**.\nSecond.\n- a\n- b\n```\ncode\n  indented\n```\nLast."
        let md = MarkdownFile.markdown(fromEditorText: editor)
        XCTAssertEqual(md, "# Heading\n\nFirst paragraph. With **bold**.\n\nSecond.\n\n- a\n- b\n\n```\ncode\n  indented\n```\n\nLast.\n")
        XCTAssertEqual(MarkdownFile.editorText(fromMarkdown: md), editor)
    }

    func testSoftWrappedProseJoins() {
        XCTAssertEqual(MarkdownFile.editorText(fromMarkdown: "A line\nwrapped here.\n\nNext."), "A line wrapped here.\nNext.")
    }

    func testPlainText() {
        let plain = MarkdownFile.plainText(fromEditorText: "## Title\nSome **bold** and *it* and [link](http://x).\n- item")
        XCTAssertEqual(plain, "Title\n\nSome bold and it and link.\n\n• item\n")
    }

    func testInlineSpans() {
        let spans = InlineMarkdown.spans(in: "a **b** *c* `*d*`")
        XCTAssertEqual(spans.map(\.kind), [.code, .strong, .emphasis])
    }
}

final class TextOperationsTests: XCTestCase {
    let doc = "# Notes\nThe river is wide. The flow is gentle and slow.\nSecond paragraph here."

    func testReplaceWithinSentence() throws {
        let edit = try TextOperations.replace("flow", with: "fleur", paragraph: 2, sentence: 2, in: doc)
        XCTAssertEqual(edit.applied(to: doc), "# Notes\nThe river is wide. The fleur is gentle and slow.\nSecond paragraph here.")
    }

    func testReplaceFallsBackToParagraphWhenSentenceIsWrong() throws {
        let edit = try TextOperations.replace("flow", with: "fleur", paragraph: 2, sentence: 1, in: doc)
        XCTAssertTrue(edit.applied(to: doc).contains("The fleur is"))
    }

    func testAmbiguousQuoteFails() {
        XCTAssertThrowsError(try TextOperations.replace("The", with: "A", paragraph: 2, sentence: nil, in: doc))
        XCTAssertNoThrow(try TextOperations.replace("The", with: "A", paragraph: 2, sentence: nil, occurrence: 2, in: doc))
    }

    func testMissingParagraphExplains() {
        XCTAssertThrowsError(try TextOperations.replace("x", with: "y", paragraph: 9, sentence: nil, in: doc)) { error in
            XCTAssertTrue(error.localizedDescription.contains("3 paragraphs"))
        }
    }

    func testCaseAndQuoteInsensitiveFallback() throws {
        let text = "It’s the river."
        let edit = try TextOperations.replace("it's THE", with: "It is the", paragraph: 1, sentence: nil, in: text)
        XCTAssertEqual(edit.applied(to: text), "It is the river.")
    }

    func testDeleteTidiesSpaces() throws {
        let text = "Hello there new paragraph world."
        XCTAssertEqual(try TextOperations.delete("there", paragraph: 1, sentence: nil, in: text).applied(to: text), "Hello new paragraph world.")
        let t2 = "Sentence done. Go to paragraph one."
        XCTAssertEqual(try TextOperations.delete("Go to paragraph one.", paragraph: 1, sentence: nil, in: t2).applied(to: t2), "Sentence done.")
        let t3 = "Um, hello."
        XCTAssertEqual(try TextOperations.delete("Um,", paragraph: 1, sentence: nil, in: t3).applied(to: t3), "hello.")
    }

    func testSplitParagraphRemovingSpokenCommand() throws {
        let text = "The day was long. New paragraph. the night was short."
        let edit = try TextOperations.splitParagraph(paragraph: 1, at: "New paragraph.", removeMatched: true, in: text)
        XCTAssertEqual(edit.applied(to: text), "The day was long.\nThe night was short.")
    }

    func testSplitWithoutRemoval() throws {
        let text = "One thing. Another thing."
        XCTAssertEqual(try TextOperations.splitParagraph(paragraph: 1, at: "Another", removeMatched: false, in: text).applied(to: text), "One thing.\nAnother thing.")
    }

    func testSplitAtEndLeavesEmptyNewParagraph() throws {
        let text = "Done here, new paragraph"
        XCTAssertEqual(try TextOperations.splitParagraph(paragraph: 1, at: "new paragraph", removeMatched: true, in: text).applied(to: text), "Done here\n")
    }

    func testMerge() throws {
        let text = "One.\nTwo."
        XCTAssertEqual(try TextOperations.mergeParagraphs(1, in: text).applied(to: text), "One. Two.")
    }

    func testInsert() throws {
        let text = "The cat sat."
        XCTAssertEqual(try TextOperations.insert("black", paragraph: 1, after: "The", before: nil, in: text).applied(to: text), "The black cat sat.")
        XCTAssertEqual(try TextOperations.insert("Then it slept.", paragraph: 1, after: nil, before: nil, in: text).applied(to: text), "The cat sat. Then it slept.")
    }

    func testInsertAndDeleteParagraph() throws {
        let text = "A.\nB."
        XCTAssertEqual(try TextOperations.insertParagraph(after: 1, text: "Mid.", in: text).applied(to: text), "A.\nMid.\nB.")
        XCTAssertEqual(try TextOperations.insertParagraph(after: 0, text: "Top.", in: text).applied(to: text), "Top.\nA.\nB.")
        XCTAssertEqual(try TextOperations.deleteParagraph(1, in: text).applied(to: text), "B.")
        XCTAssertEqual(try TextOperations.deleteParagraph(2, in: text).applied(to: text), "A.")
    }

    func testFormat() throws {
        let text = "Make this bold please.\n- item"
        XCTAssertEqual(try TextOperations.format(.bold, paragraph: 1, find: "this bold", in: text).applied(to: text), "Make **this bold** please.\n- item")
        XCTAssertEqual(try TextOperations.format(.heading2, paragraph: 1, find: nil, in: text).applied(to: text), "## Make this bold please.\n- item")
        XCTAssertEqual(try TextOperations.format(.plain, paragraph: 2, find: nil, in: text).applied(to: text), "Make this bold please.\nitem")
    }

    func testEditTransformsOffsets() {
        let edit = TextEdit(range: NSRange(location: 4, length: 3), replacement: "abcde")
        XCTAssertEqual(edit.transform(2), 2)
        XCTAssertEqual(edit.transform(5), 9)
        XCTAssertEqual(edit.transform(10), 12)
    }
}

final class DictationTests: XCTestCase {
    func testReflexCatchesNewParagraphAcrossChunks() {
        var r = CommandReflex()
        XCTAssertEqual(r.feed(" It was late."), [.text(" It was late.")])
        XCTAssertEqual(r.feed(" New"), [])
        XCTAssertEqual(r.feed(" paragraph."), [.paragraphBreak])
        XCTAssertEqual(r.feed(" The"), [.text(" The")])
    }

    func testReflexReleasesOrdinaryNew() {
        var r = CommandReflex()
        XCTAssertEqual(r.feed(" a new"), [.text(" a")])
        XCTAssertEqual(r.feed(" idea"), [.text(" new idea")])
        XCTAssertEqual(r.feed(" brand new"), [.text(" brand")])
        XCTAssertEqual(r.flush(), [.text(" new")])
    }

    func testReflexWithinOneChunk() {
        var r = CommandReflex()
        XCTAssertEqual(r.feed(" end. New line. Start"), [.text(" end."), .paragraphBreak, .text(" Start")])
    }

    func testComposerSpacingAndCapitalisation() {
        var (e, c) = DictationComposer.insert(" hello", at: 0, in: "")
        XCTAssertEqual(e.applied(to: ""), "Hello"); XCTAssertEqual(c, 5)
        (e, c) = DictationComposer.insert("world", at: 5, in: "Hello")
        XCTAssertEqual(e.applied(to: "Hello"), "Hello world")
        (e, _) = DictationComposer.insert(" again", at: 7, in: "Done.\n\n")
        XCTAssertEqual(e.applied(to: "Done.\n\n"), "Done.\n\nAgain")
        (e, _) = DictationComposer.insert(" next", at: 5, in: "Done.")
        XCTAssertEqual(e.applied(to: "Done."), "Done. Next")
        (e, c) = DictationComposer.insert(" very", at: 4, in: "The cat")
        XCTAssertEqual(e.applied(to: "The cat"), "The very cat")
        XCTAssertEqual(c, 8)
        (e, _) = DictationComposer.insert(" item", at: 2, in: "- ")
        XCTAssertEqual(e.applied(to: "- "), "- Item")
    }

    func testParagraphBreakEndsSentenceLeftWithComma() {
        let text = "the house went quiet, "
        let (e, c) = DictationComposer.paragraphBreak(at: 22, in: text)
        XCTAssertEqual(e.applied(to: text), "the house went quiet.\n")
        XCTAssertEqual(c, 22)
    }

    func testParagraphBreakTrimsSpaces() {
        let (e, c) = DictationComposer.paragraphBreak(at: 6, in: "Hello ")
        XCTAssertEqual(e.applied(to: "Hello "), "Hello\n")
        XCTAssertEqual(c, 6)
    }
}


final class NarrationTests: XCTestCase {
    func testPassagesAreSentencesWithoutMarkdown() {
        let text = "# Title\nThe **river** was wide. Yes. It was cold that year.\n- A list item here, long enough to stand alone.\nLast."
        let p = Narration.passages(from: 2, to: 4, in: text)
        XCTAssertEqual(p.map(\.text), ["The river was wide. Yes. It was cold that year.", "A list item here, long enough to stand alone.", "Last."])
        XCTAssertEqual(p.map(\.paragraph), [2, 3, 4])
        XCTAssertEqual(p.first?.sentence, 1)
        XCTAssertEqual(Narration.passages(from: 2, to: 2, sentence: 3, in: text).map(\.text), ["It was cold that year."])
        XCTAssertEqual(Narration.passages(from: 1, to: 1, in: text).map(\.text), ["Title"])
    }
}
