import AppCore
import Foundation
import SkillEngine

/// Hanlabong WordPro: 앱은 하나, 파일 형식마다 켜지는 "영역"만 다르다.
/// 안 쓰는 영역은 창이 열릴 때까지 만들어지지 않는다(PDF만 열면 문서 편집 쪽은 메모리에 안 올라온다).
enum DocumentArea: String, CaseIterable, Sendable {
    /// PDF (예전 Hanlabong PDF의 모든 기능)
    case pdf
    /// .docx .doc .rtf .odt .epub
    case word
    /// .hwpx .hwp (hwp는 읽고 .hwpx로 저장)
    case hangul
    /// .md .markdown .txt .html .htm
    case note

    /// 확장자로 영역을 고른다. 모르는 형식이면 nil
    static func of(_ url: URL) -> DocumentArea? {
        switch url.pathExtension.lowercased() {
        case "pdf": return .pdf
        case "docx", "doc", "rtf", "rtfd", "odt", "epub": return .word
        case "hwpx", "hwp": return .hangul
        case "md", "markdown", "txt", "text", "html", "htm", "xhtml": return .note
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .pdf: return "PDF"
        case .word: return L("워드", "Word")
        case .hangul: return L("한글", "Hangul")
        case .note: return L("노트", "Note")
        }
    }
}

/// 모든 영역이 같이 쓰는 아래 AI 요청칸(생각 구슬·빛 테두리·모델 고르기 칩)이 필요로 하는 것.
/// PDFSession과 문서 영역 세션이 둘 다 따른다. 요청칸·칩 화면은 이 규칙만 보고 그린다.
@MainActor
protocol AssistantHost: ObservableObject {
    /// 지금 AI가 하는 일
    var assistantPhase: AssistantPhase { get }
    /// AI 답(닫으면 nil)
    var assistantReply: String? { get set }
    /// 고를 수 있는 AI들, 지금 쓰는 AI, 직접 고른 AI(nil = 자동)
    var agentChoices: [Agent] { get }
    var currentAgent: Agent? { get }
    var assistantAgentID: String? { get }
    /// 문서가 열려 있어서 물어볼 수 있는가
    var canAsk: Bool { get }
    /// 요청칸이 비어 있을 때 보이는 안내 글
    var askPlaceholder: String { get }

    func refreshAgents() async
    func pickAgent(_ agent: Agent?)
    func ask(_ request: String)
    func stopAssistant()
}
