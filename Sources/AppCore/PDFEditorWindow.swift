import AppKit
import PDFKit
import SkillEngine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - PDF 쪽 편집 (미리보기 앱의 쪽 다루기 정도: 순서·돌리기·지우기·끼워 넣기·골라서 저장)

@MainActor
package final class PDFEditorModel: ObservableObject {
    let url: URL
    @Published var draft: PDFPageDraft
    @Published var selection: Set<UUID> = []
    @Published var problem: String?
    /// 0 = 원본, 1부터 = 끼워 넣은 파일(draft.extraFiles와 같은 순서)
    private var documents: [PDFDocument]
    private var thumbnails: [String: NSImage] = [:]
    /// ⇧ 클릭으로 범위를 고를 때 기준이 되는 쪽
    private var anchor: UUID?

    /// 처음부터 여러 파일을 합치려고 연 창인지(제목·저장 이름이 달라진다)
    let merging: Bool

    package init(url: URL, document: PDFDocument, merging others: [URL] = []) {
        self.url = url
        documents = [document]
        draft = PDFPageDraft(pageCount: document.pageCount)
        merging = !others.isEmpty
        if merging {
            add(others)
            selection = []
        }
    }

    func thumbnail(_ item: PDFPageDraft.Item) -> NSImage? {
        let key = "\(item.file)-\(item.index)"
        if let cached = thumbnails[key] { return cached }
        guard documents.indices.contains(item.file), let page = documents[item.file].page(at: item.index) else { return nil }
        let image = page.thumbnail(of: CGSize(width: 240, height: 240), for: .cropBox)
        thumbnails[key] = image
        return image
    }

    func pageLabel(_ item: PDFPageDraft.Item) -> String {
        item.file == 0 ? "\(item.index + 1)" : L("추가 \(item.file)·\(item.index + 1)", "Added \(item.file)·\(item.index + 1)")
    }

    // 고르기: 클릭 = 하나만, ⌘ = 넣고 빼기, ⇧ = 범위
    func click(_ item: PDFPageDraft.Item) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
            anchor = item.id
        } else if flags.contains(.shift), let anchor, let a = draft.items.firstIndex(where: { $0.id == anchor }),
                  let b = draft.items.firstIndex(where: { $0.id == item.id }) {
            selection = Set(draft.items[min(a, b)...max(a, b)].map(\.id))
        } else {
            selection = [item.id]
            anchor = item.id
        }
    }

    func selectAll() { selection = Set(draft.items.map(\.id)) }

    /// 고른 쪽이 없으면 전체에 적용
    private var targets: Set<UUID> { selection.isEmpty ? Set(draft.items.map(\.id)) : selection }

    func rotate(clockwise: Bool) { draft.rotate(targets, clockwise: clockwise) }

    func deleteSelected() {
        guard !selection.isEmpty else { return }
        draft.delete(selection)
        selection = []
    }

    /// 끌어 놓기: 끈 쪽이 고른 쪽 중 하나면 고른 쪽 전부를, 아니면 그 쪽만 옮긴다
    func drop(_ dragged: UUID, onto target: UUID, after: Bool) {
        let moving = selection.contains(dragged) ? selection : [dragged]
        var before: UUID? = target
        if after, let i = draft.items.firstIndex(where: { $0.id == target }) {
            // 뒤쪽 반에 놓으면 다음 쪽 앞으로(옮기는 쪽은 건너뛴다), 없으면 맨 뒤로
            before = draft.items[(i + 1)...].first { !moving.contains($0.id) }?.id
        }
        draft.move(moving, before: before)
    }

    func add(_ urls: [URL]) {
        var after = draft.items.last { selection.contains($0.id) }?.id ?? draft.items.last?.id
        var added: [UUID] = []
        for url in urls {
            do {
                let document = try PDFPageEditor.openExtra(url)
                documents.append(document)
                let ids = draft.insert(path: url.path, pageCount: document.pageCount, after: after)
                after = ids.last ?? after
                added += ids
                problem = nil
            } catch {
                problem = (error as? LocalizedError)?.errorDescription ?? L("“\(url.lastPathComponent)”을(를) 넣지 못했어요", "Couldn't add “\(url.lastPathComponent)”")
            }
        }
        if !added.isEmpty { selection = Set(added) }
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .image]
        panel.allowsMultipleSelection = true
        panel.message = L("끼워 넣을 PDF나 사진을 골라요", "Choose PDFs or images to add")
        NSApp.activate()
        if panel.runModal() == .OK { add(panel.urls) }
    }
}

