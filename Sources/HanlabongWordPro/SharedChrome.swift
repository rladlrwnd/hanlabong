import AppCore
import BotAvatarsKit
import SkillEngine
import SwiftUI
import ThinkingOrbsKit

// 모든 영역(PDF·워드·한글·노트)이 같이 쓰는 화면 부품.
// 세션 종류에 묶이지 않고 AssistantHost(WorkspaceContract.swift)만 보고 그린다.
//
// - AssistantBar(host:glass:)  아래 AI 요청칸(생각 구슬·빛 테두리·타자 효과·멈춤 단추)
// - AgentChip(host:)           요청칸 안의 AI 고르기 칩
// - GlassRail { RailIcon… }    오른쪽 세로 유리 막대(동그란 단추들을 담는 틀), 사이 줄은 RailDivider()
// - RailIcon(symbol:active:badge:)  유리 막대의 동그란 단추 하나
// - SmokyGlass(shape:)         짙은 연기빛 유리 바탕(.modifier로)
// - GlowBorder(active:cornerRadius:)  일하는 동안 테두리를 도는 빛(.modifier로)
// - TypewriterText(target:), StatusText(text:)

/// 요청칸이 쓰는 스프링(제네릭 타입 안에는 static 저장 프로퍼티를 못 둬서 따로)
enum AssistantSpring {
    static let value = Animation.spring(response: 0.42, dampingFraction: 0.82)
}

/// 아래 가운데 AI 요청칸. 간단히 보기는 둥근 유리(+ 일하는 동안 테두리 빛), 자세히 보기는 지금 도구 줄 모양 그대로.
struct AssistantBar<Host: AssistantHost>: View {
    @ObservedObject var host: Host
    var glass: Bool
    @State private var text = ""
    @FocusState private var focused: Bool

    /// glass: true = 간단히 보기(둥근 유리 상자), false = 자세히 보기(도구 줄 모양)
    init(host: Host, glass: Bool = true) {
        self.host = host
        self.glass = glass
    }

    static var spring: Animation { AssistantSpring.value }

    /// 상자 위쪽에 보일 글: AI 답(쓰는 동안 받은 데까지), 일하는 중이면 그 일
    private var shownReply: String? {
        if let status = statusLine { return status }
        if let reply = host.assistantReply, !reply.isEmpty { return reply }
        return nil
    }

    /// 일하는 중 안내(답 글이 아직 없을 때): 생각 중… / 답을 쓰는 중… / 빈칸을 채우는 중…
    private var statusLine: String? {
        if case .working(let what) = host.assistantPhase { return what }
        if let reply = host.assistantReply, !reply.isEmpty, host.assistantPhase != .waiting { return nil }
        switch host.assistantPhase {
        case .idle: return nil
        case .waiting: return L("생각 중…", "Thinking…")
        case .writing: return L("답을 쓰는 중…", "Writing…")
        case .working(let what): return what
        }
    }

    private var accent: Color { AppAccent.color(UserDefaults.standard.string(forKey: AppAccent.key) ?? AppAccent.defaultHex) }

