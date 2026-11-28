import AppCore
import AppKit
import PDFKit
import SkillEngine
import SwiftUI

/// 열어 둔 PDF 하나. 고칠 때마다 직전 상태를 PDF 바이트로 남겨서 ⌘Z로 되돌린다.
/// 저장은 언제나 원본 옆에 새 파일(_edit)로. 원본은 덮어쓰지 않는다.
@MainActor
final class PDFSession: ObservableObject {
    @Published private(set) var url: URL?
    @Published private(set) var document: PDFDocument?
    @Published private(set) var dirty = false
    /// 마지막으로 열거나 저장했을 때의 입력칸 값. 사용자가 칸에 직접 친 글은 dirty에 안 잡혀서 닫을 때 이것과 비교한다
    private var savedFormValues: [String] = []
    /// 저장 안 한 고침이 있는지(표시·쪽 고침 + 입력칸에 직접 친 글)
    var hasUnsavedChanges: Bool {
        dirty || (document.map { Self.formValues($0) != savedFormValues } ?? false)
    }

    /// 문서의 모든 입력칸 값(이름·글·체크 상태)
    static func formValues(_ document: PDFDocument) -> [String] {
        var values: [String] = []
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            for a in page.annotations where a.type == "Widget" {
                values.append("\(i)|\(a.fieldName ?? "")|\(a.widgetStringValue ?? "")|\(a.buttonWidgetState.rawValue)")
            }
        }
        return values
    }
    @Published var message: String?
    @Published var needsPassword = false
    @Published var searchText = ""
    @Published private(set) var matches: [PDFSelection] = []
    @Published var matchIndex = 0
    /// 화면(PDFView)이 붙으면 채워진다. 지금 보는 쪽·고른 글자를 알아야 해서
    weak var view: MarkupPDFView?
    /// 새 문서를 열었을 때(창 크기를 쪽 모양에 맞추려고)
    var onDocumentShown: ((PDFDocument) -> Void)?
    /// 이미 문서가 열린 창에 다른 파일이 오면 새 창으로 넘긴다(창마다 문서 하나)
    var openElsewhere: (([URL]) -> Void)?
    /// 한 쪽이 통째로 보이게 맞춘 상태(직접 확대·축소하면 풀린다). 창 크기가 바뀌면 다시 맞춘다
    var fitsPage = true

    // 표시 도구
    @Published var tool = MarkupTool.select { didSet { if tool != .select { view?.deselect() } } }
    @Published var color = NSColor.systemRed
    @Published var lineWidth: CGFloat = 2
    @Published var fontSize: CGFloat = 14
    @Published var selectedAnnotation: PDFAnnotation?
    /// 글자 넣기·메모처럼 글을 받아야 할 때 화면에 띄울 물음
    @Published var prompt: TextPrompt?
    /// 서명 그리기 창
    @Published var signing = false
    @Published var signatures: [Signature] = SignatureStore.load()
    var pendingSignaturePlace: (page: PDFPage, point: CGPoint)?
    /// 고칠 때마다 바뀌어서, 목차·표시 목록이 다시 그려지게
    @Published private(set) var revision = 0

    // 간단히 보기 / 자세히 보기
    enum Mode: String { case simple, detailed }
    @Published var mode: Mode = Mode(rawValue: UserDefaults.standard.string(forKey: "pdfMode") ?? "") ?? .simple {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "pdfMode"); if mode == .simple { tool = .select } }
    }
    /// 책처럼 두 쪽씩 볼지, 한 장씩 볼지
    @Published var bookLayout = UserDefaults.standard.bool(forKey: "pdfBookLayout") {
        didSet { UserDefaults.standard.set(bookLayout, forKey: "pdfBookLayout"); applyLayout() }
    }
    /// 두 쪽 볼 때 1쪽을 혼자(표지처럼) 둘지. 문서마다 기억한다(짝이 밀려 보이는 책 고치기)
    @Published var coverAlone = true { didSet { applyLayout(); saveReaderState() } }
    /// 지금 보는 쪽(0부터)
    @Published var currentPage = 0
    /// AI·책갈피로 나눈 파트
    @Published var bookIndex: BookIndex?
    @Published var indexing = false
    /// 책 나누기 진행 상황(단계·몇 %·시작 시각)
    @Published var indexProgress: IndexProgress?
    var indexTask: Task<Void, Never>?
    /// 내 정보(채우기용, 이 맥에만)
    @Published var profile: UserProfile = ProfileStore.load()
    @Published var editingProfile = false
    /// 아래 AI 요청칸: 지금 하는 일·AI 답
    @Published var assistantPhase: AssistantPhase = .idle
    @Published var assistantReply: String?
    var assistantTask: Task<Void, Never>?
    /// 요청칸에서 고를 수 있는 AI들과 지금 쓰는 AI
    @Published var agentChoices: [Agent] = []
    @Published var currentAgent: Agent?
    /// 요청칸에서 직접 고른 AI(없으면 자동 = 한라봉 설정을 따른다). PDF 앱에만 기억
    @Published var assistantAgentID: String? = UserDefaults.standard.string(forKey: "pdfAssistantAgentID") {
        didSet { UserDefaults.standard.set(assistantAgentID, forKey: "pdfAssistantAgentID") }
    }
    /// AI 요청이 실패했을 때 띄울 오류창 내용
    @Published var aiError: String?
    /// 파트로 건너뛰기 전에 있던 쪽들(되돌아가기)
    @Published var history: [Int] = []
    /// 파트마다 마지막으로 보던 쪽(문제 ↔ 답지를 오갈 때 보던 자리로 돌아가게)
    var lastPageInPart: [String: Int] = [:]

    private var undoStack: [Data] = []
    private var redoStack: [Data] = []
    private var lockedDocument: PDFDocument?
    private var pendingURL: URL?

    var title: String { url?.lastPathComponent ?? "Hanlabong WordPro" }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // MARK: 열기

    /// PDF는 그대로, 한글(.hwp·.hwpx)·Word 등 문서는 PDF로 바꿔서, 사진은 한 쪽짜리로 연다.
    /// 창 하나에 문서 하나(여러 개면 창이 따로 뜬다). 합치기는 "뒤에 붙이기"로.
    func open(_ urls: [URL]) {
        var urls = urls
        if let openElsewhere {
            // 워드·한글·노트처럼 다른 영역의 파일은 이 PDF 창에서 PDF로 바꾸지 않고 그 영역 창으로 넘긴다
            let foreign = urls.filter { (DocumentArea.of($0) ?? .pdf) != .pdf }
            if !foreign.isEmpty {
                urls.removeAll { (DocumentArea.of($0) ?? .pdf) != .pdf }
                // 이 창 화면(끌어 놓기 처리 중)을 바로 갈아 끼우지 않게 한 박자 뒤에
                DispatchQueue.main.async { openElsewhere(foreign) }
            }
        }
        guard let first = urls.first else { return }
        if let openElsewhere {
            // 창마다 문서 하나: 이미 문서가 열린 창이면 새 창에서, 여러 개면 첫 파일만 여기 나머지는 각자 새 창에
            if document != nil { openElsewhere(urls); return }
            if urls.count > 1 { openElsewhere(Array(urls.dropFirst())); open([first]); return }
        }
        // 새 파일이 오면 바꿔서 연다. 저장 안 한 고침이 있으면 날리지 않게 멈춘다(뒤에 붙이기는 "합치기"로)
        if document != nil {
            guard !hasUnsavedChanges else {
                message = L("저장하지 않은 고침이 있어요. 먼저 저장하거나 되돌린 뒤에 열어요", "You have unsaved changes. Save or undo them first")
                return
            }
            reset()
        }
        guard let doc = load(first) else { return }
        if doc.isLocked {
            lockedDocument = doc
            pendingURL = first
            needsPassword = true
            return
        }
        show(doc, url: first)
        if urls.count > 1 {
            append(Array(urls.dropFirst()))      // 여러 개를 한꺼번에 넘기면 합치기
        }
    }

    private func load(_ url: URL) -> PDFDocument? {
        if let doc = PDFDocument(url: url), doc.pageCount > 0 { return doc }
        let kind = FileKindDetector.kind(of: url)
        do {
            if kind == .document || kind == .text {
                // 워드·RTF는 모양(용지·단·글꼴·줄 간격)을 살려서, 나머지(한글 등)는 글만
                let data = try LayoutPDF.make(from: url) ?? RichDocumentWriter.write(try RichDocumentReader.read(url), as: .pdf)
                message = L("“\(url.lastPathComponent)”을(를) PDF로 바꿔서 열었어요", "Converted “\(url.lastPathComponent)” to PDF")
                return PDFDocument(data: data)
            }
            return try PDFPageEditor.openExtra(url)
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? L("“\(url.lastPathComponent)”을(를) 열지 못했어요", "Couldn't open “\(url.lastPathComponent)”")
            return nil
        }
    }

    func unlock(with password: String) -> Bool {
        guard let doc = lockedDocument, let url = pendingURL else { return false }
        guard doc.unlock(withPassword: password) else { return false }
        needsPassword = false
        lockedDocument = nil
        show(doc, url: url)
        message = L("암호를 풀었어요. 저장하면 암호 없는 사본이 돼요", "Unlocked. Saving makes a copy without the password")
        return true
    }

    private func show(_ doc: PDFDocument, url: URL) {
        document = doc
        self.url = url
        dirty = false
        savedFormValues = Self.formValues(doc)
        undoStack = []
        redoStack = []
        view?.document = doc
        currentPage = 0
        history = []
        lastPageInPart = [:]
        loadReaderState()
        applyLayout()
        fitsPage = true
        onDocumentShown?(doc)
        DispatchQueue.main.async { self.fitPage() }
        recognizeScannedPages(doc)
    }

    /// 스캔한 쪽(글자가 없는 쪽)은 열자마자 이 맥 안에서 글자를 인식해 보이지 않는 글자 층을 얹는다.
    /// 그래야 글자 선택·찾기·AI 요청·빈칸 채우기가 스캔 문서에서도 된다. 모양은 그대로고, 주석이 있는 쪽은 건드리지 않는다.
    private func recognizeScannedPages(_ doc: PDFDocument) {
        let targets = ScanTextLayer.scannedPages(doc).prefix(200).filter { (doc.page(at: $0)?.annotations ?? []).isEmpty }
        guard !targets.isEmpty else { return }
        message = L("스캔한 문서라 글자를 인식하는 중… (\(targets.count)쪽)", "Scanned document — recognizing text… (\(targets.count) pages)")
        Task { @MainActor [weak self] in
            var done = 0
            for index in targets {
                guard let self, self.document === doc, let page = doc.page(at: index), page.annotations.isEmpty else { return }
                // 그 쪽만 떼어 낸 한 쪽 PDF(데이터라 백그라운드로 넘겨도 안전하다)
                let single = PDFDocument()
                guard let copy = page.copy() as? PDFPage else { continue }
                single.insert(copy, at: 0)
                guard let data = single.dataRepresentation() else { continue }
                let result = await Task.detached(priority: .userInitiated) { try? ScanTextLayer.addText(toPage: data) }.value
                guard self.document === doc, doc.page(at: index) === page, page.annotations.isEmpty,
                      let result, let newPage = PDFDocument(data: result)?.page(at: 0) else { continue }
                let wasShowing = self.view?.currentPage === page
                doc.removePage(at: index)
                doc.insert(newPage, at: index)
                if wasShowing { self.view?.go(to: newPage) }
                done += 1
            }
            guard let self, self.document === doc else { return }
            self.view?.layoutDocumentView()
            self.message = done > 0
                ? L("스캔한 쪽 \(done)쪽의 글자를 인식했어요. 이제 글자 선택·찾기·AI 요청이 돼요", "Recognized text on \(done) scanned pages")
                : L("스캔한 쪽에서 글자를 찾지 못했어요", "No text found on the scanned pages")
        }
    }

    private func reset() {
        bookIndex = nil; history = []
        document = nil; url = nil; dirty = false; savedFormValues = []; undoStack = []; redoStack = []; matches = []
    }

    // MARK: 고치기(되돌릴 수 있게 직전 상태를 남긴다)

    func change(_ name: String, _ body: (PDFDocument) -> Void) {
        guard let document else { return }
        beginEdit()
        body(document)
        endEdit(name)
        if let page = view?.currentPage { view?.annotationsChanged(on: page) }
    }

    func replace(with data: Data) {
        guard let doc = PDFDocument(data: data) else { return }
        let page = view?.currentPage.flatMap { document?.index(for: $0) } ?? 0
        document = doc
        view?.document = doc
        if let target = doc.page(at: min(page, doc.pageCount - 1)) { view?.go(to: target) }
        revision += 1
    }

    // MARK: 마우스로 그리는 고침(시작할 때 직전 상태를 남기고, 끝나면 확정)

    func beginEdit() {
        guard let before = document?.dataRepresentation() else { return }
        undoStack.append(before)
        if undoStack.count > 30 { undoStack.removeFirst() }
        redoStack = []
    }

    func endEdit(_ name: String) {
        dirty = true
        message = name
        revision += 1
    }

    /// 아무것도 안 바뀌었으면 남겨 둔 상태를 버린다
    func cancelEdit() { _ = undoStack.popLast() }

    func undo() {
        guard let last = undoStack.popLast(), let now = document?.dataRepresentation() else { return }
        redoStack.append(now)
        replace(with: last)
        dirty = true
    }

    func redo() {
        guard let next = redoStack.popLast(), let now = document?.dataRepresentation() else { return }
        undoStack.append(now)
        replace(with: next)
        dirty = true
    }

    /// 다른 PDF·사진·문서를 맨 뒤에 붙인다
    func append(_ urls: [URL]) {
        let docs = urls.compactMap { url -> (URL, PDFDocument)? in load(url).map { (url, $0) } }
        guard !docs.isEmpty else { return }
        change(L("\(docs.count)개 파일을 뒤에 붙였어요", "Appended \(docs.count) files")) { document in
            for (_, extra) in docs {
                for i in 0..<extra.pageCount {
                    if let page = extra.page(at: i)?.copy() as? PDFPage { document.insert(page, at: document.pageCount) }
                }
            }
        }
    }

    func chooseAndAppend() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .image, .data]
        panel.allowsMultipleSelection = true
        panel.message = L("뒤에 붙일 PDF·사진·문서를 골라요", "Choose PDFs, photos or documents to append")
        if panel.runModal() == .OK { append(panel.urls) }
    }

    /// 쪽 정리 창(한라봉 편집 창과 같은 것)의 결과를 지금 문서에 입힌다
    func applyPageEdit(_ skill: FileSkill) {
        guard let document, case .pdfPages(let edit)? = skill.steps.last else { return }
        do {
            let data = try PDFPageEditor.make(document, edit: edit)
            guard let before = document.dataRepresentation() else { return }
            undoStack.append(before)
            redoStack = []
            replace(with: data)
            dirty = true
            message = L("쪽을 정리했어요 (\(edit.pages.count)쪽)", "Pages rearranged (\(edit.pages.count) pages)")
        } catch {
            message = (error as? LocalizedError)?.errorDescription
        }
    }

    func rotateCurrent(clockwise: Bool) {
        guard let page = view?.currentPage else { return }
        change(L("쪽을 돌렸어요", "Rotated the page")) { _ in page.rotation = (page.rotation + (clockwise ? 90 : 270)) % 360 }
    }

    // MARK: 주석

    /// 고른 글자 위에 형광펜·밑줄·취소선(지금 고른 색). 줄마다 따로 붙인다(여러 줄도 모양이 맞게)
    func mark(_ kind: MarkupTool) {
        guard let selection = view?.currentSelection, !(selection.string ?? "").isEmpty else { return }
        let type: PDFAnnotationSubtype = kind == .highlight ? .highlight : kind == .underline ? .underline : .strikeOut
        let tint = color
        change(kind.title) { _ in
            for line in selection.selectionsByLine() {
                for page in line.pages {
                    let annotation = PDFAnnotation(bounds: line.bounds(for: page), forType: type, withProperties: nil)
                    annotation.color = kind == .highlight ? tint.withAlphaComponent(0.45) : tint
                    page.addAnnotation(annotation)
                }
            }
        }
        view?.clearSelection()
    }

    /// 보고 있는 쪽에 내가 붙인 표시·메모·글자를 지운다(링크·서식 칸은 남긴다)
    func clearMarksOnPage() {
        guard let page = view?.currentPage else { return }
        let mine: Set<PDFAnnotationSubtype> = [.highlight, .underline, .strikeOut, .text, .freeText, .popup]
        let targets = page.annotations.filter { mine.contains(PDFAnnotationSubtype(rawValue: "/" + ($0.type ?? ""))) }
        guard !targets.isEmpty else { message = L("이 쪽엔 지울 표시가 없어요", "No marks on this page"); return }
        change(L("이 쪽의 표시 \(targets.count)개를 지웠어요", "Removed \(targets.count) marks on this page")) { _ in
            targets.forEach(page.removeAnnotation)
        }
    }

    // MARK: 찾기

    func search() {
        guard let document, !searchText.isEmpty else { matches = []; view?.highlightedSelections = nil; return }
        matches = document.findString(searchText, withOptions: [.caseInsensitive, .diacriticInsensitive])
        let accent = AppAccent.nsColor(UserDefaults.standard.string(forKey: AppAccent.key) ?? AppAccent.defaultHex) ?? .systemYellow
        matches.forEach { $0.color = accent.withAlphaComponent(0.5) }
        view?.highlightedSelections = matches
        matchIndex = 0
        goToMatch()
        message = matches.isEmpty ? L("찾는 글자가 없어요", "No matches") : nil
    }

    func step(_ delta: Int) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + delta + matches.count) % matches.count
        goToMatch()
    }

    private func goToMatch() {
        guard matches.indices.contains(matchIndex) else { return }
        view?.setCurrentSelection(matches[matchIndex], animate: true)
        view?.scrollSelectionToVisible(nil)
    }

    // MARK: 저장(원본 옆에 새 파일)

    enum SaveKind { case normal, smaller, password(String), split(every: Int) }

    /// 저장했으면 true. 실패하면 message에 까닭을 띄우고 false(닫기·끄기를 막을 수 있게)
    @discardableResult
    func save(_ kind: SaveKind) -> Bool {
        guard let document, let url else { return false }
        do {
            switch kind {
            case .normal:
                guard let data = try burnedRedactions(document).dataRepresentation() else { throw FileSkillError.encodeFailed("PDF") }
                finish([try FileOutputWriter.save(data, fileExtension: "pdf", suffix: "_edit", besideOriginal: url)])
            case .smaller:
                let options: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]
                guard let data = try burnedRedactions(document).dataRepresentation(options: options) else { throw FileSkillError.encodeFailed("PDF") }
                let before = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let out = try FileOutputWriter.save(data, fileExtension: "pdf", suffix: "_small", besideOriginal: url)
                finish([out], note: before > 0 ? L(" (\(before / 1000)KB → \(data.count / 1000)KB)", " (\(before / 1000) KB → \(data.count / 1000) KB)") : "")
            case .password(let password):
                let options: [PDFDocumentWriteOption: Any] = [.userPasswordOption: password, .ownerPasswordOption: password]
                guard let data = try burnedRedactions(document).dataRepresentation(options: options) else { throw FileSkillError.encodeFailed("PDF") }
                finish([try FileOutputWriter.save(data, fileExtension: "pdf", suffix: "_locked", besideOriginal: url)])
            case .split(let every):
                let n = max(1, every)
                // 나눠 저장도 가린 쪽을 먼저 굳힌다(안 그러면 가린 밑글자가 나눈 파일에 그대로 남는다)
                let source = try burnedRedactions(document)
                var outputs: [URL] = []
                var start = 0, part = 1
                while start < source.pageCount {
                    let piece = PDFDocument()
                    for i in start..<min(start + n, source.pageCount) {
                        guard let page = source.page(at: i)?.copy() as? PDFPage else { throw FileSkillError.encodeFailed("PDF") }
                        piece.insert(page, at: piece.pageCount)
                    }
                    guard let data = piece.dataRepresentation() else { throw FileSkillError.encodeFailed("PDF") }
                    outputs.append(try FileOutputWriter.save(data, fileExtension: "pdf", suffix: "_part\(part)", besideOriginal: url))
                    start += n; part += 1
                }
                finish(outputs)
            }
            return true
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? L("저장하지 못했어요", "Couldn't save")
            return false
        }
    }

    private func finish(_ outputs: [URL], note: String = "") {
        if case .some = outputs.first, outputs.count == 1 {
            message = L("저장했어요: \(outputs[0].lastPathComponent)", "Saved: \(outputs[0].lastPathComponent)") + note
        } else {
            message = L("\(outputs.count)개 파일로 저장했어요", "Saved \(outputs.count) files") + note
        }
        dirty = false
        if let document { savedFormValues = Self.formValues(document) }
    }
}

/// 아래 AI 요청칸·모델 칩(SharedChrome.swift)이 PDF 영역을 그릴 때 쓰는 것
extension PDFSession: AssistantHost {
    var canAsk: Bool { document != nil }
    var askPlaceholder: String {
        L("AI에게 부탁하기 · 예: 내 정보로 채워줘, 이 쪽 요약해줘, 해설로 가줘", "Ask AI · e.g. fill this with my info, summarize this page")
    }
}
