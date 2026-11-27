import AppKit
import Foundation
import SkillEngine
import Testing
@testable import HanlabongWordPro

/// 모델은 세션을 약하게만 잡아서(실제 화면은 창이 세션을 쥔다), 테스트가 만든 세션이 먼저 사라지지 않게 붙들어 둔다
@MainActor private var keepAlive: [AnyObject] = []

/// 문서 영역 3단계(내 정보로 빈칸 채우기 · 서명 넣기)를 화면 없이: 합성 신청서 → 빈칸 찾기 → 채우기 → 되돌리기 변환 → ⌘Z
@MainActor
struct DocumentFillTests {
    private func folder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wp-fill-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// 표(성명|빈칸, 학번|빈칸, 주소|빈칸, 서명|빈칸) + 날짜 글
    private let form = RichDocument(title: "신청서", paragraphs: [
        DocumentParagraph(runs: [DocumentRun("장학금 신청서")], headingLevel: 1),
        DocumentParagraph(runs: [], table: [["성명", ""], ["학번", ""], ["주소", ""], ["서명", ""]]),
        DocumentParagraph(runs: [DocumentRun("날짜: 2026년  월  일")]),
    ])

    private let profile = UserProfile(entries: [
        ProfileEntry(key: "이름", value: "김한라"),
        ProfileEntry(key: "학번", value: "20261234"),
        ProfileEntry(key: "주소", value: "제주시 한라로 1"),
        ProfileEntry(key: "휴대폰", value: "010-1234-5678"),
    ])

    private func signatureSample() -> Signature {
        // 물결 모양 획 하나(굵기가 점마다 달라지는 서명)
        let points = (0...20).map { CGPoint(x: Double($0) / 20, y: 0.18 + 0.1 * sin(Double($0) / 3)) }
        let widths = (0...20).map { 0.006 + 0.01 * Double($0 % 5) / 5 }
        return Signature(strokes: [points], aspect: 0.4, widths: [widths])
    }

    private func open(_ rich: RichDocument, signatures: [Signature] = []) throws
        -> (DocumentFillModel, DocumentSession, NSTextView, LoadedDocument) {
        let url = folder().appendingPathComponent("form.docx")
        try RichDocumentWriter.write(rich, as: .docx).write(to: url)
        let doc = try DocumentLoader.load(url)
        let tv = NSTextView(usingTextLayoutManager: false)
        tv.isEditable = true
        tv.isRichText = true
        tv.allowsUndo = true
        let session = DocumentSession(area: .word)
        keepAlive.append(session)
        keepAlive.append(tv)
        session.editor.attach(tv)
        tv.textStorage?.setAttributedString(doc.attributed)
        session.editor.documentLoaded(pageSize: doc.pageSize, margins: doc.margins)
        // 진짜 내 정보·서명 파일을 건드리지 않게 값을 직접 준다
        let fill = DocumentFillModel(session: session, profile: profile, signatures: signatures)
        return (fill, session, tv, doc)
    }

    private func tableCells(_ tv: NSTextView, title: String = "t") -> [[String]] {
        let rich = RichDocumentEditing.document(from: tv.textStorage!, title: title, pageSize: nil)
        return rich.paragraphs.compactMap(\.table).first ?? []
    }

    // MARK: 빈칸 찾기

    @Test func findsTableAndDateBlanksInSyntheticForm() throws {
        let (fill, _, _, _) = try open(form)
        let blanks = fill.scan()
        // 표 4칸(성명·학번·주소·서명) + 날짜의 월·일 = 6칸. 이미 쓴 "2026년"은 빈칸이 아니다
        #expect(blanks.map(\.label) == ["성명", "학번", "주소", "서명", "월", "일"])
        #expect(blanks.map(\.kind) == [.text, .text, .text, .signature, .month, .day])
        #expect(blanks.prefix(4).allSatisfy { $0.site == .tableCell })
        #expect(blanks.suffix(2).allSatisfy { $0.site == .date })
        // 엔진용 칸: 쪽 좌표는 더미(0, .zero)
        #expect(blanks[0].field.page == 0 && blanks[0].field.rect == .zero && blanks[0].field.label == "성명")
    }