    var body: some View {
        if glass {
            // 답과 요청칸이 한 상자: 답이 오면 상자가 위로 늘어나고, 일하는 동안 테두리에 빛이 돈다
                VStack(spacing: 0) {
                    if let shown = shownReply {
                        HStack(alignment: .top, spacing: 10) {
                            Group {
                                if let status = statusLine { StatusText(text: status) } else {
                                    // 긴 답은 상자 안에서 내려 읽는다(상자·창이 길어지지 않게)
                                    ScrollView(.vertical) { TypewriterText(target: shown).frame(maxWidth: .infinity, alignment: .leading) }
                                        .scrollIndicators(.automatic)
                                        .frame(maxHeight: 190)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .font(.system(size: 13.5))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            if !host.assistantPhase.busy {
                                Button { withAnimation(Self.spring) { host.assistantReply = nil } } label: {
                                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 20, height: 20)
                                }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                                .transition(.opacity)
                            }
                        }
                        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                    }
                    row.padding(.horizontal, 8).frame(height: 48)
                }
                .modifier(SmokyGlass(shape: RoundedRectangle(cornerRadius: 24, style: .continuous)))
                .modifier(GlowBorder(active: host.assistantPhase.busy, cornerRadius: 24))
            .frame(maxWidth: 580)
            .animation(Self.spring, value: shownReply == nil)
            .animation(Self.spring, value: host.assistantPhase)
        } else {
            VStack(spacing: 0) {
                if let reply = host.assistantReply {
                    HStack(alignment: .top) {
                        Text(reply).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        Button { host.assistantReply = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color(white: 0.15))
                }
                row.padding(.horizontal, 10).frame(height: 38).background(Color(white: 0.13))
            }
        }
    }

    private var row: some View { rowContent.task { await host.refreshAgents() } }

    private var rowContent: some View {
        HStack(spacing: 8) {
            orb.frame(width: 30, height: 30)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: glass ? 14 : 13))
                .focused($focused)
                .onSubmit(send)
                .disabled(!host.canAsk)
            AgentChip(host: host)
            if host.assistantPhase.busy {
                Button { host.stopAssistant() } label: { Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold)).frame(width: 28, height: 28) }
                    .buttonStyle(.plain).background(Circle().fill(.white.opacity(0.15)))
                    .help(L("그만두기", "Stop"))
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(.black.opacity(0.8)).frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .background(Circle().fill(text.isEmpty ? Color.white.opacity(0.18) : accent))
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || !host.canAsk)
                .help(L("보내기 (⏎)", "Send (⏎)"))
            }
        }
    }

    private var orb: some View {
        orbContent
            .id(orbKey)
            .transition(.scale(scale: 0.4).combined(with: .opacity))
            .animation(Self.spring, value: orbKey)
    }

    private var orbKey: Int {
        switch host.assistantPhase { case .idle: return 0; case .waiting: return 1; case .writing: return 2; case .working: return 3 }
    }

    @ViewBuilder private var orbContent: some View {
        switch host.assistantPhase {
        case .idle:
            Image(systemName: "sparkle").font(.system(size: 15, weight: .semibold)).foregroundStyle(accent)
        case .waiting:
            ThinkingOrb(state: .searching, size: .px64, displaySize: 30)
        case .writing:
            ThinkingOrb(state: .composing, size: .px64, displaySize: 30)
        case .working:
            ThinkingOrb(state: .working, size: .px64, displaySize: 30)
        }
    }

    private var placeholder: String {
        switch host.assistantPhase {
        case .waiting: return L("AI가 읽는 중…", "AI is reading…")
        case .writing: return L("AI가 쓰는 중…", "AI is writing…")
        case .working(let what): return what
        case .idle: return host.askPlaceholder
        }
    }

    private func send() {
        let request = text
        guard !request.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        text = ""
        host.ask(request)
    }

}

/// 간단히 보기 오른쪽 유리 기둥의 동그란 단추 하나
struct RailIcon: View {
    let symbol: String
    var active = false
    var badge: String?
    @State private var hovering = false

    var body: some View {
        let accent = AppAccent.color(UserDefaults.standard.string(forKey: AppAccent.key) ?? AppAccent.defaultHex)
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .medium))
            .frame(width: 40, height: 40)
            .background(Circle().fill(active ? accent.opacity(0.85) : hovering ? Color.white.opacity(0.16) : .clear))
            .foregroundStyle(active ? Color.black.opacity(0.8) : Color.primary)
            .overlay(alignment: .topTrailing) {
                if let badge {
                    Text(badge).font(.system(size: 9, weight: .bold)).monospacedDigit()
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(accent)).foregroundStyle(.black)
                        .offset(x: 4, y: -2)
                }
            }
            .scaleEffect(hovering ? 1.1 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.6), value: hovering)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: active)
            .contentShape(Circle())
            .onHover { hovering = $0 }
    }
}

/// 오른쪽 세로 유리 막대: 안에 RailIcon(을 품은 단추·메뉴)들을 세로로 담는다. 모양은 PDF 간단히 보기 그대로
struct GlassRail<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(spacing: 4) { content }
            .padding(5)
            .modifier(SmokyGlass(shape: Capsule()))
            .shadow(color: .black.opacity(0.22), radius: 14, y: 5)
    }
}

/// 유리 막대 안의 짧은 가로 줄(단추 묶음 나누기)
struct RailDivider: View {
    var body: some View { Divider().frame(width: 22).padding(.vertical, 2) }
}

/// 짙은 연기빛 유리: PDF는 거의 흰 종이라 맑은 유리는 하얗게 비쳐서 안의 글자가 안 보인다.
/// (맥의 유리 효과는 PDF 화면 위에서 처음 그릴 때 뒤를 못 읽고 흰 네모로 나와서 쓰지 않는다. 흐림 재질 + 어두운 덧칠만)
/// 그래서 어두운 판을 한 겹 깔고, 안쪽 글자는 항상 밝게(어두운 모양) 쓴다.
struct SmokyGlass<S: Shape>: ViewModifier {
    let shape: S
    func body(content: Content) -> some View {
        content
            .environment(\.colorScheme, .dark)
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(Color.black.opacity(0.52))
                    shape.stroke(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                }
                .environment(\.colorScheme, .dark)
                .shadow(color: .black.opacity(0.28), radius: 16, y: 6)
                .allowsHitTesting(false)
            }
    }
}

/// AI 답을 짜라락 써 내려가는 글: 받은 글(target)까지 한 글자씩 따라간다. 글이 늘면 이어서, 바뀌면 처음부터
struct TypewriterText: View {
    let target: String
    @State private var shown = 0

