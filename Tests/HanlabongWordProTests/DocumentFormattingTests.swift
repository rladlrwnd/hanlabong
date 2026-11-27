import AppKit
import Foundation
import SkillEngine
import Testing
@testable import HanlabongWordPro

/// 글자 크기·글꼴·색·정렬과 표 줄·칸 고치기를 화면 없이: 종이(NSTextView)에서 고치기 → 저장 길로 쓰고 다시 읽기
@MainActor
struct DocumentFormattingTests {
    /// 저장 뒤 다시 열 때 글자 크기로 제목을 짐작하지 않게(읽는 쪽은 100자 이하 문단만 짐작한다) 길게 만든 본문
    private let filler = "이 문단은 저장 뒤 다시 열 때 글자 크기로 제목을 짐작하지 않도록 일부러 길게 쓴 본문이야. 한 문단이 백 자를 넘으면 읽는 쪽이 제목으로 보지 않아서 크기와 글꼴이 그대로 남는지 확인할 수 있어. "

    private func make(_ text: String) -> (DocumentEditor, NSTextView) {
        let tv = NSTextView(usingTextLayoutManager: false)
        tv.isEditable = true
        tv.isRichText = true
        let editor = DocumentEditor()
        editor.attach(tv)
        tv.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: DocumentEditor.bodyAttributes().merging([.hanlabongPlainBody: true]) { $1 }))
        editor.documentLoaded(pageSize: CGSize(width: 595, height: 842), margins: NSEdgeInsets(top: 67, left: 48, bottom: 67, right: 48))
        return (editor, tv)
    }

    private func roundTrip(_ tv: NSTextView) throws -> RichDocument {
        let rich = RichDocumentEditing.document(from: tv.textStorage!, title: "t", pageSize: nil)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wp-fmt-\(UUID().uuidString).docx")
        try RichDocumentWriter.write(rich, as: .docx).write(to: url)
        let back = try RichDocumentReader.read(url)
        return back
    }

    @Test func alignmentAppliesToSelectedParagraphsAndSurvivesSave() throws {
        let (editor, tv) = make("첫 줄\n둘째 줄\n셋째 줄")
        tv.setSelectedRange(NSRange(location: 0, length: 8))   // 첫째·둘째 줄
        editor.setAlignment(.center)
        let storage = tv.textStorage!
        func alignment(at i: Int) -> NSTextAlignment { (storage.attribute(.paragraphStyle, at: i, effectiveRange: nil) as! NSParagraphStyle).alignment }
        #expect(alignment(at: 0) == .center)
        #expect(alignment(at: 5) == .center)
        #expect(alignment(at: 10) != .center)
        #expect(editor.currentFormat().alignment == .center)

        tv.setSelectedRange(NSRange(location: 10, length: 0))
        editor.setAlignment(.justified)
        #expect(editor.currentFormat().alignment == .justified)

        let back = try roundTrip(tv)
        #expect(back.paragraphs.first { $0.text.contains("첫 줄") }?.alignment == .center)
        #expect(back.paragraphs.first { $0.text.contains("셋째") }?.alignment == .justify)
    }

    @Test func fontSizeStepsAndSetSizeSurviveSave() throws {
        #expect(DocumentEditor.steppedSize(11, up: true) == 12)
        #expect(DocumentEditor.steppedSize(11, up: false) == 10.5)
        #expect(DocumentEditor.steppedSize(72, up: true) > 72)
        #expect(DocumentEditor.steppedSize(8, up: false) < 8)

        let (editor, tv) = make(filler + "본문 끝은 크게")
        let start = try #require((tv.string as NSString).range(of: "크게").location as Int?)
        tv.setSelectedRange(NSRange(location: start, length: 2))
        editor.setFontSize(20)
        let storage = tv.textStorage!
        #expect((storage.attribute(.font, at: start, effectiveRange: nil) as? NSFont)?.pointSize == 20)
        #expect((storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize != 20)
        #expect(editor.currentFormat().fontSize == 20)
        editor.changeFontSize(up: true)
        #expect((storage.attribute(.font, at: start, effectiveRange: nil) as? NSFont)?.pointSize == 24)

        let back = try roundTrip(tv)
        let runs = back.paragraphs.flatMap(\.runs)
        #expect(runs.contains { $0.text.contains("크게") && $0.fontSize == 24 })
    }

    @Test func colorAndFontFamilySurviveSave() throws {
        let (editor, tv) = make("빨강 글꼴 " + filler)
        tv.setSelectedRange(NSRange(location: 0, length: 2))
        editor.setTextColor(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        tv.setSelectedRange(NSRange(location: 3, length: 2))
        let family = "AppleMyungjo"
        try #require(NSFontManager.shared.availableFontFamilies.contains(family))
        editor.setFontFamily(family)
        #expect(editor.currentFormat().fontFamily == family)
        // 굵게를 얹어도 글꼴 가족은 그대로
        editor.toggleBold()
        #expect((tv.textStorage!.attribute(.font, at: 3, effectiveRange: nil) as? NSFont)?.familyName == family)

        let back = try roundTrip(tv)
        let runs = back.paragraphs.flatMap(\.runs)
        #expect(runs.contains { $0.text.contains("빨강") && $0.colorHex?.uppercased().hasSuffix("FF0000") == true })
        #expect(runs.contains { $0.text.contains("글꼴") && $0.fontName == family })

        // 기본 글꼴로 되돌리면 이름이 사라진다
        tv.setSelectedRange(NSRange(location: 3, length: 2))
        editor.setFontFamily(nil)
        #expect(editor.currentFormat().fontFamily == nil)
        #expect(tv.textStorage!.attribute(.hanlabongFontName, at: 3, effectiveRange: nil) == nil)
    }

    @Test func tableRowAndColumnEditing() throws {
        let (editor, tv) = make("앞 글\n")
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        editor.insertTable(rows: 3, columns: 2)
        let storage = tv.textStorage!
        // 칸마다 글자 채우기(뒤 칸부터 넣어야 앞 자리가 안 밀린다)
        var cells: [Int] = []
        let ns = storage.string as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byParagraphs) { _, range, _, _ in
            if DocumentEditor.tableBlock(at: range.location, in: storage) != nil { cells.append(range.location) }
        }
        #expect(cells.count == 6)
        for (location, text) in zip(cells, ["A", "B", "C", "D", "E", "F"]).reversed() {
            storage.replaceCharacters(in: NSRange(location: location, length: 0), with: NSAttributedString(string: text, attributes: storage.attributes(at: location, effectiveRange: nil)))
        }
        let start = (tv.string as NSString).range(of: "A").location
        #expect(DocumentEditor.tableSize(in: storage, at: start)?.rows == 3)
        #expect(DocumentEditor.tableSize(in: storage, at: start)?.columns == 2)

        // 둘째 줄(C D) 아래에 줄 추가 → 4줄
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).range(of: "C").location, length: 0))
        #expect(editor.currentFormat().inTable)
        #expect(editor.editTable(.addRow(below: true)))
        #expect(DocumentEditor.tableSize(in: storage, at: start)?.rows == 4)
        // 새 줄은 본문 칸(머리줄 배경 없음), 머리줄은 그대로
        let rich = RichDocumentEditing.document(from: storage, title: "t", pageSize: nil)
        let table = try #require(rich.paragraphs.compactMap(\.table).first)
        #expect(table.map { $0.first ?? "" } == ["A", "C", "", "E"])

        // 오른쪽에 칸 추가 → 3칸
        #expect(editor.editTable(.addColumn(right: true)))
        #expect(DocumentEditor.tableSize(in: storage, at: start)?.columns == 3)
        let table2 = try #require(RichDocumentEditing.document(from: storage, title: "t", pageSize: nil).paragraphs.compactMap(\.table).first)
        #expect(table2.allSatisfy { $0.count == 3 })
        #expect(table2[1] == ["C", "", "D"])

        // 칸 삭제 · 줄 삭제 → 원래 3줄 2칸 근처
        #expect(editor.editTable(.deleteColumn))
        #expect(DocumentEditor.tableSize(in: storage, at: start)?.columns == 2)
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).range(of: "C").location, length: 0))
        #expect(editor.editTable(.addRow(below: false)))
        #expect(editor.editTable(.deleteRow))
        #expect(DocumentEditor.tableSize(in: storage, at: start)?.rows == 4)

        // 표 안이 아니면 아무 일도 없다 · 앞 글은 그대로
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(editor.editTable(.deleteRow) == false)
        #expect(tv.string.hasPrefix("앞 글"))
    }

    @Test func lastRowOrColumnCannotBeDeleted() throws {
        let (editor, tv) = make("")
        editor.insertTable(rows: 1, columns: 1)
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(editor.editTable(.deleteRow) == false)
        #expect(editor.editTable(.deleteColumn) == false)
        #expect(editor.editTable(.addRow(below: true)))
        #expect(editor.editTable(.deleteRow))
    }

    @Test func boldShortcutIgnoredWithoutDocumentFocus() throws {
        let (editor, tv) = make("글")
        tv.setSelectedRange(NSRange(location: 0, length: 1))
        // 창이 없으니 종이가 첫 응답자가 아니다: 단축키는 무시
        editor.toggleBoldShortcut()
        editor.toggleItalicShortcut()
        #expect(editor.documentHasFocus == false)
        #expect(editor.currentFormat().bold == false)
        // 단추(직접 호출)는 그대로 먹는다
        editor.toggleBold()
        #expect(editor.currentFormat().bold)
    }
}