    @Test func findsInlineBlanksInText() {
        func attributed(_ lines: [String]) -> NSAttributedString {
            NSAttributedString(string: lines.joined(separator: "\n") + "\n", attributes: DocumentEditor.bodyAttributes())
        }
        let text = attributed([
            "신청서",
            "성명: ____________",
            "연락처 :      ",
            "주소(            )",
            "학번 ________",
            "신청인:   ______   학번:   ______",
            "    년    월    일",
            "신청인 (인)",
            "회의는 10:30에 시작해요. 참고: 다음 장을 봐요",
            "1월 일정은 월요일부터 시작",
        ])
        let blanks = DocumentBlankFinder.find(in: text)
        let summary = blanks.map { "\($0.site):\($0.label)" }
        #expect(summary.contains("afterLabel:성명"))
        #expect(summary.contains("afterLabel:연락처"))
        #expect(summary.contains("parentheses:주소"))
        #expect(summary.contains("afterLabel:학번"))
        #expect(summary.contains("afterLabel:신청인"))
        #expect(blanks.filter { $0.site == .date }.map(\.label) == ["년", "월", "일"])
        #expect(blanks.filter { $0.kind == .signature }.count == 1)       // "(인)"
        // 평범한 글(시각 10:30, "참고:" 뒤 글, "월요일")은 빈칸이 아니다
        #expect(!blanks.contains { $0.context.contains("10:30") })
        #expect(!blanks.contains { $0.context.contains("월요일") })
        // 한 줄에 칸이 둘이면 둘 다 잡고, 값을 넣어도 칸 사이 틈은 남는다
        #expect(blanks.filter { $0.context.hasPrefix("신청인:") }.count == 2)
    }

    // MARK: 자동 채우기 · 되돌리기

    @Test func autoFillFillsTableAndDateAndUndoesInOneStep() async throws {
        let (fill, session, tv, doc) = try open(form)
        let before = tv.string
        let report = try #require(await fill.autoFill(animated: false, useAI: false))
        // 6칸 중 5칸(서명 칸은 저장해 둔 서명이 없어서 그대로)
        #expect(report.found == 6)
        #expect(report.filled == 5)
        #expect(report.needSignature == 1)
        #expect(report.signed == 0)
        #expect(report.summary.contains("빈칸 6개 중 5개를 채웠어요"))
        #expect(session.assistantReply == report.summary)

        // 되돌리기 변환기로 읽어도 칸에 값이 들어 있다
        let cells = tableCells(tv)
        #expect(cells.map { $0.first ?? "" } == ["성명", "학번", "주소", "서명"])
        #expect(cells.map { $0.last ?? "" } == ["김한라", "20261234", "제주시 한라로 1", ""])
        let rich = RichDocumentEditing.document(from: tv.textStorage!, title: doc.title, pageSize: nil)
        let date = try #require(rich.paragraphs.first { $0.text.hasPrefix("날짜") }).text
        let year = Calendar(identifier: .gregorian).component(.year, from: Date())
        #expect(date.contains("\(year)년") == false || date.contains("2026년"))
        #expect(date.contains("월") && date.contains("일"))
        #expect(date.range(of: #"2026년\s+\d{1,2}월\s+\d{1,2}일"#, options: .regularExpression) != nil)

        // 채운 칸은 이제 빈칸이 아니다(서명 칸만 남음)
        #expect(fill.scan().map(\.label) == ["서명"])
        // 세션이 고쳤다고 안다
        #expect(session.dirty)

        // ⌘Z 한 번에 처음 모양으로
        #expect(fill.busy == false)
        session.editor.undo.undo()
        #expect(tv.string == before)
        #expect(tableCells(tv).map { $0.last ?? "" } == ["", "", "", ""])
        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(!session.dirty)          // 처음 상태까지 되돌리면 깨끗한 것으로
        // 다시 하기(⌘⇧Z)도 한 묶음
        session.editor.undo.redo()
        #expect(tableCells(tv).map { $0.last ?? "" } == ["김한라", "20261234", "제주시 한라로 1", ""])
    }

