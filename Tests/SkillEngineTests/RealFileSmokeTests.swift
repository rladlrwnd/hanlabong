import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
@testable import SkillEngine

/// 실제 메모리 사용량(활동 모니터의 "메모리"와 같은 값). resident 크기는 파일 캐시까지 세서 부풀려 보인다.
private func footprintMB() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    _ = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: 1) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return Int(info.phys_footprint) / 1_000_000
}

/// 진짜 사진으로 돌려보는 선택형 테스트. 환경변수가 없으면 건너뛴다.
///   DRAGEDIT_SAMPLES=/경로/a.RAF:/경로/b.jpg swift test --filter RealFileSmoke
/// 원본은 읽기만 하고, 결과는 임시 폴더에 쓴다(원본 옆에 저장하지 않는다). RAW(후지 RAF 등)는 이걸로 확인한다.
struct RealFileSmokeTests {
    private static var samples: [URL] {
        (ProcessInfo.processInfo.environment["DRAGEDIT_SAMPLES"] ?? "")
            .split(separator: ":").map { URL(fileURLWithPath: String($0)) }
    }

    @Test(.enabled(if: !RealFileSmokeTests.samples.isEmpty), arguments: RealFileSmokeTests.samples)
    func presetsOnRealPhoto(sample: URL) throws {
        let executor = FileSkillExecutor()
        if FileKindDetector.kind(of: sample) == .pdf { try pdfSmoke(sample, executor: executor); return }
        let source = CGImageSourceCreateWithURL(sample as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        let kind = FileKindDetector.kind(of: sample).map(\.rawValue) ?? "?"
        print("\n▶︎ \(sample.lastPathComponent)  종류=\(kind)  \(props["PixelWidth"] ?? "?")×\(props["PixelHeight"] ?? "?")  depth=\(props["Depth"] ?? "?")  프로필=\(props["ProfileName"] ?? "없음")  Orientation=\(props["Orientation"] ?? "-")")

        let outDir = try Fixtures.makeTempDir()
        for preset in DefaultFileSkills.photoPresets {
            let start = Date()
            let result = try executor.run(preset, input: sample)
            let seconds = Date().timeIntervalSince(start)
            let out = Fixtures.properties(of: result.data)
            let tiff = out["{TIFF}"] as? [String: Any] ?? [:], exif = out["{Exif}"] as? [String: Any] ?? [:]
            print(String(format: "   %-8@ %5.1f초 (작업 뒤 메모리 %dMB)  %d×%d  %.2fMB  프로필=%@  GPS=%@  Make=%@  ISO=%@  Artist=%@",
                         preset.name as NSString, seconds, footprintMB(), result.width, result.height, Double(result.data.count) / 1_000_000,
                         (out["ProfileName"] as? String ?? "없음") as NSString,
                         out["{GPS}"] == nil ? "없음" : "있음", (tiff["Make"] as? String ?? "-") as NSString,
                         "\(exif["ISOSpeedRatings"] ?? "-")" as NSString, (tiff["Artist"] as? String ?? "-") as NSString))
            try result.data.write(to: outDir.appendingPathComponent("\(sample.deletingPathExtension().lastPathComponent)\(preset.output.suffix).\(result.fileExtension)"))
            #expect(max(result.width, result.height) <= 4096)
        }
        print("   결과 폴더: \(outDir.path)")
    }

    /// PDF: 내용은 찍지 않고(개인 문서일 수 있다) 숫자만 본다. PRINT_PDF_TEXT=1이면 앞부분을 보여준다.
    private func pdfSmoke(_ sample: URL, executor: FileSkillExecutor) throws {
        let document = try PDFTextExtractor.extract(PDFDocument(url: sample)!) { page, index in try PDFPageOCR.lines(of: page, index: index) }
        let paragraphs = document.paragraphs
        let joined = paragraphs.map(\.text).joined(separator: "\n")
        // 조사·어미 앞에 잘못 들어간 띄어쓰기로 보이는 곳(예: "속도 는 ")
        let suspicious = try NSRegularExpression(pattern: #"[가-힣] (는|은|을|를|의|에서|으로|와|과|다\.|습니다|했다)[ .,\n]"#)
            .numberOfMatches(in: joined, range: NSRange(joined.startIndex..., in: joined))
        print("\n▶︎ \(sample.lastPathComponent)  \(document.pageCount)쪽  문단 \(paragraphs.count)개  제목 \(paragraphs.filter { $0.headingLevel != nil }.count)개  본문 \(document.bodyFontSize)pt  글자 \(joined.count)자  의심 띄어쓰기 \(suspicious)곳")
        if ProcessInfo.processInfo.environment["PRINT_PDF_TEXT"] == "1" {
            for paragraph in paragraphs.prefix(6) { print("   [\(paragraph.headingLevel.map { "H\($0)" } ?? "본문")] \(paragraph.text.prefix(160))") }
        }
        let outDir = try Fixtures.makeTempDir()
        for skill in [DefaultFileSkills.pdfToWord, DefaultFileSkills.pdfToPlainText] {
            let start = Date()
            let result = try executor.run(skill, input: sample)
            let url = outDir.appendingPathComponent("out.\(result.fileExtension)")
            try result.data.write(to: url)
            var opened = "-"
            if result.fileExtension == "docx" {
                let textutil = Process()
                textutil.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
                textutil.arguments = ["-convert", "txt", "-stdout", url.path]
                textutil.standardOutput = Pipe(); textutil.standardError = Pipe()
                try textutil.run(); textutil.waitUntilExit()
                opened = textutil.terminationStatus == 0 ? "열림" : "안 열림"
            }
            print(String(format: "   %@ %.2f초  %.1fKB  Word로 열기: %@", skill.name, Date().timeIntervalSince(start), Double(result.data.count) / 1000, opened))
        }
    }
}
