import AppCore
import AppKit
import SkillEngine
import SwiftUI

/// 상태 막대의 "지금 보는 쪽 / 전체 쪽"(쪽 보기에서 화면이 알려 준다)
struct DocumentPagePosition: Equatable {
    var current = 1
    var total = 1
}

/// 화면(DocumentCanvas)에게 시키는 일: 제목 자리로 가기, 확대·축소, 찾기 막대 열기.
/// 값이 바뀔 때마다 새 id가 붙어서, 같은 일을 두 번 시켜도(예: 같은 제목을 또 누르기) 화면이 알아본다.
struct CanvasCommand: Equatable {
    enum Kind: Equatable {
        case scroll(location: Int, length: Int)
        case zoomIn, zoomOut, fit, actualSize
        case find
    }
    let id = UUID()
    let kind: Kind
}

/// 워드·한글·노트 영역에서 열어 둔 문서 하나. 2단계: 종이에서 바로 고치고, 원본 옆 `이름_edit.확장자`로 저장한다.
/// 읽기·저장은 백그라운드에서 하고, 화면(DocumentWindowView)은 이 세션만 본다. 글 고치기는 editor(DocumentEditor)가 맡는다.
@MainActor
final class DocumentSession: ObservableObject, AssistantHost {
    enum Mode: String { case simple, detailed }

    let area: DocumentArea
    @Published private(set) var url: URL?
    /// 읽어 온 문서(읽는 중이거나 못 읽었으면 nil)
    @Published private(set) var document: LoadedDocument?
    @Published private(set) var loading = false
    @Published var message: String?
    /// 저장하지 않은 고침이 있다(⌘Z로 처음 상태까지 되돌리면 다시 false)
    @Published private(set) var dirty = false
    /// 지금 커서 자리 모양(도구 막대 단추)
    @Published private(set) var format = DocumentFormatState()
    /// 이 창에서 처음 저장한 뒤로 계속 덮어쓰는 파일(원본 옆 _edit). 아직 저장 안 했으면 nil
    @Published private(set) var savedURL: URL?
    @Published private(set) var saving = false
    /// 잠깐 떴다 사라지는 안내(간단히 보기 위쪽)
    @Published private(set) var notice: String?

    /// 종이(NSTextView)를 고치는 일
    let editor = DocumentEditor()
    /// 이 창의 빈칸 채우기(화면이 만들어 넘겨준다). 요청칸에서 "빈칸 채워 줘"를 받으면 이걸 부른다
    weak var fill: DocumentFillModel?
    /// 고칠 때마다 늘어나는 번호(저장하는 사이에 또 고쳤으면 저장 뒤에도 dirty로 남긴다)
    private var editGeneration = 0
    private var refreshTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    /// 화면에 시킬 일(제목으로 가기·확대·찾기)
    @Published private(set) var command: CanvasCommand?

