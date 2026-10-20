import SkillEngine
import AppKit
import Foundation

/// AI를 쓰는 기능들. 기본 에이전트 하나 + 기능별로 바꾸고 싶은 것만 따로 지정한다.
package enum AIFeature: String, CaseIterable, Identifiable, Sendable {
    case popup, skillAuthoring, ocrTypoFix, whatIs

    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .popup: return L("글 팝업 (자연어로 고치기)", "Text popup (edit in plain language)")
        case .skillAuthoring: return L("스킬 만들기", "Create skill")
        case .ocrTypoFix: return L("OCR 오타수정 (파일)", "OCR typo fix (files)")
        case .whatIs: return L("What is it? (요약·심층 분석)", "What is it? (summary · deep dive)")
        }
    }

    package var symbol: String {
        switch self {
        case .popup: return "text.bubble"
        case .skillAuthoring: return "wand.and.stars"
        case .ocrTypoFix: return "text.viewfinder"
        case .whatIs: return "questionmark.bubble"
        }
    }
}

/// 쓸 수 있는 에이전트 목록과 지금 고른 에이전트.
/// - 로컬: Ollama·LM Studio에 설치된 모델을 전부 찾아서 하나씩 에이전트로 만든다.
/// - 클라우드: "클라우드 AI 사용"이 켜져 있고 API 키가 있는 서비스만 에이전트로 보인다.
@MainActor
package final class AgentStore: ObservableObject {
    package enum LocalStatus: Equatable {
        case unknown, running, notRunning
    }

    @Published package private(set) var localAgents: [Agent] = []
    @Published package private(set) var ollamaStatus: LocalStatus = .unknown
    @Published package private(set) var lmStudioStatus: LocalStatus = .unknown
    /// 클라우드 서비스별로 받아온 모델 목록
    @Published package private(set) var cloudModels: [AgentProvider: [String]] = [:]
    @Published package private(set) var keyStored: [AgentProvider: Bool] = [:]
    @Published package private(set) var isRefreshing = false
    /// 지금 Ollama 메모리에 올라가 있는 모델들
    @Published package private(set) var loadedModels: [AIClient.LoadedModel] = []

    /// 사용하지 않으면 몇 분 뒤 로컬 모델을 메모리에서 내릴지 (0 = 쓰자마자 바로)
    @Published package var keepAliveMinutes: Int {
        didSet { defaults.set(keepAliveMinutes, forKey: AIClient.keepAliveDefaultsKey) }
    }
    package static let keepAliveChoices = [0, 1, 5, 15, 30, 60]

    private var lastRefresh: Date?

    @Published package var selectedID: String? {
        didSet { defaults.set(selectedID, forKey: Keys.selected) }
    }
    /// 기능별로 따로 지정한 에이전트(없으면 기본 에이전트를 쓴다)
    @Published package var featureAgentIDs: [String: String] {
        didSet { defaults.set(featureAgentIDs, forKey: Keys.featureAgents) }
    }
    @Published package var cloudEnabled: Bool {
        didSet {
            defaults.set(cloudEnabled, forKey: Keys.cloudEnabled)
            if cloudEnabled { Task { await refreshCloudModels() } }
        }
    }

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let selected = "selectedAgentID"
        static let cloudEnabled = "cloudAIEnabled"
        static let featureAgents = "featureAgentIDs"
        static func cloudModel(_ p: AgentProvider) -> String { "cloudModel.\(p.rawValue)" }
    }

    package init() {
        selectedID = defaults.string(forKey: Keys.selected)
        featureAgentIDs = defaults.dictionary(forKey: Keys.featureAgents) as? [String: String] ?? [:]
        cloudEnabled = defaults.bool(forKey: Keys.cloudEnabled)
        keepAliveMinutes = AIClient.keepAliveMinutes
        for provider in AgentProvider.cloud { keyStored[provider] = KeychainStore.hasKey(for: provider) }
        KeychainStore.finishLegacyMigration()
    }

    // MARK: - 목록

    package var cloudAgents: [Agent] {
        guard cloudEnabled else { return [] }
        return AgentProvider.cloud.compactMap { provider in
            guard keyStored[provider] == true, let model = cloudModel(for: provider) else { return nil }
            return Agent(provider: provider, model: model, detail: model)
        }
    }

    package var allAgents: [Agent] { localAgents + cloudAgents }

    /// 기본 에이전트. 아직 안 골랐거나 사라졌으면 첫 번째 로컬 에이전트.
    /// 고른 게 로컬인데 꺼져 있으면 다른 로컬로만 넘어간다 — 클라우드로 자동으로 넘기지 않는다(글이 밖으로 나가니까).
    package var selected: Agent? {
        Self.resolveDefault(selectedID: selectedID, local: localAgents, cloud: cloudAgents)
    }

    /// 기본 에이전트 고르기(화면·네트워크와 분리해서 테스트한다)
    package static func resolveDefault(selectedID: String?, local: [Agent], cloud: [Agent]) -> Agent? {
        if let id = selectedID, let agent = (local + cloud).first(where: { $0.id == id }) { return agent }
        if let id = selectedID, isLocalID(id) { return local.first }
        return local.first ?? cloud.first
    }

    /// 기능별 에이전트 고르기: 따로 지정했는데 없으면 nil(다른 에이전트로 넘기지 않는다)
    package static func resolve(overrideID: String?, defaultAgent: Agent?, available: [Agent]) -> Agent? {
        guard let overrideID else { return defaultAgent }
        return available.first { $0.id == overrideID }
    }

    package func select(_ agent: Agent) {
        selectedID = agent.id
    }

    /// 로컬 에이전트 이름표인지("ollama:모델", "lmStudio:모델")
    package static func isLocalID(_ id: String) -> Bool {
        id.hasPrefix(AgentProvider.ollama.rawValue + ":") || id.hasPrefix(AgentProvider.lmStudio.rawValue + ":")
    }

    // MARK: - 기능별 에이전트

    /// 그 기능이 쓸 에이전트. 따로 지정했는데 꺼져 있으면 nil — 다른 에이전트로 넘기지 않는다.
    package func agent(for feature: AIFeature) -> Agent? {
        Self.resolve(overrideID: featureAgentIDs[feature.rawValue], defaultAgent: selected, available: allAgents)
    }

    package func overrideID(for feature: AIFeature) -> String? { featureAgentIDs[feature.rawValue] }

    package func setOverride(_ agentID: String?, for feature: AIFeature) {
        featureAgentIDs[feature.rawValue] = agentID
    }

    /// 그 기능 안에서 에이전트를 바꿀 때(예: 팝업의 Tab): 따로 지정돼 있으면 그걸, 아니면 기본을 바꾼다
    package func select(_ agent: Agent, for feature: AIFeature) {
        if featureAgentIDs[feature.rawValue] != nil {
            featureAgentIDs[feature.rawValue] = agent.id
        } else {
            select(agent)
        }
    }

    /// 최근에 새로 고쳤으면 건너뛴다(팝업을 열 때마다 목록을 다시 받지 않도록).
    package func refreshIfStale(maxAge: TimeInterval = 20) async {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < maxAge { return }
        await refresh()
    }

    package func refresh() async {
        lastRefresh = Date()
        isRefreshing = true
        defer { isRefreshing = false }
        async let ollama = AIClient.ollamaModels()
        async let lmStudio = AIClient.lmStudioModels()
        let (ollamaModels, lmStudioModels) = await (ollama, lmStudio)

        ollamaStatus = ollamaModels == nil ? .notRunning : .running
        lmStudioStatus = lmStudioModels == nil ? .notRunning : .running
        localAgents =
            (ollamaModels ?? []).map { Agent(provider: .ollama, model: $0.name, detail: $0.detail) }
            + (lmStudioModels ?? []).map { Agent(provider: .lmStudio, model: $0.name, detail: $0.detail) }
        log.info("agents: ollama=\(ollamaModels?.count ?? -1, privacy: .public) lmstudio=\(lmStudioModels?.count ?? -1, privacy: .public)")

        await refreshLoadedModels()
        await refreshCloudModels()
    }

    // MARK: - 메모리에 올라간 모델

    package func refreshLoadedModels() async {
        loadedModels = ollamaStatus == .notRunning ? [] : await AIClient.loadedOllamaModels()
    }

    package func unload(_ model: AIClient.LoadedModel) {
        AIClient.unload(ollamaModel: model.name)
        loadedModels.removeAll { $0.id == model.id }
        Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            await refreshLoadedModels()
        }
    }

    // MARK: - 클라우드

    package func cloudModel(for provider: AgentProvider) -> String? {
        if let saved = defaults.string(forKey: Keys.cloudModel(provider)) { return saved }
        return Self.preferredModel(in: cloudModels[provider] ?? [], for: provider)
    }

    package func setCloudModel(_ model: String, for provider: AgentProvider) {
        defaults.set(model, forKey: Keys.cloudModel(provider))
        objectWillChange.send()
    }

    package func saveKey(_ key: String, for provider: AgentProvider) {
        KeychainStore.setKey(key, for: provider)
        keyStored[provider] = KeychainStore.hasKey(for: provider)
        Task { await refreshCloudModels() }
    }

    package func deleteKey(for provider: AgentProvider) {
        KeychainStore.deleteKey(for: provider)
        keyStored[provider] = false
        cloudModels[provider] = nil
    }

    /// 클라우드가 켜져 있을 때만 목록을 받아온다(모델 이름만 오가고 글자는 보내지 않음).
    private func refreshCloudModels() async {
        guard cloudEnabled else { return }
        for provider in AgentProvider.cloud {
            guard let key = KeychainStore.key(for: provider), !key.isEmpty else { continue }
            let models = await AIClient.cloudModels(provider, apiKey: key)
            if !models.isEmpty { cloudModels[provider] = models }
        }
    }

    /// 텍스트 다듬기에는 빠르고 똑똑한 중간급 모델이 알맞아서 그쪽을 기본으로 고른다.
    private static func preferredModel(in models: [String], for provider: AgentProvider) -> String? {
        let hints: [String]
        switch provider {
        case .anthropic: hints = ["claude-sonnet-5", "sonnet", "haiku"]
        case .openAI: hints = ["gpt-5-mini", "gpt-5", "gpt-4.1-mini", "gpt-4o-mini"]
        case .groq: hints = ["llama-3.3-70b-versatile", "gpt-oss-120b", "llama-3.3", "gpt-oss", "qwen"]
        case .gemini: hints = ["gemini-2.5-flash", "flash"]
        default: hints = []
        }
        for hint in hints {
            if let match = models.first(where: { $0 == hint }) ?? models.first(where: { $0.contains(hint) }) {
                return match
            }
        }
        return models.first
    }

    /// Ollama 앱을 켠다. 어디에 설치돼 있든 번들 식별자로 찾는다.
    package func openOllama() {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.electron.ollama")
            ?? URL(fileURLWithPath: "/Applications/Ollama.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    package var isOllamaInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.electron.ollama") != nil
            || FileManager.default.fileExists(atPath: "/Applications/Ollama.app")
    }
}
