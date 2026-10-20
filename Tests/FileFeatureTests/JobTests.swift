import AppCore
import CoreGraphics
import Foundation
import ImageIO
import SkillEngine
import Testing
import UniformTypeIdentifiers
@testable import FileFeature

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dragedit-job-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// 작은 테스트 사진(PNG)을 코드로 만든다
private func photo(_ name: String, in dir: URL, size: Int = 64) throws -> URL {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    let url = dir.appendingPathComponent(name)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(destination))
    return url
}

// MARK: - 작업 기록

@MainActor
struct JobHistoryTests {
    private func record(_ name: String, outputs: [URL] = []) -> JobRecord {
        JobRecord(date: Date(), skillID: "photo-web", skillName: name, symbol: "globe", inputCount: max(1, outputs.count),
                  outputs: outputs.map(\.path), duration: 1)
    }

    @Test func recordsAreSavedAndComeBackAfterRestart() throws {
        let file = try tempDir().appendingPathComponent("history.json")
        let history = JobHistory(fileURL: file)
        history.add(record("웹용"))
        history.add(record("미리보기"))
        let reopened = JobHistory(fileURL: file)
        #expect(reopened.records.map(\.skillName) == ["미리보기", "웹용"])         // 최신이 맨 앞
        #expect(reopened.records.map(\.id) == history.records.map(\.id))
        for (a, b) in zip(reopened.records, history.records) {
            #expect(abs(a.date.timeIntervalSince(b.date)) < 0.001)              // 날짜는 밀리초까지 저장한다
            var sameDate = a
            sameDate.date = b.date
            #expect(sameDate == b)                                              // 나머지는 전부 그대로
        }
    }

    @Test func historyKeepsOnlyTheLatest200() throws {
        let history = JobHistory(fileURL: try tempDir().appendingPathComponent("h.json"))
        for i in 0..<230 { history.add(record("job \(i)")) }
        #expect(history.records.count == 200)
        #expect(history.records.first?.skillName == "job 229")
    }

    @Test func undoTrashesOnlyThatJobsOutputsAndRemembersIt() throws {
        let dir = try tempDir()
        func file(_ name: String) throws -> URL { let u = dir.appendingPathComponent(name); try Data(name.utf8).write(to: u); return u }
        let original = try file("orig.jpg")
        let older = try file("orig_web.jpg"), newer = try file("orig_sample.jpg"), gone = try file("orig_preview.jpg")

        let history = JobHistory(fileURL: dir.appendingPathComponent("h.json"))
        history.add(record("웹용", outputs: [older]))
        history.add(record("샘플", outputs: [newer, gone]))
        try FileManager.default.removeItem(at: gone)                          // 사용자가 이미 지운 파일

        let latest = try #require(history.latestUndoable)
        #expect(latest.skillName == "샘플")
        var trashed: [URL] = []
        let outcome = history.undo(latest.id) { trashed.append($0) }
        #expect(trashed == [newer])
        #expect(outcome == JobHistory.UndoOutcome(trashed: 1, missing: 1, failed: 0))
        #expect(history.records.first?.undone == true)
        #expect(history.latestUndoable?.skillName == "웹용")                   // 다음 되돌리기는 그 전 작업
        #expect(history.undo(latest.id) == JobHistory.UndoOutcome())           // 같은 작업은 두 번 되돌리지 않는다
        #expect(FileManager.default.fileExists(atPath: original.path))         // 원본은 기록에도 없고 건드리지도 않는다
    }

    @Test func failedUndoIsNotMarkedAsDone() throws {
        let dir = try tempDir()
        let output = dir.appendingPathComponent("x_web.jpg")
        try Data([1]).write(to: output)
        let history = JobHistory(fileURL: dir.appendingPathComponent("h.json"))
        history.add(record("웹용", outputs: [output]))
        struct Locked: Error {}
        let outcome = history.undo(history.records[0].id) { _ in throw Locked() }
        #expect(outcome.failed == 1)
        #expect(history.records[0].undone == false)
        #expect(history.latestUndoable != nil)                                // 다시 시도할 수 있다
    }

    @Test func jobsWithoutOutputsAreNotUndoable() throws {
        let history = JobHistory(fileURL: try tempDir().appendingPathComponent("h.json"))
        history.add(record("전부 실패"))
        #expect(history.latestUndoable == nil)
    }

    @Test func clearingHistoryLeavesFilesAlone() throws {
        let dir = try tempDir()
        let output = dir.appendingPathComponent("x_web.jpg")
        try Data([1]).write(to: output)
        let history = JobHistory(fileURL: dir.appendingPathComponent("h.json"))
        history.add(record("웹용", outputs: [output]))
        history.clear()
        #expect(history.records.isEmpty)
        #expect(JobHistory(fileURL: dir.appendingPathComponent("h.json")).records.isEmpty)
        #expect(FileManager.default.fileExists(atPath: output.path))
    }
}

// MARK: - 실행·취소

