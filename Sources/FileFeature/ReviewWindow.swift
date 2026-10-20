import AppCore
import AppKit
import BotAvatarsKit
import SkillEngine
import SwiftUI

/// AI 오타수정 검토: 인식 그대로 / 고친 결과를 나란히 보여주고, 고친 곳을 하나씩 켜고 끌 수 있다.
/// "적용"해야 저장된다. 취소하면 아무것도 남지 않는다.
@MainActor
final class ReviewModel: ObservableObject {
    @Published var documents: [OCRReview.Document]
    @Published var index = 0
    let agent: Agent

    init(documents: [OCRReview.Document], agent: Agent) {
        self.documents = documents
        self.agent = agent
    }

    var current: OCRReview.Document { documents[index] }
    var acceptedCount: Int { documents.reduce(0) { $0 + $1.changes.filter(\.accepted).count } }

    func toggle(_ changeID: Int) {
        guard let i = documents[index].changes.firstIndex(where: { $0.id == changeID }) else { return }
        documents[index].changes[i].accepted.toggle()
    }

    /// 한 줄씩: 원래 줄은 고친 곳을 빨갛게, 고친 줄은 바뀐 말을 초록으로
    func lines() -> [(original: AttributedString, corrected: AttributedString)] {
        let document = current
        let corrected = document.correctedLines
        return document.originalLines.enumerated().map { lineIndex, original in
            let changes = document.changes.filter { $0.line == lineIndex }.sorted { $0.range.lowerBound < $1.range.lowerBound }
            var left = AttributedString()
            var right = AttributedString()
            let characters = Array(original)
            var cursor = 0
            for change in changes {
                guard change.range.lowerBound >= cursor, change.range.upperBound <= characters.count else { continue }
                let plain = AttributedString(String(characters[cursor..<change.range.lowerBound]))
                left += plain
                right += plain
                var removed = AttributedString(change.original)
                removed.backgroundColor = .red.opacity(change.accepted ? 0.28 : 0.10)
                if change.accepted { removed.strikethroughStyle = .single }
                left += removed
                var added = AttributedString(change.accepted ? change.replacement : change.original)
                if change.accepted { added.backgroundColor = .green.opacity(0.3) }
                right += added
                cursor = change.range.upperBound
            }
            let rest = AttributedString(String(characters[min(cursor, characters.count)...]))
            left += rest
            right += rest
            _ = corrected
            return (left, right)
        }
    }
}

/// 검토 창: 테두리 없는 유리 패널(휠·팝업과 같은 질감). 키보드(⏎ 적용, esc 닫기)를 받고, 배경을 끌어서 옮길 수 있다.
/// 비활성 패널이라 지금 쓰던 앱은 그대로 맨 앞에 남는다.
/// 창의 빈 배경. 여기를 끌면 창이 움직이고, 그 위의 버튼·슬라이더는 자기 동작만 한다.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override var mouseDownCanMoveWindow: Bool { false }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}
}

/// 창이 떠 있는지(등장·퇴장 모션용). 모든 유리 창이 같은 모션을 쓴다.
@MainActor
final class PanelPresence: ObservableObject {
    @Published var shown = true
}

/// 창 내용을 감싸서, 아래에서 살짝 떠오르며 커지고(등장) 가라앉으며 사라지게(퇴장) 한다. 휠과 같은 스프링.
struct PresenceWrap<Content: View>: View {
    @ObservedObject var presence: PanelPresence
    let content: Content

    var body: some View {
        content
            .scaleEffect(presence.shown ? 1 : 0.94)
            .offset(y: presence.shown ? 0 : 14)
            .opacity(presence.shown ? 1 : 0)
            .animation(presence.shown ? .spring(response: 0.4, dampingFraction: 0.86) : .easeIn(duration: 0.18), value: presence.shown)
    }
}

