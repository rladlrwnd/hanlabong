import SkillEngine
import AppCore
import BorderBeamKit
import BotAvatarsKit
import SwiftUI
import ThinkingOrbsKit

/// libraries.dev의 Border Beam(공식 SwiftUI 포트): 카드 테두리를 따라 도는 무지개빛 빛줄기.
/// 설정은 사용자가 고른 웹 예시 그대로: size md, colorful, strength 0.7. AI가 일하는 동안은 조금 더 밝게.
private struct Beam: ViewModifier {
    let active: Bool
    let busy: Bool

    func body(content: Content) -> some View {
        BorderBeam(
            size: .md,
            colorVariant: .colorful,
            theme: .auto,
            active: active,
            borderRadius: Double(PopupView.cornerRadius),
            strength: busy ? 1.0 : 0.7
        ) {
            content
        }
    }
}

/// 팝업 화면. Figma의 iOS 26 Liquid Glass 메뉴(아이콘 + 이름이 한 줄씩, 선택된 줄은
/// 테두리에 빛이 맺힌 밝은 알약 모양)를 맥의 작은 팝업 크기로 옮겼다.
/// 유리 효과는 흉내가 아니라 macOS 26의 실제 Liquid Glass(`glassEffect`)다.
package struct PopupView: View {
    /// 그림자가 잘리지 않도록 카드 바깥에 두는 여백. 창 위치를 계산할 때도 쓴다.
    package static let outerMargin: CGFloat = 44
    package static let cardWidth: CGFloat = 360
    package static let cornerRadius: CGFloat = 20
    /// 목록은 이 줄 수까지만 펼치고, 넘으면 안에서 스크롤한다.
    package static let maxVisibleRows = 7
    package static let rowHeight: CGFloat = 38
    package static let rowSpacing: CGFloat = 2

    @ObservedObject package var model: PopupModel
    @Namespace private var highlight
    @FocusState private var promptFocused: Bool

    /// 목록 바꾸기·선택 이동·패널 전환에 공통으로 쓰는 스프링
    private static let switchSpring = Animation.spring(response: 0.34, dampingFraction: 0.86)

    package var body: some View {
        if model.isPresented {
            card
                .scaleEffect(model.isShown ? 1 : 0.97, anchor: model.anchor)
                .offset(y: model.isShown ? 0 : (model.anchor == .topLeading ? -6 : 6))
                .opacity(model.isShown ? 1 : 0)
                .animation(
                    model.isShown ? .spring(response: 0.4, dampingFraction: 0.86) : .easeInOut(duration: 0.18),
                    value: model.isShown
                )
                .padding(Self.outerMargin)
                // 창이 잠깐 내용보다 클 때(줄어드는 애니메이션 중) 카드가 선택 영역 쪽 가장자리에 붙어 있게
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.anchor == .topLeading ? .top : .bottom)
                .onChange(of: model.focusToken) { _, _ in promptFocused = true }
        }
    }

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        return VStack(alignment: .leading, spacing: 6) {
            if let text = model.selectedText {
                promptField
                preview(text)
                if let message = model.message { messageRow(message) }
                lowerPanel
            } else if let message = model.message {
                messageRow(message)
            }
        }
        .padding(8)
        .frame(width: Self.cardWidth, alignment: .leading)
        .modifier(GlassFinish(shape: shape))
        .modifier(Beam(active: model.isShown, busy: model.isBusy))
        .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
        .animation(Self.switchSpring, value: model.showingAgents)
        .animation(Self.switchSpring, value: model.isBusy)
        .animation(Self.switchSpring, value: model.draft)
    }

    /// 입력창 아래 영역: 스킬 목록 ↔ 에이전트 목록 ↔ AI 작업 중 ↔ 스킬 미리보기.
    /// 겹쳐 놓고(ZStack) 바꿔치기해서, Tab을 누르면 스킬은 왼쪽으로 빠지고 에이전트가 오른쪽에서 밀려 들어온다.
    private var lowerPanel: some View {
        ZStack(alignment: .top) {
            if model.isBusy {
                thinkingPanel
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            } else if let draft = model.draft {
                DraftPanel(
                    preview: draft,
                    onSave: { model.onSaveDraft?(false) },
                    onSaveAndApply: { model.onSaveDraft?(true) },
                    onDiscard: { model.onDiscardDraft?() }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            } else if model.showingAgents {
                agentList
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                actionList
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .clipped()
    }

    // MARK: - 입력창

    private var promptField: some View {
        HStack(spacing: 8) {
            agentChip
            TextField(L("요청하거나 “…스킬 만들어줘”", "Ask anything, or “make a skill that…”"), text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .focused($promptFocused)
                .disabled(model.isBusy || model.draft != nil)
                .onSubmit { model.onSubmitPrompt?() }
            if !model.query.trimmingCharacters(in: .whitespaces).isEmpty, !model.isBusy, !model.listNavigated, model.draft == nil {
                Text(model.isSkillRequest ? L("⏎ 스킬 만들기", "⏎ Create skill") : "⏎ AI")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .transition(.opacity)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .frame(height: 42)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(.primary.opacity(0.05))
        )
    }

    /// 지금 에이전트: [캐릭터 이름 ⌄] 알약. 누르면(또는 Tab) 에이전트 목록으로 바뀐다.
    private var agentChip: some View {
        Button {
            model.agentIndex = model.agents.firstIndex { $0.id == model.agent?.id } ?? 0
            model.showingAgents.toggle()
        } label: {
            HStack(spacing: 4) {
                if let agent = model.agent {
                    avatar(for: agent, size: 20, working: model.isBusy)
                        .frame(width: 22, height: 22)
                    Text(agent.name)
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 104, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                } else {
                    Image(systemName: "sparkle")
                        .font(.system(size: 11, weight: .semibold))
                    Text(L("AI 없음", "No AI"))
                        .font(.system(size: 11.5, weight: .semibold))
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(model.showingAgents ? 180 : 0))
                    .animation(Self.switchSpring, value: model.showingAgents)
            }
            .padding(.leading, 4)
            .padding(.trailing, 8)
            .frame(height: 28)
            .background(
                Capsule(style: .continuous)
                    .fill(.primary.opacity(model.showingAgents ? 0.12 : 0.07))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy)
        .help(L("에이전트 바꾸기 (Tab)", "Switch agent (Tab)"))
    }

    /// 작은 크기에선 입체 플라스틱 질감(매 프레임 픽셀 계산)이 티가 안 나서 가벼운 smooth 질감을 쓰고,
    /// 움직이는 건 입력창의 지금 에이전트 하나뿐이다(목록의 캐릭터들은 멈춘 그림).
    private func avatar(for agent: Agent, size: Double, working: Bool, animated: Bool = true) -> some View {
        BotAvatar(
            type: agent.avatar,
            state: working ? .working : .default,
            size: size,
            paused: !animated || !model.isShown,
            shading: .smooth,
            interactive: false
        )
    }

    private func preview(_ text: String) -> some View {
        Text(text.replacingOccurrences(of: "\n", with: " ⏎ "))
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 10)
            .padding(.top, 2)
    }

    // MARK: - AI가 일하는 중

    private var thinkingPanel: some View {
        HStack(alignment: .top, spacing: 12) {
            ThinkingOrb(state: model.designingSkill ? .shaping : (model.aiPhase == .waiting ? .searching : .composing), size: .px64, displaySize: 40)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(statusLine)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(thinkingDetail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(3, reservesSpace: true)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
            Text("Esc")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(height: 92, alignment: .top)
    }

    private var thinkingDetail: String {
        if model.designingSkill { return L("기본 블록 중에서 알맞은 조합을 고르고, 이 글자로 시험해보는 중…", "Picking a combination of built-in blocks and testing it on this text…") }
        return model.streamed.isEmpty ? L("잠깐만…", "One moment…") : tail(of: model.streamed)
    }

    private var statusLine: String {
        let name = model.agent?.name ?? "AI"
        if model.designingSkill { return L("\(name)가 스킬을 설계하는 중", "\(name) is designing a skill") }
        switch model.aiPhase {
        case .waiting: return model.agent?.isLocal == true ? L("\(name) 불러오는 중", "Loading \(name)") : L("\(name)에게 보내는 중", "Sending to \(name)")
        case .writing: return L("\(name)가 쓰는 중", "\(name) is writing")
        case .idle: return name
        }
    }

    private func tail(of text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 160 ? "…" + flat.suffix(160) : flat
    }

    // MARK: - 에이전트 고르기

    private var agentList: some View {
        let height = listHeight(rows: model.agents.count, rowHeight: 44)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L("에이전트 고르기", "Choose agent"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(L("Tab · Esc 닫기", "Tab · Esc to close"))
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.top, 2)
            agentScroll(height: height)
        }
        // ↑↓로 고를 때 선택 알약이 미끄러지듯 따라간다
        .animation(Self.switchSpring, value: model.agentIndex)
    }

    private func agentScroll(height: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: Self.rowSpacing) {
                    if model.agents.isEmpty {
                        Text(L("쓸 수 있는 AI가 없어요. Ollama를 켜거나 설정 › API 키를 확인해줘", "No AI available. Start Ollama or check Settings › API Keys"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(10)
                    }
                    ForEach(Array(model.agents.enumerated()), id: \.element.id) { index, agent in
                        agentRow(agent, index: index).id(index)
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(height: max(height, model.agents.isEmpty ? 50 : 0))
            .onChange(of: model.agentIndex) { _, index in proxy.scrollTo(index) }
        }
    }

    private func agentRow(_ agent: Agent, index: Int) -> some View {
        let isSelected = index == model.agentIndex
        return HStack(spacing: 10) {
            avatar(for: agent, size: 28, working: false, animated: false)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.name)
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(1)
                Text(agent.isLocal ? L("이 컴퓨터 · \(agent.detail)", "This computer · \(agent.detail)") : L("클라우드 · \(agent.detail)", "Cloud · \(agent.detail)"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if agent.id == model.agent?.id {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 44)
        .background { if isSelected { selectionPill(id: "agentHighlight") } }
        .contentShape(Rectangle())
        .onHover { hovering in if hovering { model.agentIndex = index } }
        .onTapGesture { model.onSelectAgent?(agent) }
    }

    // MARK: - 스킬 목록

    private var actionList: some View {
        let actions = model.actions
        let height = listHeight(rows: actions.count, rowHeight: Self.rowHeight)
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: Self.rowSpacing) {
                    ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                        row(action, index: index).id(index)
                    }
                }
            }
            .scrollIndicators(.never)
            .scrollDisabled(actions.count <= Self.maxVisibleRows)
            // 높이를 고정해야 창 크기(fittingSize)를 정확히 잴 수 있다
            .frame(height: height)
            .onChange(of: model.selectedIndex) { _, index in proxy.scrollTo(index) }
        }
        .animation(Self.switchSpring, value: model.selectedIndex)
    }

    private func listHeight(rows: Int, rowHeight: CGFloat) -> CGFloat {
        let visible = min(rows, Self.maxVisibleRows)
        return CGFloat(visible) * rowHeight + CGFloat(max(visible - 1, 0)) * Self.rowSpacing
    }

    private func row(_ action: PopupAction, index: Int) -> some View {
        let isSelected = index == model.selectedIndex && (model.query.isEmpty || model.listNavigated)
        return HStack(spacing: 10) {
            Image(systemName: action.symbol)
                .font(.system(size: 12.5, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.primary.opacity(isSelected ? 0.10 : 0.06))
                )
            Text(action.title)
                .font(.system(size: 13.5, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
            if let shortcut = action.shortcut {
                Text(shortcut)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.rowHeight)
        .background { if isSelected { selectionPill(id: "skillHighlight") } }
        .contentShape(Rectangle())
        .onHover { hovering in if hovering { model.selectedIndex = index } }
        .onTapGesture { model.onPerform?(action) }
    }

    /// Figma의 선택된 알약처럼 윗변에 빛이 맺힌 얇은 테두리.
    /// 목록마다 이름표(id)를 따로 써야 두 목록이 겹쳐 바뀌는 동안 알약이 서로 꼬이지 않는다.
    private func selectionPill(id: String) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.primary.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.55), .white.opacity(0.06)],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 0.7
                    )
            )
            .matchedGeometryEffect(id: id, in: highlight)
    }

    private func messageRow(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: model.selectedText == nil ? "text.cursor" : "exclamationmark.circle")
                .foregroundStyle(.secondary)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12.5, weight: .medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}
