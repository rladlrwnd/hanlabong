import AppCore
import BotAvatarsKit
import SkillEngine
import SwiftUI
import ThinkingOrbsKit

/// 아래 가운데 AI 요청칸. 간단히 보기는 둥근 유리(+ 일하는 동안 테두리 빛), 자세히 보기는 지금 도구 줄 모양 그대로.
struct AssistantBar: View {
    @ObservedObject var session: PDFSession
    var glass: Bool
    @State private var text = ""
    @FocusState private var focused: Bool

    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.82)

    /// 상자 위쪽에 보일 글: AI 답(쓰는 동안 받은 데까지), 일하는 중이면 그 일
    private var shownReply: String? {
        if let status = statusLine { return status }
        if let reply = session.assistantReply, !reply.isEmpty { return reply }
        return nil
    }

    /// 일하는 중 안내(답 글이 아직 없을 때): 생각 중… / 답을 쓰는 중… / 빈칸을 채우는 중…
    private var statusLine: String? {
        if case .working(let what) = session.assistantPhase { return what }
        if let reply = session.assistantReply, !reply.isEmpty, session.assistantPhase != .waiting { return nil }
        switch session.assistantPhase {
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
                            if !session.assistantPhase.busy {
                                Button { withAnimation(Self.spring) { session.assistantReply = nil } } label: {
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
                .modifier(GlowBorder(active: session.assistantPhase.busy, cornerRadius: 24))
            .frame(maxWidth: 580)
            .animation(Self.spring, value: shownReply == nil)
            .animation(Self.spring, value: session.assistantPhase)
        } else {
            VStack(spacing: 0) {
                if let reply = session.assistantReply {
                    HStack(alignment: .top) {
                        Text(reply).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        Button { session.assistantReply = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color(white: 0.15))
                }
                row.padding(.horizontal, 10).frame(height: 38).background(Color(white: 0.13))
            }
        }
    }

    private var row: some View { rowContent.task { await session.refreshAgents() } }

    private var rowContent: some View {
        HStack(spacing: 8) {
            orb.frame(width: 30, height: 30)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: glass ? 14 : 13))
                .focused($focused)
                .onSubmit(send)
                .disabled(session.document == nil)
            AgentChip(session: session)
            if session.assistantPhase.busy {
                Button { session.stopAssistant() } label: { Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold)).frame(width: 28, height: 28) }
                    .buttonStyle(.plain).background(Circle().fill(.white.opacity(0.15)))
                    .help(L("그만두기", "Stop"))
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(.black.opacity(0.8)).frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .background(Circle().fill(text.isEmpty ? Color.white.opacity(0.18) : accent))
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || session.document == nil)
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
        switch session.assistantPhase { case .idle: return 0; case .waiting: return 1; case .writing: return 2; case .working: return 3 }
    }

    @ViewBuilder private var orbContent: some View {
        switch session.assistantPhase {
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
        switch session.assistantPhase {
        case .waiting: return L("AI가 읽는 중…", "AI is reading…")
        case .writing: return L("AI가 쓰는 중…", "AI is writing…")
        case .working(let what): return what
        case .idle: return L("AI에게 부탁하기 · 예: 내 정보로 채워줘, 이 쪽 요약해줘, 해설로 가줘", "Ask AI · e.g. fill this with my info, summarize this page")
        }
    }

    private func send() {
        let request = text
        guard !request.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        text = ""
        session.ask(request)
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

/// 내 정보: 채우기에 쓸 이름·학교·연락처 등. 이 맥에만 저장
struct ProfileEditor: View {
    @State var profile: UserProfile
    let save: (UserProfile) -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("내 정보", "My info")).font(.title3.bold())
            Text(L("계약서·신청서의 빈칸을 채울 때 써요. 이 맥에만 저장돼요. 클라우드 AI를 쓰면 채울 때 이 정보가 그 AI 서비스로 가요.",
                   "Used to fill forms. Saved only on this Mac. With a cloud AI, this info is sent to that service when filling."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach($profile.entries) { $entry in
                        HStack(spacing: 8) {
                            TextField(L("항목", "Item"), text: $entry.key).textFieldStyle(.roundedBorder).frame(width: 120)
                            TextField(L("값", "Value"), text: $entry.value).textFieldStyle(.roundedBorder)
                            Button { profile.entries.removeAll { $0.id == entry.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(height: 340)
            HStack {
                Button { profile.entries.append(ProfileEntry(key: "")) } label: { Label(L("항목 더하기", "Add item"), systemImage: "plus") }
                Spacer()
                Button(L("취소", "Cancel"), action: close).keyboardShortcut(.cancelAction)
                Button(L("저장", "Save")) {
                    profile.entries.removeAll { $0.key.trimmingCharacters(in: .whitespaces).isEmpty }
                    save(profile); close()
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
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
struct AgentChip: View {
    @ObservedObject var session: PDFSession
    @State private var hovering = false

    var body: some View {
        Menu {
            Button { session.pickAgent(nil) } label: {
                Label(L("자동 (한라봉 설정대로)", "Auto (Hanlabong settings)"), systemImage: session.assistantAgentID == nil ? "checkmark" : "sparkle")
            }
            let local = session.agentChoices.filter(\.isLocal), cloud = session.agentChoices.filter { !$0.isLocal }
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
            if session.agentChoices.isEmpty {
                Text(L("쓸 수 있는 AI가 없어요 · Ollama를 켜거나 한라봉 설정에서 API 키를 넣어줘", "No AI available"))
            }
            Divider()
            Button(L("목록 새로 고치기", "Refresh list")) { Task { await session.refreshAgents() } }
        } label: {
            HStack(spacing: 5) {
                if let agent = session.currentAgent {
                    BotAvatar(type: agent.avatar, state: session.assistantPhase.busy ? .working : .default, size: 18,
                              paused: !session.assistantPhase.busy, shading: .smooth, interactive: false)
                        .frame(width: 20, height: 20)
                    Text(agent.name).font(.system(size: 11.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 110, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                } else {
                    Image(systemName: "sparkle").font(.system(size: 11, weight: .semibold))
                    Text(L("AI 없음", "No AI")).font(.system(size: 11.5, weight: .semibold))
                }
                if session.assistantAgentID == nil {
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
        .disabled(session.assistantPhase.busy)
        .help(L("요청칸이 쓸 AI 고르기", "Choose the AI for requests"))
    }

    private func pick(_ agent: Agent, detail: String) -> some View {
        Button { session.pickAgent(agent) } label: {
            if session.assistantAgentID == agent.id { Label(agent.name, systemImage: "checkmark") } else { Text(agent.name) }
        }
    }
}