extension NSPanel {
    /// 새 유리 창은 처음 그릴 때 유리가 덜 준비돼 흐리게 나오니, 거의 투명하게 한 번 그려 두었다가(0.3초)
    /// 내용을 숨긴 채 다시 띄우고, 모션으로 드러낸다.
    @MainActor
    func present(_ presence: PanelPresence, makeKey key: Bool = true) {
        presence.shown = true
        alphaValue = 0.02
        orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.isVisible else { return }
            self.orderOut(nil)
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) { presence.shown = false }
            self.alphaValue = 1
            self.orderFrontRegardless()
            if key { self.makeKey() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { presence.shown = true }
        }
    }

    /// 사라지는 모션 뒤에 닫는다
    @MainActor
    func dismiss(_ presence: PanelPresence) {
        guard isVisible, presence.shown else { close(); return }
        presence.shown = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in self?.close() }
    }
}

final class ReviewPanel: NSPanel {
    init(size: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false                    // 그림자는 SwiftUI가 그린다
        // 창 전체를 끌어 옮기게 두면 슬라이더 손잡이를 끌어도 창이 움직인다 → 빈 배경(WindowDragArea)에서만 옮긴다
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ReviewWindowController: NSObject, NSWindowDelegate {
    private var panel: ReviewPanel?
    private let presence = PanelPresence()
    private let model: ReviewModel
    private let onApply: ([OCRReview.Document]) -> Void
    private let onDiscard: () -> Void
    private let onClose: () -> Void
    private var finished = false
    /// 검토 창을 띄울 자리(휠이 있던 곳). 그 화면 가운데에 뜬다.
    var anchor: NSPoint?

    /// - onApply: 적용(저장) · onDiscard: 취소(아무것도 저장 안 함) · onClose: 창만 닫음(카드에서 다시 열 수 있다)
    init(documents: [OCRReview.Document], agent: Agent, onApply: @escaping ([OCRReview.Document]) -> Void,
         onDiscard: @escaping () -> Void, onClose: @escaping () -> Void) {
        model = ReviewModel(documents: documents, agent: agent)
        self.onApply = onApply
        self.onDiscard = onDiscard
        self.onClose = onClose
    }

    func show() {
        if panel == nil {
            let size = NSSize(width: ReviewView.cardSize.width + ReviewView.shadowMargin * 2,
                              height: ReviewView.cardSize.height + ReviewView.shadowMargin * 2)
            let panel = ReviewPanel(size: size)
            panel.contentView = NSHostingView(rootView: PresenceWrap(presence: presence, content: ReviewView(
                model: model,
                apply: { [weak self] in self?.finish(apply: true) },
                discard: { [weak self] in self?.finish(apply: false) },
                close: { [weak self] in self?.close() }
            )))
            panel.delegate = self
            let point = anchor ?? NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
            let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
            self.panel = panel
            panel.present(presence)
        } else {
            panel?.orderFrontRegardless()
            panel?.makeKey()
        }
    }


    private func finish(apply: Bool) {
        guard !finished else { return }
        finished = true
        if apply { onApply(model.documents) } else { onDiscard() }
        panel?.dismiss(presence)
    }

    private func close() {
        panel?.dismiss(presence)
    }

    func windowWillClose(_ notification: Notification) {
        if !finished { onClose() }
    }
}

private struct ReviewView: View {
    static let cardSize = CGSize(width: 880, height: 600)
    static let shadowMargin: CGFloat = 30

    @ObservedObject var model: ReviewModel
    let apply: () -> Void
    let discard: () -> Void
    let close: () -> Void

    var body: some View {
        let document = model.current
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        VStack(alignment: .leading, spacing: 14) {
            header

            Text(document.changes.isEmpty
                 ? L("“\(document.fileName)”: 불확실한 \(document.spotCount)곳을 AI가 확인했는데 고칠 곳이 없다고 했어요.", "“\(document.fileName)”: the AI checked \(document.spotCount) uncertain spot(s) and found nothing to fix.")
                 : L("“\(document.fileName)”: 불확실한 \(document.spotCount)곳 중 \(document.changes.count)곳을 AI가 고쳤어요. 알약을 눌러 끄면 그곳은 인식한 그대로 둬요.", "“\(document.fileName)”: the AI fixed \(document.changes.count) of \(document.spotCount) uncertain spot(s). Click a pill to turn it off and keep the recognized text there."))
                .font(.callout)
                .foregroundStyle(.secondary)

            let lines = model.lines()
            HStack(alignment: .top, spacing: 12) {
                column(L("인식한 그대로", "As recognized"), lines.map(\.original))
                column(L("고친 결과", "Fixed"), lines.map(\.corrected))
            }

            if !document.changes.isEmpty {
                ScrollView {
                    GlassEffectContainer(spacing: 6) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                            ForEach(document.changes) { change in
                                ChangeChip(change: change) { model.toggle(change.id) }
                            }
                        }
                    }
                    .padding(2)
                }
                .frame(maxHeight: 112)
            }

            HStack {
                Text(L("적용하면 원본 옆에 같은 이름의 .txt로 저장돼요. 원본 사진은 그대로예요.", "Applying saves a .txt with the same name next to the original. The photo is untouched."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("취소", "Cancel"), action: discard)
                    .buttonStyle(.glass)
                    .help(L("아무것도 저장하지 않고 끝내요", "Finish without saving anything"))
                Button(model.documents.count > 1 ? L("모두 적용", "Apply all") : L("적용", "Apply"), action: apply)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: Self.cardSize.width, height: Self.cardSize.height)
        .background(WindowDragArea())
            .modifier(GlassFinish(shape: shape, surface: .panel))
        .environment(\.controlActiveState, .key)
        .shadow(color: .black.opacity(0.28), radius: 22, y: 10)
        .padding(Self.shadowMargin)
        // esc = 창만 닫기(카드의 "검토하기"로 다시 열 수 있다)
        .background { Button("", action: close).keyboardShortcut(.cancelAction).opacity(0) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            BotAvatar(type: model.agent.avatar, state: .default, size: 30, paused: false, shading: .smooth, interactive: false)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(L("AI 오타수정 검토", "Review AI typo fixes")).font(.system(size: 18, weight: .bold))
                DestinationBadge(agent: model.agent)
            }
            Spacer()
            if model.documents.count > 1 {
                HStack(spacing: 8) {
                    Button { model.index -= 1 } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.glass)
                        .disabled(model.index == 0)
                    Text("\(model.index + 1)/\(model.documents.count)").monospacedDigit()
                    Button { model.index += 1 } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(.glass)
                        .disabled(model.index == model.documents.count - 1)
                }
            }
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 12, weight: .bold)) }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help(L("닫기 (진행 카드의 “검토하기”로 다시 열 수 있어요)", "Close (reopen with “Review” on the progress card)"))
        }
    }

    private func column(_ title: String, _ lines: [AttributedString]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 13)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
            }
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.primary.opacity(0.06)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 고친 곳 하나 = 유리 알약. 누르면 켜고 끈다(켜짐: 초록빛 유리).
private struct ChangeChip: View {
    let change: OCRReview.Change
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: change.accepted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(change.accepted ? Color.green : Color.secondary)
                Text(change.original).strikethrough(change.accepted).foregroundStyle(.secondary)
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                Text(change.replacement).fontWeight(.semibold).opacity(change.accepted ? 1 : 0.5)
            }
            .font(.system(size: 12))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(change.accepted ? .regular.tint(.green.opacity(0.22)).interactive() : .regular.interactive(), in: Capsule())
        .help(L("\(change.line + 1)번째 줄 · 누르면 \(change.accepted ? "원래대로 둬요" : "고친 걸 써요")", "Line \(change.line + 1) · click: \(change.accepted ? "keep the original" : "use the fix")"))
    }
}
