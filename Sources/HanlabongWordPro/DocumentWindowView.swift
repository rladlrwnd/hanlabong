import AppCore
import AppKit
import SkillEngine
import SwiftUI
import UniformTypeIdentifiers

/// 워드·한글·노트 영역의 창 화면. PDF 영역(PDFWindowView)과 같은 디자인 문법:
/// - 간단히 보기: 종이 + 오른쪽 유리 기둥(목차·찾기·확대·자세히) + 아래 가운데 AI 요청칸
/// - 자세히 보기: 위쪽 도구 막대(굵게·기울임·제목·목록·표·그림·쪽 나눔) + 옆 목차 칸 + 아래 AI 요청줄 + 상태 막대("3 / 12쪽")
/// - 쪽 보기(보기 메뉴): 한 쪽씩(기본) / 두 쪽씩(책처럼) / 이어 보기
/// - 두 보기 다 종이에서 바로 고친다. 저장(⌘S)은 원본 옆 `이름_edit.확장자`, 다른 형식으로 저장은 ⌘⇧S
struct DocumentWindowView: View {
    @ObservedObject var session: DocumentSession
    @State private var showContents = false
    @State private var showSidebar = true
    /// 표 크기 고르기(자세히 보기 도구 막대 / 간단히 보기 + 메뉴)
    @State private var pickingTable = false
    @State private var pickingColor = false
    @State private var pickingTableFromRail = false
    /// 내 정보로 빈칸 채우기·서명 넣기(3단계). 세션은 안 건드리고 이 모델이 편집기를 쓴다
    @StateObject private var fill: DocumentFillModel

    init(session: DocumentSession) {
        self.session = session
        let model = DocumentFillModel(session: session)
        _fill = StateObject(wrappedValue: model)
        session.fill = model
    }

    private var detailed: Bool { session.mode == .detailed }
    private var accent: Color { AppAccent.color(UserDefaults.standard.string(forKey: AppAccent.key) ?? AppAccent.defaultHex) }
    private var hasDocument: Bool { session.document != nil }

    var body: some View {
        VStack(spacing: 0) {
            if detailed {
                topBar
                toolBar
            }
            HStack(spacing: 0) {
                if detailed, showSidebar, session.document != nil {
                    sidePanel
                        .frame(width: 210)
                        .background(Color(white: 0.13))
                }
                ZStack {
                    // 간단히 보기도 종이가 창 맨 위까지 이어진다(PDF 영역과 같은 모양). 신호등 단추 밑 여백은 화면 안쪽 여백이 맡는다
                    DocumentCanvas(session: session)
                    if session.loading { loadingCard } else if session.document == nil { empty }
                    if !detailed, session.document != nil { readerOverlay }
                    if !detailed, let notice = session.notice { noticeToast(notice) }
                }
            }
            if detailed, session.document != nil { AssistantBar(host: session, glass: false) }
            if detailed { statusBar }
        }
        .background(Color(white: 0.16))
        .background {
            // 단축키: ⌘E 보기 바꾸기, ⌘F 찾기, ⌘± 확대·축소, ⌘9 창에 맞추기, ⌘0 실제 크기
            Group {
                Button("") { session.mode = detailed ? .simple : .detailed }.keyboardShortcut("e", modifiers: .command)
                Button("") { session.send(.find) }.keyboardShortcut("f", modifiers: .command)
                Button("") { session.send(.zoomOut) }.keyboardShortcut("-", modifiers: .command)
                Button("") { session.send(.zoomIn) }.keyboardShortcut("=", modifiers: .command)
                Button("") { session.send(.fit) }.keyboardShortcut("9", modifiers: .command)
                Button("") { session.send(.actualSize) }.keyboardShortcut("0", modifiers: .command)
                Button("") { session.saveInBackground() }.keyboardShortcut("s", modifiers: .command).disabled(!hasDocument)
                Button("") { saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(!hasDocument)
                Button("") { session.toggleBoldShortcut() }.keyboardShortcut("b", modifiers: .command).disabled(!hasDocument)
                Button("") { session.toggleItalicShortcut() }.keyboardShortcut("i", modifiers: .command).disabled(!hasDocument)
            }
            .opacity(0).allowsHitTesting(false)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: \.isFileURL) else { return false }
            guard DocumentArea.of(url) != nil else {
                session.message = L("“\(url.lastPathComponent)”은(는) 이 앱이 여는 형식이 아니에요", "“\(url.lastPathComponent)” isn't a format this app opens")
                return false
            }
            session.open(url)
            return true
        }
        .alert(L("AI 요청 실패", "AI request failed"), isPresented: Binding(get: { session.aiError != nil }, set: { if !$0 { session.aiError = nil } })) {
            Button(L("확인", "OK"), role: .cancel) { session.aiError = nil }
        } message: { Text(session.aiError ?? "") }
        .sheet(isPresented: $fill.editingProfile) {
            ProfileEditor(profile: fill.profile, save: { fill.saveProfile($0) }, close: { fill.editingProfile = false })
        }
        .sheet(isPresented: $fill.listing) {
            DocumentBlankListSheet(fill: fill, close: { fill.listing = false })
        }
        .sheet(isPresented: $fill.signing, onDismiss: { fill.signTarget = nil }) {
            SignaturePad(saved: fill.signatures, onDone: { signature in
                // 새로 쓴 서명: 이 맥에 저장해 두고 바로 넣는다
                fill.signing = false
                if let signature { fill.addSignature(signature); fill.place(signature) } else { fill.signTarget = nil }
            }, onDelete: { fill.deleteSignature($0) }, onUse: { signature in
                fill.signing = false
                fill.place(signature)
            })
        }
    }

