import AppKit
import Foundation
import SkillEngine
import Testing
@testable import HanlabongWordPro

/// 문서 영역 2단계(편집·저장)를 화면 없이: 읽기 → 종이(NSTextView)에서 고치기 → document(from:) → 쓰고 다시 읽기
@MainActor
struct DocumentEditingTests {
    private func folder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wp-edit-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private let sample = RichDocument(title: "샘플", paragraphs: [
        DocumentParagraph(runs: [DocumentRun("첫째 장 서론")], headingLevel: 1),
        DocumentParagraph(runs: [DocumentRun("이 문서는 한라봉 테스트용이야. 본문 한 줄.")]),
        DocumentParagraph(runs: [DocumentRun("둘째 절 방법")], headingLevel: 2),
        DocumentParagraph(runs: [DocumentRun("방법을 설명하는 글이야.")]),
        DocumentParagraph(runs: [], table: [["이름", "값"], ["가", "1"], ["나", "2"]]),
        DocumentParagraph(runs: [DocumentRun("셋째 장 결론")], headingLevel: 1, pageBreakBefore: true),
        DocumentParagraph(runs: [DocumentRun("끝맺는 말.")]),
    ])

    /// 파일을 읽어 종이에 올리고 편집기를 이어 준다
    private func open(_ format: DocumentFormat, name: String = "sample") throws -> (DocumentEditor, NSTextView, LoadedDocument, URL) {
        let url = folder().appendingPathComponent("\(name).\(format.fileExtension)")
        try RichDocumentWriter.write(sample, as: format).write(to: url)
        let doc = try DocumentLoader.load(url)
        let tv = NSTextView(usingTextLayoutManager: false)
        tv.isEditable = true
        tv.isRichText = true
        tv.allowsUndo = true
        let editor = DocumentEditor()
        editor.attach(tv)
        tv.textStorage?.setAttributedString(doc.attributed)
        editor.documentLoaded(pageSize: doc.pageSize, margins: doc.margins)
        return (editor, tv, doc, url)
    }

    private func range(of text: String, in tv: NSTextView) throws -> NSRange {
        let found = (tv.string as NSString).range(of: text)
        try #require(found.location != NSNotFound, "“\(text)” 없음")
        return found
    }

    @Test func editsBoldAndHeadingSurviveDocxRoundTrip() throws {
        let (editor, tv, doc, _) = try open(.docx)

        // 글 한 군데 바꾸기(사용자가 친 것처럼 NSTextView를 거쳐서)
        tv.insertText("고친 본문이야.", replacementRange: try range(of: "방법을 설명하는 글이야.", in: tv))
        #expect(tv.string.contains("고친 본문이야."))
        #expect(editor.undo.canUndo)

        // 굵게
        tv.setSelectedRange(try range(of: "고친 본문", in: tv))
        editor.toggleBold()
        #expect(editor.currentFormat().bold)

        // 제목 바꾸기: "둘째 절 방법"(제목 2) → 본문, "끝맺는 말."(본문) → 제목 3
        tv.setSelectedRange(NSRange(location: try range(of: "둘째 절 방법", in: tv).location, length: 0))
        #expect(editor.currentFormat().heading == 2)
        editor.setHeading(nil)
        #expect(editor.currentFormat().heading == nil)
        tv.setSelectedRange(NSRange(location: try range(of: "끝맺는 말.", in: tv).location + 1, length: 0))
        editor.setHeading(3)
        #expect(editor.currentFormat().heading == 3)

        // 저장 길(세션과 같은 함수)로 docx를 쓰고 다시 읽기
        let rich = RichDocumentEditing.document(from: tv.textStorage!, title: doc.title, pageSize: doc.pageSize)
        let out = folder().appendingPathComponent("back.docx")
        try RichDocumentWriter.write(rich, as: .docx).write(to: out)
        let back = try RichDocumentReader.read(out)

        let edited = try #require(back.paragraphs.first { $0.text.contains("고친 본문이야.") })
        #expect(edited.runs.contains { $0.bold && $0.text.contains("고친 본문") })
        #expect(!back.paragraphs.contains { $0.text.contains("방법을 설명하는 글이야.") })
        #expect(back.paragraphs.first { $0.text.contains("둘째 절 방법") }?.headingLevel == nil)
        #expect(back.paragraphs.first { $0.text.contains("끝맺는 말.") }?.headingLevel == 3)
        #expect(back.paragraphs.first { $0.text.contains("첫째 장 서론") }?.headingLevel == 1)
        // 표·쪽 나눔은 그대로, 쪽 띠 글("2쪽")은 내용으로 남지 않는다
        #expect(back.paragraphs.contains { $0.table?.first == ["이름", "값"] })
        #expect(back.paragraphs.first { $0.text.contains("셋째 장 결론") }?.pageBreakBefore == true)
        #expect(!back.paragraphs.contains { $0.text.contains("2쪽") || $0.text.contains("Page 2") })
        #expect(!back.paragraphs.contains { $0.table?.count == 1 && $0.table?.first?.count == 1 })
    }

