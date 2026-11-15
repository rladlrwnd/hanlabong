import Foundation
import Testing
@testable import FileFeature

/// 진행 카드의 남은 시간 계산
@MainActor
struct JobEstimateTests {
    private func job(sizes: [Int64], past: Double? = nil) -> JobCenter.Job {
        var job = JobCenter.Job(id: UUID(), title: "t", symbol: "photo", total: sizes.count, started: Date(timeIntervalSince1970: 0))
        job.sizes = sizes
        job.pastSecondsPerByte = past
        return job
    }

    @Test func firstTimeHasNoRemaining() {
        let e = job(sizes: [50_000_000]).estimate(at: Date(timeIntervalSince1970: 6))
        #expect(e.fraction == nil)
        #expect(e.remaining == nil)
    }

    @Test func pastSpeedGivesRemaining() {
        // 지난번엔 50MB에 20초 → 6초 지났으면 14초 남음
        let e = job(sizes: [50_000_000], past: 20.0 / 50_000_000).estimate(at: Date(timeIntervalSince1970: 6))
        #expect(abs((e.remaining ?? 0) - 14) < 0.01)
        #expect(abs((e.fraction ?? 0) - 0.3) < 0.01)
    }

    @Test func realFractionWins() {
        var j = job(sizes: [100, 100], past: 1)
        j.fractions[0] = 0.5
        let e = j.estimate(at: Date(timeIntervalSince1970: 10))
        #expect(abs((e.fraction ?? 0) - 0.25) < 0.001)
        #expect(abs((e.remaining ?? 0) - 30) < 0.01)      // 10초에 25% → 30초 남음
    }

    @Test func thisJobSpeedAfterOneFile() {
        var j = job(sizes: [100, 300])
        j.finished = [0]
        j.lastFinishedAt = Date(timeIntervalSince1970: 5)   // 100바이트에 5초 → 전체 20초
        let e = j.estimate(at: Date(timeIntervalSince1970: 8))
        #expect(abs((e.remaining ?? 0) - 12) < 0.01)
    }

    @Test func overdueWaitsAt97() {
        let e = job(sizes: [100], past: 0.05).estimate(at: Date(timeIntervalSince1970: 10))   // 예상 5초인데 10초째
        #expect(e.fraction == 0.97)
        #expect(e.overdue)
    }
}