    @Test func typingEffectEndsInTheSameTextAndStillOneUndo() async throws {
        let (fill, session, tv, _) = try open(form)
        let before = tv.string
        let report = try #require(await fill.autoFill(animated: true, useAI: false))
        #expect(report.filled == 5)
        #expect(tableCells(tv).map { $0.last ?? "" } == ["김한라", "20261234", "제주시 한라로 1", ""])
        // 이벤트 루프를 돌려도(타자 효과가 길게 걸렸어도) 되돌리기는 한 묶음
        session.editor.undo.undo()
        #expect(tv.string == before)
        #expect(!session.editor.undo.canUndo)
        // 채운 칸 강조는 화면에만(저장되는 글 속성에는 없다)
        var hasBackground = false
        tv.textStorage!.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: tv.textStorage!.length)) { value, _, _ in
            if value != nil { hasBackground = true }
        }
        #expect(!hasBackground)
        fill.clearFlash()
    }

    @Test func emptyProfileAsksForInfoInsteadOfFilling() async throws {
        let (_, session, tv, _) = try open(form)
        let fill = DocumentFillModel(session: session, profile: UserProfile(entries: [ProfileEntry(key: "이름")]), signatures: [])
        let before = tv.string
        let report = await fill.autoFill(animated: false, useAI: false)
        #expect(report == nil)
        #expect(fill.editingProfile)
        #expect(tv.string == before)
    }

    @Test func noBlanksShowsGuide() async throws {
        let plain = RichDocument(title: "글", paragraphs: [DocumentParagraph(runs: [DocumentRun("그냥 본문이야. 빈칸 없음.")])])
        let (fill, session, _, _) = try open(plain)
        #expect(fill.scan().isEmpty)
        let report = await fill.autoFill(animated: false, useAI: false)
        #expect(report == nil)
        #expect(session.assistantReply == "이 문서에서 빈칸을 못 찾았어요")
        fill.openList()
        #expect(!fill.listing)
    }

    // MARK: 수동 채우기

    @Test func manualFillOfOneBlankAndSuggestions() async throws {
        let (fill, _, tv, _) = try open(form)
        let blanks = fill.scan()
        let name = try #require(blanks.first { $0.label == "성명" })
        #expect(fill.suggestion(for: name) == "김한라")
        let month = try #require(blanks.first { $0.label == "월" })
        #expect(Int(fill.suggestion(for: month) ?? "") != nil)         // 날짜 칸은 오늘 날짜
        let sign = try #require(blanks.first { $0.kind == .signature })
        #expect(fill.suggestion(for: sign) == nil)
        #expect(await fill.fillOne(name, with: "  이한라  ", animated: false))
        #expect(tableCells(tv).first?.last == "이한라")
        #expect(fill.blanks.count == 5)
        // 서명 칸은 글로 채우지 않는다
        #expect(await fill.fillOne(sign, with: "x", animated: false) == false)
    }

    // MARK: 서명

    @Test func signatureImageIsTransparentAndSizedByLineHeight() throws {
        let signature = signatureSample()
        let tv = NSTextView(usingTextLayoutManager: false)
        let line = DocumentSignatureImage.lineHeight(for: tv)
        let content = CGSize(width: 499, height: 708)
        let size = DocumentSignatureImage.size(for: signature, lineHeight: line, content: content)
        #expect(size.height >= line * 2 - 1 && size.height <= line * 3 + 1)
        #expect(size.width <= content.width)
        let png = try #require(DocumentSignatureImage.png(signature, size: size))
        let rep = try #require(NSBitmapImageRep(data: png))
        #expect(rep.hasAlpha)
        #expect(rep.pixelsWide == Int((size.width * 4).rounded(.up)))
        // 모서리는 투명, 안쪽에는 검은 잉크 픽셀이 있다
        #expect(rep.colorAt(x: 0, y: 0)?.alphaComponent == 0)
        var ink = 0
        for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { ink += 1 } }
        #expect(ink > 50)
        // 아주 가로로 긴 서명도 본문 폭 안
        let wide = Signature(strokes: [[CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0.02)]], aspect: 0.02)
        let wideSize = DocumentSignatureImage.size(for: wide, lineHeight: line, content: content)
        #expect(wideSize.width <= content.width)
    }

    @Test func autoFillSignsSignatureBlankWithSavedSignatureAndKeepsItAfterSave() async throws {
        let (_, session, tv, doc) = try open(form)
        let fill = DocumentFillModel(session: session, profile: profile, signatures: [signatureSample()])
        let before = tv.string
        let report = try #require(await fill.autoFill(animated: false, useAI: false))
        #expect(report.found == 6 && report.filled == 5 && report.signed == 1 && report.needSignature == 0)
        #expect(report.summary.contains("빈칸 6개 중 6개를 채웠어요"))

        // 서명은 표 바로 뒤의 그림 문단(표 칸 안에는 그림이 저장되지 않아서)
        var attachments: [NSTextAttachment] = []
        tv.textStorage!.enumerateAttribute(.attachment, in: NSRange(location: 0, length: tv.textStorage!.length)) { value, _, _ in
            if let a = value as? NSTextAttachment { attachments.append(a) }
        }
        #expect(attachments.count == 1)
        let size = try #require(attachments.first?.bounds.size)
        #expect(size.width <= session.editor.contentSize.width + 0.5 && size.height > 20)
        // 서명이 들어간 칸은 더는 빈칸이 아니다
        #expect(fill.scan().isEmpty)

        // 저장 길(세션과 같은 함수)로 docx를 쓰고 다시 읽어도 서명은 그림으로 남는다
        let rich = RichDocumentEditing.document(from: tv.textStorage!, title: doc.title, pageSize: doc.pageSize)
        let image = try #require(rich.paragraphs.compactMap(\.image).first)
        #expect(abs(image.size.width - size.width) < 1 && abs(image.size.height - size.height) < 1)
        let out = folder().appendingPathComponent("signed.docx")
        try RichDocumentWriter.write(rich, as: .docx).write(to: out)
        let back = try RichDocumentReader.read(out)
        #expect(back.paragraphs.contains { $0.image != nil })
        #expect(back.paragraphs.compactMap(\.table).first?.map { $0.last ?? "" } == ["김한라", "20261234", "제주시 한라로 1", ""])
        let reloaded = try DocumentLoader.load(out)
        #expect(DocumentBlankFinder.find(in: reloaded.attributed).isEmpty)       // 다시 열어도 서명 칸은 이미 찬 것으로

        // ⌘Z 한 번으로 글도 서명도 처음대로
        session.editor.undo.undo()
        #expect(tv.string == before)
    }

    @Test func placeSignatureAtCursorAsOwnPictureLine() throws {
        let (_, session, tv, _) = try open(RichDocument(title: "글", paragraphs: [
            DocumentParagraph(runs: [DocumentRun("첫 문단이야.")]),
            DocumentParagraph(runs: [DocumentRun("둘째 문단이야.")]),
        ]))
        let fill = DocumentFillModel(session: session, profile: profile, signatures: [])
        let middle = (tv.string as NSString).range(of: "첫 문단")
        tv.setSelectedRange(NSRange(location: middle.location + 2, length: 0))      // 문단 가운데
        #expect(fill.place(signatureSample()))
        let rich = RichDocumentEditing.document(from: tv.textStorage!, title: "t", pageSize: nil)
        #expect(rich.paragraphs.contains { $0.image != nil })
        #expect(rich.paragraphs.map(\.text).joined().contains("둘째 문단이야."))
        #expect(session.dirty)
        session.editor.undo.undo()
        #expect(!tv.string.contains("\u{FFFC}"))
    }

    // MARK: 실제 샘플(있을 때만)

    /// 샘플 PDF를 우리 변환기(pdf-word)로 docx로 바꾼 뒤 → 빈칸 찾기 → 채우기 → ⌘Z
    @Test func realSamplePDFConvertedByOurConverter() async throws {
        let sample = URL(fileURLWithPath: NSHomeDirectory() + "/Desktop/Tasking/DRAGEDIT/테스트/장학금 신청서 샘플.pdf")
        guard FileManager.default.fileExists(atPath: sample.path) else { return }
        let dir = folder()
        let copy = dir.appendingPathComponent("장학금 신청서 샘플.pdf")
        try FileManager.default.copyItem(at: sample, to: copy)
        let result = try FileSkillExecutor().run(DefaultFileSkills.pdfToWord, input: copy)
        let docx = dir.appendingPathComponent("장학금 신청서 샘플.docx")
        try result.data.write(to: docx)
        let doc = try DocumentLoader.load(docx)
        let blanks = DocumentBlankFinder.find(in: doc.attributed)
        print("SAMPLE BLANKS: \(blanks.count) · " + blanks.map { "\($0.site)/\($0.kind)/\($0.label)" }.joined(separator: ", "))
        // 표 안 이름표 8칸(성명·영문 성명·학교·학과·학번·학년·연락처·이메일) + 주소 밑줄 + 날짜 월·일 + (인) 서명 = 12
        #expect(blanks.count == 12)
        #expect(blanks.filter { $0.site == .inCell }.count == 8)
        #expect(blanks.filter { $0.kind == .signature }.count == 1)
        #expect(blanks.filter { $0.kind == .month || $0.kind == .day }.count == 2)

        let tv = NSTextView(usingTextLayoutManager: false)
        tv.isRichText = true
        tv.allowsUndo = true
        let session = DocumentSession(area: .word)
        keepAlive += [session, tv]
        session.editor.attach(tv)
        tv.textStorage?.setAttributedString(doc.attributed)
        session.editor.documentLoaded(pageSize: doc.pageSize, margins: doc.margins)
        let fill = DocumentFillModel(session: session, profile: profile, signatures: [])
        let before = tv.string
        let report = try #require(await fill.autoFill(animated: false, useAI: false))
        print("SAMPLE REPORT: \(report.summary)")
        // 이름·학번·연락처(휴대폰)·주소·월·일 = 6칸. 학교·학과·학년·이메일·영문 성명은 내 정보에 없어서 비움, 서명은 저장해 둔 서명이 없어서 비움
        #expect(report.filled == 6)
        #expect(report.needSignature == 1)
        #expect(tv.string.contains("성명: 김한라"))
        #expect(tv.string.contains("학번 20261234"))
        #expect(tv.string.contains("연락처 010-1234-5678"))
        #expect(tv.string.contains("주소 제주시 한라로 1"))
        session.editor.undo.undo()
        #expect(tv.string == before)
    }
}
