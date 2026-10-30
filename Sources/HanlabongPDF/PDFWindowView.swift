import AppCore
import AppKit
import PDFKit
import SkillEngine
import SwiftUI

/// 맥 기본 PDF 화면(미리보기 앱과 같은 엔진) 위에 표시 도구를 얹은 것. 서식 칸 채우기·링크·글자 고르기는 PDF 화면이 한다.
struct PDFCanvas: NSViewRepresentable {
    @ObservedObject var session: PDFSession
    let twoUp: Bool

    func makeNSView(context: Context) -> MarkupPDFView {
        let view = MarkupPDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = NSColor(white: 0.16, alpha: 1)
        view.document = session.document
        view.session = session
        session.view = view
        return view
    }

    func updateNSView(_ view: MarkupPDFView, context: Context) {
        if view.document !== session.document { view.document = session.document }
        let mode: PDFDisplayMode = twoUp ? .twoUpContinuous : .singlePageContinuous
        if view.displayMode != mode { view.displayMode = mode; view.autoScales = true }
        view.session = session
        session.view = view
    }
}

/// 왼쪽 쪽 그림 띠
struct PDFThumbnails: NSViewRepresentable {
    @ObservedObject var session: PDFSession
    func makeNSView(context: Context) -> PDFThumbnailView {
        let thumbs = PDFThumbnailView()
        thumbs.thumbnailSize = CGSize(width: 120, height: 150)
        thumbs.backgroundColor = .clear
        thumbs.pdfView = session.view
        return thumbs
    }
    func updateNSView(_ thumbs: PDFThumbnailView, context: Context) {
        if thumbs.pdfView !== session.view { thumbs.pdfView = session.view }
    }
}

struct PDFWindowView: View {
    @ObservedObject var session: PDFSession
    @State private var twoUp = false
    @State private var sidebar = Sidebar.pages
    @State private var showSidebar = true
    @State private var organizing: PDFEditorModel?
    @State private var asking: Ask?
    @State private var input = ""
    @State private var password = ""

    enum Sidebar: String, CaseIterable { case pages, contents, marks }
    enum Ask: Identifiable { case lock, split; var id: Self { self } }

