import AppCore
import AppKit
import BorderBeamKit
import SkillEngine
import SwiftUI
import ThinkingOrbsKit

/// What is it? 화면 상태. 요약은 바로, 심층 분석은 Tab을 눌렀을 때 만든다.
@MainActor
final class WhatIsModel: ObservableObject {
    enum Mode { case summary, deep }
    enum Phase: Equatable {
        case reading
        case partial(done: Int, total: Int)
        case writing
        case done
        case failed(String)
        case idle
    }

    let agent: Agent
    let fileName: String
    @Published var characters = 0
    @Published var readingMinutes = 0
    @Published var mode: Mode = .summary
    @Published var summary = ""
    @Published var deep = ""
    @Published var summaryPhase: Phase = .reading
    @Published var deepPhase: Phase = .idle

    init(agent: Agent, fileName: String) {
        self.agent = agent
        self.fileName = fileName
    }

    var phase: Phase { mode == .summary ? summaryPhase : deepPhase }
    var text: String { mode == .summary ? summary : deep }
    var isWorking: Bool {
        switch phase {
        case .reading, .partial, .writing: return true
        default: return false
        }
    }
}

/// 요약·심층 분석을 만들고 보여주는 창. AI는 글 팝업과 같은 에이전트 설정을 쓴다.
@MainActor
final class WhatIsController: NSObject, NSWindowDelegate {
    private var panel: ReviewPanel?
    private var task: Task<Void, Never>?
    private let model: WhatIsModel
    private let agents: AgentStore
    private let url: URL
    private var source: WhatIsText.Source?
    /// 긴 글은 부분 요약들을 합친 것(심층 분석의 재료)
    private var digest: String?
    private var parts = 1
    var anchor: NSPoint?
    var onClose: (() -> Void)?

    private let presence = PanelPresence()

    init(url: URL, agent: Agent, agents: AgentStore) {
        self.url = url
        self.agents = agents
        model = WhatIsModel(agent: agent, fileName: url.lastPathComponent)
    }

    func show() {
        let size = NSSize(width: WhatIsView.cardSize.width + WhatIsView.margin * 2, height: WhatIsView.cardSize.height + WhatIsView.margin * 2)
        let panel = ReviewPanel(size: size)
        panel.contentView = NSHostingView(rootView: PresenceWrap(presence: presence, content: WhatIsView(
            model: model,
            close: { [weak self] in guard let self else { return }; self.panel?.dismiss(self.presence) },
            switchMode: { [weak self] in self?.toggleMode() },
            copy: { [weak self] in self?.copyText() }
        )))
        panel.delegate = self
        let point = anchor ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
        self.panel = panel
        panel.present(presence)
        start()
    }

    func windowWillClose(_ notification: Notification) {
        task?.cancel()
        onClose?()
    }

    // MARK: 요약

    private func start() {
        let agent = model.agent
        let apiKey = agent.isLocal ? nil : KeychainStore.key(for: agent.provider)
        let cloudEnabled = agents.cloudEnabled
        let url = self.url
        log.info("whatis start: cloud=\(!agent.isLocal, privacy: .public)")
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let source = try await FileJobRunner.onWorkQueue { try WhatIsText.read(url, cancellation: $0) }
                self.source = source
                self.model.characters = source.characters
                self.model.readingMinutes = source.readingMinutes

                let chunks = WhatIsText.chunks(source.text)
                self.parts = chunks.count
                var body = source.text
                if chunks.count > 1 {
                    var partials: [String] = []
                    for (index, chunk) in chunks.enumerated() {
                        try Task.checkCancellation()
                        self.model.summaryPhase = .partial(done: index, total: chunks.count)
                        partials.append(try await AIClient.complete(
                            system: WhatIsText.partSystem, messages: [.user(WhatIsText.partPrompt(chunk, index: index + 1, total: chunks.count))],
                            agent: agent, apiKey: apiKey, cloudEnabled: cloudEnabled, json: false, temperature: 0.2))
                    }
                    body = partials.enumerated().map { L("[\($0.offset + 1)부분]\n", "[Part \($0.offset + 1)]\n") + AIClient.clean($0.element, original: "") }.joined(separator: "\n\n")
                    self.digest = body
                }
                self.model.summaryPhase = .writing
                try await self.stream(system: WhatIsText.summarySystem, prompt: WhatIsText.summaryPrompt(body: body, parts: chunks.count),
                                      agent: agent, apiKey: apiKey, cloudEnabled: cloudEnabled) { self.model.summary = $0 }
                self.model.summaryPhase = .done
                log.info("whatis summary done: parts=\(chunks.count, privacy: .public)")
            } catch is CancellationError {
            } catch {
                self.model.summaryPhase = .failed(error.localizedDescription)
            }
        }
    }

    /// Tab: 요약 ↔ 심층 분석. 심층 분석은 처음 누를 때 만든다.
    private func toggleMode() {
        if model.mode == .deep { model.mode = .summary; return }
        model.mode = .deep
        guard model.deepPhase == .idle || { if case .failed = model.deepPhase { return true } else { return false } }(),
              let source else { return }
        let agent = model.agent
        let apiKey = agent.isLocal ? nil : KeychainStore.key(for: agent.provider)
        let cloudEnabled = agents.cloudEnabled
        let body = digest ?? source.text
        let parts = self.parts
        model.deepPhase = .writing
        model.deep = ""
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.stream(system: WhatIsText.deepSystem, prompt: WhatIsText.deepPrompt(body: body, parts: parts),
                                      agent: agent, apiKey: apiKey, cloudEnabled: cloudEnabled) { self.model.deep = $0 }
                self.model.deepPhase = .done
            } catch is CancellationError {
            } catch {
                self.model.deepPhase = .failed(error.localizedDescription)
            }
        }
    }

    private func stream(system: String, prompt: String, agent: Agent, apiKey: String?, cloudEnabled: Bool,
                        update: (String) -> Void) async throws {
        var output = ""
        // 글자가 올 때마다 화면을 다시 그리면(굵은 글씨 해석 포함) 긴 글에서 버벅이니, 0.06초에 한 번만 그린다
        var lastDraw = Date.distantPast
        for try await piece in AIClient.stream(system: system, messages: [.user(prompt)], agent: agent, apiKey: apiKey,
                                               cloudEnabled: cloudEnabled, json: false, temperature: 0.2) {
            try Task.checkCancellation()
            output += piece
            if Date().timeIntervalSince(lastDraw) > 0.06 {
                lastDraw = Date()
                update(AIClient.clean(output, original: ""))
            }
        }
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError.emptyResult }
        update(AIClient.clean(output, original: ""))
    }

    private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.text, forType: .string)
    }
}

