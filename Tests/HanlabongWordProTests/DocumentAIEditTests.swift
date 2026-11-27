import AppKit
import Foundation
import SkillEngine
import Testing
@testable import HanlabongWordPro

/// 문서 영역 3단계(AI가 문서를 직접 고치기)를 화면 없이: JSON 행동 읽기 → 계획 → 적용 → document(from:)로 확인 → ⌘Z 한 번
@MainActor
struct DocumentAIEditTests {
    private let sample = RichDocument(title: "입시 정리", paragraphs: [
        DocumentParagraph(runs: [DocumentRun("수능 등급컷 정리")], headingLevel: 1),
        DocumentParagraph(runs: [DocumentRun("이 문서는 영어 등급컷을 정리한 거야. 해마다 조금씩 달라.")]),
        DocumentParagraph(runs: [], table: [["구분", "1컷", "2컷"], ["2025 수능", "44", "41"], ["2026 수능", "44", "40"]]),
        DocumentParagraph(runs: [DocumentRun("신청서")], headingLevel: 2),
        DocumentParagraph(runs: [], table: [["이름", "홍길동"], ["주소", " "]]),
        DocumentParagraph(runs: [DocumentRun("연락처: ________")]),
        DocumentParagraph(runs: [DocumentRun("학번:")]),
        DocumentParagraph(runs: [DocumentRun("마무리")], headingLevel: 1, pageBreakBefore: true),
        DocumentParagraph(runs: [DocumentRun("공부 열심히 하자. 끝.")]),
    ])

