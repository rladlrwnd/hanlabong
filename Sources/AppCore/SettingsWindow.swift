import SkillEngine
import AppKit
import ApplicationServices
import BotAvatarsKit
import ServiceManagement
import SwiftUI

/// 기능 모듈이 설정 창에 끼워 넣는 탭. (스킬 탭은 TextFeature가 낸다)
package struct SettingsTab: Identifiable {
    package let id: String
    package let title: String
    package let systemImage: String
    /// 설정 창이 열릴 때마다 불린다(목록 새로고침 등).
    package let onShow: (() -> Void)?
    package let content: () -> AnyView

    package init(id: String, title: String, systemImage: String, onShow: (() -> Void)? = nil, content: @escaping () -> AnyView) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.onShow = onShow
        self.content = content
    }
}

package struct SettingsInfoRow: Identifiable {
    package let label: String
    package let value: String
    package var id: String { label }

    package init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

/// 일반 탭에 기능 모듈이 채워 넣는 부분: 모양 미리보기, 단축키 안내, 정보 줄.
package struct GeneralSettingsExtras {
    /// 유리 모양 슬라이더를 잡았을 때(true)/놓았을 때(false)
    package var appearanceEditing: (Bool) -> Void
    package var shortcuts: [SettingsInfoRow]
    package var info: [SettingsInfoRow]
    /// 기능 모듈이 통째로 넣는 섹션(예: 파일 기능 켜기/끄기). `Section { … }`을 담은 뷰를 돌려준다.
    package var sections: [() -> AnyView]

    package init(appearanceEditing: @escaping (Bool) -> Void = { _ in }, shortcuts: [SettingsInfoRow] = [], info: [SettingsInfoRow] = [], sections: [() -> AnyView] = []) {
        self.appearanceEditing = appearanceEditing
        self.shortcuts = shortcuts
        self.info = info
        self.sections = sections
    }
}

/// 메뉴 막대 아이콘 → "설정…" 으로 여는 창 (RunCat·Rectangle 같은 방식).
/// 창 틀과 에이전트·API 키·일반 탭은 여기서, 스킬 같은 기능별 탭은 `tabs`로 받는다.
@MainActor
package final class SettingsWindowController: NSObject, NSWindowDelegate {
    package static let agentsTabID = "agents"
    package static let keysTabID = "keys"
    package static let generalTabID = "general"

    private var window: NSWindow?
    private let tabs: [SettingsTab]
    private let agents: AgentStore
    private let extras: GeneralSettingsExtras
    private let general = GeneralSettings()
    private let selection: TabSelection

    package init(tabs: [SettingsTab], agents: AgentStore, extras: GeneralSettingsExtras = GeneralSettingsExtras()) {
        self.tabs = tabs
        self.agents = agents
        self.extras = extras
        self.selection = TabSelection(initial: tabs.first?.id ?? Self.agentsTabID)
    }

    package func show(tab: String? = nil) {
        tabs.forEach { $0.onShow?() }
        general.refresh()
        Task { await agents.refresh() }
        if let tab { selection.tab = tab }
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: SettingsView.width, height: 620),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false
            )
            window.title = L("DragEdit 설정", "DragEdit Settings")
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        // 창을 닫을 때 내용을 떼어내서, 안 보이는 아바타 애니메이션이 계속 돌지 않게 한다.
        if window?.contentView == nil || !(window?.isVisible ?? false) {
            window?.contentView = NSHostingView(rootView: SettingsView(
                tabs: tabs, agents: agents, general: general, selection: selection, extras: extras
            ))
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    package func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
    }
}

@MainActor
final class TabSelection: ObservableObject {
    @Published var tab: String

    init(initial: String) { tab = initial }
}

// MARK: - 일반 설정 상태

@MainActor
final class GeneralSettings: ObservableObject {
    @Published var launchAtLogin = false
    @Published var needsLoginApproval = false
    @Published var trusted = AXIsProcessTrusted()
    @Published var error: String?

