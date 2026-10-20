import AppCore
import Foundation
import SkillEngine

/// 휠에 놓인 파일들을 스킬로 바꿔서 각각 원본 옆에 저장한다.
/// - 사진 수백 장(RAW)을 놓아도 메모리가 튀지 않게, 동시에 돌리는 개수를 제한한다.
/// - 취소하면 새 파일을 더 시작하지 않고, 처리 중이던 파일은 저장하지 않고 버린다(반쯤 된 파일이 남지 않는다).
final class FileJobRunner: @unchecked Sendable {
    struct Report {
        var outputs: [URL] = []
        var failures: [JobRecord.Failure] = []
        /// 폴더처럼 이 스킬 대상이 아니라서 건너뛴 것
        var skipped = 0
        /// 취소 때문에 만들지 않은 것
        var canceled = 0
    }

    private enum Outcome {
        case done(URL)
        case failed(JobRecord.Failure)
        case skipped
        case canceled
    }

    private let executor = FileSkillExecutor()
    /// 무거운 변환을 돌리는 전용 큐. Swift 동시성 공용 스레드를 붙잡지 않는다(Vision 글자 인식이 그 스레드를 쓰기 때문).
    private static let workQueue = DispatchQueue(label: "app.dragedit.file-jobs", qos: .userInitiated, attributes: .concurrent)
    /// 큰 사진 한 장은 처리 중에 1~2GB를 쓴다. 둘까지만 동시에.
    let maxConcurrent: Int

    init(maxConcurrent: Int = 2) {
        self.maxConcurrent = maxConcurrent
    }

    /// 무거운 일 하나를 전용 큐에서 돌린다(공용 스레드를 붙잡지 않는다). Task가 취소되면 깃발로 전한다.
    static func onWorkQueue<T: Sendable>(_ work: @escaping @Sendable (FileCancellation) throws -> T) async throws -> T {
        let cancellation = FileCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                workQueue.async { continuation.resume(with: Result { try work(cancellation) }) }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// - Parameters:
    ///   - onStarted: 파일 하나를 시작할 때(이름은 화면에만 쓰고 로그에는 남기지 않는다)
    ///   - onProgress: 파일 하나가 끝날 때마다(끝난 수, 전체 수)
    func run(skill: FileSkill, urls: [URL],
             onStarted: @escaping @Sendable (_ name: String) -> Void = { _ in },
             onProgress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void = { _, _ in }) async -> Report {
        var report = Report()
        let total = urls.count
        var done = 0
        var started = 0
        var iterator = urls.makeIterator()
        let executor = self.executor

        await withTaskGroup(of: (Int, Outcome).self) { group in
            func addNext() {
                guard !Task.isCancelled, let url = iterator.next() else { return }
                let position = started
                started += 1
                onStarted(url.lastPathComponent)
                group.addTask(priority: .userInitiated) {
                    let cancellation = FileCancellation()
                    return await withTaskCancellationHandler {
                        await withCheckedContinuation { continuation in
                            Self.workQueue.async {
                                continuation.resume(returning: (position, Self.process(skill, url, executor: executor, cancellation: cancellation)))
                            }
                        }
                    } onCancel: {
                        cancellation.cancel()
                    }
                }
            }
            for _ in 0..<min(maxConcurrent, total) { addNext() }

            var ordered: [(Int, Outcome)] = []
            while let result = await group.next() {
                done += 1
                ordered.append(result)
                onProgress(done, total)
                addNext()
            }
            for (_, outcome) in ordered.sorted(by: { $0.0 < $1.0 }) {
                switch outcome {
                case .done(let url): report.outputs.append(url)
                case .failed(let failure): report.failures.append(failure)
                case .skipped: report.skipped += 1
                case .canceled: report.canceled += 1
                }
            }
        }
        // 취소해서 아예 시작하지 않은 파일
        report.canceled += total - started
        return report
    }

    private static func process(_ skill: FileSkill, _ url: URL, executor: FileSkillExecutor, cancellation: FileCancellation) -> Outcome {
        if cancellation.isCancelled { return .canceled }
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return .skipped }
        do {
            let result = try executor.run(skill, input: url, cancellation: cancellation)
            // 그리는 동안 취소됐으면 저장하지 않는다
            if cancellation.isCancelled { return .canceled }
            if let file = result.fileURL {
                return .done(try FileOutputWriter.save(movingFile: file, fileExtension: result.fileExtension,
                                                       suffix: skill.output.suffix, besideOriginal: url))
            }
            return .done(try FileOutputWriter.save(result.data, fileExtension: result.fileExtension,
                                                   suffix: skill.output.suffix, besideOriginal: url))
        } catch is CancellationError {
            return .canceled                    // 여러 쪽짜리 OCR을 쪽 사이에서 멈췄다
        } catch {
            // 파일 이름은 사용자에게 보여주는 오류 문구에만 쓰고, 로그에는 남기지 않는다
            log.error("file job failed: \(String(describing: error), privacy: .private)")
            return .failed(JobRecord.Failure(name: url.lastPathComponent, message: error.localizedDescription))
        }
    }
}
