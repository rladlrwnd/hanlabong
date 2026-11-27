import AppCore
import AppKit
import PDFKit
import SkillEngine
import SwiftUI

/// 화면에 띄울 글 입력 물음(글자 넣기·메모·고치기)
struct TextPrompt: Identifiable {
    let id = UUID()
    let title: String
    var text: String
    let done: (String) -> Void
}

/// 서명 하나: 0~1로 맞춘 획들(가로 기준). 이 맥에만 저장한다
struct Signature: Codable, Identifiable, Equatable {
    var id = UUID()
    var strokes: [[CGPoint]]
    /// 세로/가로 비율
    var aspect: Double
    /// 점마다 굵기(가로 기준 0~1). 트랙패드로 쓴 서명은 빠르기·누르는 힘에 따라 굵기가 바뀐다. 예전 서명은 없음
    var widths: [[Double]]? = nil
}

enum SignatureStore {
    static var fileURL: URL { AppPaths.supportFolder.appendingPathComponent("signatures.json") }
    static func load() -> [Signature] {
        (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([Signature].self, from: $0) } ?? []
    }
    static func save(_ list: [Signature]) {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(list).write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
}

/// 왼쪽 목차 한 줄
struct OutlineRow: Identifiable {
    let id = UUID()
    let title: String
    let depth: Int
    let destination: PDFDestination?
}

/// 왼쪽 "표시 목록" 한 줄
struct MarkRow: Identifiable {
    let id = UUID()
    let annotation: PDFAnnotation
    let pageIndex: Int
    let kind: String
    let text: String
}

extension PDFSession {
    // MARK: 글자·메모·서명 놓기

    func placeText(on page: PDFPage, at point: CGPoint) {
        prompt = TextPrompt(title: L("넣을 글자", "Text to add"), text: "") { [weak self] text in
            guard let self, !text.isEmpty else { return }
            let font = NSFont.systemFont(ofSize: self.fontSize)
            let size = (text as NSString).boundingRect(with: CGSize(width: 400, height: 2000), options: [.usesLineFragmentOrigin],
                                                       attributes: [.font: font]).size
            self.change(L("글자를 넣었어요", "Added text")) { _ in
                let box = PDFAnnotation(bounds: CGRect(x: point.x, y: point.y - size.height - 6, width: size.width + 12, height: size.height + 8),
                                        forType: .freeText, withProperties: nil)
                box.contents = text
                box.font = font
                box.fontColor = self.color
                box.color = .clear
                let border = PDFBorder(); border.lineWidth = 0
                box.border = border
                page.addAnnotation(box)
            }
        }
    }

    func placeNote(on page: PDFPage, at point: CGPoint) {
        prompt = TextPrompt(title: L("메모", "Note"), text: "") { [weak self] text in
            guard let self, !text.isEmpty else { return }
            self.change(L("메모를 붙였어요", "Added a note")) { _ in
                let note = PDFAnnotation(bounds: CGRect(x: point.x, y: point.y - 20, width: 20, height: 20), forType: .text, withProperties: nil)
                note.contents = text
                note.color = self.color
                page.addAnnotation(note)
            }
        }
    }

    /// 글자 상자·메모를 두 번 누르면 내용 고치기
    func editText(of annotation: PDFAnnotation) {
        prompt = TextPrompt(title: L("내용 고치기", "Edit text"), text: annotation.contents ?? "") { [weak self] text in
            guard let self else { return }
            self.change(L("고쳤어요", "Edited")) { _ in annotation.contents = text }
        }
    }

    func remove(_ annotation: PDFAnnotation) { remove([annotation]) }

    func remove(_ annotations: [PDFAnnotation]) {
        guard !annotations.isEmpty else { return }
        change(L("지웠어요", "Deleted")) { _ in for a in annotations { a.page?.removeAnnotation(a) } }
    }

    func selectionChanged(_ annotation: PDFAnnotation?) { selectedAnnotation = annotation }