    func refresh() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        needsLoginApproval = status == .requiresApproval
        trusted = AXIsProcessTrusted()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            error = nil
        } catch {
            self.error = L("자동 실행을 바꾸지 못했어요: \(error.localizedDescription)", "Couldn't change launch at login: \(error.localizedDescription)")
        }
        refresh()
    }
}

// MARK: - 화면

private struct SettingsView: View {
    let tabs: [SettingsTab]
    @ObservedObject var agents: AgentStore
    @ObservedObject var general: GeneralSettings
    @ObservedObject var selection: TabSelection
    let extras: GeneralSettingsExtras

    var body: some View {
        TabView(selection: $selection.tab) {
            ForEach(tabs) { tab in
                tab.content()
                    .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                    .tag(tab.id)
            }
            AgentsTab(agents: agents) { selection.tab = SettingsWindowController.keysTabID }
                .tabItem { Label(L("에이전트", "Agents"), systemImage: "person.2.crop.square.stack") }
                .tag(SettingsWindowController.agentsTabID)
            KeysTab(agents: agents)
                .tabItem { Label(L("API 키", "API Keys"), systemImage: "key") }
                .tag(SettingsWindowController.keysTabID)
            GeneralTab(general: general, extras: extras)
                .tabItem { Label(L("일반", "General"), systemImage: "gearshape") }
                .tag(SettingsWindowController.generalTabID)
        }
        .padding(20)
        .frame(width: Self.width, height: 620)
    }

    /// 영어는 탭 이름이 길어서(Photo presets·File wheels…) 좁으면 탭 줄이 » 메뉴로 접힌다 → 넓게
    static let width: CGFloat = AppLanguage.isKorean ? 820 : 960
}

// MARK: - 에이전트 탭

