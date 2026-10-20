import AppCore
import Foundation

/// 지금 돌고 있는 파일 변환들. 5초를 넘긴 작업만 진행 카드에 보인다(짧은 작업은 휠 가운데 표시로 충분하다).
@MainActor
package final class JobCenter: ObservableObject {
    package struct Job: Identifiable, Equatable {
        package let id: UUID
        package let title: String
        package let symbol: String
        package var total: Int
        package let started: Date
        package var done = 0
        package var current: String?
        /// 5초를 넘겨서 진행 카드에 보이는 중
        package var isLong = false
        package var isCanceling = false
        /// AI가 끼는 작업이면 그 에이전트(로컬/클라우드 표시·아바타)
        package var agent: Agent?
        /// 진행 숫자 뒤에 붙는 단위(AI 작업은 "곳")
        package var unit = ""
        /// AI가 끝나서 사용자의 검토를 기다리는 중
        package var awaitingReview = false

        package init(id: UUID, title: String, symbol: String, total: Int, started: Date, agent: Agent? = nil, unit: String = "") {
            self.id = id
            self.title = title
            self.symbol = symbol
            self.total = total
            self.started = started
            self.agent = agent
            self.unit = unit
        }
    }

    /// 이 시간을 넘기면 진행 카드를 띄운다
    package nonisolated static let longJobThreshold: TimeInterval = 5

    @Published package private(set) var jobs: [Job] = []
    private var cancelHandlers: [UUID: () -> Void] = [:]
    private var reviewHandlers: [UUID: () -> Void] = [:]

    package var longJobs: [Job] { jobs.filter(\.isLong) }

    package init() {}

    package func begin(_ job: Job, cancel: @escaping () -> Void) {
        jobs.append(job)
        cancelHandlers[job.id] = cancel
    }

    package func update(_ id: UUID, done: Int? = nil, total: Int? = nil, current: String? = nil) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        if let done { jobs[index].done = done }
        if let total { jobs[index].total = total }
        if let current { jobs[index].current = current }
    }

    /// AI가 끝났다: 카드에 "검토하기"를 띄우고(빛이 천천히 깜빡인다) 사용자를 기다린다
    package func awaitReview(_ id: UUID, open: @escaping () -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].awaitingReview = true
        jobs[index].isLong = true
        reviewHandlers[id] = open
    }

    package func openReview(_ id: UUID) { reviewHandlers[id]?() }

    package var hasAIJobs: Bool { longJobs.contains { $0.agent != nil } }
    package var isAwaitingReview: Bool { longJobs.contains(where: \.awaitingReview) }

    /// 5초가 지났는데 아직 돌고 있으면 true를 돌려주고 카드에 올린다
    @discardableResult
    package func markLongIfRunning(_ id: UUID) -> Bool {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return false }
        jobs[index].isLong = true
        return true
    }

    package func cancel(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), !jobs[index].isCanceling else { return }
        jobs[index].isCanceling = true
        log.info("job cancel requested")
        cancelHandlers[id]?()
    }

    /// 끝난 작업을 내린다. 카드에 보이던(오래 걸린) 작업이었는지 돌려준다.
    @discardableResult
    package func finish(_ id: UUID) -> Bool {
        let wasLong = jobs.first(where: { $0.id == id })?.isLong ?? false
        jobs.removeAll { $0.id == id }
        cancelHandlers[id] = nil
        reviewHandlers[id] = nil
        return wasLong
    }
}