struct FileJobRunnerTests {
    private final class Box: @unchecked Sendable {
        var task: Task<FileJobRunner.Report, Never>?
        var started = 0
        var progress: [Int] = []
        let lock = NSLock()
    }

    @Test func convertsEveryFileBesideItsOriginal() async throws {
        let dir = try tempDir()
        let urls = try (0..<4).map { try photo("p\($0).png", in: dir) }
        let box = Box()
        let report = await FileJobRunner().run(skill: DefaultFileSkills.web, urls: urls, onProgress: { done, _ in
            box.lock.lock(); box.progress.append(done); box.lock.unlock()
        })
        #expect(report.outputs.map(\.lastPathComponent) == ["p0_web.jpg", "p1_web.jpg", "p2_web.jpg", "p3_web.jpg"])
        #expect(report.failures.isEmpty && report.canceled == 0)
        #expect(box.progress.sorted() == [1, 2, 3, 4])
    }

    @Test func foldersAreSkippedAndBrokenFilesAreReported() async throws {
        let dir = try tempDir()
        let good = try photo("ok.png", in: dir)
        let folder = dir.appendingPathComponent("a folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let broken = dir.appendingPathComponent("broken.jpg")
        try Data("not a photo".utf8).write(to: broken)

        let report = await FileJobRunner().run(skill: DefaultFileSkills.web, urls: [good, folder, broken])
        #expect(report.outputs.count == 1)
        #expect(report.skipped == 1)
        #expect(report.failures.map(\.name) == ["broken.jpg"])
    }

    @Test func cancelStopsNewFilesAndLeavesNoHalfWrittenFiles() async throws {
        let dir = try tempDir()
        let urls = try (0..<6).map { try photo("c\($0).png", in: dir, size: 256) }
        let runner = FileJobRunner(maxConcurrent: 1)
        let box = Box()
        box.task = Task {
            await runner.run(skill: DefaultFileSkills.web, urls: urls, onStarted: { _ in
                box.lock.lock(); box.started += 1; let n = box.started; box.lock.unlock()
                if n == 2 { box.task?.cancel() }                                 // 두 번째 파일을 시작할 때 취소
            })
        }
        let report = await box.task!.value
        #expect(report.outputs.count == 1)
        #expect(report.canceled == 5)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.filter { $0.contains("_web") } == ["c0_web.jpg"])
        #expect(!names.contains { $0.hasSuffix(".tmp") })
    }
}

// MARK: - 진행 중인 작업

@MainActor
struct JobCenterTests {
    private func job(_ id: UUID = UUID()) -> JobCenter.Job {
        JobCenter.Job(id: id, title: "웹용", symbol: "globe", total: 3, started: Date())
    }

    @Test func onlyLongJobsShowOnTheCard() {
        let center = JobCenter()
        let quick = job(), slow = job()
        center.begin(quick) {}
        center.begin(slow) {}
        #expect(center.longJobs.isEmpty)
        #expect(center.markLongIfRunning(slow.id))
        #expect(center.longJobs.map(\.id) == [slow.id])
        #expect(center.finish(slow.id) == true)                               // 카드에 보였던 작업 → 알림 대상
        #expect(center.finish(quick.id) == false)
        #expect(center.markLongIfRunning(quick.id) == false)                  // 이미 끝난 작업은 카드에 안 올린다
    }

    @Test func cancelCallsTheHandlerOnce() {
        let center = JobCenter()
        let j = job()
        var calls = 0
        center.begin(j) { calls += 1 }
        center.cancel(j.id)
        center.cancel(j.id)
        #expect(calls == 1)
        #expect(center.jobs.first?.isCanceling == true)
    }

    @Test func aiJobWaitsForReviewOnTheCard() {
        let center = JobCenter()
        let agent = Agent(provider: .ollama, model: "qwen3.6:27b", detail: "")
        let job = JobCenter.Job(id: UUID(), title: "AI 오타수정", symbol: "sparkles", total: 0, started: Date(), agent: agent, unit: "곳")
        var opened = 0
        center.begin(job) {}
        #expect(center.longJobs.isEmpty && !center.hasAIJobs)
        center.update(job.id, done: 3, total: 12)
        center.awaitReview(job.id) { opened += 1 }
        #expect(center.longJobs.map(\.id) == [job.id])                       // 짧게 끝났어도 카드에 올린다(사용자가 할 일이 있다)
        #expect(center.hasAIJobs && center.isAwaitingReview)                  // 빛줄기 + 깜빡임
        center.openReview(job.id)
        #expect(opened == 1)
        center.finish(job.id)
        #expect(!center.isAwaitingReview)
    }

    @Test func progressUpdatesTheRightJob() {
        let center = JobCenter()
        let a = job(), b = job()
        center.begin(a) {}
        center.begin(b) {}
        center.update(b.id, done: 2, current: "DSCF0001.RAF")
        #expect(center.jobs.first { $0.id == b.id }?.done == 2)
        #expect(center.jobs.first { $0.id == b.id }?.current == "DSCF0001.RAF")
        #expect(center.jobs.first { $0.id == a.id }?.done == 0)
    }
}