private struct AgentsTab: View {
    @ObservedObject var agents: AgentStore
    let openKeys: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("기본 에이전트를 골라. 기능마다 다른 AI를 쓰고 싶으면 아래 “기능별 AI”에서 따로 지정해. 팝업에서도 알약을 누르거나 Tab으로 바꿀 수 있어.", "Pick the default agent. To use a different AI for a feature, set it under “AI per feature” below. You can also switch in the popup by clicking the pill or pressing Tab."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button {
                    Task { await agents.refresh() }
                } label: {
                    if agents.isRefreshing { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                }
                .help(L("모델 목록 새로 고침", "Refresh model list"))
            }

            List {
                Section {
                    if agents.localAgents.isEmpty {
                        localEmptyState
                    }
                    ForEach(agents.localAgents) { agent in
                        AgentSettingsRow(agent: agent, isSelected: agent.id == agents.selected?.id) {
                            agents.select(agent)
                        }
                    }
                } header: {
                    Label(L("이 컴퓨터 — 글자가 밖으로 나가지 않아요", "This computer — your text stays here"), systemImage: "desktopcomputer")
                }

                Section {
                    if !agents.cloudEnabled {
                        cloudHint(L("클라우드 AI가 꺼져 있어요. API 키 탭에서 켜면 여기 나타나요.", "Cloud AI is off. Turn it on in the API Keys tab and it shows up here."))
                    } else if agents.cloudAgents.isEmpty {
                        cloudHint(L("API 키 탭에서 키를 넣으면 여기 나타나요.", "Add a key in the API Keys tab and it shows up here."))
                    }
                    ForEach(agents.cloudAgents) { agent in
                        AgentSettingsRow(agent: agent, isSelected: agent.id == agents.selected?.id) {
                            agents.select(agent)
                        } trailing: {
                            CloudModelPicker(agents: agents, provider: agent.provider)
                        }
                    }
                } header: {
                    Label(L("클라우드 — 고르면 글자가 인터넷으로 보내져요", "Cloud — choosing one sends your text over the internet"), systemImage: "cloud")
                }

                Section {
                    ForEach(AIFeature.allCases) { feature in
                        FeatureAgentRow(agents: agents, feature: feature)
                    }
                } header: {
                    Label(L("기능별 AI — 지정한 AI가 꺼져 있으면 다른 AI로 넘기지 않고 멈춰요", "AI per feature — if the chosen AI is off, the feature stops instead of switching to another AI"), systemImage: "slider.horizontal.3")
                }

                Section {
                    Picker(L("사용하지 않으면 메모리에서 내리기", "Unload from memory when idle"), selection: $agents.keepAliveMinutes) {
                        ForEach(AgentStore.keepAliveChoices, id: \.self) { minutes in
                            Text(minutes == 0 ? L("쓰자마자 바로", "Right after use") : minutes == 60 ? L("1시간 뒤", "After 1 hour") : L("\(minutes)분 뒤", "After \(minutes) min")).tag(minutes)
                        }
                    }
                    if agents.loadedModels.isEmpty {
                        Text(L("지금 메모리에 올라간 로컬 모델이 없어요", "No local models are loaded right now"))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(agents.loadedModels) { loaded in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(loaded.name).font(.system(size: 13, weight: .medium))
                                HStack(spacing: 4) {
                                    Text(ByteCountFormatter.string(fromByteCount: loaded.bytes, countStyle: .memory))
                                    if let expires = loaded.expiresAt, expires > Date() {
                                        Text("·")
                                        Text(expires, style: .relative)
                                        Text(L("뒤 자동으로 내려감", " until it unloads"))
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(L("지금 내리기", "Unload now")) { agents.unload(loaded) }
                        }
                    }
                } header: {
                    Label(L("메모리 — 큰 모델은 램을 많이 차지해요", "Memory — large models use a lot of RAM"), systemImage: "memorychip")
                } footer: {
                    Text(L("모델은 처음 쓸 때 메모리에 올라가서(큰 모델은 20초쯤) 정한 시간 동안 머물러요. 짧게 잡을수록 램이 빨리 비지만, 다시 쓸 때 또 기다려야 해요. DragEdit을 끄면 DragEdit이 올린 모델도 같이 내려요.", "A model loads into memory the first time you use it (about 20 s for large ones) and stays for the time you set. Shorter frees RAM sooner, but you wait again next time. Quitting DragEdit also unloads the models it loaded."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .task { await agents.refreshLoadedModels() }
    }

    @ViewBuilder
    private var localEmptyState: some View {
        HStack {
            Text(!agents.isOllamaInstalled ? L("Ollama가 설치돼 있지 않아요 (ollama.com에서 받을 수 있어요).", "Ollama isn't installed (get it at ollama.com).")
                 : agents.ollamaStatus == .notRunning ? L("Ollama가 꺼져 있어요.", "Ollama isn't running.") : L("설치된 로컬 모델이 없어요.", "No local models installed."))
                .foregroundStyle(.secondary)
            Spacer()
            if agents.isOllamaInstalled, agents.ollamaStatus == .notRunning {
                Button(L("Ollama 켜기", "Start Ollama")) {
                    agents.openOllama()
                    Task {
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        await agents.refresh()
                    }
                }
            }
        }
    }

    private func cloudHint(_ text: String) -> some View {
        HStack {
            Text(text).foregroundStyle(.secondary)
            Spacer()
            Button(L("API 키 열기", "Open API Keys"), action: openKeys)
        }
    }
}

/// 기능 하나: "기본"을 따르거나, 다른 에이전트를 따로 지정한다
private struct FeatureAgentRow: View {
    @ObservedObject var agents: AgentStore
    let feature: AIFeature

    var body: some View {
        let override = agents.overrideID(for: feature)
        HStack {
            Label(feature.title, systemImage: feature.symbol)
            Spacer()
            Picker("", selection: Binding(
                get: { override ?? "" },
                set: { agents.setOverride($0.isEmpty ? nil : $0, for: feature) }
            )) {
                Text(L("기본 — \(agents.selected?.name ?? "없음")", "Default — \(agents.selected?.name ?? "none")")).tag("")
                Divider()
                ForEach(agents.allAgents) { agent in
                    Text(agent.isLocal ? agent.name : L("\(agent.name) · 클라우드", "\(agent.name) · Cloud")).tag(agent.id)
                }
                if let override, !agents.allAgents.contains(where: { $0.id == override }) {
                    Text(L("\(override) (지금 꺼져 있음)", "\(override) (off right now)")).tag(override)
                }
            }
            .labelsHidden()
            .frame(width: 240)
        }
        if let override, !agents.allAgents.contains(where: { $0.id == override }) {
            Text(L("지정한 AI가 꺼져 있어서 이 기능은 지금 AI를 쓸 수 없어요", "The chosen AI is off, so this feature can't use AI right now"))
                .font(.caption)
                .foregroundStyle(.orange)
        } else if let agent = agents.agent(for: feature), !agent.isLocal {
            Text(L("이 기능의 글·파일 일부가 \(agent.name)(클라우드)로 보내져요", "Parts of this feature's text and files are sent to \(agent.name) (cloud)"))
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}

private struct AgentSettingsRow<Trailing: View>: View {
    let agent: Agent
    let isSelected: Bool
    let onSelect: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            // 고른 에이전트만 움직이고 나머지는 멈춘 그림 — 설정 창이 열려 있어도 CPU를 거의 안 쓰게
            BotAvatar(type: agent.avatar, state: isSelected ? .default : .sleeping, size: 34,
                      paused: !isSelected, shading: .smooth, interactive: false)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                    .font(.system(size: 13.5, weight: .medium))
                Text(agent.isLocal ? "\(agent.provider.displayName) · \(agent.detail)" : agent.provider.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            trailing()
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

extension AgentSettingsRow where Trailing == EmptyView {
    init(agent: Agent, isSelected: Bool, onSelect: @escaping () -> Void) {
        self.init(agent: agent, isSelected: isSelected, onSelect: onSelect) { EmptyView() }
    }
}

private struct CloudModelPicker: View {
    @ObservedObject var agents: AgentStore
    let provider: AgentProvider

    var body: some View {
        let models = agents.cloudModels[provider] ?? []
        if models.isEmpty {
            Text(agents.cloudModel(for: provider) ?? L("모델 목록을 받는 중…", "Loading models…"))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Picker(L("모델", "Model"), selection: Binding(
                get: { agents.cloudModel(for: provider) ?? models[0] },
                set: { agents.setCloudModel($0, for: provider) }
            )) {
                ForEach(models, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: 200)
        }
    }
}

// MARK: - API 키 탭

private struct KeysTab: View {
    @ObservedObject var agents: AgentStore

    var body: some View {
        Form {
            Section {
                Toggle(L("클라우드 AI 사용", "Use cloud AI"), isOn: $agents.cloudEnabled)
                Text(L("켜면 클라우드 에이전트를 골랐을 때 선택한 글자가 해당 회사 서버로 보내져요. 로컬 에이전트(Ollama·LM Studio)는 이 설정과 상관없이 항상 이 컴퓨터 안에서만 처리해요.", "When on, choosing a cloud agent sends your selected text to that company's servers. Local agents (Ollama, LM Studio) always run only on this computer, whatever this setting."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section(L("API 키 — 맥 키체인에 안전하게 저장돼요", "API keys — stored safely in your Mac's Keychain")) {
                ForEach(AgentProvider.cloud, id: \.self) { provider in
                    KeyRow(agents: agents, provider: provider)
                }
            }
            .disabled(!agents.cloudEnabled)
        }
        .formStyle(.grouped)
    }
}

private struct KeyRow: View {
    @ObservedObject var agents: AgentStore
    let provider: AgentProvider
    @State private var draft = ""

    var body: some View {
        let stored = agents.keyStored[provider] == true
        LabeledContent {
            HStack(spacing: 8) {
                if stored {
                    Label(L("저장됨", "Saved"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button(L("삭제", "Delete"), role: .destructive) { agents.deleteKey(for: provider) }
                } else {
                    SecureField(provider.keyPlaceholder, text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(save)
                    Button(L("저장", "Save"), action: save)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        } label: {
            HStack(spacing: 8) {
                BotAvatar(type: Agent(provider: provider, model: "", detail: "").avatar, state: stored ? .default : .sleeping, size: 24,
                          paused: true, shading: .smooth, interactive: false)
                    .frame(width: 28, height: 28)
                Text("\(provider.agentName) (\(provider.displayName))")
            }
        }
    }

    private func save() {
        agents.saveKey(draft, for: provider)
        draft = ""
    }
}

private struct GeneralTab: View {
    @ObservedObject var general: GeneralSettings
    let extras: GeneralSettingsExtras
    @AppStorage(PopupGlass.blurKey) private var blur = PopupGlass.defaultBlur
    @AppStorage(PopupGlass.tintKey) private var tint = PopupGlass.defaultTint
    @AppStorage(PopupGlass.brightnessKey) private var brightness = PopupGlass.defaultBrightness
    @AppStorage(PopupGlass.followSystemKey) private var followSystem = PopupGlass.defaultFollowSystem

    var body: some View {
        Form {
            Section {
                HapticSlider(title: L("흐림", "Blur"), value: $blur, onEditing: extras.appearanceEditing)
                HapticSlider(title: L("틴트", "Tint"), value: $tint, onEditing: extras.appearanceEditing)
                Toggle(L("밝기를 맥의 라이트/다크 모드에 맞추기", "Match brightness to light/dark mode"), isOn: $followSystem)
                HapticSlider(title: L("밝기", "Brightness"), value: $brightness, disabled: followSystem, onEditing: extras.appearanceEditing)
                HStack {
                    Text(L("슬라이더를 움직이면 설정 창 옆에 팝업이 떠서 바로 보여줘요.", "Move a slider and a preview popup appears next to Settings."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L("기본값", "Defaults")) {
                        PopupGlass.resetToDefaults()
                        extras.appearanceEditing(true)
                        extras.appearanceEditing(false)
                    }
                }
            } header: {
                Text(L("모양", "Appearance"))
            } footer: {
                Text(L("흐림: 뒤 화면을 얼마나 뿌옇게 할지 · 틴트: 밝기 색을 얼마나 진하게 덧칠할지 · 밝기: 밝으면 어두운 글자, 어두우면 흰 글자", "Blur: how frosted the background looks · Tint: how strongly the brightness color is laid on · Brightness: light gives dark text, dark gives white text"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(L("언어", "Language")) {
                LanguagePicker()
            }
            Section(L("시작", "Startup")) {
                Toggle(L("로그인할 때 자동으로 켜기", "Open at login"), isOn: Binding(
                    get: { general.launchAtLogin },
                    set: { general.setLaunchAtLogin($0) }
                ))
                if general.needsLoginApproval {
                    HStack {
                        Text(L("시스템 설정 › 일반 › 로그인 항목에서 허용해줘", "Allow it in System Settings › General › Login Items"))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(L("열기", "Open")) { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let error = general.error {
                    Text(error).foregroundStyle(.orange)
                }
            }
            if !extras.shortcuts.isEmpty {
                Section(L("단축키", "Shortcuts")) {
                    ForEach(extras.shortcuts) { row in
                        LabeledContent(row.label, value: row.value)
                    }
                }
            }
            ForEach(Array(extras.sections.enumerated()), id: \.offset) { _, section in
                section()
            }
            Section(L("권한", "Permissions")) {
                LabeledContent(L("손쉬운 사용", "Accessibility")) {
                    if general.trusted {
                        Label(L("켜짐", "On"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button(L("설정 열기", "Open Settings")) { PermissionWindowController.requestAccess() }
                    }
                }
            }
            Section(L("정보", "About")) {
                LabeledContent(L("버전", "Version"), value: AppVersion.label)
                ForEach(extras.info) { row in
                    LabeledContent(row.label, value: row.value)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { general.refresh() }
    }
}


/// 언어 고르기. 화면 글자는 켤 때 정해지니, 바꾸면 다시 켜기 버튼을 보여준다.
struct LanguagePicker: View {
    @State private var choice = AppLanguage.choice
    private let launched = AppLanguage.choice

    var body: some View {
        Picker(L("앱 언어", "App language"), selection: $choice) {
            ForEach(AppLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .onChange(of: choice) { _, value in AppLanguage.choice = value }
        if choice != launched {
            HStack {
                Text(L("다시 켜면 바뀌어요", "Takes effect after a restart")).foregroundStyle(.secondary)
                Spacer()
                Button(L("지금 다시 켜기", "Restart now")) { Self.relaunch() }
            }
        }
    }

    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