    @Test func pageBandIsProtectedAndBecomesAPageBreak() throws {
        let (editor, tv, _, _) = try open(.docx)
        let bands = DocumentEditor.bandRanges(in: tv.textStorage!)
        try #require(bands.count == 1)
        let band = bands[0]
        let before = tv.string

        // 띠 안에 글자를 넣으려 하면 막힌다
        tv.setSelectedRange(NSRange(location: band.location + 1, length: 0))
        tv.insertText("x", replacementRange: NSRange(location: band.location + 1, length: 0))
        #expect(tv.string == before)

        // 띠 앞에 쪽 나눔을 하나 더 넣으면 표시 문단이 둘(글자 하나 + 줄바꿈, 번호는 화면이 센다)
        tv.setSelectedRange(NSRange(location: try range(of: "둘째 절 방법", in: tv).location, length: 0))
        editor.insertPageBreak()
        let two = DocumentEditor.bandRanges(in: tv.textStorage!)
        #expect(two.count == 2)
        let marks = two.map { (tv.string as NSString).substring(with: $0) }
        #expect(marks == Array(repeating: DocumentLoader.pageBreakMark + "\n", count: 2))
        // 커서는 표시 줄에 멈추지 않는다(앞으로 가면 다음 쪽 첫 자리로, 뒤로 가면 앞 문단 끝으로)
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.setSelectedRange(NSRange(location: two[0].location, length: 0))
        #expect(tv.selectedRange().location == NSMaxRange(two[0]))
        tv.setSelectedRange(NSRange(location: NSMaxRange(two[0]) - 1, length: 0))
        #expect(tv.selectedRange().location == two[0].location - 1)

        // 띠 바로 뒤에서 ⌫: 띠 전체가 지워진다(쪽 나눔 없앰) → 남은 띠는 다시 2쪽
        let last = two[1]
        tv.setSelectedRange(NSRange(location: NSMaxRange(last), length: 0))
        tv.deleteBackward(nil)
        let one = DocumentEditor.bandRanges(in: tv.textStorage!)
        #expect(one.count == 1)
        #expect((tv.string as NSString).substring(with: one[0]).hasPrefix(DocumentLoader.pageBreakMark))
        #expect(tv.string.contains("셋째 장 결론"))

        // 남은 띠는 저장하면 쪽 나눔으로 돌아간다
        let rich = RichDocumentEditing.document(from: tv.textStorage!, title: "t", pageSize: nil)
        #expect(rich.paragraphs.first { $0.text.contains("둘째 절 방법") }?.pageBreakBefore == true)
        #expect(rich.paragraphs.first { $0.text.contains("셋째 장 결론") }?.pageBreakBefore == false)

        // ⌘Z로 차례로 되돌릴 수 있다
        #expect(editor.undo.canUndo)
    }