    var body: some View {
        let visible = String(target.prefix(shown))
        Text(visible + (shown < target.count ? "▍" : ""))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .task(id: target) {
                if shown > target.count { shown = 0 }
                while shown < target.count {
                    // 남은 게 많으면 빠르게(밀리지 않게), 적으면 한 글자씩
                    let left = target.count - shown
                    shown += max(1, left / 24)
                    try? await Task.sleep(nanoseconds: 16_000_000)
                    if Task.isCancelled { return }
                }
            }
    }
}

/// 일하는 중 안내 글: 은은하게 숨 쉬듯 밝아졌다 어두워진다
struct StatusText: View {
    let text: String
    @State private var dim = false
    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .opacity(dim ? 0.45 : 1)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
            .contentTransition(.opacity)
    }
}

/// 테두리를 따라 도는 빛(Beam 모양을 SwiftUI만으로): 일하는 동안만, 부드럽게 나타나고 사라진다.
/// (BorderBeam 부품은 셰이더 파일을 앱 맨 위 폴더에서만 찾아서 애드온 앱에선 흰 네모로 나온다)
struct GlowBorder: ViewModifier {
    let active: Bool
    let cornerRadius: CGFloat

    private static let colors: [Color] = [
        .clear, .clear, Color(red: 1, green: 0.70, blue: 0.28), Color(red: 1, green: 0.42, blue: 0.45),
        Color(red: 1, green: 0.85, blue: 0.45), .clear, .clear,
    ]

    func body(content: Content) -> some View {
        content.overlay {
            if active {
                TimelineView(.animation) { context in
                    let angle = Angle.degrees(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4 * 360)
                    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    let gradient = AngularGradient(colors: Self.colors, center: .center, angle: angle)
                    ZStack {
                        shape.strokeBorder(gradient, lineWidth: 7).blur(radius: 9).opacity(0.8)
                        shape.strokeBorder(gradient, lineWidth: 1.6)
                    }
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: active)
    }
}

/// 요청칸의 AI 고르기 칩(한라봉 팝업처럼 캐릭터 얼굴 + 이름). 자동 = 한라봉 설정을 따름
struct AgentChip<Host: AssistantHost>: View {
    @ObservedObject var host: Host
    @State private var hovering = false

    init(host: Host) { self.host = host }

    var body: some View {
        Menu {
            Button { host.pickAgent(nil) } label: {
                Label(L("자동 (한라봉 설정대로)", "Auto (Hanlabong settings)"), systemImage: host.assistantAgentID == nil ? "checkmark" : "sparkle")
            }
            let local = host.agentChoices.filter(\.isLocal), cloud = host.agentChoices.filter { !$0.isLocal }
            if !local.isEmpty {
                Section(L("이 맥", "This Mac")) {
                    ForEach(local) { agent in pick(agent, detail: agent.detail) }
                }
            }
            if !cloud.isEmpty {
                Section(L("클라우드 (글이 밖으로 나가요)", "Cloud (text leaves this Mac)")) {
                    ForEach(cloud) { agent in pick(agent, detail: agent.model) }
                }
            }
            if host.agentChoices.isEmpty {
                Text(L("쓸 수 있는 AI가 없어요 · Ollama를 켜거나 한라봉 설정에서 API 키를 넣어줘", "No AI available"))
            }
            Divider()
            Button(L("목록 새로 고치기", "Refresh list")) { Task { await host.refreshAgents() } }
        } label: {
            HStack(spacing: 5) {
                if let agent = host.currentAgent {
                    BotAvatar(type: agent.avatar, state: host.assistantPhase.busy ? .working : .default, size: 18,
                              paused: !host.assistantPhase.busy, shading: .smooth, interactive: false)
                        .frame(width: 20, height: 20)
                    Text(agent.name).font(.system(size: 11.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 110, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                } else {
                    Image(systemName: "sparkle").font(.system(size: 11, weight: .semibold))
                    Text(L("AI 없음", "No AI")).font(.system(size: 11.5, weight: .semibold))
                }
                if host.assistantAgentID == nil {
                    Text(L("자동", "Auto")).font(.system(size: 9.5, weight: .bold)).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.secondary)
            }
            .padding(.leading, 4).padding(.trailing, 8)
            .frame(height: 28)
            .background(Capsule(style: .continuous).fill(.primary.opacity(hovering ? 0.13 : 0.07)))
            .overlay(Capsule(style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
            .contentShape(Capsule())
            .animation(.easeOut(duration: 0.15), value: hovering)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .disabled(host.assistantPhase.busy)
        .help(L("요청칸이 쓸 AI 고르기", "Choose the AI for requests"))
    }

    private func pick(_ agent: Agent, detail: String) -> some View {
        Button { host.pickAgent(agent) } label: {
            if host.assistantAgentID == agent.id { Label(agent.name, systemImage: "checkmark") } else { Text(agent.name) }
        }
    }
}