    /// 고른 표시의 색 바꾸기
    func recolorSelection() {
        guard let a = selectedAnnotation else { return }
        let tint = color
        change(L("색을 바꿨어요", "Recolored")) { _ in
            if a.type == "FreeText" { a.fontColor = tint } else if a.type == "Highlight" { a.color = tint.withAlphaComponent(0.45) } else { a.color = tint }
        }
    }

    /// 서명: 저장해 둔 게 있으면 첫 번째를 놓고, 없으면 서명 그리기 창을 연다
    func placeSignature(on page: PDFPage, at point: CGPoint) {
        guard let signature = signatures.first else {
            pendingSignaturePlace = (page, point)
            signing = true
            return
        }
        stamp(signature, on: page, at: point)
    }

    func stamp(_ signature: Signature, on page: PDFPage, at point: CGPoint) {
        let width: CGFloat = 160, height = width * CGFloat(signature.aspect)
        let box = CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)
        let tint = color == .systemRed ? NSColor.black : color
        change(L("서명을 넣었어요", "Signed")) { _ in
            for a in signatureAnnotations(signature, in: box, tint: tint) { page.addAnnotation(a) }
        }
    }

    func addSignature(_ signature: Signature) {
        signatures.insert(signature, at: 0)
        SignatureStore.save(signatures)
        if let place = pendingSignaturePlace { stamp(signature, on: place.page, at: place.point) }
        pendingSignaturePlace = nil
    }

    func deleteSignature(_ signature: Signature) {
        signatures.removeAll { $0.id == signature.id }
        SignatureStore.save(signatures)
    }

    // MARK: 가리기: 저장할 때 그 쪽을 그림으로 다시 만들어서 밑에 있던 글자까지 없앤다

    /// 가리기 표시가 있는 쪽만 그림으로 굳힌 사본. 없으면 원래 문서 그대로
    func burnedRedactions(_ document: PDFDocument) throws -> PDFDocument {
        guard let burned = PDFRedaction.burned(document) else { return document }
        message = L("가린 쪽은 그림으로 바뀌어서 그 쪽 글자는 고를 수 없어요", "Redacted pages became images, so their text can't be selected")
        return burned
    }

    // MARK: 목차·표시 목록

    var outline: [OutlineRow] {
        _ = revision
        guard let root = document?.outlineRoot else { return [] }
        var rows: [OutlineRow] = []
        func walk(_ item: PDFOutline, depth: Int) {
            for i in 0..<item.numberOfChildren {
                guard let child = item.child(at: i) else { continue }
                rows.append(OutlineRow(title: child.label ?? "—", depth: depth, destination: child.destination))
                if rows.count < 2000 { walk(child, depth: depth + 1) }
            }
        }
        walk(root, depth: 0)
        return rows
    }

