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
    /// 동시에 돌릴 개수. nil이면 변환 종류와 이 맥 사양을 보고 알아서 정한다(`Parallelism`)
    let maxConcurrent: Int?

    init(maxConcurrent: Int? = nil) {
        self.maxConcurrent = maxConcurrent
    }

    /// 이 스킬을 몇 개씩 동시에 돌릴지(파일 수보다 많이는 안 돈다)
    func concurrency(for skill: FileSkill, files: Int) -> Int {
        max(1, min(maxConcurrent ?? Parallelism.limit(for: skill), max(files, 1)))
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
    ///   - onProgress: 파일 하나가 끝날 때마다(끝난 수, 전체 수, 방금 끝난 파일의 순번)
    ///   - onFraction: 진행률을 아는 변환(영상 등)이 파일 하나 안에서 몇 %인지 알려줄 때(순번, 0~1)
    func run(skill: FileSkill, urls: [URL],
             onStarted: @escaping @Sendable (_ name: String) -> Void = { _ in },
             onProgress: @escaping @Sendable (_ done: Int, _ total: Int, _ finished: Int) -> Void = { _, _, _ in },
             onFraction: @escaping @Sendable (_ index: Int, _ fraction: Double) -> Void = { _, _ in }) async -> Report {
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
                    cancellation.onFraction = { onFraction(position, $0) }
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
            for _ in 0..<concurrency(for: skill, files: total) { addNext() }

            var ordered: [(Int, Outcome)] = []
            while let result = await group.next() {
                done += 1
                ordered.append(result)
                onProgress(done, total, result.0)
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

/// 변환을 몇 개씩 동시에 돌릴지 정한다. 무엇이 병목인지가 종류마다 달라서:
/// - 영상: 맥의 영상 인코딩 칩 수가 한계(M1~M5 기본·Pro·Max는 2개처럼 쓰고, Ultra는 칩이 두 배라 4). ffmpeg는 파일 하나에도 코어를 거의 다 쓴다
/// - 사진·RAW: 큰 사진 한 장이 1~2GB를 쓰니 메모리가 한계(8GB당 하나), 성능 코어 수를 넘지 않게
/// - 글자 인식(OCR)·PDF·문서: 코어 수의 절반
enum Parallelism {
    struct Machine: Equatable {
        var performanceCores: Int
        var memoryGB: Int
        var chip: String

        static let current: Machine = {
            func sysctlInt(_ name: String) -> Int {
                var value: Int32 = 0
                var size = MemoryLayout<Int32>.size
                return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : 0
            }
            var chip = [CChar](repeating: 0, count: 128)
            var size = chip.count
            let name = sysctlbyname("machdep.cpu.brand_string", &chip, &size, nil, 0) == 0
                ? String(decoding: chip.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
            let cores = sysctlInt("hw.perflevel0.physicalcpu")
            return Machine(performanceCores: cores > 0 ? cores : ProcessInfo.processInfo.activeProcessorCount,
                           memoryGB: Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824),
                           chip: name)
        }()
    }

    static func limit(for skill: FileSkill, on machine: Machine = .current) -> Int {
        switch skill.steps.last {
        case .video?:
            return machine.chip.contains("Ultra") ? 4 : 2
        default:
            break
        }
        let photos = skill.input.contains(.image) || skill.input.contains(.raw)
        if photos, !skill.input.contains(.pdf) {
            return min(max(min(machine.performanceCores, machine.memoryGB / 8), 2), 6)
        }
        return min(max(machine.performanceCores / 2, 2), 4)
    }
}
