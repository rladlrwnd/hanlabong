import AppCore
import SkillEngine
import SwiftUI

/// 팝업 목록의 한 줄: 저장된 스킬, 또는 방금 바꾼 결과를 원래대로 돌리는 항목.
package enum PopupAction: Identifiable {
    case restore
    case skill(Skill, number: Int)

    package var id: String {
        switch self {
        case .restore: return "__restore"
        case .skill(let skill, _): return skill.id
        }
    }

    package var title: String {
        switch self {
        case .restore: return L("원래대로", "Undo")
        case .skill(let skill, _): return skill.name
        }
    }

    package var symbol: String {
        switch self {
        case .restore: return "arrow.uturn.backward"
        case .skill(let skill, _): return skill.symbol ?? "wand.and.stars"
        }
    }

    package var shortcut: String? {
        switch self {
        case .restore: return "⌘Z"
        case .skill(_, let number): return number <= 9 ? "⌘\(number)" : nil
        }
    }
}

package enum AIPhase: Equatable {
    case idle
    /// 요청을 보내고 첫 글자를 기다리는 중
    case waiting
    /// 결과가 조금씩 도착하는 중
    case writing
}

@MainActor
package final class PopupModel: ObservableObject {
    /// 팝업 내용을 아예 만들어 둘지. 창을 숨긴 뒤 false로 바꿔 화면 구성 자체를 비운다 —
    /// 빛줄기·아바타 애니메이션이 숨은 창에서 몰래 돌 수 없게.
    @Published package var isPresented = false
    /// 등장/퇴장 애니메이션 상태
    @Published package var isShown = false
    /// nil이면 "선택된 글자를 못 찾았어요" 같은 안내만 보여주는 모드
    @Published package var selectedText: String?
    @Published package var message: String?
    @Published package var allActions: [PopupAction] = []
    @Published package var selectedIndex = 0
    /// 팝업이 튀어나오는 기준점(선택 영역 아래에 뜨면 위쪽, 위에 뜨면 아래쪽)
    @Published package var anchor: UnitPoint = .topLeading

    /// 자연어 입력창. 글자를 치면 스킬 목록도 이름으로 걸러진다.
    @Published package var query = "" {
        didSet {
            guard query != oldValue else { return }
            selectedIndex = 0
            listNavigated = false
            if oldValue.isEmpty, !query.isEmpty { onStartTyping?() }
        }
    }
    /// 입력창에 처음 글자를 칠 때(= AI를 쓸 가능성이 생길 때) 불린다.
    package var onStartTyping: (() -> Void)?
    /// 입력한 뒤 ↑↓로 목록을 골랐으면 ⏎는 AI 대신 고른 스킬을 실행한다.
    @Published package var listNavigated = false

    @Published package var agents: [Agent] = []
    @Published package var agent: Agent?
    @Published package var showingAgents = false
    @Published package var agentIndex = 0

    @Published package var aiPhase: AIPhase = .idle
    @Published package var streamed = ""
    /// AI가 지금 하는 일: 글자 바꾸기, 또는 스킬 설계
    @Published package var designingSkill = false
    /// AI가 설계한 새 스킬 미리보기(저장 전)
    @Published package var draft: SkillGenerator.Preview?

    /// 입력한 요청이 "…스킬 만들어줘" 류인가
    package var isSkillRequest: Bool { SkillAuthoring.isCreationRequest(query) }

    /// 값이 바뀔 때마다 입력창에 커서를 넣는다.
    @Published package var focusToken = 0

    package var onPerform: ((PopupAction) -> Void)?
    package var onSubmitPrompt: (() -> Void)?
    package var onSelectAgent: ((Agent) -> Void)?
    /// 스킬 초안 저장(true면 저장하고 바로 적용) / 버리기
    package var onSaveDraft: ((Bool) -> Void)?
    package var onDiscardDraft: (() -> Void)?

    package var isBusy: Bool { aiPhase != .idle }

    package var actions: [PopupAction] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return allActions }
        return allActions.filter { action in
            if case .restore = action { return true }
            return action.title.localizedCaseInsensitiveContains(needle)
        }
    }

    package func move(_ delta: Int) {
        if showingAgents {
            guard !agents.isEmpty else { return }
            agentIndex = (agentIndex + delta + agents.count) % agents.count
            return
        }
        let count = actions.count
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + delta + count) % count
        listNavigated = true
    }
}