    var marks: [MarkRow] {
        _ = revision
        guard let document else { return [] }
        var rows: [MarkRow] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for a in page.annotations where !["Link", "Widget", "Popup"].contains(a.type ?? "") {
                let text: String
                if a.userName == redactionTag { text = L("가린 곳", "Redaction") }
                else if let c = a.contents, !c.isEmpty { text = c }
                else if ["Highlight", "Underline", "StrikeOut"].contains(a.type ?? "") {
                    text = page.selection(for: a.bounds.insetBy(dx: 1, dy: 1))?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                } else { text = "" }
                rows.append(MarkRow(annotation: a, pageIndex: index, kind: a.type ?? "", text: text))
            }
        }
        return rows
    }

    func go(to row: MarkRow) {
        guard let page = row.annotation.page else { return }
        view?.go(to: row.annotation.bounds, on: page)
    }

    func go(to destination: PDFDestination?) {
        if let destination { view?.go(to: destination) }
    }

    // MARK: 보기

    func zoom(_ step: Int) {
        guard let view else { return }
        switch step {
        case 1: fitsPage = false; view.zoomIn(nil)
        case -1: fitsPage = false; view.zoomOut(nil)
        case 0: fitsPage = true; fitPage()
        default: fitsPage = false; view.scaleFactor = 1
        }
    }

    /// 한 쪽(책처럼 보기면 두 쪽)이 창 안에 통째로 보이게. 간단히 보기는 오른쪽 기둥·아래 요청칸 자리를 비워 둔다
    func fitPage() {
        guard let view, let page = view.currentPage ?? document?.page(at: 0) else { return }
        var size = page.bounds(for: view.displayBox).size
        if page.rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
        // 책처럼 두 쪽 보기일 때만 두 쪽 너비(쪽이 하나뿐이면 한 쪽)
        if bookLayout, (document?.pageCount ?? 1) > 1 { size.width *= 2 }
        let simple = mode == .simple
        let room = CGSize(width: view.bounds.width - (simple ? 150 : 40), height: view.bounds.height - (simple ? 110 : 30))
        guard size.width > 0, size.height > 0, room.width > 50, room.height > 50 else { return }
        view.autoScales = false
        view.scaleFactor = min(room.width / size.width, room.height / size.height)
        view.go(to: page)
    }

    func printDocument() {
        guard let document else { return }
        let info = NSPrintInfo.shared
        document.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: true)?.run()
    }

    // MARK: 쪽

    func insertBlankPage() {
        guard let document, let current = view?.currentPage else { return }
        let index = document.index(for: current) + 1
        let size = current.bounds(for: .mediaBox).size
        change(L("빈 쪽을 넣었어요", "Inserted a blank page")) { doc in
            let blank = NSImage(size: size, flipped: false) { rect in NSColor.white.setFill(); rect.fill(); return true }
            if let page = PDFPage(image: blank) { doc.insert(page, at: index) }
        }
    }

    func deleteCurrentPage() {
        guard let document, document.pageCount > 1, let current = view?.currentPage else { return }
        let index = document.index(for: current)
        change(L("\(index + 1)쪽을 뺐어요", "Removed page \(index + 1)")) { doc in doc.removePage(at: index) }
    }

    // MARK: 한라봉 엔진으로 내보내기(미리보기 앱엔 없는 것)

    enum EngineExport { case word, images, searchable }

    func export(_ kind: EngineExport) {
        guard let document, let url else { return }
        let skill: FileSkill
        switch kind {
        case .word: skill = FileSkill(id: "pdf-word", name: "Word", input: [.pdf], steps: [.pdfToDocx], output: FileOutput(suffix: ""))
        case .images: skill = DefaultFileSkills.pdfToPNG
        case .searchable: skill = FileSkill(id: "pdf-ocr", name: "OCR", input: [.pdf], steps: [.ocrPDF], output: FileOutput(suffix: "_searchable"))
        }
        message = L("만드는 중…", "Working…")
        guard let data = try? burnedRedactions(document).dataRepresentation() else { return }
        let source = url
        Task.detached(priority: .userInitiated) {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("hanlabong-pdf-\(UUID().uuidString).pdf")
            let outcome: Result<URL, Error> = Result {
                try data.write(to: temp)
                defer { try? FileManager.default.removeItem(at: temp) }
                let result = try FileSkillExecutor().run(skill, input: temp)
                if let file = result.fileURL {
                    return try FileOutputWriter.save(movingFile: file, fileExtension: result.fileExtension, suffix: skill.output.suffix, besideOriginal: source)
                }
                return try FileOutputWriter.save(result.data, fileExtension: result.fileExtension, suffix: skill.output.suffix, besideOriginal: source)
            }
            await MainActor.run {
                switch outcome {
                case .success(let out): self.message = L("만들었어요: \(out.lastPathComponent)", "Created: \(out.lastPathComponent)")
                case .failure(let error): self.message = (error as? LocalizedError)?.errorDescription ?? L("만들지 못했어요", "Couldn't create it")
                }
            }
        }
    }
}
