import AppCore
import AppKit
import PDFKit
import SkillEngine
import SwiftUI

/// 맥 기본 PDF 화면(미리보기 앱과 같은 엔진) 위에 표시 도구를 얹은 것. 서식 칸 채우기·링크·글자 고르기는 PDF 화면이 한다.
/// 간단히 보기·자세히 보기가 같은 화면을 쓴다(바꿔도 보던 자리가 그대로).
struct PDFCanvas: NSViewRepresentable {
    @ObservedObject var session: PDFSession

    final class Coordinator: NSObject {
        weak var session: PDFSession?
        @objc func pageChanged(_ note: Notification) { MainActor.assumeIsolated { session?.pageChanged() } }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MarkupPDFView {
        let view = MarkupPDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = NSColor(white: 0.16, alpha: 1)
        view.document = session.document
        view.session = session
        session.view = view
        context.coordinator.session = session
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.pageChanged(_:)), name: .PDFViewPageChanged, object: view)
        session.applyLayout()
        return view
    }

    func updateNSView(_ view: MarkupPDFView, context: Context) {
        if view.document !== session.document { view.document = session.document; session.applyLayout() }
        view.session = session
        session.view = view
        context.coordinator.session = session
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
    @State private var sidebar = Sidebar.pages
    @State private var showSidebar = true
    @State private var organizing: PDFEditorModel?
    @State private var asking: Ask?
    @State private var input = ""
    @State private var password = ""
    @State private var showStyle = false
    @State private var showContents = false
    @State private var typingPage = false
    @State private var pageField = ""

    enum Sidebar: String, CaseIterable { case pages, contents, marks }
    enum Ask: Identifiable { case lock, split; var id: Self { self } }

    private static let palette: [NSColor] = [.systemYellow, .systemGreen, .systemBlue, .systemPink, .systemPurple, .systemRed, .systemOrange, .black]
    private var detailed: Bool { session.mode == .detailed }

    var body: some View {
        VStack(spacing: 0) {
            if detailed {
                topBar
                if session.document != nil { toolBar }
            }
            HStack(spacing: 0) {
                if detailed, showSidebar, session.document != nil {
                    sidePanel
                        .frame(width: 210)
                        .background(Color(white: 0.13))
                }
                ZStack {
                    PDFCanvas(session: session)
                    if session.document == nil { empty }
                    if !detailed, session.document != nil { readerOverlay }
                }
            }
            if detailed, session.document != nil { AssistantBar(session: session, glass: false) }
            if detailed { statusBar }
        }
        .background(Color(white: 0.16))
        .background {
            // 단축키: ⌘E 보기 바꾸기, ⌘[ 되돌아가기
            Group {
                Button("") { session.mode = detailed ? .simple : .detailed }.keyboardShortcut("e", modifiers: .command)
                Button("") { session.goBack() }.keyboardShortcut("[", modifiers: .command)
                Button("") { session.zoom(-1) }.keyboardShortcut("-", modifiers: .command)
                Button("") { session.zoom(1) }.keyboardShortcut("=", modifiers: .command)
                Button("") { session.zoom(0) }.keyboardShortcut("9", modifiers: .command)
                Button("") { session.zoom(2) }.keyboardShortcut("0", modifiers: .command)
            }
            .opacity(0).allowsHitTesting(false)
        }
        .onChange(of: session.url) { _, _ in
            // 책처럼 긴 PDF는 처음 열 때 알아서 파트를 나눈다(한 번 나누면 이 맥에 기억)
            if let doc = session.document, doc.pageCount >= 20, session.bookIndex == nil { session.buildIndex() }
        }
        .dropDestination(for: URL.self) { urls, _ in
            session.open(urls.filter(\.isFileURL))
            return true
        }
        .sheet(item: $organizing) { model in
            PDFEditorView(model: model, save: { session.applyPageEdit($0) }, close: { organizing = nil })
        }
        .sheet(isPresented: $session.editingProfile) {
            ProfileEditor(profile: session.profile, save: { session.saveProfile($0) }, close: { session.editingProfile = false })
        }
        .sheet(isPresented: $session.signing) {
            SignaturePad(saved: session.signatures, onDone: { signature in
                // 놓을 자리 없이 새로 쓴 서명이면, 다음에 누르는 곳에 바로 넣게 서명 도구를 켠다
                if let signature { if session.pendingSignaturePlace == nil { session.tool = .signature }; session.addSignature(signature) }
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
        .alert(L("AI 요청 실패", "AI request failed"), isPresented: Binding(get: { session.aiError != nil }, set: { if !$0 { session.aiError = nil } })) {
            Button(L("확인", "OK"), role: .cancel) { session.aiError = nil }
        } message: { Text(session.aiError ?? "") }
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


    // MARK: 간단히 보기: 오른쪽에 둥근 유리 기둥(보기·목차·채우기·자세히), 그 아래 건너가기·쪽수, 아래 가운데 AI 요청칸

    private var readerOverlay: some View {
        ZStack {
            HStack(alignment: .top) {
                Spacer()
                VStack(alignment: .trailing, spacing: 10) {
                    rail
                    Spacer()
                    jumpStack
                }
            }
            .padding(.top, 40).padding(.trailing, 14).padding(.bottom, 14)
            VStack {
                if session.tool != .select { toolHint.transition(.move(edge: .top).combined(with: .opacity)) }
                Spacer()
                AssistantBar(session: session, glass: true)
                    .padding(.horizontal, 120)
                    .padding(.bottom, 16)
            }
            .padding(.top, 12)
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.8), value: session.tool)
    }

    /// 오른쪽 유리 기둥
    private var rail: some View {
        VStack(spacing: 4) {
            viewMenu(label: RailIcon(symbol: session.bookLayout ? "book" : "rectangle.portrait"), plain: true)
                .help(L("보기 · 한 장씩/책처럼 · 확대", "View · layout · zoom"))
            Button { showContents.toggle() } label: {
                RailIcon(symbol: "list.bullet", badge: session.indexProgress?.fraction.map { "\(Int($0 * 100))" })
            }
            .buttonStyle(.plain)
            .help(session.indexing ? indexingShort : L("목차", "Contents"))
            .popover(isPresented: $showContents, arrowEdge: .leading) { contentsList.frame(width: 340, height: 460) }
            insertMenu
                .help(L("넣기 · 글자·서명·메모·입력칸", "Insert · text, signature, note, field"))
            fillMenu(label: RailIcon(symbol: "text.badge.checkmark"))
                .help(L("빈칸 채우기 · 내 정보", "Fill in · my info"))
            Divider().frame(width: 22).padding(.vertical, 2)
            Button { session.mode = .detailed } label: { RailIcon(symbol: "slider.horizontal.3") }
                .buttonStyle(.plain)
                .help(L("자세히 보기 — 표시·그리기·저장 (⌘E)", "Detailed view — markup, save (⌘E)"))
        }
        .padding(5)
        .modifier(SmokyGlass(shape: Capsule()))
        .shadow(color: .black.opacity(0.22), radius: 14, y: 5)
    }

    /// 오른쪽 아래: 되돌아가기 · 건너가기 · 쪽수
    private var jumpStack: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let back = session.history.last {
                Button { session.goBack() } label: { Label(L("\(back + 1)쪽으로", "Back to p.\(back + 1)"), systemImage: "arrow.uturn.backward") }
                    .help(L("건너뛰기 전 자리로 (⌘[)", "Back to where you were (⌘[)"))
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            ForEach(session.jumpTargets) { target in
                Button { session.go(to: target) } label: { Label(target.label, systemImage: "arrow.turn.down.right") }
                    .help(target.hint)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            pageBadge
        }
        .buttonStyle(.glass)
        .controlSize(.regular)
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: session.jumpTargets.map(\.id))
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: session.history.count)
    }

    /// 간단히 보기에서 입력칸·서명 도구를 쓰는 중일 때 위에 뜨는 안내
    private var toolHint: some View {
        HStack(spacing: 10) {
            Image(systemName: session.tool.symbol)
            Text(hint).font(.callout).lineLimit(1)
            Button(L("끝", "Done")) { session.tool = .select }.buttonStyle(.glass).controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .modifier(SmokyGlass(shape: Capsule()))
    }

    /// + 넣기: 고르면 그 도구가 켜지고, 쪽을 누르면 거기에 들어간다
    private var insertMenu: some View {
        let inserting: [MarkupTool] = [.text, .signature, .note, .field]
        return Menu {
            Button { session.tool = .text } label: { Label(L("글자", "Text"), systemImage: MarkupTool.text.symbol) }
            Button { session.tool = .signature } label: { Label(L("서명", "Signature"), systemImage: MarkupTool.signature.symbol) }
            Button { session.signing = true } label: { Label(L("새 서명 쓰기…", "New signature…"), systemImage: "hand.draw") }
            Button { session.tool = .note } label: { Label(L("메모", "Note"), systemImage: MarkupTool.note.symbol) }
            Button { session.tool = .field } label: { Label(L("입력칸", "Field"), systemImage: MarkupTool.field.symbol) }
        } label: {
            RailIcon(symbol: inserting.contains(session.tool) ? session.tool.symbol : "plus", active: inserting.contains(session.tool))
        }
        .menuStyle(.button)
        .modifier(PlainMenuIf(plain: true))
        .fixedSize()
        .disabled(session.document == nil)
    }

    /// 채우기 메뉴(간단히·자세히 둘 다)
    private func fillMenu<MenuLabel: View>(label: MenuLabel, plain: Bool = true) -> some View {
        Menu {
            Button(L("내 정보로 채우기 (AI)", "Fill with my info (AI)")) { session.fillFromProfile() }
            Button(L("빈칸 찾아서 입력칸 만들기", "Find blanks and add fields")) { session.findBlanks() }
            Divider()
            Button(L("입력칸 직접 그리기", "Draw a field yourself")) { session.tool = .field }
            Button(L("서명 넣기", "Place a signature")) { session.tool = .signature }
            Divider()
            Button(L("내 정보 고치기…", "Edit my info…")) { session.editingProfile = true }
        } label: { label }
        .menuStyle(.button)
        .modifier(PlainMenuIf(plain: plain))
        .fixedSize()
        .disabled(session.document == nil)
    }

    /// "37 / 412" — 누르면 쪽 번호를 바로 쳐서 가기
    private var pageBadge: some View {
        Group {
            if typingPage {
                TextField("", text: $pageField)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .onSubmit {
                        if let n = Int(pageField) { session.go(toPage: n - 1, remember: true) }
                        typingPage = false
                    }
                    .onExitCommand { typingPage = false }
            } else {
                Button {
                    pageField = "\(session.currentPage + 1)"
                    typingPage = true
                } label: {
                    Text("\(session.currentPage + 1) / \(session.document?.pageCount ?? 0)").monospacedDigit()
                }
                .help(L("눌러서 쪽 번호로 가기", "Click to go to a page"))
            }
        }
    }

    /// 목차: AI·책갈피로 나눈 파트 + PDF에 원래 있던 목차
    private var contentsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("목차", "Contents")).font(.headline)
                Spacer()
                Button(session.bookIndex == nil ? L("AI로 나누기", "Split with AI") : L("다시 나누기", "Redo")) { session.buildIndex(force: true) }
                    .controlSize(.small)
                    .disabled(session.indexing)
            }
            if let progress = session.indexProgress { progressCard(progress) }
            List {
                if let index = session.bookIndex {
                    Section(index.source == .ai ? L("AI가 나눈 파트", "Parts (AI)") : L("파트", "Parts")) {
                        ForEach(index.sections) { section in
                            Button { session.jump(to: section); showContents = false } label: {
                                HStack(spacing: 8) {
                                    Circle().fill(color(for: section.role)).frame(width: 7, height: 7)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(section.title).lineLimit(1).font(section.level == 0 ? .body.weight(.medium) : .body)
                                        Text((section.role.isEmpty ? "" : "\(section.role) · ") + "\(section.start + 1)–\(section.end + 1)쪽")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if section.id == session.currentSection?.id { Image(systemName: "location.fill").font(.caption2).foregroundStyle(.secondary) }
                                }
                                .padding(.leading, CGFloat(min(section.level, 3)) * 14)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                let outline = session.outline
                if !outline.isEmpty {
                    Section(L("PDF 목차", "Bookmarks")) {
                        ForEach(outline) { row in
                            Button { session.rememberAndGo(to: row.destination); showContents = false } label: {
                                Text(row.title).lineLimit(1).padding(.leading, CGFloat(row.depth) * 10).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if session.bookIndex == nil, outline.isEmpty, !session.indexing {
                    Text(L("아직 목차가 없어요. AI로 나누기를 눌러봐요", "No contents yet. Try Split with AI")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
        }
        .padding(12)
    }

    /// 목차 단추에 붙는 짧은 진행 표시
    private var indexingShort: String {
        if let f = session.indexProgress?.fraction { return L("나누는 중 \(Int(f * 100))%", "Splitting \(Int(f * 100))%") }
        return L("나누는 중…", "Splitting…")
    }

    /// 책 나누기 진행 카드: 단계, 막대, 걸린 시간, 남은 시간 짐작, 그만두기
    private func progressCard(_ progress: IndexProgress) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(progress.title).font(.callout.weight(.medium))
                    if let f = progress.fraction { Text("\(Int(f * 100))%").font(.callout).monospacedDigit().foregroundStyle(.secondary) }
                    Spacer()
                    if progress.stage == .reading || progress.stage == .writing {
                        Button(L("AI 그만두기", "Stop AI")) { session.stopAIIndexing() }
                            .controlSize(.small)
                            .help(L("AI 없이 쪽 표시·책갈피로만 나눠요", "Split with page marks and bookmarks only"))
                    }
                }
                if let f = progress.fraction { ProgressView(value: f) } else { ProgressView().progressViewStyle(.linear) }
                HStack(spacing: 4) {
                    Text(L("걸린 시간 ", "Elapsed ") + IndexProgress.clock(context.date.timeIntervalSince(progress.started)))
                    if let left = progress.remaining(now: context.date) { Text(L("· 남은 시간 약 ", "· about ") + IndexProgress.clock(left) + L("", " left")) }
                    Spacer()
                    if let model = progress.model { Text(model).lineLimit(1) }
                }
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if progress.stage == .reading {
                    Text(L("AI가 책 전체를 먼저 읽고 나서 목차를 쓰기 시작해요. 쓰기 시작하면 몇 %인지 보여요", "The AI reads the whole digest first; the percentage appears once it starts writing"))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// 역할 이름에 따라 점 색(AI가 정한 말이라 대충 낱말로 본다)
    private func color(for role: String) -> Color {
        let r = role.lowercased()
        if ["정답", "해설", "답", "answer", "solution"].contains(where: r.contains) { return .green }
        if ["문제", "기출", "실전", "연습", "test", "exercise", "practice"].contains(where: r.contains) { return .orange }
        if ["개념", "이론", "정리", "concept", "theory"].contains(where: r.contains) { return .blue }
        return .gray
    }

    /// "보기" 메뉴(간단히·자세히 둘 다): 한 장씩 / 책처럼, 두 쪽 기준, 확대, 보기 바꾸기
    private func viewMenu<MenuLabel: View>(label: MenuLabel, plain: Bool = false) -> some View {
        Menu {
            Picker(L("보는 방식", "Layout"), selection: $session.bookLayout) {
                Label(L("한 장씩 보기", "Single page"), systemImage: "rectangle.portrait").tag(false)
                Label(L("책처럼 두 쪽 보기", "Two pages like a book"), systemImage: "book").tag(true)
            }
            .pickerStyle(.inline)
            Section(L("두 쪽 기준", "Page pairing")) {
                Toggle(L("1쪽은 혼자 (표지처럼)", "First page alone (cover)"), isOn: $session.coverAlone)
                Button(L("지금 보는 쪽을 왼쪽에 두기", "Put the current page on the left")) { session.alignCurrentPageLeft() }
            }
            Section {
                Button(L("크게 (⌘+)", "Zoom in (⌘+)")) { session.zoom(1) }
                Button(L("작게 (⌘−)", "Zoom out (⌘−)")) { session.zoom(-1) }
                Button(L("창에 맞추기 (⌘9)", "Fit (⌘9)")) { session.zoom(0) }
                Button(L("실제 크기 (⌘0)", "Actual size (⌘0)")) { session.zoom(2) }
            }
            Section {
                if detailed {
                    Toggle(L("왼쪽 칸 보기", "Show sidebar"), isOn: $showSidebar)
                    Button(L("간단히 보기로 (⌘E)", "Simple view (⌘E)")) { session.mode = .simple }
                } else {
                    Button(L("자세히 보기로 — 표시·서명·저장 (⌘E)", "Detailed view — markup, sign, save (⌘E)")) { session.mode = .detailed }
                }
            }
        } label: { label }
        .menuStyle(.button)
        .modifier(PlainMenuIf(plain: plain))
        .fixedSize()
    }

    // MARK: 자세히 보기: 맨 위 한 줄에 묶음별로(보기 · 도구 · 모양 · 쪽 · 찾기 · 저장)

    private var topBar: some View {
        HStack(spacing: 8) {
            Text(session.title + (session.dirty ? " •" : "")).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 200, alignment: .leading)
                .padding(.leading, 72)
            viewMenu(label: Label(L("보기", "View"), systemImage: "book")).controlSize(.small)
                .disabled(session.document == nil)
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                TextField(L("찾기", "Find"), text: $session.searchText).textFieldStyle(.roundedBorder).frame(width: 150)
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

    /// 둘째 줄: 도구는 묶음별 메뉴 4개 + 고르기 + 가리기, 색·굵기는 한 곳, 쪽 일은 메뉴 하나로
    private var toolBar: some View {
        HStack(spacing: 8) {
            GlassEffectContainer(spacing: 4) {
                HStack(spacing: 4) {
                    toolButton(.select)
                    toolGroup(L("표시", "Mark"), [.highlight, .underline, .strike])
                    toolGroup(L("그리기", "Draw"), [.pen, .rect, .oval, .line, .arrow])
                    toolGroup(L("넣기", "Insert"), [.text, .note, .signature, .field])
                    toolButton(.redact)
                }
            }
            .controlSize(.small)
            // 모양: 지금 색 하나만 보이고, 누르면 색·굵기·글자 크기
            Button { showStyle.toggle() } label: {
                HStack(spacing: 6) {
                    Circle().fill(Color(nsColor: session.color)).frame(width: 14, height: 14).overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 1))
                    Text("\(Int(session.lineWidth))pt · \(Int(session.fontSize))").font(.caption).monospacedDigit()
                }
            }
            .buttonStyle(.glass).controlSize(.small)
            .help(L("색 · 굵기 · 글자 크기", "Color · width · font size"))
            .popover(isPresented: $showStyle, arrowEdge: .bottom) { stylePanel.padding(14) }
            fillMenu(label: Label(L("채우기", "Fill"), systemImage: "text.badge.checkmark"), plain: false)
                .controlSize(.small)
            if session.selectedAnnotation != nil {
                Button(role: .destructive) {
                    if let a = session.selectedAnnotation { session.remove(session.view?.siblings(of: a) ?? [a]); session.view?.deselect() }
                } label: { Image(systemName: "trash") }
                .buttonStyle(.glass).controlSize(.small).help(L("고른 표시 지우기 (⌫)", "Delete selected mark (⌫)"))
            }
            Spacer()
            Menu {
                Button(L("이 쪽 오른쪽으로 돌리기", "Rotate this page right")) { session.rotateCurrent(clockwise: true) }
                Button(L("이 쪽 왼쪽으로 돌리기", "Rotate this page left")) { session.rotateCurrent(clockwise: false) }
                Button(L("빈 쪽 넣기", "Insert blank page")) { session.insertBlankPage() }
                Button(L("이 쪽 빼기", "Remove this page")) { session.deleteCurrentPage() }
                Divider()
                Button(L("쪽 정리… (순서·돌리기·빼기·끼워 넣기)", "Organize pages…")) { openOrganizer() }
                Button(L("다른 파일 뒤에 붙이기 (합치기)…", "Append files (merge)…")) { session.chooseAndAppend() }
            } label: { Label(L("쪽", "Pages"), systemImage: "doc.on.doc") }
            .menuStyle(.button).buttonStyle(.glass).controlSize(.small).fixedSize()
            Button { session.mode = .simple } label: { Label(L("간단히 보기", "Simple view"), systemImage: "rectangle.compress.vertical") }
                .buttonStyle(.glass).controlSize(.small)
                .help(L("쪽수·목차만 보이게 (⌘E)", "Only page number and contents (⌘E)"))
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Color(white: 0.14))
    }

    private var accent: Color { AppAccent.color(UserDefaults.standard.string(forKey: AppAccent.key) ?? AppAccent.defaultHex) }

    private func toolButton(_ tool: MarkupTool) -> some View {
        Button { session.tool = tool } label: { Image(systemName: tool.symbol).frame(width: 18) }
            .buttonStyle(.glass)
            .tint(session.tool == tool ? accent : nil)
            .help(tool.title)
    }

    /// 같은 종류 도구 묶음: 지금 고른 도구가 이 묶음이면 그 아이콘이 보인다
    private func toolGroup(_ title: String, _ tools: [MarkupTool]) -> some View {
        let active = tools.contains(session.tool)
        return Menu {
            ForEach(tools) { tool in
                Button { session.tool = tool } label: { Label(tool.title, systemImage: tool.symbol) }
            }
        } label: {
            Label(title, systemImage: (active ? session.tool : tools[0]).symbol)
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .tint(active ? accent : nil)
        .fixedSize()
    }

    private var stylePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("색", "Color")).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(Self.palette, id: \.self) { color in
                    Circle().fill(Color(nsColor: color)).frame(width: 22, height: 22)
                        .overlay(Circle().stroke(.white, lineWidth: session.color == color ? 2.5 : 0))
                        .onTapGesture {
                            session.color = color
                            if session.selectedAnnotation != nil { session.recolorSelection() }
                        }
                }
            }
            Picker(L("선 굵기", "Line width"), selection: $session.lineWidth) {
                ForEach([1, 2, 3, 5, 8], id: \.self) { Text("\($0) pt").tag(CGFloat($0)) }
            }
            .pickerStyle(.segmented)
            Picker(L("글자 크기", "Font size"), selection: $session.fontSize) {
                ForEach([10, 12, 14, 18, 24, 36], id: \.self) { Text("\($0)").tag(CGFloat($0)) }
            }
            .pickerStyle(.segmented)
            Text(L("고른 표시가 있으면 그 표시 색도 바뀌어요", "Changes the selected mark's color too")).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(width: 340)
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
                            .onTapGesture { session.rememberAndGo(to: row.destination) }
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
        case .signature: return L("서명을 놓을 곳을 눌러요 · 넣은 서명은 끌어서 옮기고, 오른쪽 아래 모서리를 끌면 크기", "Click where to sign · drag to move, drag the bottom-right corner to resize")
        case .field: return L("입력칸을 놓을 곳을 끌어서 그려요 · 그 칸을 눌러서 바로 써요", "Drag to draw a field · then click it to type")
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

/// 서명 그리기: 트랙패드(판 전체가 서명 칸, 빠르기·누르는 힘에 따라 굵기) 또는 마우스로 쓰면 이 맥에 저장해 두고, 다음부터는 누르기만 하면 들어간다
struct SignaturePad: View {
    let saved: [Signature]
    let onDone: (Signature?) -> Void
    let onDelete: (Signature) -> Void
    let onUse: (Signature) -> Void
    enum Input: String { case trackpad, mouse }
    @AppStorage("signatureInput") private var input = Input.trackpad
    @State private var strokes: [[CGPoint]] = []
    @State private var widths: [[CGFloat]] = []
    @State private var current: [CGPoint] = []
    @State private var currentWidths: [CGFloat] = []
    @State private var capturing = false
    @State private var startToken = 0
    private let size = CGSize(width: 460, height: 180)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("서명", "Signature")).font(.title3.bold())
                Spacer()
                Picker("", selection: $input) {
                    Text(L("트랙패드", "Trackpad")).tag(Input.trackpad)
                    Text(L("마우스", "Mouse")).tag(Input.mouse)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                .disabled(capturing)
            }
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
            Text(input == .trackpad
                 ? (capturing ? L("트랙패드에 손가락으로 써요 · 빠르면 가늘게, 꾹 누르면 굵게 · 다 쓰면 아무 키나 (Esc = 지우기)",
                                  "Write on the trackpad · fast = thin, press harder = thick · press any key when done (Esc = clear)")
                              : L("아래 칸을 누르면 트랙패드가 서명 칸이 돼요(포인터는 멈춰요)", "Click the box: the trackpad becomes the signing area (the pointer stays put)"))
                 : L("새 서명: 아래 칸에 마우스로 써요", "New signature: draw below with the mouse"))
                .font(.caption).foregroundStyle(capturing ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                .animation(.easeInOut(duration: 0.2), value: capturing)
            ZStack {
                Canvas { context, _ in
                    for (i, stroke) in strokes.enumerated() { draw(stroke, i < widths.count ? widths[i] : [], in: &context) }
                    draw(current, currentWidths, in: &context)
                }
                if input == .trackpad {
                    TrackpadCanvas(capturing: $capturing,
                                   onStroke: { points, w in strokes.append(points); widths.append(w) },
                                   onLive: { points, w in current = points; currentWidths = w },
                                   onClear: { strokes = []; widths = [] },
                                   startToken: startToken)
                    if !capturing && strokes.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "hand.point.up.left").font(.system(size: 26, weight: .light))
                            Text(L("눌러서 시작", "Click to begin")).font(.callout)
                        }
                        .foregroundStyle(.gray)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white))
            .overlay(Rectangle().fill(.gray.opacity(0.4)).frame(height: 1).padding(.horizontal, 30).offset(y: 50).allowsHitTesting(false))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange, lineWidth: capturing ? 2.5 : 0).animation(.easeInOut(duration: 0.2), value: capturing))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard input == .mouse else { return }
                    current.append(value.location); currentWidths.append(2.2)
                }
                .onEnded { _ in
                    guard input == .mouse else { return }
                    if current.count > 1 { strokes.append(current); widths.append(currentWidths) }
                    current = []; currentWidths = []
                })
            HStack {
                Button(L("지우고 다시", "Clear")) { strokes = []; widths = [] }.disabled(capturing)
                if input == .trackpad, !capturing {
                    Button(strokes.isEmpty ? L("트랙패드로 쓰기", "Write with trackpad") : L("이어서 쓰기", "Keep writing")) { startToken += 1 }
                }
                Spacer()
                Button(L("취소", "Cancel")) { onDone(nil) }.keyboardShortcut(.cancelAction).disabled(capturing)
                Button(L("저장하고 넣기", "Save & place")) { onDone(normalized()) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(strokes.isEmpty || capturing)
            }
        }
        .padding(20)
    }

    /// 마디마다 굵기를 다르게 그린다
    private func draw(_ stroke: [CGPoint], _ w: [CGFloat], in context: inout GraphicsContext) {
        guard stroke.count > 1 else { return }
        for i in 1..<stroke.count {
            var path = Path(); path.move(to: stroke[i - 1]); path.addLine(to: stroke[i])
            let width = w.count == stroke.count ? (w[i - 1] + w[i]) / 2 : 2.2
            context.stroke(path, with: .color(.black), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }
    }

    /// 쓴 부분만 잘라서 가로 0~1로 맞춘다(굵기도 같은 비율로)
    private func normalized() -> Signature? {
        let all = strokes.flatMap { $0 }
        guard let minX = all.map(\.x).min(), let maxX = all.map(\.x).max(), let minY = all.map(\.y).min(), let maxY = all.map(\.y).max(), maxX > minX else { return nil }
        let w = maxX - minX
        let scaled = strokes.map { $0.map { CGPoint(x: ($0.x - minX) / w, y: ($0.y - minY) / w) } }
        let scaledWidths = widths.map { $0.map { Double($0 / w) } }
        return Signature(strokes: scaled, aspect: Double(max(maxY - minY, 1) / w), widths: scaledWidths.count == scaled.count ? scaledWidths : nil)
    }

    private func preview(_ sig: Signature) -> some View {
        Canvas { context, box in
            let w = min(box.width - 10, (box.height - 10) / CGFloat(max(sig.aspect, 0.01)))
            for (n, stroke) in sig.strokes.enumerated() where stroke.count > 1 {
                let ws = sig.widths.flatMap { n < $0.count ? $0[n] : nil }
                for i in 1..<stroke.count {
                    var path = Path()
                    path.move(to: CGPoint(x: 5 + stroke[i - 1].x * w, y: 5 + stroke[i - 1].y * w))
                    path.addLine(to: CGPoint(x: 5 + stroke[i].x * w, y: 5 + stroke[i].y * w))
                    let lw = ws.map { $0.count == stroke.count ? CGFloat(($0[i - 1] + $0[i]) / 2) * w : 1.6 } ?? 1.6
                    context.stroke(path, with: .color(.black), style: StrokeStyle(lineWidth: max(lw, 0.6), lineCap: .round))
                }
            }
        }
    }
}

/// 기둥 안에서는 메뉴를 유리 단추 없이(동그란 아이콘만)
private struct PlainMenuIf: ViewModifier {
    let plain: Bool
    func body(content: Content) -> some View {
        if plain { content.buttonStyle(.plain).menuIndicator(.hidden) } else { content.buttonStyle(.glass) }
    }
}