    @Test func bulletTableAndPictureInsert() throws {
        let (editor, tv, _, _) = try open(.docx)
        tv.setSelectedRange(NSRange(location: try range(of: "끝맺는 말.", in: tv).location, length: 0))
        editor.toggleBullet()
        #expect(tv.string.contains("• 끝맺는 말."))
        #expect(editor.currentFormat().bullet)
        editor.toggleBullet()
        #expect(!tv.string.contains("• 끝맺는 말."))

        // 끝에 2×3 표와 그림
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        editor.insertTable(rows: 2, columns: 3)
        let pixel = NSImage(size: NSSize(width: 2000, height: 1000), flipped: false) { rect in NSColor.red.setFill(); rect.fill(); return true }
        let png = NSBitmapImageRep(data: pixel.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        let file = folder().appendingPathComponent("p.png")
        try png.write(to: file)
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        #expect(editor.insertImage(from: file))

        // 그림은 본문 폭 안으로, 비율 유지
        var attachment: NSTextAttachment?
        tv.textStorage!.enumerateAttribute(.attachment, in: NSRange(location: 0, length: tv.textStorage!.length)) { value, _, _ in
            if let a = value as? NSTextAttachment { attachment = a }
        }
        let bounds = try #require(attachment?.bounds.size)
        #expect(bounds.width <= editor.contentSize.width + 0.5)
        #expect(abs(bounds.width / bounds.height - 2) < 0.02)

        let rich = RichDocumentEditing.document(from: tv.textStorage!, title: "t", pageSize: nil)
        #expect(rich.paragraphs.contains { $0.table?.count == 2 && $0.table?.first?.count == 3 })
        #expect(rich.paragraphs.contains { $0.image != nil })
    }

    @Test func sessionGoesDirtyAndLiveOutlineFollowsEdits() throws {
        let session = DocumentSession(area: .word)
        let (_, tv, _, _) = try open(.docx)
        // 세션 편집기에 이어서 확인
        session.editor.attach(tv)
        session.editor.documentLoaded(pageSize: CGSize(width: 595, height: 842), margins: NSEdgeInsets(top: 48, left: 48, bottom: 48, right: 48))
        tv.setSelectedRange(NSRange(location: try range(of: "끝맺는 말.", in: tv).location, length: 0))
        session.setHeading(2)
        #expect(session.dirty)
        let summary = DocumentLoader.liveSummary(of: tv.textStorage!)
        #expect(summary.outline.map(\.title).contains("끝맺는 말."))
        #expect(summary.pages == 2)
        #expect(!summary.head.contains("2쪽"))
    }

    // MARK: 저장 이름 규칙

    @Test func saveFormatFollowsOriginalAndUpgradesLegacy() {
        func f(_ name: String) -> DocumentFormat { DocumentSession.saveFormat(for: URL(fileURLWithPath: "/tmp/\(name)")) }
        #expect(f("a.docx") == .docx)
        #expect(f("a.doc") == .docx)
        #expect(f("a.hwp") == .hwpx)
        #expect(f("a.hwpx") == .hwpx)
        #expect(f("a.rtf") == .rtf)
        #expect(f("a.odt") == .odt)
        #expect(f("a.md") == .md)
        #expect(f("a.txt") == .txt)
        #expect(f("a.htm") == .html)
    }

    @Test func savesBesideAsEditThenOverwritesThatFile() throws {
        let dir = folder()
        let original = dir.appendingPathComponent("보고서.hwp")
        try Data("원본".utf8).write(to: original)
        let text = NSAttributedString(string: "첫 저장\n", attributes: DocumentEditor.bodyAttributes())
        var job = DocumentSession.SaveJob(text: text, title: "보고서", pageSize: nil, format: DocumentSession.saveFormat(for: original),
                                          original: original, existing: nil, destination: nil)
        let first = try DocumentSession.perform(job)
        #expect(first.lastPathComponent == "보고서_edit.hwpx")
        #expect(try Data(contentsOf: original) == Data("원본".utf8))         // 원본은 그대로

        // 같은 창에서 다시 저장: 그 _edit 파일을 덮어쓴다(새 파일이 안 생긴다)
        job.existing = first
        job.text = NSAttributedString(string: "두 번째 저장\n", attributes: DocumentEditor.bodyAttributes())
        let second = try DocumentSession.perform(job)
        #expect(second == first)
        #expect(try RichDocumentReader.read(second).paragraphs.contains { $0.text.contains("두 번째 저장") })

        // 다른 창(새로 연 문서)에서 처음 저장하면 이미 있는 _edit는 두고 _edit (1)
        job.existing = nil
        let third = try DocumentSession.perform(job)
        #expect(third.lastPathComponent == "보고서_edit (1).hwpx")

        // 다른 형식으로 저장이라도 원본 자리에는 못 쓴다
        job.destination = original
        #expect(throws: (any Error).self) { try DocumentSession.perform(job) }
        #expect(try Data(contentsOf: original) == Data("원본".utf8))

        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(files == ["보고서.hwp", "보고서_edit (1).hwpx", "보고서_edit.hwpx"])
    }
}