    // MARK: 간단히 보기: 오른쪽에 둥근 유리 기둥(목차·찾기·확대·자세히), 아래 가운데 AI 요청칸

    private var readerOverlay: some View {
        ZStack {
            HStack(alignment: .top) {
                Spacer()
                VStack(alignment: .trailing, spacing: 10) {
                    rail
                    Spacer()
                    areaBadge
                }
            }
            .padding(.top, 40).padding(.trailing, 14).padding(.bottom, 14)
            VStack {
                Spacer()
                AssistantBar(host: session, glass: true)
                    .padding(.horizontal, 120)
                    .padding(.bottom, 16)
            }
            .padding(.top, 12)
        }
    }

    private var rail: some View {
        GlassRail {
            Button { showContents.toggle() } label: { RailIcon(symbol: "list.bullet", active: showContents) }
                .buttonStyle(.plain)
                .help(L("목차", "Contents"))
                .popover(isPresented: $showContents, arrowEdge: .leading) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("목차", "Contents")).font(.headline)
                        DocumentOutlineList(session: session) { showContents = false }
                    }
                    .padding(12)
                    .frame(width: 320, height: 420)
                }
            Button { session.send(.find) } label: { RailIcon(symbol: "magnifyingglass") }
                .buttonStyle(.plain)
                .help(L("문서 안에서 찾기 (⌘F)", "Find in document (⌘F)"))
            insertMenu
                .help(L("넣기 · 표·그림·서명·쪽 나눔", "Insert · table, picture, signature, page break"))
            fillMenu(label: RailIcon(symbol: "text.badge.checkmark", active: fill.busy), plain: true)
                .help(L("채우기 · 내 정보로 빈칸 채우기", "Fill · fill blanks with my info"))
            zoomMenu(label: RailIcon(symbol: "plus.magnifyingglass"), plain: true)
                .help(L("보기 · 한 쪽씩·두 쪽씩·이어 보기 · 확대·축소", "View · one page, two pages, continuous · zoom"))
            RailDivider()
            Button { session.mode = .detailed } label: { RailIcon(symbol: "slider.horizontal.3") }
                .buttonStyle(.plain)
                .help(L("자세히 보기 — 편집 도구·목차 칸 (⌘E)", "Detailed view — tools, contents (⌘E)"))
        }
    }

    /// 채우기 메뉴(간단히·자세히 둘 다, PDF 영역의 채우기 메뉴와 같은 모양)
    private func fillMenu<MenuLabel: View>(label: MenuLabel, plain: Bool) -> some View {
        Menu {
            Button { fill.fillFromProfile() } label: { Label(L("내 정보로 자동 채우기", "Fill with my info"), systemImage: "wand.and.stars") }
            Button { fill.openList() } label: { Label(L("빈칸 목록…", "Blank list…"), systemImage: "list.bullet.rectangle") }
            Divider()
            Button { fill.beginSigning(target: nil) } label: { Label(L("서명 넣기…", "Add signature…"), systemImage: "signature") }
            Divider()
            Button { fill.beginEditingProfile() } label: { Label(L("내 정보 편집…", "Edit my info…"), systemImage: "person.text.rectangle") }
        } label: { label }
        .menuStyle(.button)
        .modifier(PlainMenuIfNeeded(plain: plain))
        .fixedSize()
        .disabled(!hasDocument || fill.busy)
    }

    /// + 넣기(PDF 영역의 넣기 메뉴와 같은 모양): 표는 크기를 고르는 작은 칸이 뜬다
    private var insertMenu: some View {
        Menu {
            Button { pickingTableFromRail = true } label: { Label(L("표 넣기…", "Table…"), systemImage: "tablecells") }
            Button { pickImage() } label: { Label(L("그림 넣기…", "Picture…"), systemImage: "photo") }
            Button { fill.beginSigning(target: nil) } label: { Label(L("서명 넣기…", "Signature…"), systemImage: "signature") }
            Button { session.insertPageBreak() } label: { Label(L("쪽 나눔 넣기", "Page break"), systemImage: "rectangle.split.1x2") }
        } label: {
            RailIcon(symbol: "plus", active: pickingTableFromRail)
        }
        .menuStyle(.button)
        .modifier(PlainMenuIfNeeded(plain: true))
        .fixedSize()
        .disabled(!hasDocument)
        .popover(isPresented: $pickingTableFromRail, arrowEdge: .leading) {
            TableSizePicker { rows, columns in
                pickingTableFromRail = false
                session.insertTable(rows: rows, columns: columns)
            }
        }
    }

    /// 간단히 보기 위쪽에 잠깐 뜨는 안내(저장했어요 등)
    private func noticeToast(_ text: String) -> some View {
        VStack {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                Text(text).font(.callout).lineLimit(1)
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .modifier(SmokyGlass(shape: Capsule()))
            .padding(.top, 44)
            Spacer()
        }
        .allowsHitTesting(false)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// 오른쪽 아래: 어떤 영역인지(옛 .hwp는 저장 안내까지)
    private var areaBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: areaSymbol)
            Text(session.document?.isLegacyHwp == true ? L("한글 · 옛 .hwp는 .hwpx로 저장", "Hangul · legacy .hwp saves as .hwpx") : session.area.title)
            if let pageText { Text("· " + pageText).monospacedDigit().foregroundStyle(.secondary) }
            if session.dirty { Circle().fill(accent).frame(width: 6, height: 6).help(L("저장 안 한 고침 있음 (⌘S)", "Unsaved changes (⌘S)")) }
        }
        .font(.system(size: 11.5, weight: .semibold))
        .padding(.horizontal, 12).padding(.vertical, 6)
        .modifier(SmokyGlass(shape: Capsule()))
        .help(session.hint)
    }

    private var areaSymbol: String {
        switch session.area {
        case .pdf: return "doc.richtext"
        case .word: return "doc.text"
        case .hangul: return "character.book.closed"
        case .note: return "note.text"
        }
    }

    /// 쪽 보기 방식 고르기(한 쪽씩 / 두 쪽씩 / 이어 보기). 간단히·자세히 보기 메뉴에 같이 들어간다
    private var pageLayoutPicker: some View {
        Picker(L("쪽 보기", "Pages"), selection: $session.pageLayout) {
            ForEach(DocumentPageLayout.allCases) { layout in
                Label(layout.title, systemImage: layout.symbol).tag(layout)
            }
        }
        .pickerStyle(.inline)
    }

    /// 지금 보는 쪽 / 전체 쪽 글("3 / 12쪽"). 이어 보기면 쪽 나눔으로 센 쪽 수
    private var pageText: String? {
        guard let document = session.document else { return nil }
        if session.pageLayout.paginates {
            let position = session.pagePosition
            return L("\(position.current) / \(position.total)쪽", "Page \(position.current) of \(position.total)")
        }
        return document.pageCount > 1 ? L("\(document.pageCount)쪽", "\(document.pageCount) pages") : nil
    }

    private func zoomMenu<MenuLabel: View>(label: MenuLabel, plain: Bool) -> some View {
        Menu {
            pageLayoutPicker
            Divider()
            Button(L("크게 (⌘+)", "Zoom in (⌘+)")) { session.send(.zoomIn) }
            Button(L("작게 (⌘−)", "Zoom out (⌘−)")) { session.send(.zoomOut) }
            Button(L("창에 맞추기 (⌘9)", "Fit width (⌘9)")) { session.send(.fit) }
            Button(L("실제 크기 (⌘0)", "Actual size (⌘0)")) { session.send(.actualSize) }
        } label: { label }
        .menuStyle(.button)
        .modifier(PlainMenuIfNeeded(plain: plain))
        .fixedSize()
        .disabled(session.document == nil)
    }

    // MARK: 자세히 보기: 맨 위 줄(이름·보기·찾기·저장) + 둘째 줄(편집 도구 자리)

    private var topBar: some View {
        HStack(spacing: 8) {
            Text(session.title + (session.dirty ? " •" : "")).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 220, alignment: .leading)
                .padding(.leading, 72)
            Menu {
                pageLayoutPicker
                Divider()
                Toggle(L("옆 목차 칸 보기", "Show contents panel"), isOn: $showSidebar)
                Divider()
                Button(L("크게 (⌘+)", "Zoom in (⌘+)")) { session.send(.zoomIn) }
                Button(L("작게 (⌘−)", "Zoom out (⌘−)")) { session.send(.zoomOut) }
                Button(L("창에 맞추기 (⌘9)", "Fit width (⌘9)")) { session.send(.fit) }
                Button(L("실제 크기 (⌘0)", "Actual size (⌘0)")) { session.send(.actualSize) }
                Divider()
                Button(L("간단히 보기로 (⌘E)", "Simple view (⌘E)")) { session.mode = .simple }
            } label: { Label(L("보기", "View"), systemImage: "book") }
            .menuStyle(.button).buttonStyle(.glass).controlSize(.small).fixedSize()
            .disabled(session.document == nil)
            Spacer(minLength: 8)
            Button { session.send(.find) } label: { Label(L("찾기", "Find"), systemImage: "magnifyingglass") }
                .buttonStyle(.glass).controlSize(.small)
                .help(L("문서 안에서 찾기 (⌘F)", "Find in document (⌘F)"))
                .disabled(session.document == nil)
            Menu {
                Button(L("다른 형식으로 저장… (⌘⇧S)", "Save in another format… (⌘⇧S)")) { saveAs() }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.button).buttonStyle(.glass).controlSize(.small).menuIndicator(.hidden).fixedSize()
                .disabled(!hasDocument || session.saving)
                .help(L("다른 형식으로 저장 — 워드·한글·PDF·RTF·ODT·Markdown·텍스트·HTML", "Save as Word, Hangul, PDF, RTF, ODT, Markdown, text or HTML"))
            Button { session.saveInBackground() } label: { Label(L("저장", "Save"), systemImage: "square.and.arrow.down") }
                .buttonStyle(.glassProminent).controlSize(.small)
                .disabled(!hasDocument || session.saving)
                .help(L("원본은 그대로 두고 옆에 \(session.saveTargetName)로 저장 (⌘S)", "Keeps the original; saves beside it as \(session.saveTargetName) (⌘S)"))
                .padding(.trailing, 12)
        }
        .frame(height: 44)
        .background(WindowDragArea())
        .background(Color(white: 0.12))
    }

    /// 편집 도구: 굵게·기울임·제목 단계·목록·표·그림·쪽 나눔. 커서 자리 모양(굵게인지, 제목 몇인지)이 단추에 비친다
    private var toolBar: some View {
        let state = session.format
        return HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 4) {
                HStack(spacing: 4) {
                    tool("bold", L("굵게 (⌘B)", "Bold (⌘B)"), active: state.bold) { session.toggleBold() }
                    tool("italic", L("기울임 (⌘I)", "Italic (⌘I)"), active: state.italic) { session.toggleItalic() }
                    headingMenu(state)
                    fontMenu(state)
                    tool("textformat.size.smaller", L("글자 작게", "Smaller text"), active: false) { session.changeFontSize(up: false) }
                    sizeMenu(state)
                    tool("textformat.size.larger", L("글자 크게", "Larger text"), active: false) { session.changeFontSize(up: true) }
                    tool("paintpalette", L("글자 색", "Text color"), active: pickingColor) { pickingColor = true }
                        .popover(isPresented: $pickingColor, arrowEdge: .bottom) {
                            TextColorPicker { color in session.setTextColor(color) }
                        }
                    tool("text.alignleft", L("왼쪽 정렬", "Align left"), active: state.alignment == .left) { session.setAlignment(.left) }
                    tool("text.aligncenter", L("가운데 정렬", "Center"), active: state.alignment == .center) { session.setAlignment(.center) }
                    tool("text.alignright", L("오른쪽 정렬", "Align right"), active: state.alignment == .right) { session.setAlignment(.right) }
                    tool("text.justify", L("양쪽 정렬", "Justify"), active: state.alignment == .justified) { session.setAlignment(.justified) }
                    tool("list.bullet", L("글머리 목록", "Bulleted list"), active: state.bullet) { session.toggleBullet() }
                        .disabled(!hasDocument || state.inBlock)
                    tool("tablecells", L("표 넣기", "Insert table"), active: pickingTable) { pickingTable = true }
                        .popover(isPresented: $pickingTable, arrowEdge: .bottom) {
                            TableSizePicker { rows, columns in
                                pickingTable = false
                                session.insertTable(rows: rows, columns: columns)
                            }
                        }
                    tableEditMenu(state)
                    tool("photo", L("그림 넣기…", "Insert picture…"), active: false) { pickImage() }
                    tool("rectangle.split.1x2", L("쪽 나눔 넣기", "Insert page break"), active: false) { session.insertPageBreak() }
                    tool("signature", L("서명 넣기…", "Insert signature…"), active: fill.signing) { fill.beginSigning(target: nil) }
                    fillMenu(label: Label(L("채우기", "Fill"), systemImage: "text.badge.checkmark").labelStyle(.titleAndIcon), plain: false)
                        .help(L("내 정보로 빈칸 채우기 · 빈칸 목록 · 내 정보 편집", "Fill blanks with my info · blank list · edit my info"))
                }
            }
            .controlSize(.small)
            .disabled(!hasDocument)
            }
            Spacer(minLength: 0)
            Button { session.mode = .simple } label: { Label(L("간단히 보기", "Simple view"), systemImage: "rectangle.compress.vertical") }
                .buttonStyle(.glass).controlSize(.small)
                .help(L("종이와 요청칸만 보이게 (⌘E)", "Just the paper and the request box (⌘E)"))
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Color(white: 0.14))
    }

    private func tool(_ symbol: String, _ name: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 18) }
            .modifier(ToolButtonStyle(active: active))
            .help(name)
    }

    /// 제목 단계 메뉴: 본문 / 제목 1 / 제목 2 / 제목 3 (지금 단계에 체크)
    private func headingMenu(_ state: DocumentFormatState) -> some View {
        Menu {
            ForEach([nil, 1, 2, 3] as [Int?], id: \.self) { level in
                Button {
                    session.setHeading(level)
                } label: {
                    if state.heading == level { Label(headingName(level), systemImage: "checkmark") } else { Text(headingName(level)) }
                }
            }
        } label: {
            Label(headingName(state.heading), systemImage: "textformat.size").labelStyle(.titleAndIcon)
        }
        .menuStyle(.button).buttonStyle(.glass).fixedSize()
        .disabled(!hasDocument || state.inBlock)
        .help(L("제목 단계 — 목차에 올라가요", "Heading level — shows in contents"))
    }

    /// 표 고치기 메뉴: 커서가 표 칸 안일 때만 켜진다
    private func tableEditMenu(_ state: DocumentFormatState) -> some View {
        Menu {
            Button(L("위에 줄 추가", "Add row above")) { session.editTable(.addRow(below: false)) }
            Button(L("아래에 줄 추가", "Add row below")) { session.editTable(.addRow(below: true)) }
            Button(L("줄 삭제", "Delete row"), role: .destructive) { session.editTable(.deleteRow) }
            Divider()
            Button(L("왼쪽에 칸 추가", "Add column left")) { session.editTable(.addColumn(right: false)) }
            Button(L("오른쪽에 칸 추가", "Add column right")) { session.editTable(.addColumn(right: true)) }
            Button(L("칸 삭제", "Delete column"), role: .destructive) { session.editTable(.deleteColumn) }
        } label: {
            Image(systemName: "tablecells.badge.ellipsis").frame(width: 18)
        }
        .menuStyle(.button).buttonStyle(.glass).menuIndicator(.hidden).fixedSize()
        .disabled(!hasDocument || !state.inTable)
        .help(L("표 줄·칸 고치기 (표 칸 안에 커서가 있을 때)", "Edit table rows/columns (caret inside a table)"))
    }

    /// 글꼴 메뉴: 기본 + 이 맥에 깔린 글꼴(지금 글꼴에 체크)
    private func fontMenu(_ state: DocumentFormatState) -> some View {
        Menu {
            Button { session.setFontFamily(nil) } label: {
                if state.fontFamily == nil { Label(L("기본 글꼴", "Default font"), systemImage: "checkmark") } else { Text(L("기본 글꼴", "Default font")) }
            }
            Divider()
            ForEach(DocumentEditor.availableFamilies(), id: \.self) { name in
                Button { session.setFontFamily(name) } label: {
                    if state.fontFamily == name { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
        } label: {
            Label(state.fontFamily ?? L("기본", "Default"), systemImage: "textformat").labelStyle(.titleAndIcon)
        }
        .menuStyle(.button).buttonStyle(.glass).fixedSize()
        .help(L("글꼴", "Font"))
    }

    /// 글자 크기 메뉴: 지금 크기가 단추에 보이고, 단계표에서 고른다
    private func sizeMenu(_ state: DocumentFormatState) -> some View {
        Menu {
            ForEach(DocumentEditor.sizeSteps, id: \.self) { size in
                Button { session.setFontSize(size) } label: {
                    if abs(state.fontSize - size) < 0.05 { Label(Self.sizeText(size), systemImage: "checkmark") } else { Text(Self.sizeText(size)) }
                }
            }
        } label: {
            Text(state.fontSize > 0 ? Self.sizeText(state.fontSize) : "–").monospacedDigit().frame(minWidth: 26)
        }
        .menuStyle(.button).buttonStyle(.glass).fixedSize()
        .help(L("글자 크기(pt)", "Text size (pt)"))
    }

    private static func sizeText(_ size: CGFloat) -> String {
        size == size.rounded() ? String(Int(size)) : String(format: "%.1f", size)
    }

    private func headingName(_ level: Int?) -> String {
        switch level {
        case 1?: return L("제목 1", "Heading 1")
        case 2?: return L("제목 2", "Heading 2")
        case 3?: return L("제목 3", "Heading 3")
        default: return L("본문", "Body")
        }
    }

    // MARK: 그림 고르기 · 다른 형식으로 저장

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.message = L("넣을 그림을 골라요 · 본문 폭에 맞춰 줄어들어요", "Choose a picture · it shrinks to fit the text width")
        if panel.runModal() == .OK, let url = panel.url { session.insertImage(url) }
    }

    /// 형식을 고르는 칸이 붙은 저장 창. 고른 형식에 맞춰 확장자가 바뀐다
    private func saveAs() {
        guard let url = session.url else { return }
        let formats: [DocumentFormat] = [.docx, .hwpx, .pdf, .rtf, .odt, .md, .txt, .html]
        let start = DocumentSession.saveFormat(for: url)
        let panel = NSSavePanel()
        panel.directoryURL = url.deletingLastPathComponent()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let base = url.deletingPathExtension().lastPathComponent + "_edit"
        panel.nameFieldStringValue = base + "." + start.fileExtension
        panel.message = L("다른 형식으로 저장 · 원본은 덮어쓰지 않아요", "Save in another format · the original is never overwritten")
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for format in formats { popup.addItem(withTitle: "\(format.title) (.\(format.fileExtension))") }
        popup.selectItem(at: formats.firstIndex(of: start) ?? 0)
        func apply() {
            let format = formats[max(popup.indexOfSelectedItem, 0)]
            if let type = UTType(filenameExtension: format.fileExtension) { panel.allowedContentTypes = [type] }
            let name = (panel.nameFieldStringValue as NSString).deletingPathExtension
            panel.nameFieldStringValue = (name.isEmpty ? base : name) + "." + format.fileExtension
        }
        let target = PopupTarget(apply)
        popup.target = target
        popup.action = #selector(PopupTarget.changed(_:))
        let label = NSTextField(labelWithString: L("형식:", "Format:"))
        let row = NSStackView(views: [label, popup])
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        panel.accessoryView = row
        apply()
        let picked = panel.runModal() == .OK ? panel.url : nil
        withExtendedLifetime(target) {}
        guard let picked else { return }
        session.export(to: picked, as: formats[max(popup.indexOfSelectedItem, 0)])
    }

    // MARK: 옆 목차 칸

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("목차", "Contents")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.top, 10)
            DocumentOutlineList(session: session)
        }
    }

    // MARK: 아래 상태 막대: 영역 이름 · 문단 수 · 글자 수 · 안내

    private var statusBar: some View {
        HStack(spacing: 10) {
            Text(session.area.title).font(.caption.weight(.semibold))
            if let document = session.document {
                Text(L("문단 \(document.paragraphCount)", "\(document.paragraphCount) paragraphs") + " · "
                     + L("글자 \(document.characterCount.formatted())자 (공백 빼고 \(document.characterCountNoSpaces.formatted())자)",
                         "\(document.characterCount.formatted()) characters (\(document.characterCountNoSpaces.formatted()) without spaces)"))
                    .font(.caption).monospacedDigit()
                if let pageText {
                    Text(pageText).font(.caption).monospacedDigit()
                }
            }
            if session.dirty {
                Label(L("저장 안 한 고침 있음", "Unsaved changes"), systemImage: "circle.fill")
                    .labelStyle(.titleAndIcon).font(.caption).foregroundStyle(accent).lineLimit(1)
                    .help(session.hint)
            }
            Text(session.message ?? session.hint)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Color(white: 0.12))
    }

    // MARK: 읽는 중 · 빈 화면

    private var loadingCard: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text(L("“\(session.title)”을(를) 읽는 중…", "Reading “\(session.title)”…")).foregroundStyle(.secondary)
        }
        .padding(28)
        .modifier(SmokyGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous)))
    }

    /// 아직 문서가 없거나 못 읽었을 때
    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: session.message == nil ? areaSymbol : "exclamationmark.triangle").font(.system(size: 44, weight: .light))
            Text(session.message ?? L("한라봉 휠 ⌘ › Hanlabong WordPro에 놓거나, 여기로 끌어 놓아요 · \(session.area.title) 문서", "Drop on Hanlabong wheel ⌘ › Hanlabong WordPro, or drag here · \(session.area.title) documents"))
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            Button(L("파일 열기…", "Open…")) {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url { session.open(url) }
            }
            .buttonStyle(.glass)
        }
        .foregroundStyle(.white.opacity(0.85))
    }
}

