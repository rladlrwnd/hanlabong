import AppCore
import AppKit
import QuickLookThumbnailing
import SkillEngine
import SwiftUI

/// 띄워두기(Float): 파일을 화면 위 작은 유리 선반에 올려두고, 나중에 다른 앱·폴더로 끌어다 쓴다.
/// 파일은 옮기지 않는다(선반에는 자리만 기억). 두 번 누르면 열고, ✕로 내린다.
@MainActor
final class FloatShelfModel: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        var thumbnail: NSImage?
    }
    @Published var items: [Item] = []
}

@MainActor
final class FloatShelfController {
    private let model = FloatShelfModel()
    private let presence = PanelPresence()
    private var panel: ReviewPanel?

    func add(_ urls: [URL], near point: NSPoint?) {
        let fresh = urls.filter { url in !model.items.contains { $0.url == url } }
        for url in fresh {
            let item = FloatShelfModel.Item(url: url, thumbnail: NSWorkspace.shared.icon(forFile: url.path))
            model.items.append(item)
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 96, height: 96), scale: 2, representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
                guard let image = rep?.nsImage else { return }
                DispatchQueue.main.async {
                    guard let self, let index = self.model.items.firstIndex(where: { $0.id == item.id }) else { return }
                    self.model.items[index].thumbnail = image
                }
            }
        }
        show(near: point)
    }

    private func show(near point: NSPoint?) {
        if let panel, panel.isVisible { panel.orderFrontRegardless(); return }
        let size = NSSize(width: FloatShelfView.width + 48, height: 420)
        let panel = ReviewPanel(size: size)
        panel.level = .floating
        panel.contentView = NSHostingView(rootView: PresenceWrap(presence: presence, content: FloatShelfView(model: model, close: { [weak self] in self?.close() })))
        let anchor = point ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // 화면 오른쪽 가장자리에 붙여 둔다(작업을 가리지 않게)
        panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 8, y: min(max(anchor.y - size.height / 2, visible.minY), visible.maxY - size.height)))
        self.panel = panel
        panel.present(presence, makeKey: false)
    }

    private func close() {
        panel?.dismiss(presence)
        model.items.removeAll()
        panel = nil
    }
}

struct FloatShelfView: View {
    static let width: CGFloat = 132
    @ObservedObject var model: FloatShelfModel
    let close: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "pin.fill").font(.system(size: 11, weight: .semibold))
                Text(L("띄워둔 파일", "Floating")).font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.small)
                    .help(L("모두 내리기(파일은 그대로)", "Clear all (files stay)"))
            }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(model.items) { item in
                        VStack(spacing: 4) {
                            Image(nsImage: item.thumbnail ?? NSImage())
                                .resizable().aspectRatio(contentMode: .fit)
                                .frame(width: 84, height: 84)
                                .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                            Text(item.url.lastPathComponent).font(.system(size: 10)).lineLimit(2).multilineTextAlignment(.center)
                        }
                        .frame(width: Self.width - 24)
                        .contentShape(Rectangle())
                        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
                        .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
                        .contextMenu {
                            Button(L("열기", "Open")) { NSWorkspace.shared.open(item.url) }
                            Button(L("Finder에서 보기", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                            Button(L("선반에서 내리기", "Remove")) { model.items.removeAll { $0.id == item.id } }
                        }
                        .help(L("끌어서 다른 곳에 놓기 · 두 번 눌러 열기", "Drag out to use · double-click to open"))
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(12)
        .frame(width: Self.width)
        .frame(maxHeight: 372)
        .fixedSize(horizontal: false, vertical: true)
        .background(WindowDragArea())
        .modifier(GlassFinish(shape: shape, surface: .panel))
        .environment(\.controlActiveState, .key)
        .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
        .padding(24)
        .onChange(of: model.items.isEmpty) { _, empty in if empty { close() } }
    }
}