    /// 간단히 보기 / 자세히 보기. PDF 영역과 같은 키("pdfMode")를 써서 영역끼리 같은 보기로 열린다
    @Published var mode: Mode = Mode(rawValue: UserDefaults.standard.string(forKey: "pdfMode") ?? "") ?? .simple {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "pdfMode") }
    }

    /// 쪽 보기 방식: 한 쪽씩(기본) / 두 쪽씩 / 이어 보기. 창마다가 아니라 이 맥에 기억해 둔다
    @Published var pageLayout: DocumentPageLayout = DocumentPageLayout(rawValue: UserDefaults.standard.string(forKey: "docPageLayout") ?? "") ?? .single {
        didSet { UserDefaults.standard.set(pageLayout.rawValue, forKey: "docPageLayout") }
    }
    /// 지금 보는 쪽 / 전체 쪽(화면이 스크롤·쪽 수가 바뀔 때마다 알려 준다)
    @Published private(set) var pagePosition = DocumentPagePosition()

    func setPagePosition(_ position: DocumentPagePosition) {
        if pagePosition != position { pagePosition = position }
    }

    /// 새 문서가 화면에 떴을 때(창 제목·크기를 맞추려고). 못 읽었을 땐 안 불린다
    var onDocumentShown: (() -> Void)?
    /// 이미 문서가 열린 창에 다른 파일이 오면 새 창으로 넘긴다(창마다 문서 하나). 안 정해 두면 이 창에서 바꿔 연다
    var openElsewhere: ((URL) -> Void)?

    // 아래 AI 요청칸(AssistantHost)
    @Published var assistantPhase: AssistantPhase = .idle
    @Published var assistantReply: String?
    @Published var agentChoices: [Agent] = []
    @Published var currentAgent: Agent?
    /// 직접 고른 AI(nil = 자동). PDF 영역과 같은 키라서 영역끼리 같은 AI를 쓴다
    @Published var assistantAgentID: String? = UserDefaults.standard.string(forKey: "pdfAssistantAgentID") {
        didSet { UserDefaults.standard.set(assistantAgentID, forKey: "pdfAssistantAgentID") }
    }
    /// AI 요청이 실패했을 때 띄울 오류창 내용
    @Published var aiError: String?
    var assistantTask: Task<Void, Never>?

    private var loadTask: Task<Void, Never>?

    init(area: DocumentArea) {
        self.area = area
        editor.onChange = { [weak self] in self?.textChanged() }
        editor.onFormat = { [weak self] state in
            guard let self, self.format != state else { return }
            self.format = state
        }
    }

    var title: String { url?.lastPathComponent ?? "Hanlabong WordPro" }
    var canAsk: Bool { document != nil }
    var askPlaceholder: String { L("물어보거나 고쳐 달라고 해 보세요 · 예: 2026 수능 1컷을 33으로", "Ask or request an edit · e.g. change 44 to 33") }

    // MARK: 열기

    /// 읽어서 보여 준다. 못 읽으면 message에 안내가 뜬다
    func open(_ url: URL) {
        // 문서가 이미 열린 창이거나, 이 창과 영역이 다른 파일(빈 워드 창에 PDF 등)이면 앱이 알맞은 창에서 연다
        let otherArea = DocumentArea.of(url).map { $0 != area } ?? true
        if document != nil || loading || otherArea, let openElsewhere, url.standardizedFileURL != self.url?.standardizedFileURL {
            openElsewhere(url)
            return
        }
        // 1단계는 고침이 없다. 2단계에서는 dirty일 때 여기서 멈추고 물어야 한다
        guard !dirty else {
            message = L("저장하지 않은 고침이 있어요. 먼저 저장하거나 되돌린 뒤에 열어요", "You have unsaved changes. Save or undo them first")
            return
        }
        loadTask?.cancel()
        assistantTask?.cancel()
        assistantReply = nil
        assistantPhase = .idle
        self.url = url
        document = nil
        message = nil
        savedURL = nil
        editGeneration = 0
        loading = true
        loadTask = Task { [weak self] in
            // 파일 읽기·글 짜기는 오래 걸릴 수 있어서 화면 일을 막지 않게 따로 돌린다
            let result: Result<LoadedDocument, Error> = await Task.detached(priority: .userInitiated) {
                Result { try DocumentLoader.load(url) }
            }.value
            guard let self, !Task.isCancelled, self.url == url else { return }
            self.loading = false
            switch result {
            case .success(let loaded):
                self.document = loaded
                self.onDocumentShown?()
            case .failure(let error):
                self.message = (error as? LocalizedError)?.errorDescription
                    ?? L("“\(url.lastPathComponent)”을(를) 열지 못했어요", "Couldn't open “\(url.lastPathComponent)”")
            }
        }
    }

    /// 창을 닫을 때 부르면 일하던 것(읽기·AI)을 멈춘다
    func shutdown() {
        loadTask?.cancel()
        assistantTask?.cancel()
        refreshTask?.cancel()
    }

    // MARK: 고치기

    /// 글이 바뀌었을 때(되돌리기 포함). 되돌리기 기록이 비면(처음 상태) 아직 저장 안 했을 때만 깨끗한 것으로 본다
    private func textChanged() {
        editGeneration += 1
        if message != nil, !saving { message = nil }
        dirty = true
        // 되돌리기 중에는 기록이 아직 정리 전이라 한 박자 늦게 본다
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !self.editor.undo.canUndo, self.savedURL == nil { self.dirty = false }
        }
        // 목차·글자 수는 손을 멈추면 다시 센다
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !Task.isCancelled, let storage = self.editor.textView?.textStorage else { return }
            self.document?.refresh(from: storage)
        }
    }

    func toggleBold() { editor.toggleBold() }
    func toggleItalic() { editor.toggleItalic() }
    /// 키보드 단축키(⌘B·⌘I)용: 문서 종이에 커서가 있을 때만
    func toggleBoldShortcut() { editor.toggleBoldShortcut() }
    func toggleItalicShortcut() { editor.toggleItalicShortcut() }
    func setFontSize(_ size: CGFloat) { editor.setFontSize(size) }
    func changeFontSize(up: Bool) { editor.changeFontSize(up: up) }
    func setFontFamily(_ name: String?) { editor.setFontFamily(name) }
    func setTextColor(_ color: NSColor?) { editor.setTextColor(color) }
    func setAlignment(_ alignment: NSTextAlignment) { editor.setAlignment(alignment) }
    func setHeading(_ level: Int?) { editor.setHeading(level) }
    func toggleBullet() { editor.toggleBullet() }
    func insertTable(rows: Int, columns: Int) { editor.insertTable(rows: rows, columns: columns) }
    func editTable(_ edit: DocumentEditor.TableEdit) {
        if !editor.editTable(edit) {
            message = L("이 표는 이렇게 못 고쳐요 (합친 칸이 있거나 마지막 줄·칸이에요)", "Can't change this table that way (merged cells, or it's the last row/column)")
        }
    }
    func insertPageBreak() { editor.insertPageBreak() }
    func insertImage(_ url: URL) {
        if !editor.insertImage(from: url) {
            message = L("“\(url.lastPathComponent)” 그림을 읽지 못했어요", "Couldn't read the picture “\(url.lastPathComponent)”")
        }
    }

    // MARK: 저장(원본은 절대 덮어쓰지 않는다)

    /// 원본 형식으로 저장할 형식. 우리가 못 쓰는 옛 형식은 새 형식으로: .hwp → .hwpx, .doc → .docx
    static func saveFormat(for url: URL) -> DocumentFormat {
        switch url.pathExtension.lowercased() {
        case "hwpx", "hwp": return .hwpx
        case "rtf", "rtfd": return .rtf
        case "odt": return .odt
        case "epub": return .epub
        case "md", "markdown": return .md
        case "txt", "text": return .txt
        case "html", "htm", "xhtml": return .html
        default: return .docx
        }
    }

    /// 저장 한 번에 필요한 것(화면에서 떼어 낸 글 복사본이라 백그라운드에서 써도 된다)
    struct SaveJob: @unchecked Sendable {
        var text: NSAttributedString
        var title: String
        var pageSize: CGSize?
        /// 읽어 온 원래 문서(여백·머리글·꼬리글·쪽 번호·본문 글꼴을 이어 쓴다)
        var basedOn: RichDocument? = nil
        var format: DocumentFormat
        var original: URL
        /// 이미 만든 _edit 파일(있으면 덮어쓴다)
        var existing: URL?
        /// 다른 형식으로 저장: 고른 자리
        var destination: URL?
    }

    /// 쓰기: 처음엔 원본 옆 `이름_edit.확장자`(있으면 `_edit (1)`…, PDF 영역과 같은 FileOutputWriter 규칙), 다음부턴 그 파일을 덮어쓴다
    nonisolated static func perform(_ job: SaveJob) throws -> URL {
        let rich = RichDocumentEditing.document(from: job.text, title: job.title, pageSize: job.pageSize, basedOn: job.basedOn)
        let data = try RichDocumentWriter.write(rich, as: job.format)
        let original = job.original.standardizedFileURL
        if let target = job.destination ?? job.existing {
            guard target.standardizedFileURL != original else { throw SaveError.wouldOverwriteOriginal }
            do { try data.write(to: target, options: .atomic) } catch { throw SaveError.writeFailed(target.lastPathComponent) }
            return target
        }
        return try FileOutputWriter.save(data, fileExtension: job.format.fileExtension, suffix: "_edit", besideOriginal: job.original)
    }

    enum SaveError: LocalizedError {
        case wouldOverwriteOriginal, writeFailed(String)
        var errorDescription: String? {
            switch self {
            case .wouldOverwriteOriginal: return L("원본 파일에는 덮어쓸 수 없어요. 다른 이름을 골라 줘요", "The original can't be overwritten. Pick another name")
            case .writeFailed(let name): return L("“\(name)”에 쓰지 못했어요", "Couldn't write “\(name)”")
            }
        }
    }

    private func makeJob(format: DocumentFormat? = nil, destination: URL? = nil) -> SaveJob? {
        guard let url, let document, let storage = editor.textView?.textStorage else { return nil }
        let wanted = format ?? Self.saveFormat(for: url)
        return SaveJob(text: NSAttributedString(attributedString: storage), title: document.title, pageSize: document.pageSize,
                       basedOn: document.source,
                       format: wanted, original: url, existing: destination == nil ? savedURL : nil, destination: destination)
    }

    /// ⌘S · 저장 단추: 백그라운드에서 쓰고 끝나면 알려 준다
    func saveInBackground() {
        guard !saving, let job = makeJob() else { return }
        run(job, asExport: false)
    }

    /// 다른 형식으로 저장(⌘⇧S): 고른 자리에 고른 형식으로. 원본 자리는 거절
    func export(to destination: URL, as format: DocumentFormat) {
        guard !saving, let job = makeJob(format: format, destination: destination) else { return }
        run(job, asExport: true)
    }

    private func run(_ job: SaveJob, asExport: Bool) {
        saving = true
        let generation = editGeneration
        message = L("저장하는 중…", "Saving…")
        Task { [weak self] in
            let result: Result<URL, Error> = await Task.detached(priority: .userInitiated) { Result { try Self.perform(job) } }.value
            guard let self else { return }
            self.saving = false
            self.finishSave(result, generation: generation, asExport: asExport)
        }
    }

    private func finishSave(_ result: Result<URL, Error>, generation: Int, asExport: Bool) {
        switch result {
        case .success(let out):
            if !asExport { savedURL = out }
            if generation == editGeneration { dirty = false }
            let text = L("\(out.lastPathComponent)로 저장했어요", "Saved as \(out.lastPathComponent)")
            message = text
            show(notice: text)
        case .failure(let error):
            let text = (error as? LocalizedError)?.errorDescription ?? L("저장하지 못했어요", "Couldn't save")
            message = text
            show(notice: text)
        }
    }

    /// 창 닫기·앱 끄기(main.swift)에서: 끝날 때까지 기다렸다가 성공했는지 돌려준다. 실패하면 알림창을 띄운다
    @discardableResult
    func save() -> Bool {
        guard let job = makeJob() else { return true }
        let generation = editGeneration
        let result = Result { try Self.perform(job) }
        finishSave(result, generation: generation, asExport: false)
        if case .failure = result {
            let alert = NSAlert()
            alert.messageText = message ?? L("저장하지 못했어요", "Couldn't save")
            alert.runModal()
            return false
        }
        return true
    }

    private func show(notice text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    /// 저장하면 생길 파일 이름(안내용)
    var saveTargetName: String {
        if let savedURL { return savedURL.lastPathComponent }
        guard let url else { return "" }
        return url.deletingPathExtension().lastPathComponent + "_edit." + Self.saveFormat(for: url).fileExtension
    }

    // MARK: 화면에 시키는 일

    func send(_ kind: CanvasCommand.Kind) { command = CanvasCommand(kind: kind) }

    /// 목차에서 누르면 그 제목 자리로
    func scroll(to item: DocumentOutlineItem) {
        guard let location = item.location else { return }
        send(.scroll(location: location, length: item.length))
    }

    /// 상태 막대·배지 안내: 저장 상태
    var hint: String {
        if saving { return L("저장하는 중…", "Saving…") }
        if dirty { return L("저장 안 한 고침 있음 · ⌘S로 \(saveTargetName)에 저장", "Unsaved changes · ⌘S saves to \(saveTargetName)") }
        if let savedURL { return L("저장됨 · \(savedURL.lastPathComponent)", "Saved · \(savedURL.lastPathComponent)") }
        if document?.isLegacyHwp == true {
            return L("옛 .hwp 파일이에요 · 저장은 .hwpx로 해요", "Legacy .hwp file · saving will use .hwpx")
        }
        if url?.pathExtension.lowercased() == "doc" {
            return L("옛 .doc 파일이에요 · 저장은 .docx로 해요", "Legacy .doc file · saving will use .docx")
        }
        return L("고치면 원본은 그대로 두고 옆에 \(saveTargetName)로 저장해요", "Edits save beside the original as \(saveTargetName)")
    }
}
