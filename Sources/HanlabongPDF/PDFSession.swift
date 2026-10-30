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
    @Published var message: String?
    @Published var needsPassword = false
    @Published var searchText = ""
    @Published private(set) var matches: [PDFSelection] = []
    @Published var matchIndex = 0
    /// 화면(PDFView)이 붙으면 채워진다. 지금 보는 쪽·고른 글자를 알아야 해서
    weak var view: MarkupPDFView?

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

    private var undoStack: [Data] = []
    private var redoStack: [Data] = []
    private var lockedDocument: PDFDocument?
    private var pendingURL: URL?

    var title: String { url?.lastPathComponent ?? "Hanlabong PDF" }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // MARK: 열기

    /// PDF는 그대로, 한글(.hwp·.hwpx)·Word 등 문서는 PDF로 바꿔서, 사진은 한 쪽짜리로 연다.
    /// 여러 개를 한꺼번에 넘기면 첫 파일 뒤에 차례대로 붙인다(합치기).
    func open(_ urls: [URL]) {
        guard let first = urls.first else { return }
        // 새 파일이 오면 바꿔서 연다. 저장 안 한 고침이 있으면 날리지 않게 멈춘다(뒤에 붙이기는 "합치기"로)
        if document != nil {
            guard !dirty else {
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
                let data = try RichDocumentWriter.write(try RichDocumentReader.read(url), as: .pdf)
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
        undoStack = []
        redoStack = []
        view?.document = doc
    }

    private func reset() {
        document = nil; url = nil; dirty = false; undoStack = []; redoStack = []; matches = []
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

    func save(_ kind: SaveKind) {
        guard let document, let url else { return }
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
                var outputs: [URL] = []
                var start = 0, part = 1
                while start < document.pageCount {
                    let piece = PDFDocument()
                    for i in start..<min(start + n, document.pageCount) {
                        if let page = document.page(at: i)?.copy() as? PDFPage { piece.insert(page, at: piece.pageCount) }
                    }
                    guard let data = piece.dataRepresentation() else { throw FileSkillError.encodeFailed("PDF") }
                    outputs.append(try FileOutputWriter.save(data, fileExtension: "pdf", suffix: "_part\(part)", besideOriginal: url))
                    start += n; part += 1
                }
                finish(outputs)
            }
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? L("저장하지 못했어요", "Couldn't save")
        }
    }

    private func finish(_ outputs: [URL], note: String = "") {
        if case .some = outputs.first, outputs.count == 1 {
            message = L("저장했어요: \(outputs[0].lastPathComponent)", "Saved: \(outputs[0].lastPathComponent)") + note
        } else {
            message = L("\(outputs.count)개 파일로 저장했어요", "Saved \(outputs.count) files") + note
        }
        dirty = false
    }
}