/// 목차: 제목(1~3단계) 목록. 누르면 그 자리로 부드럽게 내려간다
struct DocumentOutlineList: View {
    @ObservedObject var session: DocumentSession
    var onPick: () -> Void = {}

    var body: some View {
        if let outline = session.document?.outline, !outline.isEmpty {
            List(outline) { item in
                Button { session.scroll(to: item); onPick() } label: {
                    Text(item.title)
                        .font(item.level == 1 ? .callout.weight(.semibold) : .callout)
                        .foregroundStyle(item.level >= 3 ? .secondary : .primary)
                        .lineLimit(2)
                        .padding(.leading, CGFloat(item.level - 1) * 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(item.location == nil)
            }
            .scrollContentBackground(.hidden)
        } else {
            Text(session.document == nil ? "" : L("이 문서엔 제목이 없어요", "No headings in this document"))
                .font(.caption).foregroundStyle(.secondary)
                .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

/// 기둥 안에서는 메뉴를 유리 단추 없이(동그란 아이콘만)
private struct PlainMenuIfNeeded: ViewModifier {
    let plain: Bool
    func body(content: Content) -> some View {
        if plain { content.buttonStyle(.plain).menuIndicator(.hidden) } else { content.buttonStyle(.glass) }
    }
}

/// 도구 단추: 켜진 모양(굵게인 자리 등)이면 진한 유리
private struct ToolButtonStyle: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active { content.buttonStyle(.glassProminent) } else { content.buttonStyle(.glass) }
    }
}

/// NSPopUpButton이 바뀔 때 부를 곳(저장 창의 형식 고르기)
private final class PopupTarget: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func changed(_ sender: Any?) { action() }
}

/// 글자 색 고르기: 자주 쓰는 색 칸 + 직접 고르기(색상 패널)
struct TextColorPicker: View {
    var onPick: (NSColor?) -> Void
    @State private var custom = Color.black
    private let swatches: [(String, NSColor)] = [
        ("검정", NSColor.black), ("진회색", NSColor(white: 0.35, alpha: 1)), ("빨강", NSColor(srgbRed: 0.85, green: 0.15, blue: 0.15, alpha: 1)),
        ("주황", NSColor(srgbRed: 0.95, green: 0.55, blue: 0.10, alpha: 1)), ("초록", NSColor(srgbRed: 0.15, green: 0.55, blue: 0.25, alpha: 1)),
        ("파랑", NSColor(srgbRed: 0.10, green: 0.35, blue: 0.85, alpha: 1)), ("보라", NSColor(srgbRed: 0.50, green: 0.25, blue: 0.75, alpha: 1)),
        ("흰색", NSColor.white),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("글자 색", "Text color")).font(.callout.weight(.semibold))
            HStack(spacing: 6) {
                ForEach(swatches, id: \.0) { name, color in
                    Circle().fill(Color(nsColor: color))
                        .overlay(Circle().stroke(Color.secondary.opacity(0.5), lineWidth: 0.5))
                        .frame(width: 20, height: 20)
                        .contentShape(Circle())
                        .onTapGesture { onPick(color) }
                        .help(name)
                }
            }
            HStack {
                ColorPicker(L("다른 색", "Other"), selection: $custom, supportsOpacity: false)
                    .onChange(of: custom) { _, value in onPick(NSColor(value)) }
                Spacer()
                Button(L("기본(검정)", "Default")) { onPick(nil) }.controlSize(.small)
            }
        }
        .padding(12)
    }
}