    /// docx로 쓰고 다시 읽어서(실제 파일 읽기 길) 종이에 올린다
    private func open() throws -> (DocumentEditor, NSTextView, LoadedDocument) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wp-ai-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("cut.docx")
        try RichDocumentWriter.write(sample, as: .docx).write(to: url)
        let doc = try DocumentLoader.load(url)
        let tv = NSTextView(usingTextLayoutManager: false)
        tv.isEditable = true
        tv.isRichText = true
        tv.allowsUndo = true
        let editor = DocumentEditor()
        editor.attach(tv)
        tv.textStorage?.setAttributedString(doc.attributed)
        editor.documentLoaded(pageSize: doc.pageSize, margins: doc.margins)
        return (editor, tv, doc)
    }

    private func saved(_ tv: NSTextView) -> RichDocument {
        RichDocumentEditing.document(from: tv.textStorage!, title: "t", pageSize: nil)
    }

    private func grid(_ rich: RichDocument, containing word: String) -> [[String]]? {
        rich.paragraphs.compactMap(\.table).first { $0.contains { $0.contains(word) } }
    }

    // MARK: JSON

    @Test func parsesEveryActionKind() throws {
        let answer = """
        <think>생각 중</think>
        ```json
        {"actions":[
          {"type":"replace","find":"해마다","with":"매년"},
          {"type":"cell","table":1,"row":"2","col":1,"text":33},
          {"type":"insert","after":"end","text":"새 문단","heading":2},
          {"type":"insert","after":"신청서","text":"본문 하나","heading":0},
          {"type":"rewrite","find":"공부 열심히","text":"공부를 열심히 합시다."},
          {"type":"goto","heading":"마무리"},
          {"type":"unknown","x":1}
        ],"reply":"바꿨어요"}
        ```
        """
        let parsed = try #require(DocumentAIEdit.parse(answer))
        #expect(parsed.reply == "바꿨어요")
        #expect(parsed.actions == [
            .replace(find: "해마다", with: "매년"),
            .cell(table: 1, row: 2, col: 1, text: "33"),
            .insert(after: "end", text: "새 문단", heading: 2),
            .insert(after: "신청서", text: "본문 하나", heading: nil),
            .rewrite(find: "공부 열심히", text: "공부를 열심히 합시다."),
            .goto(heading: "마무리"),
        ])
        // 행동 하나만 바로 온 모양, 답만 온 모양, JSON이 아닌 답
        #expect(DocumentAIEdit.parse(#"{"type":"cell","table":1,"row":1,"col":2,"text":"39"}"#)?.actions == [.cell(table: 1, row: 1, col: 2, text: "39")])
        let answerOnly = try #require(DocumentAIEdit.parse(#"{"actions":[],"reply":"표가 두 개 있어요"}"#))
        #expect(answerOnly.actions.isEmpty && answerOnly.reply == "표가 두 개 있어요")
        #expect(DocumentAIEdit.parse("그냥 글로 답했어요") == nil)
    }

    // MARK: 표 칸

    @Test func cellEditKeepsTableAndUndoesInOneStep() throws {
        let (editor, tv, _) = try open()
        let before = tv.string
        let tables = DocumentAIEdit.tables(in: tv.textStorage!)
        #expect(tables.count == 2)
        #expect(tables[0].rows == 3 && tables[0].cols == 3)
        #expect(DocumentAIEdit.cellText(tables[0].cell(2, 1)!.text) == "44")

        let plan = DocumentAIEdit.plan([.cell(table: 1, row: 2, col: 1, text: "33")], in: tv.textStorage!)
        #expect(plan.failures.isEmpty)
        #expect(plan.edits.first?.summary == "표 1의 2026 수능 1컷을 33으로 바꿨어요")
        let ranges = editor.applyPlanned(plan.edits)
        #expect((tv.string as NSString).substring(with: ranges[0]) == "33")

        // 저장 길로 되돌려도 표 모양 그대로, 그 칸만 33
        let table = try #require(grid(saved(tv), containing: "구분"))
        #expect(table == [["구분", "1컷", "2컷"], ["2025 수능", "44", "41"], ["2026 수능", "33", "40"]])

        // ⌘Z 한 번에 원래대로
        editor.undo.undo()
        #expect(tv.string == before)
        #expect(grid(saved(tv), containing: "구분")?[2][1] == "44")
    }

    // MARK: 여러 행동을 한 번에

    @Test func replaceInsertRewriteTogetherUndoOnce() throws {
        let (editor, tv, _) = try open()
        let before = tv.string
        let actions: [DocumentEditAction] = [
            .replace(find: "해마다", with: "매년"),
            .insert(after: "신청서", text: "아래 칸을 채워 주세요.", heading: nil),
            .insert(after: "end", text: "참고 자료", heading: 2),
            .rewrite(find: "공부 열심히", text: "공부를 열심히 합시다. 끝입니다."),
            .cell(table: 1, row: 1, col: 2, text: "39"),
        ]
        let plan = DocumentAIEdit.plan(actions, in: tv.textStorage!)
        #expect(plan.failures.isEmpty)
        #expect(plan.edits.count == 5)
        let ranges = editor.applyPlanned(plan.edits)
        #expect(ranges.count == 5)
        let ns = tv.string as NSString
        #expect(ranges.contains { ns.substring(with: $0) == "매년" })
        #expect(ranges.contains { ns.substring(with: $0) == "39" })

        let rich = saved(tv)
        let texts = rich.paragraphs.map(\.text)
        #expect(texts.contains("이 문서는 영어 등급컷을 정리한 거야. 매년 조금씩 달라."))
        #expect(texts.contains("공부를 열심히 합시다. 끝입니다."))
        #expect(!texts.contains("공부 열심히 하자. 끝."))
        // 넣은 문단: 신청서 바로 뒤 본문, 끝에 제목 2
        let i = try #require(texts.firstIndex(of: "신청서"))
        #expect(texts[i + 1] == "아래 칸을 채워 주세요.")
        #expect(rich.paragraphs[i + 1].headingLevel == nil)
        #expect(rich.paragraphs.last?.text == "참고 자료")
        #expect(rich.paragraphs.last?.headingLevel == 2)
        // 쪽 나눔·표는 그대로
        #expect(rich.paragraphs.first { $0.text == "마무리" }?.pageBreakBefore == true)
        #expect(grid(rich, containing: "구분")?[1][2] == "39")
        #expect(grid(rich, containing: "이름") != nil)

        editor.undo.undo()
        #expect(tv.string == before)
    }

    // MARK: 못 찾음 · 보호

    @Test func honestFailuresAndProtectedBands() throws {
        let (_, tv, _) = try open()
        let storage = tv.textStorage!
        let plan = DocumentAIEdit.plan([
            .replace(find: "없는 글귀", with: "x"),
            .replace(find: DocumentLoader.pageLabel(2), with: "x"),       // 쪽 띠 글은 못 고친다
            .cell(table: 5, row: 0, col: 0, text: "x"),
            .replace(find: "2025 수능 44", with: "x"),                     // 표 칸 여러 개에 걸친 글
        ], in: storage)
        #expect(plan.edits.isEmpty)
        #expect(plan.failures.count == 4)
        #expect(plan.failures[0] == "문서에서 ‘없는 글귀’를 못 찾았어요")
        #expect(plan.failures[1].contains("못 찾았어요"))
        #expect(plan.failures[2].contains("표 5"))

        // 숫자는 더 큰 숫자 안에서 세지 않는다("2026" 속 "02"는 없음), 띄어쓰기가 달라도 찾는다
        #expect(DocumentAIEdit.matches(of: "02", in: storage).isEmpty)
        #expect(DocumentAIEdit.matches(of: "영어  등급컷을", in: storage).count == 1)
        #expect(DocumentAIEdit.matches(of: "44", in: storage).count == 2)
    }

    // MARK: 로컬 빠른 길

    @Test func localFastPaths() throws {
        let (editor, tv, _) = try open()
        let storage = tv.textStorage!

        // "44"는 두 군데 → AI에게(꺼져 있으면 정직한 안내)
        let twice = DocumentAIEdit.local("44를 33으로 바꿔 줘", in: storage)
        #expect(twice.plan == nil)
        #expect(twice.note?.contains("2군데") == true)

        // 문서에 그대로 없는 말 → AI가 맡는다
        let fuzzy = DocumentAIEdit.local("2026 수능 표의 1컷 44를 33으로 바꿔줘", in: storage)
        #expect(fuzzy.plan == nil)
        #expect(fuzzy.note?.contains("못 찾았어요") == true)

        // 딱 한 번 있는 글 → 바로
        let once = try #require(DocumentAIEdit.local("41을 39로 바꿔줘", in: storage).plan)
        #expect(once.edits.first?.summary == "‘41’을 ‘39’로 바꿨어요")
        editor.applyPlanned(once.edits)
        #expect(grid(saved(tv), containing: "구분")?[1][2] == "39")

        // 라벨 말("주소를 서울로")은 값 바꾸기일 수 있어 AI에게
        #expect(DocumentAIEdit.local("주소를 서울로 바꿔줘", in: storage).plan == nil)

        // "주소에 ~ 써 줘": 표의 '주소' 옆 칸
        let address = try #require(DocumentAIEdit.local("주소에 서울시 마포구 써 줘", in: storage).plan)
        editor.applyPlanned(address.edits)
        let form = try #require(grid(saved(tv), containing: "이름"))
        #expect(form[1] == ["주소", "서울시 마포구"])
        #expect(form[0] == ["이름", "홍길동"])

        // '연락처: ____' 밑줄 자리, '학번:' 뒤 빈자리
        let phone = try #require(DocumentAIEdit.local("연락처에 010-1234-5678 써줘", in: storage).plan)
        editor.applyPlanned(phone.edits)
        let id = try #require(DocumentAIEdit.local("학번에 2024123 적어줘", in: storage).plan)
        editor.applyPlanned(id.edits)
        let texts = saved(tv).paragraphs.map(\.text)
        #expect(texts.contains("연락처: 010-1234-5678"))
        #expect(texts.contains("학번: 2024123"))

        // 바꿀 게 아닌 말은 그냥 지나간다
        let none = DocumentAIEdit.local("이 문서 요약해 줘", in: storage)
        #expect(none.plan == nil && none.note == nil)
    }

    // MARK: 세션: 타자 효과 뒤 한 묶음 · dirty · 결과 한 줄

    @Test func sessionAppliesWithTypingThenOneUndo() async throws {
        let session = DocumentSession(area: .word)
        let (_, tv, _) = try open()
        session.editor.attach(tv)
        session.editor.documentLoaded(pageSize: CGSize(width: 595, height: 842), margins: NSEdgeInsets(top: 48, left: 48, bottom: 48, right: 48))
        let before = tv.string
        let plan = DocumentAIEdit.plan([.cell(table: 1, row: 2, col: 1, text: "33"), .replace(find: "해마다", with: "매년")], in: tv.textStorage!)
        let reply = await session.applyEdits(plan, reply: "", animated: true)
        #expect(reply == "표 1의 2026 수능 1컷을 33으로 바꿨어요 · ‘해마다’를 ‘매년’으로 바꿨어요 · ⌘Z로 되돌리기")
        #expect(session.dirty)
        #expect(tv.isEditable)
        #expect(tv.string.contains("매년 조금씩"))
        #expect(grid(saved(tv), containing: "구분")?[2][1] == "33")
        // 보여 주기(타자 효과)는 되돌리기 기록에 안 남고, 진짜 적용은 한 묶음
        session.editor.undo.undo()
        #expect(tv.string == before)
        #expect(!session.editor.undo.canUndo)
    }

    // MARK: AI 맥락

    @Test func contextListsTablesAndHidesBands() throws {
        let (_, tv, doc) = try open()
        let context = DocumentAIEdit.context(text: tv.textStorage!, fileName: "cut.docx", kind: "워드", outline: doc.outline,
                                             visible: nil, selection: NSRange(location: 0, length: 4), focus: nil)
        #expect(context.contains("표 1: 3줄 × 3칸"))
        #expect(context.contains("r2: c0=2026 수능 | c1=44 | c2=40"))
        #expect(context.contains("[표 1]") && context.contains("[표 2]"))
        #expect(context.contains("(쪽 나눔)"))
        #expect(!context.contains("\n" + DocumentLoader.pageLabel(2) + "\n"))
        #expect(context.contains("선택한 글:\n수능 등"))
        #expect(context.contains("본문(전체)"))
        #expect(DocumentAIEdit.system.contains("\"type\":\"cell\""))
    }
}
