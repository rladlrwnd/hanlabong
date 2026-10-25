import Foundation
import Testing
@testable import SkillEngine

/// 옛 한글(.hwp) 읽기. 진짜 파일 확인은 선택형:
///   DRAGEDIT_HWP=/경로/문서.hwp swift test --filter HwpReader
struct HwpReaderTests {
    /// 레코드 하나 만들기: 머리(종류 10비트 + 길이 12비트) + 내용
    private func record(tag: UInt32, _ payload: Data) -> Data {
        var head = (UInt32(payload.count) << 20) | tag
        var out = Data(bytes: &head, count: 4)
        out.append(payload)
        return out
    }

    private func utf16(_ units: [UInt16]) -> Data {
        units.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    @Test func readsParagraphTextAndSkipsControls() {
        let text = Array("생활과 윤리".utf16)
        // 표 자리(11, 8글자 차지) + 글자 + 묶음 빈칸(30) + 글자 + 문단 끝(13)
        let table: [UInt16] = [11, 0x6c62, 0x7462, 0, 0, 0, 0, 11]
        let units = table + text + [30] + Array("1학기".utf16) + [13]
        let data = record(tag: 66, Data(count: 22)) + record(tag: 67, utf16(units)) + record(tag: 68, Data(count: 12))
        #expect(HwpReader.texts(inRecords: data) == ["생활과 윤리 1학기"])
    }

    @Test func longRecordUsesExtendedSize() {
        let long = Array(String(repeating: "가", count: 3000).utf16)
        var head: UInt32 = (0xFFF << 20) | 67
        var size = UInt32(long.count * 2)
        let data = Data(bytes: &head, count: 4) + Data(bytes: &size, count: 4) + utf16(long)
        #expect(HwpReader.texts(inRecords: data).first?.count == 3000)
    }

    @Test func brokenRecordsDoNotCrash() {
        let junk = Data((0..<500).map { UInt8(truncatingIfNeeded: $0 &* 37) })
        _ = HwpReader.texts(inRecords: junk)
        #expect(throws: (any Error).self) { try CompoundFile(junk) }
    }

    @Test func notAnOLEFileIsRejected() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-\(UUID().uuidString).hwp")
        try Data("그냥 글자".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: (any Error).self) { try RichDocumentReader.read(url) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DRAGEDIT_HWP"] != nil))
    func realHangulFileConverts() throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DRAGEDIT_HWP"]!)
        #expect(FileKindDetector.kind(of: url) == .document)
        let document = try RichDocumentReader.read(url)
        let chars = document.paragraphs.reduce(0) { $0 + $1.text.count }
        print("▶︎ 문단 \(document.paragraphs.count)개, 글자 \(chars)자")
        #expect(chars > 50)

        // 문서 변환 전부(PDF·Word·한글 등)가 실제로 파일을 만드는지. DRAGEDIT_HWP_OUT이 있으면 결과를 거기 남긴다
        let outDir = ProcessInfo.processInfo.environment["DRAGEDIT_HWP_OUT"].map { URL(fileURLWithPath: $0) }
        for skill in DefaultFileSkills.documentConversions {
            let result = try FileSkillExecutor().run(skill, input: url)
            #expect(!result.data.isEmpty || result.fileURL != nil, "\(skill.id)")
            if let outDir { try result.data.write(to: outDir.appendingPathComponent("out.\(result.fileExtension)")) }
        }
    }
}