    private static let palette: [NSColor] = [.systemYellow, .systemGreen, .systemBlue, .systemPink, .systemPurple, .systemRed, .systemOrange, .black]

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if session.document != nil { toolBar }
            HStack(spacing: 0) {
                if showSidebar, session.document != nil {
                    sidePanel
                        .frame(width: 210)
                        .background(Color(white: 0.13))
                }
                ZStack {
                    PDFCanvas(session: session, twoUp: twoUp)
                    if session.document == nil { empty }
                }
            }
            statusBar
        }
        .background(Color(white: 0.16))
        .dropDestination(for: URL.self) { urls, _ in
            session.open(urls.filter(\.isFileURL))
            return true
        }
        .sheet(item: $organizing) { model in
            PDFEditorView(model: model, save: { session.applyPageEdit($0) }, close: { organizing = nil })
        }
        .sheet(isPresented: $session.signing) {
            SignaturePad(saved: session.signatures, onDone: { signature in
                if let signature { session.addSignature(signature) }
                session.signing = false
            }, onDelete: { session.deleteSignature($0) }, onUse: { signature in
                session.signing = false
                if let place = session.pendingSignaturePlace { session.stamp(signature, on: place.page, at: place.point) }
                session.pendingSignaturePlace = nil
            })
        }
        .alert(session.prompt?.title ?? "", isPresented: Binding(get: { session.prompt != nil }, set: { if !$0 { session.prompt = nil } })) {
            TextField(L("내용", "Text"), text: Binding(get: { session.prompt?.text ?? "" }, set: { session.prompt?.text = $0 }))
            Button(L("확인", "OK")) {
                if let prompt = session.prompt { session.prompt = nil; prompt.done(prompt.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
            Button(L("취소", "Cancel"), role: .cancel) { session.prompt = nil }
        }
        .alert(asking == .lock ? L("암호 걸어서 저장", "Save with a password") : L("나눠서 저장", "Split into files"),
               isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } })) {
            if asking == .lock { SecureField(L("암호", "Password"), text: $input) } else { TextField(L("몇 쪽마다", "Pages per file"), text: $input) }
            Button(L("확인", "OK")) { confirm() }
            Button(L("취소", "Cancel"), role: .cancel) { asking = nil }
        }
        .alert(L("암호가 걸린 PDF예요", "This PDF is password-protected"), isPresented: $session.needsPassword) {
            SecureField(L("암호", "Password"), text: $password)
            Button(L("열기", "Open")) {
                if !session.unlock(with: password) { session.message = L("암호가 맞지 않아요", "Wrong password") }
                password = ""
            }
            Button(L("취소", "Cancel"), role: .cancel) { password = "" }
        }
    }

    private func confirm() {
        let value = input.trimmingCharacters(in: .whitespaces)
        if asking == .lock, !value.isEmpty { session.save(.password(value)) }
        if asking == .split, let n = Int(value), n > 0 { session.save(.split(every: n)) }
        input = ""
        asking = nil
    }

    // MARK: 맨 위: 파일·보기·찾기·저장

    private var topBar: some View {
        HStack(spacing: 8) {
            Text(session.title + (session.dirty ? " •" : "")).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 240, alignment: .leading)
                .padding(.leading, 72)
            Spacer(minLength: 8)
            Group {
                Button { showSidebar.toggle() } label: { Image(systemName: "sidebar.left") }.help(L("옆 칸", "Sidebar"))
                Button { session.zoom(-1) } label: { Image(systemName: "minus.magnifyingglass") }.keyboardShortcut("-", modifiers: .command).help(L("작게", "Zoom out"))
                Button { session.zoom(1) } label: { Image(systemName: "plus.magnifyingglass") }.keyboardShortcut("=", modifiers: .command).help(L("크게", "Zoom in"))
                Button { session.zoom(0) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.keyboardShortcut("9", modifiers: .command).help(L("창에 맞추기", "Fit"))
                Button { session.zoom(2) } label: { Text("1:1").font(.caption.bold()) }.keyboardShortcut("0", modifiers: .command).help(L("실제 크기", "Actual size"))
                Button { twoUp.toggle() } label: { Image(systemName: twoUp ? "rectangle.split.2x1.fill" : "rectangle.split.2x1") }.help(L("두 쪽 보기", "Two pages"))
            }
            .buttonStyle(.glass).controlSize(.small)
            .disabled(session.document == nil)
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                TextField(L("찾기", "Find"), text: $session.searchText).textFieldStyle(.roundedBorder).frame(width: 160)
                    .onSubmit { session.search() }
                if !session.matches.isEmpty {
                    Text("\(session.matchIndex + 1)/\(session.matches.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Button { session.step(-1) } label: { Image(systemName: "chevron.up") }.keyboardShortcut("g", modifiers: [.command, .shift])
                    Button { session.step(1) } label: { Image(systemName: "chevron.down") }.keyboardShortcut("g", modifiers: .command)
                }
            }
            .buttonStyle(.glass).controlSize(.small)
            .disabled(session.document == nil)
            Menu {
                Button(L("저장 (옆에 _edit)", "Save (beside, _edit)")) { session.save(.normal) }.keyboardShortcut("s", modifiers: .command)
                Button(L("용량 줄여서 저장 (_small)", "Save smaller (_small)")) { session.save(.smaller) }
                Button(L("암호 걸어서 저장 (_locked)…", "Save with password (_locked)…")) { asking = .lock }
                Button(L("나눠서 저장 (_part1, _part2…)…", "Split into files…")) { input = "1"; asking = .split }
                Divider()
                Button(L("Word로 내보내기", "Export as Word")) { session.export(.word) }
                Button(L("쪽마다 그림으로 내보내기 (PNG)", "Export pages as images (PNG)")) { session.export(.images) }
                Button(L("글자 찾을 수 있게 (스캔 PDF 글자 인식)", "Make searchable (OCR)")) { session.export(.searchable) }
                Divider()
                Button(L("프린트…", "Print…")) { session.printDocument() }.keyboardShortcut("p", modifiers: .command)
            } label: { Label(L("저장", "Save"), systemImage: "square.and.arrow.down") }
            .menuStyle(.button).buttonStyle(.glassProminent).controlSize(.small).fixedSize()
            .disabled(session.document == nil)
            .padding(.trailing, 12)
        }
        .frame(height: 44)
        .background(WindowDragArea())
        .background(Color(white: 0.12))
    }

    // MARK: 둘째 줄: 표시 도구(미리보기 앱 마크업 막대 + 가리기)

    private var toolBar: some View {
        HStack(spacing: 6) {
            GlassEffectContainer(spacing: 4) {
                HStack(spacing: 4) {
                    ForEach(MarkupTool.allCases) { tool in
                        Button { session.tool = tool } label: { Image(systemName: tool.symbol).frame(width: 18) }
                            .buttonStyle(.glass)
                            .tint(session.tool == tool ? AppAccent.color(UserDefaults.standard.string(forKey: AppAccent.key) ?? AppAccent.defaultHex) : nil)
                            .opacity(session.tool == tool ? 1 : 0.75)
                            .help(tool.title)
                    }
                }
            }
            .controlSize(.small)
            Divider().frame(height: 18)
            // 색: 고른 표시가 있으면 그 표시의 색도 바꾼다
            HStack(spacing: 4) {
                ForEach(Self.palette, id: \.self) { color in
                    Circle().fill(Color(nsColor: color)).frame(width: 15, height: 15)
                        .overlay(Circle().stroke(.white, lineWidth: session.color == color ? 2 : 0))
                        .onTapGesture {
                            session.color = color
                            if session.selectedAnnotation != nil { session.recolorSelection() }
                        }
                }
            }
            Menu {
                ForEach([1, 2, 3, 5, 8], id: \.self) { w in Button("\(w) pt") { session.lineWidth = CGFloat(w) } }
            } label: { Label("\(Int(session.lineWidth)) pt", systemImage: "lineweight") }
            .menuStyle(.button).buttonStyle(.glass).controlSize(.small).fixedSize()
            .help(L("선 굵기", "Line width"))
            Menu {
                ForEach([10, 12, 14, 18, 24, 36], id: \.self) { s in Button("\(s) pt") { session.fontSize = CGFloat(s) } }
            } label: { Label("\(Int(session.fontSize))", systemImage: "textformat.size") }
            .menuStyle(.button).buttonStyle(.glass).controlSize(.small).fixedSize()
            .help(L("글자 크기", "Font size"))
            if session.selectedAnnotation != nil {
                Button(role: .destructive) {
                    if let a = session.selectedAnnotation { session.remove(a); session.view?.deselect() }
                } label: { Image(systemName: "trash") }
                .buttonStyle(.glass).controlSize(.small).help(L("고른 표시 지우기 (⌫)", "Delete selected mark (⌫)"))
            }
            Spacer()
            Group {
                Button { session.rotateCurrent(clockwise: true) } label: { Image(systemName: "rotate.right") }.help(L("이 쪽 돌리기", "Rotate this page"))
                Button { session.insertBlankPage() } label: { Image(systemName: "doc.badge.plus") }.help(L("빈 쪽 넣기", "Insert blank page"))
                Button { session.deleteCurrentPage() } label: { Image(systemName: "doc.badge.minus") }.help(L("이 쪽 빼기", "Remove this page"))
                Button { openOrganizer() } label: { Label(L("쪽 정리", "Pages"), systemImage: "square.grid.2x2") }.help(L("순서·돌리기·빼기·끼워 넣기", "Reorder · rotate · remove · insert"))
                Button { session.chooseAndAppend() } label: { Label(L("합치기", "Merge"), systemImage: "rectangle.stack.badge.plus") }.help(L("다른 파일을 뒤에 붙이기", "Append other files"))
            }
            .buttonStyle(.glass).controlSize(.small)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Color(white: 0.14))
    }

    // MARK: 옆 칸: 쪽 그림 · 목차 · 표시 목록

    private var sidePanel: some View {
        VStack(spacing: 6) {
            Picker("", selection: $sidebar) {
                Text(L("쪽", "Pages")).tag(Sidebar.pages)
                Text(L("목차", "Contents")).tag(Sidebar.contents)
                Text(L("표시", "Marks")).tag(Sidebar.marks)
            }
            .pickerStyle(.segmented).labelsHidden().padding(8)
            switch sidebar {
            case .pages:
                PDFThumbnails(session: session)
            case .contents:
                let rows = session.outline
                if rows.isEmpty {
                    Text(L("이 PDF엔 목차가 없어요", "No table of contents")).font(.caption).foregroundStyle(.secondary).frame(maxHeight: .infinity)
                } else {
                    List(rows) { row in
                        Text(row.title).font(.callout).lineLimit(2).padding(.leading, CGFloat(row.depth) * 12)
                            .contentShape(Rectangle())
                            .onTapGesture { session.go(to: row.destination) }
                    }
                    .scrollContentBackground(.hidden)
                }
            case .marks:
                let rows = session.marks
                if rows.isEmpty {
                    Text(L("아직 표시가 없어요", "No marks yet")).font(.caption).foregroundStyle(.secondary).frame(maxHeight: .infinity)
                } else {
                    List(rows) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("\(row.pageIndex + 1)쪽 · \(row.kind)", "p.\(row.pageIndex + 1) · \(row.kind)")).font(.caption2).foregroundStyle(.secondary)
                            if !row.text.isEmpty { Text(row.text).font(.callout).lineLimit(3) }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { session.go(to: row) }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
        }
    }

    private var statusBar: some View {
        HStack {
            Text(session.message ?? hint)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button(L("되돌리기", "Undo")) { session.undo() }.keyboardShortcut("z", modifiers: .command).disabled(!session.canUndo)
                .buttonStyle(.plain).font(.caption)
            Button(L("다시", "Redo")) { session.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!session.canRedo)
                .buttonStyle(.plain).font(.caption)
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Color(white: 0.12))
    }

    private var hint: String {
        switch session.tool {
        case .select: return L("표시를 눌러 고르고 끌어서 옮겨요 · 오른쪽 아래 모서리를 끌면 크기 · ⌫ 지우기 · 글자 상자는 두 번 눌러 고치기",
                               "Click a mark to select, drag to move · drag its bottom-right corner to resize · ⌫ deletes · double-click text to edit")
        case .highlight, .underline, .strike: return L("글자를 끌어서 고르면 바로 표시돼요", "Drag over text to mark it")
        case .pen: return L("끌어서 그려요", "Drag to draw")
        case .rect, .oval, .line, .arrow: return L("끌어서 크기를 정해요", "Drag to draw the shape")
        case .text: return L("글자를 넣을 곳을 눌러요", "Click where the text goes")
        case .note: return L("메모를 붙일 곳을 눌러요", "Click where the note goes")
        case .signature: return L("서명을 놓을 곳을 눌러요 (처음이면 서명을 그려요)", "Click where to sign (first time: draw your signature)")
        case .redact: return L("가릴 곳을 끌어서 덮어요 · 저장하면 그 쪽 밑글자까지 지워져요", "Drag over what to hide · saving truly removes it from that page")
        }
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.richtext").font(.system(size: 44, weight: .light))
            Text(L("한라봉 휠 ⌘ › Hanlabong PDF에 놓거나, 여기로 끌어 놓아요 · PDF·한글·Word·사진", "Drop on Hanlabong wheel ⌘ › Hanlabong PDF, or drag here · PDF, Hangul, Word, photos"))
                .foregroundStyle(.secondary)
            Button(L("파일 열기…", "Open…")) {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = true
                if panel.runModal() == .OK { session.open(panel.urls) }
            }
            .buttonStyle(.glass)
        }
        .foregroundStyle(.white.opacity(0.85))
    }

    private func openOrganizer() {
        guard let url = session.url, let data = session.document?.dataRepresentation(), let doc = PDFDocument(data: data) else { return }
        organizing = PDFEditorModel(url: url, document: doc)
    }
}

