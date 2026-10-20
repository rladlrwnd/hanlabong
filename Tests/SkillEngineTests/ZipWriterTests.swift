import Foundation
import Testing
@testable import SkillEngine

/// zip 묶음이 표준 도구(unzip)로 열리고 내용이 그대로인지
struct ZipWriterTests {
    private func unzip(_ args: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test func crc32MatchesKnownValues() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(CRC32.checksum(Data()) == 0)
    }

    @Test func archiveIsValidAndContentsSurvive() throws {
        let long = String(repeating: "문단 하나. Paragraph one. ", count: 400)   // 잘 줄어드는 내용 → DEFLATE
        let tiny = "x"                                                          // 줄지 않는 내용 → 그대로
        var zip = ZipWriter()
        zip.add("[Content_Types].xml", long)
        zip.add("word/한글 이름.xml", tiny)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("z-\(UUID().uuidString).zip")
        try zip.finish().write(to: url)

        let test = try unzip(["-t", url.path])
        #expect(test.status == 0, "\(test.output)")
        #expect(test.output.contains("No errors detected"))
        // 풀어서 내용 비교(macOS 기본 도구 ditto — 한글 이름도 그대로 풀린다)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("z-out-\(UUID().uuidString)")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", url.path, out.path]
        try ditto.run()
        ditto.waitUntilExit()
        #expect(ditto.terminationStatus == 0)
        #expect(try String(contentsOf: out.appendingPathComponent("[Content_Types].xml"), encoding: .utf8) == long)
        #expect(try String(contentsOf: out.appendingPathComponent("word/한글 이름.xml"), encoding: .utf8) == tiny)
        #expect(try Data(contentsOf: url).count < long.utf8.count / 5)         // 실제로 압축됐다
    }
}