struct WhatIsView: View {
    static let cardSize = CGSize(width: 640, height: 560)
    static let margin: CGFloat = 30

    @ObservedObject var model: WhatIsModel
    let close: () -> Void
    let switchMode: () -> Void
    let copy: () -> Void

    private var rendered: AttributedString {
        (try? AttributedString(markdown: model.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(model.text)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        // AI가 일하는 동안에만 테두리에 빛이 돈다
        BorderBeam(size: .md, colorVariant: .colorful, theme: .auto, active: model.isWorking, borderRadius: 26, strength: 0.8) {
            VStack(alignment: .leading, spacing: 12) {
                header
                content
                footer
            }
            .padding(22)
            .frame(width: Self.cardSize.width, height: Self.cardSize.height)
            .background(WindowDragArea())
            .modifier(GlassFinish(shape: shape, surface: .panel))
        }
        .environment(\.controlActiveState, .key)
        .shadow(color: .black.opacity(0.28), radius: 22, y: 10)
        .padding(Self.margin)
        .background {
            Group {
                Button("", action: close).keyboardShortcut(.cancelAction)
                Button("", action: switchMode).keyboardShortcut(.tab, modifiers: [])
            }
            .opacity(0)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if model.isWorking {
                ThinkingOrb(state: model.mode == .deep ? .solving : .composing, size: .px64, displaySize: 38)
            } else {
                Image(systemName: "questionmark.bubble").font(.system(size: 24, weight: .medium)).frame(width: 38, height: 38)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("What is it?").font(.system(size: 18, weight: .bold))
                Text(model.fileName).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 12, weight: .bold)) }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
        }
    }

    @ViewBuilder private var content: some View {
        HStack(spacing: 8) {
            modeButton(L("요약", "Summary"), .summary)
            modeButton(L("심층 분석", "Deep dive"), .deep)
            Text("⇥ Tab").font(.caption).foregroundStyle(.tertiary)
            Spacer()
            if model.characters > 0 {
                Text(L("\(model.characters.formatted())자 · 읽는 데 약 \(model.readingMinutes)분", "\(model.characters.formatted()) characters · about \(model.readingMinutes) min read"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                switch model.phase {
                case .reading:
                    status(L("글을 읽는 중…", "Reading…"))
                case .partial(let done, let total):
                    status(L("긴 글이라 나눠서 읽는 중 · \(done + 1)/\(total)", "Long text, reading in parts · \(done + 1)/\(total)"))
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case .idle:
                    status(L("Tab을 눌러 심층 분석을 만들어요", "Press Tab for a deep dive"))
                case .writing, .done:
                    if model.text.isEmpty { status(model.mode == .deep ? L("깊이 분석하는 중…", "Analyzing in depth…") : L("요약하는 중…", "Summarizing…")) }
                    else { Text(rendered).font(.system(size: 14)).lineSpacing(4).textSelection(.enabled) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.primary.opacity(0.06)))
    }

    private func status(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(.secondary)
    }

    private func modeButton(_ title: String, _ mode: WhatIsModel.Mode) -> some View {
        Button(title) { if model.mode != mode { switchMode() } }
            .buttonStyle(.glass)
            .controlSize(.small)
            .opacity(model.mode == mode ? 1 : 0.6)
    }

    private var footer: some View {
        HStack {
            DestinationBadge(agent: model.agent)
            Spacer()
            Button { copy() } label: { Label(L("복사", "Copy"), systemImage: "doc.on.doc") }
                .buttonStyle(.glass)
                .disabled(model.text.isEmpty)
        }
    }
}
