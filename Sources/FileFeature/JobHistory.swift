import SkillEngine
import AppCore
import Foundation

/// 파일 변환 한 번(휠에 한 번 놓은 것)의 기록.
package struct JobRecord: Codable, Identifiable, Equatable {
    package struct Failure: Codable, Equatable {
        package var name: String
        package var message: String
    }

    package var id = UUID()
    package var date: Date
    package var skillID: String
    package var skillName: String
    package var symbol: String?
    /// 놓은 파일 수
    package var inputCount: Int
    /// 만들어진 결과 파일 경로(원본 경로는 적지 않는다)
    package var outputs: [String]
    package var failures: [Failure] = []
    package var skipped = 0
    /// 취소해서 만들지 않은 파일 수
    package var canceledCount = 0
    package var duration: TimeInterval
    /// 되돌려서 결과 파일을 휴지통으로 옮겼는지
    package var undone = false

    package var outputURLs: [URL] { outputs.map { URL(fileURLWithPath: $0) } }
    package var wasCanceled: Bool { canceledCount > 0 }
    package var canUndo: Bool { !undone && !outputs.isEmpty }
}

/// 설정 › 작업 기록 탭에 보이는 목록이자 되돌리기의 근거.
/// `~/Library/Application Support/Prism/file-history.json`에 저장한다(최근 200개).
/// 되돌리기 = 그 작업이 만든 결과 파일을 휴지통으로 옮기는 것. 원본은 기록에도 없고 건드리지도 않는다.
@MainActor
package final class JobHistory: ObservableObject {
    package nonisolated static let defaultFileURL = AppPaths.supportFolder.appendingPathComponent("file-history.json")
    static let limit = 200

    /// 최신이 맨 앞
    @Published package private(set) var records: [JobRecord] = []
    private let fileURL: URL

    package init(fileURL: URL = JobHistory.defaultFileURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let text = try decoder.singleValueContainer().decode(String.self)
                guard let date = Self.dateFormatter().date(from: text) else {
                    throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: L("날짜 형식이 아니에요: \(text)", "Not a date: \(text)")))
                }
                return date
            }
            records = (try? decoder.decode([JobRecord].self, from: data)) ?? []
        }
    }

    package func add(_ record: JobRecord) {
        records.insert(record, at: 0)
        if records.count > Self.limit { records.removeLast(records.count - Self.limit) }
        save()
    }

    /// 메뉴의 "마지막 파일 변환 되돌리기"가 되돌릴 작업
    package var latestUndoable: JobRecord? { records.first(where: \.canUndo) }

    package struct UndoOutcome: Equatable {
        package var trashed = 0
        /// 이미 지워졌거나 옮겨져서 없는 파일
        package var missing = 0
        package var failed = 0
    }

    /// 그 작업의 결과 파일을 `trash`로 치운다(기본은 휴지통).
    @discardableResult
    package func undo(_ id: JobRecord.ID, fileManager: FileManager = .default,
                      trash: ((URL) throws -> Void)? = nil) -> UndoOutcome {
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].canUndo else { return UndoOutcome() }
        var outcome = UndoOutcome()
        for url in records[index].outputURLs {
            guard fileManager.fileExists(atPath: url.path) else { outcome.missing += 1; continue }
            do {
                if let trash { try trash(url) } else { try fileManager.trashItem(at: url, resultingItemURL: nil) }
                outcome.trashed += 1
            } catch {
                outcome.failed += 1
            }
        }
        if outcome.failed == 0 { records[index].undone = true }
        save()
        return outcome
    }

    /// 기록만 지운다. 파일은 그대로다.
    package func clear() {
        records = []
        save()
    }

    /// 사람이 읽을 수 있는 날짜(ISO 8601)로, 1초 미만까지 저장한다
    private nonisolated static func dateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .custom { date, encoder in
                var container = encoder.singleValueContainer()
                try container.encode(Self.dateFormatter().string(from: date))
            }
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(records).write(to: fileURL, options: .atomic)
        } catch {
            log.error("file history save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
