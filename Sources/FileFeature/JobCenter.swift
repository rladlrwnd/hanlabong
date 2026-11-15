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
        /// 남은 시간 계산용: 파일마다 크기(바이트), 끝난 파일, 진행률을 아는 파일의 지금 %
        package var sizes: [Int64] = []
        package var finished: Set<Int> = []
        package var fractions: [Int: Double] = [:]
        /// 마지막 파일이 끝난 시각(이번 작업의 실제 빠르기를 재려고)
        package var lastFinishedAt: Date?
        /// 지난번 같은 변환의 빠르기(1바이트에 몇 초). 처음 하는 변환이면 nil
        package var pastSecondsPerByte: Double?
        /// 동시에 돌리는 개수(2개 이상이면 카드에 보여준다)
        package var parallel = 1

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

    package func update(_ id: UUID, done: Int? = nil, total: Int? = nil, current: String? = nil, finishedFile: Int? = nil) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        if let finishedFile {
            jobs[index].finished.insert(finishedFile)
            jobs[index].fractions[finishedFile] = nil
            jobs[index].lastFinishedAt = Date()
        }
        if let done { jobs[index].done = done }
        if let total { jobs[index].total = total }
        if let current { jobs[index].current = current }
    }

    /// 진행률을 아는 변환이 파일 하나 안에서 몇 %인지. 너무 자주 그리지 않게 1% 넘게 바뀔 때만
    package func updateFraction(_ id: UUID, file: Int, fraction: Double) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), !jobs[index].finished.contains(file) else { return }
        if let old = jobs[index].fractions[file], abs(old - fraction) < 0.01 { return }
        jobs[index].fractions[file] = fraction
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

extension JobCenter.Job {
    package struct Estimate {
        /// 0~1. 모르면 nil(움직이는 막대)
        package var fraction: Double?
        /// 남은 초. 모르면 nil
        package var remaining: TimeInterval?
        /// 예상보다 오래 걸리는 중(거의 다 됐을 때)
        package var overdue = false
    }

    /// 얼마나 됐고 얼마나 남았는지.
    /// 1) 영상처럼 진행률을 아는 변환은 그 %로  2) 이번 작업에서 끝난 파일이 있으면 그 빠르기로
    /// 3) 지난번 같은 변환의 빠르기로  4) 다 모르면 끝난 개수만
    /// 크기를 모르면(AI 작업 등) 끝난 개수로: 하나라도 끝났으면 그 빠르기로 남은 시간도
    private func byCount(_ elapsed: TimeInterval) -> Estimate {
        guard total > 1 else { return Estimate() }
        let f = Double(done) / Double(total)
        return Estimate(fraction: f, remaining: done > 0 ? elapsed * (1 - f) / f : nil)
    }

    package func estimate(at now: Date) -> Estimate {
        let elapsed = max(now.timeIntervalSince(started), 0.001)
        let totalBytes = Double(sizes.reduce(0, +))
        guard totalBytes > 0, sizes.count == total else { return byCount(elapsed) }
        let doneBytes = Double(finished.reduce(Int64(0)) { $0 + (sizes.indices.contains($1) ? sizes[$1] : 0) })
        // 1) 진행 중인 파일의 실제 %
        if !fractions.isEmpty {
            let partial = fractions.reduce(0.0) { $0 + Double(sizes.indices.contains($1.key) ? sizes[$1.key] : 0) * $1.value }
            let f = min((doneBytes + partial) / totalBytes, 1)
            let remaining = f > 0.02 ? elapsed * (1 - f) / f : nil
            return Estimate(fraction: f, remaining: remaining)
        }
        // 2) 이번 작업의 빠르기 → 3) 지난번 빠르기
        var secondsPerByte = pastSecondsPerByte
        if doneBytes > 0, let lastFinishedAt { secondsPerByte = lastFinishedAt.timeIntervalSince(started) / doneBytes }
        guard let secondsPerByte, secondsPerByte > 0 else { return byCount(elapsed) }
        let expected = totalBytes * secondsPerByte
        let left = expected - elapsed
        // 예상 시간이 지나도 안 끝나면 막대는 97%에서 기다린다
        return Estimate(fraction: min(max(elapsed / expected, doneBytes / totalBytes), 0.97),
                        remaining: left > 0 ? left : nil, overdue: left <= 0)
    }
}

/// 변환마다 지난번 빠르기(1바이트에 몇 초)를 기억한다. 다음에 같은 변환을 하면 남은 시간을 미리 알려주려고
package enum JobSpeedStore {
    private static let key = "jobSecondsPerByte"

    package static func secondsPerByte(for skillID: String) -> Double? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Double])?[skillID]
    }

    /// 잘 끝난 작업만 넣는다. 새 값과 옛 값을 반반 섞어서 한 번 튄 값에 크게 흔들리지 않게
    package static func record(skillID: String, bytes: Int64, duration: TimeInterval) {
        guard bytes > 0, duration > 0.3 else { return }
        var all = (UserDefaults.standard.dictionary(forKey: key) as? [String: Double]) ?? [:]
        let measured = duration / Double(bytes)
        all[skillID] = all[skillID].map { ($0 + measured) / 2 } ?? measured
        UserDefaults.standard.set(all, forKey: key)
    }
}
