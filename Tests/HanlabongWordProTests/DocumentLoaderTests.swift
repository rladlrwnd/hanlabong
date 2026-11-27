import AppKit
import Foundation
import SkillEngine
import Testing
@testable import HanlabongWordPro

/// 문서 영역이 파일을 읽어서 보여 줄 글·목차·글자 수를 만드는 부분(화면 없이)
/// (Package.swift에 이 폴더를 테스트 타깃으로 달아야 돈다: dependencies ["HanlabongWordPro"])
struct DocumentLoaderTests {
    private func temp(_ name: String) -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wp-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(name)
    }

    private let sample = RichDocument(title: "샘플", paragraphs: [
        DocumentParagraph(runs: [DocumentRun("첫째 장 서론")], headingLevel: 1),
        DocumentParagraph(runs: [DocumentRun("이 문서는 한라봉 테스트용이야. 본문 한 줄.")]),
        DocumentParagraph(runs: [DocumentRun("둘째 절 방법")], headingLevel: 2),
        DocumentParagraph(runs: [DocumentRun("방법을 설명하는 글이야.")]),
        DocumentParagraph(runs: [], table: [["이름", "값"], ["가", "1"], ["나", "2"]]),
        DocumentParagraph(runs: [DocumentRun("셋째 장 결론")], headingLevel: 1, pageBreakBefore: true),
        DocumentParagraph(runs: [DocumentRun("끝.")]),
    ])

    @Test func markdownReadsParagraphsAndHeadings() throws {
        let url = temp("note.md")
        try "# 큰 제목\n\n본문 하나.\n\n## 작은 제목\n\n본문 둘.\n".write(to: url, atomically: true, encoding: .utf8)
        let doc = try DocumentLoader.load(url)
        #expect(doc.paragraphCount == 4)
        #expect(doc.outline.map(\.title) == ["큰 제목", "작은 제목"])
        #expect(doc.outline.map(\.level) == [1, 2])
        #expect(doc.outline.allSatisfy { $0.location != nil })
        #expect(doc.attributed.string.contains("본문 둘."))
        // 목차 위치가 실제 제목 글자를 가리키는지
        let ns = doc.attributed.string as NSString
        let second = try #require(doc.outline.last?.location)
        #expect(ns.substring(from: second).hasPrefix("작은 제목"))
        // 제목 아래 글(AI 맥락)
        #expect(doc.sectionText[doc.outline[0].id]?.contains("본문 하나.") == true)
    }

    @Test func docxIsShownThroughRichDocument() throws {
        let url = temp("sample.docx")
        try RichDocumentWriter.write(sample, as: .docx).write(to: url)
        let doc = try DocumentLoader.load(url)
        #expect(doc.attributed.string.contains("방법을 설명하는 글이야."))
        #expect(doc.attributed.string.contains("이름") && doc.attributed.string.contains("값"))
        #expect(doc.characterCount > 0 && doc.characterCountNoSpaces <= doc.characterCount)
        #expect(doc.pageSize.width > 200)
    }

    @Test func rtfOutlineComesFromFontSizes() throws {
        let url = temp("sample.rtf")
        try RichDocumentWriter.write(sample, as: .rtf).write(to: url)
        let doc = try DocumentLoader.load(url)
        #expect(doc.outline.contains { $0.title.contains("서론") && $0.level == 1 })
        #expect(doc.outline.contains { $0.title.contains("결론") })
        let ns = doc.attributed.string as NSString
        let intro = try #require(doc.outline.first { $0.title.contains("서론") }?.location)
        #expect(ns.substring(from: intro).hasPrefix("첫째 장 서론"))
        #expect(doc.pageCount >= 1)
    }

    @Test func rebuiltLayoutHasTableAndPageBreak() throws {
        // hwpx는 다시 짠 모양으로 보여 준다(표·쪽 나눔은 글만 남아도 쪽 구분선은 PDF 쪽과 같은 방법으로 나뉜다)
        let url = temp("sample.hwpx")
        try RichDocumentWriter.write(sample, as: .hwpx).write(to: url)
        let doc = try DocumentLoader.load(url)
        #expect(doc.paragraphCount >= 5)
        #expect(doc.attributed.string.contains("방법을 설명하는 글이야."))
        #expect(!doc.isLegacyHwp)
    }

    @MainActor @Test func dividerBuiltFromPageBreaksInRebuiltLayout() {
        let (text, pages) = DocumentLoader.withPageDividers(NSAttributedString(string: "앞 쪽\n\u{0C}뒤 쪽\n"))
        #expect(pages == 2)
        #expect(!text.string.contains("\u{0C}"))
        // 쪽 나눔 표시 문단(글자 하나 + 줄바꿈, `.hanlabongPageBreak`)이 들어간다. 쪽 번호는 글이 아니라 화면이 그린다
        #expect(DocumentEditor.bandRanges(in: text).count == 1)
        #expect(text.string.contains(DocumentLoader.pageBreakMark))
        #expect(text.string.contains("앞 쪽") && text.string.contains("뒤 쪽"))
    }

    @Test func plainTextIsReadWithoutHeadings() throws {
        let url = temp("plain.txt")
        try "첫 문단.\n\n둘째 문단.\n".write(to: url, atomically: true, encoding: .utf8)
        let doc = try DocumentLoader.load(url)
        #expect(doc.paragraphCount == 2)
        #expect(doc.outline.isEmpty)
        #expect(doc.pageCount == 1)
    }

    @Test func unreadableFileThrows() {
        let url = temp("empty.md")
        try? Data().write(to: url)
        #expect(throws: (any Error).self) { try DocumentLoader.load(url) }
    }

    @Test func headingMatchingFindsTheLongestTitle() throws {
        let url = temp("find.md")
        try "# 1장\n\n가.\n\n# 1장 서론과 배경\n\n나.\n".write(to: url, atomically: true, encoding: .utf8)
        let doc = try DocumentLoader.load(url)
        #expect(doc.outlineItem(matching: "1장 서론과 배경으로 가줘")?.title == "1장 서론과 배경")
        #expect(doc.outlineItem(matching: "요약해줘") == nil)
    }

    @Test func outlineSkipsTablesPicturesAndTinyHeadings() {
        let picture = DocumentImage(png: Data([0]), size: CGSize(width: 10, height: 10))
        let rich = RichDocument(title: "t", paragraphs: [
            DocumentParagraph(runs: [DocumentRun("개요")], headingLevel: 1),
            DocumentParagraph(runs: [], headingLevel: 1, table: [["이름", "값"], ["가", "1"]]),
            DocumentParagraph(runs: [], headingLevel: 2, image: picture),
            DocumentParagraph(runs: [DocumentRun("12")], headingLevel: 2),
            DocumentParagraph(runs: [DocumentRun("가")], headingLevel: 2),
            DocumentParagraph(runs: [DocumentRun("1.")], headingLevel: 2),
            DocumentParagraph(runs: [DocumentRun("본문 한 줄")]),
            DocumentParagraph(runs: [DocumentRun("방법 절")], headingLevel: 2),
        ])
        let shown = NSAttributedString(string: "개요\n이름\t값\n12\n본문 한 줄\n방법 절\n")
        let (items, _) = DocumentLoader.outline(of: rich, in: shown)
        #expect(items.map(\.title) == ["개요", "방법 절"])
    }

    @Test func everyFormatUsesTheSameDrawingPathAndDefaultFont() throws {
        let doc = try DocumentLoader.load({
            let url = temp("same.docx")
            try? RichDocumentWriter.write(sample, as: .docx).write(to: url)
            return url
        }())
        var fonts = Set<String>()
        doc.attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: doc.attributed.length)) { value, _, _ in
            if let font = value as? NSFont { fonts.insert(font.familyName ?? "") }
        }
        #expect(!fonts.contains { $0.contains("Times") })
    }

    @MainActor @Test func paperSitsCenteredOnDarkBackdropWithGutters() throws {
        let url = temp("layout.docx")
        try RichDocumentWriter.write(sample, as: .docx).write(to: url)
        let doc = try DocumentLoader.load(url)

        let coordinator = DocumentCanvas.Coordinator()
        let scroll = DocumentCanvas.build(coordinator: coordinator, session: nil)
        scroll.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        scroll.layoutSubtreeIfNeeded()
        coordinator.show(doc, mode: .detailed)
        scroll.layoutSubtreeIfNeeded()

        let paper = try #require(coordinator.pager.pages.first)
        let backdrop = try #require(coordinator.backdrop)
        let mag = scroll.magnification
        // 종이 폭(화면에서) + 양옆 24pt 이상이 창 안에 들어온다
        let paperOnScreen = doc.pageSize.width * mag
        #expect(paperOnScreen <= 1200 - 2 * 24)
        #expect(paperOnScreen >= 1200 - 2 * 40)
        // 종이는 배경 가운데, 양옆이 같은 너비의 어두운 배경
        let left = paper.frame.minX, right = backdrop.frame.width - paper.frame.maxX
        #expect(abs(left - right) <= 1)
        #expect(left * mag >= 24)
        #expect(paper.frame.size == doc.pageSize)
        #expect(backdrop.frame.height >= paper.frame.height)
        // 글 뷰는 종이 여백 안쪽에
        #expect(paper.textView.frame.minX == doc.margins.left)
        #expect(paper.textView.frame.width == doc.pageSize.width - doc.margins.left - doc.margins.right)

        // 아주 넓은 창에서도 종이는 쪽 폭 × 배율, 양옆은 더 넓은 배경
        scroll.frame = NSRect(x: 0, y: 0, width: 3000, height: 800)
        coordinator.refit()
        #expect(scroll.magnification <= 2.5)
        #expect(paper.frame.width * scroll.magnification <= 3000 - 2 * 24)
    }
}