package struct PDFEditorView: View {
    package static let cardSize = CGSize(width: 980, height: 740)
    package static let margin: CGFloat = 30

    @ObservedObject var model: PDFEditorModel
    let save: (FileSkill) -> Void
    let close: () -> Void

    package init(model: PDFEditorModel, save: @escaping (FileSkill) -> Void, close: @escaping () -> Void) {
        self.model = model; self.save = save; self.close = close
    }
    @State private var dropTarget: (id: UUID, after: Bool)?
    /// 직접 끄는 중인 쪽과 손가락 위치(그리드 좌표). 시스템 끌어 놓기 대신 쓴다:
    /// 이 창은 바탕을 잡으면 창이 움직이게 돼 있어서 시스템 끌기가 안 먹혔다(사진 자르기처럼 직접 끄는 건 잘 된다).
    @State private var dragging: UUID?
    @State private var dragPoint: CGPoint = .zero
    @State private var frames: [UUID: CGRect] = [:]
    @State private var gridGlobal: CGRect = .zero
    @State private var scrollGlobal: CGRect = .zero
    private static let grid = "pages"
    @AppStorage(AppAccent.key) private var accentHex = AppAccent.defaultHex

    package var body: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "doc.on.doc").font(.system(size: 20, weight: .medium))
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.merging ? L("PDF로 합치기", "Merge into PDF") : L("PDF 편집", "Edit PDF")).font(.system(size: 18, weight: .bold))
                    Text(model.merging ? L("\(model.url.lastPathComponent) 외 \(model.draft.extraFiles.count)개", "\(model.url.lastPathComponent) and \(model.draft.extraFiles.count) more") : model.url.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 12, weight: .bold)) }
                    .buttonStyle(.glass).buttonBorderShape(.circle)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 160), spacing: 14)], spacing: 16) {
                        ForEach(model.draft.items) { item in
                            cell(item, proxy: proxy)
                        }
                    }
                    .padding(14)
                    .coordinateSpace(.named(Self.grid))
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { gridGlobal = $0 }
                    .overlay(alignment: .topLeading) { floatingPreview }
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { scrollGlobal = $0 }
            }
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.black.opacity(0.18)))
            .contentShape(Rectangle())
            .onTapGesture { model.selection = [] }
            // Finder에서 PDF·사진을 끌어 놓으면 끼워 넣기
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty else { return false }
                model.add(files)
                return true
            }

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button { model.rotate(clockwise: false) } label: { Label(L("왼쪽으로", "Left"), systemImage: "rotate.left") }
                        .keyboardShortcut("l", modifiers: .command)
                    Button { model.rotate(clockwise: true) } label: { Label(L("오른쪽으로", "Right"), systemImage: "rotate.right") }
                        .keyboardShortcut("r", modifiers: .command)
                    Button(role: .destructive) { model.deleteSelected() } label: { Label(L("빼기", "Remove"), systemImage: "trash") }
                        .keyboardShortcut(.delete, modifiers: [])
                        .disabled(model.selection.isEmpty || model.selection.count == model.draft.items.count)
                    Button { model.chooseFiles() } label: { Label(L("쪽 추가…", "Add pages…"), systemImage: "plus.rectangle.on.rectangle") }
                    Button(L("모두 고르기", "Select all")) { model.selectAll() }
                        .keyboardShortcut("a", modifiers: .command)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }

            Text(model.problem ?? L("끌어서 순서를 바꿔요 · ⌘·⇧ 클릭으로 여러 쪽 · 고른 게 없으면 돌리기는 전체에 · Finder에서 PDF·사진을 끌어 놓으면 끼워 넣어요",
                                    "Drag to reorder · ⌘/⇧-click for several pages · rotate applies to all when nothing is selected · drop PDFs or images from Finder to add"))
                .font(.caption).foregroundStyle(model.problem == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))

            HStack {
                Text(L("\(model.draft.items.count)쪽 · 원본은 그대로 두고 옆에 저장해요", "\(model.draft.items.count) pages · the original stays as is"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("취소", "Cancel"), action: close).buttonStyle(.glass).keyboardShortcut(.cancelAction)
                Button(L("고른 \(model.selection.count)쪽만 저장", "Save \(model.selection.count) selected")) {
                    save(model.draft.skill(only: model.selection)); close()
                }
                .buttonStyle(.glass)
                .disabled(model.selection.isEmpty || model.selection.count == model.draft.items.count)
                Button(L("저장", "Save")) { save(model.draft.skill()); close() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.draft.hasChanges)
            }
            .controlSize(.large)
        }
        .padding(22)
        .frame(width: Self.cardSize.width, height: Self.cardSize.height)
        .background(WindowDragArea())
        .modifier(GlassFinish(shape: shape, surface: .panel))
        .environment(\.controlActiveState, .key)
        .shadow(color: .black.opacity(0.28), radius: 22, y: 10)
        .padding(Self.margin)
    }

    private func cell(_ item: PDFPageDraft.Item, proxy: ScrollViewProxy) -> some View {
        let selected = model.selection.contains(item.id)
        return VStack(spacing: 6) {
            ZStack {
                if let image = model.thumbnail(item) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .rotationEffect(.degrees(Double(item.rotation)))
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                } else {
                    Image(systemName: "doc").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 120, height: 120)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? AppAccent.color(accentHex).opacity(0.38) : .clear))
            .overlay(alignment: dropTarget?.after == true ? .trailing : .leading) {
                // 놓일 자리 표시(이 쪽 앞 또는 뒤)
                if dropTarget?.id == item.id { Capsule().fill(.white).frame(width: 3).offset(x: dropTarget?.after == true ? 9 : -9) }
            }
            Text(model.pageLabel(item)).font(.caption).monospacedDigit().foregroundStyle(selected ? .primary : .secondary)
        }
        .contentShape(Rectangle())
        .opacity(isMoving(item.id) ? 0.35 : 1)
        .id(item.id)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.grid)) } action: { frames[item.id] = $0 }
        .onTapGesture { model.click(item) }
        .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.grid))
            .onChanged { value in
                dragging = item.id
                dragPoint = value.location
                dropTarget = target(at: value.location)
                autoScroll(proxy)
            }
            .onEnded { value in
                if let target = target(at: value.location) { model.drop(item.id, onto: target.id, after: target.after) }
                dragging = nil
                dropTarget = nil
            })
    }

    /// 끄는 쪽(고른 쪽 중 하나를 끌면 고른 쪽 전부)
    private func isMoving(_ id: UUID) -> Bool {
        guard let dragging else { return false }
        return model.selection.contains(dragging) ? model.selection.contains(id) : id == dragging
    }

    /// 손가락 아래(없으면 가장 가까운) 쪽. 왼쪽 반이면 그 앞, 오른쪽 반이면 뒤. 옮기는 쪽은 빼고 찾는다.
    private func target(at point: CGPoint) -> (id: UUID, after: Bool)? {
        let candidates = frames.filter { id, _ in !isMoving(id) && model.draft.items.contains { $0.id == id } }
        guard let best = candidates.min(by: { distance($0.value, point) < distance($1.value, point) }) else { return nil }
        return (best.key, point.x > best.value.midX)
    }

    private func distance(_ rect: CGRect, _ point: CGPoint) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX), dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }

    /// 끄는 손가락이 보이는 영역 위·아래 끝에 가까우면 그쪽으로 한 줄씩 넘긴다
    private func autoScroll(_ proxy: ScrollViewProxy) {
        let globalY = gridGlobal.minY + dragPoint.y
        guard let index = model.draft.items.firstIndex(where: { $0.id == dropTarget?.id }) else { return }
        if globalY > scrollGlobal.maxY - 40, index + 1 < model.draft.items.count {
            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(model.draft.items[index + 1].id, anchor: .bottom) }
        } else if globalY < scrollGlobal.minY + 40, index > 0 {
            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(model.draft.items[index - 1].id, anchor: .top) }
        }
    }

    /// 끄는 동안 손가락을 따라오는 작은 쪽 그림(여러 쪽이면 장 수 표시)
    @ViewBuilder private var floatingPreview: some View {
        if let dragging, let item = model.draft.items.first(where: { $0.id == dragging }) {
            let count = model.selection.contains(dragging) ? model.selection.count : 1
            ZStack(alignment: .topTrailing) {
                if let image = model.thumbnail(item) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .rotationEffect(.degrees(Double(item.rotation)))
                        .frame(width: 80, height: 80)
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                }
                if count > 1 {
                    Text("\(count)").font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(AppAccent.color(accentHex)))
                        .offset(x: 6, y: -6)
                }
            }
            .position(dragPoint)
            .allowsHitTesting(false)
        }
    }
}