extension PDFEditorModel: Identifiable {
    nonisolated public var id: ObjectIdentifier { ObjectIdentifier(self) }
}

/// 서명 그리기: 트랙패드나 마우스로 쓰면 이 맥에 저장해 두고, 다음부터는 누르기만 하면 들어간다
struct SignaturePad: View {
    let saved: [Signature]
    let onDone: (Signature?) -> Void
    let onDelete: (Signature) -> Void
    let onUse: (Signature) -> Void
    @State private var strokes: [[CGPoint]] = []
    @State private var current: [CGPoint] = []
    private let size = CGSize(width: 460, height: 180)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("서명", "Signature")).font(.title3.bold())
            if !saved.isEmpty {
                Text(L("저장해 둔 서명 · 눌러서 쓰기", "Saved signatures · click to use")).font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(saved) { sig in
                            preview(sig).frame(width: 140, height: 60)
                                .background(RoundedRectangle(cornerRadius: 8).fill(.white))
                                .onTapGesture { onUse(sig) }
                                .contextMenu { Button(L("지우기", "Delete"), role: .destructive) { onDelete(sig) } }
                        }
                    }
                }
            }
            Text(L("새 서명: 아래 칸에 써요", "New signature: write below")).font(.caption).foregroundStyle(.secondary)
            Canvas { context, _ in
                for stroke in strokes + [current] where stroke.count > 1 {
                    var path = Path(); path.addLines(stroke)
                    context.stroke(path, with: .color(.black), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                }
            }
            .frame(width: size.width, height: size.height)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white))
            .overlay(Rectangle().fill(.gray.opacity(0.4)).frame(height: 1).padding(.horizontal, 30).offset(y: 50))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { current.append($0.location) }
                .onEnded { _ in if current.count > 1 { strokes.append(current) }; current = [] })
            HStack {
                Button(L("지우고 다시", "Clear")) { strokes = [] }
                Spacer()
                Button(L("취소", "Cancel")) { onDone(nil) }.keyboardShortcut(.cancelAction)
                Button(L("저장하고 넣기", "Save & place")) { onDone(normalized()) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(strokes.isEmpty)
            }
        }
        .padding(20)
    }

    /// 쓴 부분만 잘라서 가로 0~1로 맞춘다
    private func normalized() -> Signature? {
        let all = strokes.flatMap { $0 }
        guard let minX = all.map(\.x).min(), let maxX = all.map(\.x).max(), let minY = all.map(\.y).min(), let maxY = all.map(\.y).max(), maxX > minX else { return nil }
        let w = maxX - minX
        let scaled = strokes.map { $0.map { CGPoint(x: ($0.x - minX) / w, y: ($0.y - minY) / w) } }
        return Signature(strokes: scaled, aspect: Double(max(maxY - minY, 1) / w))
    }

    private func preview(_ sig: Signature) -> some View {
        Canvas { context, box in
            let w = min(box.width - 10, (box.height - 10) / CGFloat(max(sig.aspect, 0.01)))
            for stroke in sig.strokes where stroke.count > 1 {
                var path = Path(); path.addLines(stroke.map { CGPoint(x: 5 + $0.x * w, y: 5 + $0.y * w) })
                context.stroke(path, with: .color(.black), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            }
        }
    }
}