/// 표 크기 고르기: 칸 위에 마우스를 올리면 그만큼 칠해지고, 누르면 그 크기로 넣는다(워드처럼)
struct TableSizePicker: View {
    var onPick: (Int, Int) -> Void
    @State private var hover = (rows: 2, columns: 2)
    private let maxRows = 8, maxColumns = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("표 넣기 · \(hover.rows)줄 × \(hover.columns)칸", "Insert table · \(hover.rows) × \(hover.columns)"))
                .font(.callout.weight(.semibold)).monospacedDigit()
            VStack(spacing: 3) {
                ForEach(0..<maxRows, id: \.self) { r in
                    HStack(spacing: 3) {
                        ForEach(0..<maxColumns, id: \.self) { c in
                            let on = r < hover.rows && c < hover.columns
                            RoundedRectangle(cornerRadius: 2)
                                .fill(on ? Color.accentColor.opacity(0.75) : Color.secondary.opacity(0.18))
                                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.secondary.opacity(0.35), lineWidth: 0.5))
                                .frame(width: 18, height: 18)
                                .contentShape(Rectangle())
                                .onHover { if $0 { hover = (r + 1, c + 1) } }
                                .onTapGesture { onPick(r + 1, c + 1) }
                        }
                    }
                }
            }
            Text(L("첫 줄은 머리줄(옅은 배경·굵게)이에요", "The first row is the header row"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
    }
}
