import BotAvatarsKit
import Foundation

/// AI를 어디서 돌리는지.
package enum AgentProvider: String, CaseIterable, Sendable {
    case ollama, lmStudio, openAI, anthropic, gemini, groq

    /// 클라우드면 선택한 글자가 인터넷으로 나간다 → 설정에서 명시적으로 켰을 때만 쓴다.
    package var isCloud: Bool { self == .openAI || self == .anthropic || self == .gemini || self == .groq }

    package static let cloud: [AgentProvider] = [.anthropic, .openAI, .gemini, .groq]

    package var displayName: String {
        switch self {
        case .ollama: return "Ollama"
        case .lmStudio: return "LM Studio"
        case .openAI: return "OpenAI"
        case .groq: return "Groq"
        case .anthropic: return "Anthropic"
        case .gemini: return "Google Gemini"
        }
    }

    /// 에이전트 목록에 보이는 이름(클라우드는 서비스 이름)
    package var agentName: String {
        switch self {
        case .openAI: return "ChatGPT"
        case .groq: return "Groq"
        case .anthropic: return "Claude"
        case .gemini: return "Gemini"
        default: return displayName
        }
    }

    package var keyPlaceholder: String {
        switch self {
        case .openAI: return "sk-…"
        case .groq: return "gsk_…"
        case .anthropic: return "sk-ant-…"
        case .gemini: return "AIza…"
        default: return ""
        }
    }
}

/// 에이전트 = "어느 AI의 어느 모델". 로컬은 모델마다 하나, 클라우드는 서비스마다 하나.
package struct Agent: Identifiable, Hashable, Sendable {
    package let provider: AgentProvider
    package let model: String
    /// 목록에 보이는 부가 설명 (예: "27B · 17.8GB", "claude-sonnet-5")
    package let detail: String

    package init(provider: AgentProvider, model: String, detail: String) {
        self.provider = provider
        self.model = model
        self.detail = detail
    }

    package var id: String { provider.isCloud ? provider.rawValue : "\(provider.rawValue):\(model)" }
    package var name: String { provider.isCloud ? provider.agentName : model }
    package var isLocal: Bool { !provider.isCloud }

    /// 에이전트마다 고정된 bot-avatars 캐릭터. 같은 모델은 항상 같은 캐릭터.
    package var avatar: BotAvatarType {
        switch provider {
        case .anthropic: return .star
        case .openAI: return .ghost
        case .groq: return .mech
        case .gemini: return .clover
        case .ollama, .lmStudio:
            let pool: [BotAvatarType] = [
                .blob, .droid, .alien, .cat, .mech, .hexagon, .circle, .drop,
                .pebble, .puddle, .pill, .cloud, .square, .triangle, .flower,
            ]
            // String.hashValue는 실행할 때마다 바뀌어서, 글자 코드 합으로 고정된 값을 만든다.
            let sum = model.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
            return pool[sum % pool.count]
        }
    }
}
