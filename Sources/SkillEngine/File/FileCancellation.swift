import Foundation

/// 파일 작업 취소 깃발.
/// 무거운 변환(Vision 글자 인식 등)은 Swift 동시성의 공용 스레드가 아니라 전용 작업 큐에서 돌린다
/// (Vision이 안에서 그 공용 스레드를 쓰는데, 우리가 공용 스레드를 다 붙잡고 기다리면 서로 멈춘다).
/// 그래서 Task의 취소를 직접 볼 수 없고, 이 깃발로 전한다.
public final class FileCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    /// 취소할 일이 없는 작업용
    public static var never: FileCancellation { FileCancellation() }

    public func cancel() { lock.withLock { cancelled = true } }

    public var isCancelled: Bool { lock.withLock { cancelled } }

    /// 취소됐으면 CancellationError를 던진다(여러 쪽짜리 OCR의 쪽 사이에서 부른다)
    public func check() throws {
        if isCancelled { throw CancellationError() }
    }
}
