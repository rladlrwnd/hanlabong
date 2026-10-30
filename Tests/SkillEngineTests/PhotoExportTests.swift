import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import SkillEngine

/// 내보내기 설정(라이트룸 내보내기 창 참고): 크기·형식·용량·ppi·이름·위치
struct PhotoExportTests {
    private func photo(in dir: URL, width: Int = 600, height: Int = 400) throws -> URL {
        try Fixtures.write(Fixtures.noise(width: width, height: height), to: dir.appendingPathComponent("shot.jpg"), type: .jpeg)
    }

    @Test func fitBoxKeepsAspectAndDoesNotEnlarge() throws {
        let dir = try Fixtures.makeTempDir(), url = try photo(in: dir)
        var s = PhotoExportSettings(); s.sizing = .fit; s.fitWidth = 300; s.fitHeight = 300
        let r = try FileSkillExecutor().run(s.skill(develop: DevelopSettings()), input: url)
        #expect(r.width == 300 && r.height == 200)
        s.fitWidth = 2000; s.fitHeight = 2000
        let big = try FileSkillExecutor().run(s.skill(develop: DevelopSettings()), input: url)
        #expect(big.width == 600)                                    // 키우지 않기
    }

    @Test func megapixelsAndPpi() throws {
        let dir = try Fixtures.makeTempDir(), url = try photo(in: dir)
        var s = PhotoExportSettings(); s.sizing = .megapixels; s.megapixels = 0.1; s.ppi = 300
        let r = try FileSkillExecutor().run(s.skill(develop: DevelopSettings()), input: url)
        #expect(abs(r.width * r.height - 100_000) < 2_000)
        let props = Fixtures.properties(of: r.data)
        #expect((props[kCGImagePropertyDPIWidth as String] as? Int) == 300)
    }

    @Test func fileSizeLimitIsRespected() throws {
        let dir = try Fixtures.makeTempDir(), url = try photo(in: dir, width: 1200, height: 900)
        var s = PhotoExportSettings(); s.limitFileSize = true; s.maxKilobytes = 120
        let r = try FileSkillExecutor().run(s.skill(develop: DevelopSettings()), input: url)
        #expect(r.data.count <= 120_000)
    }

    @Test func sharpenAndWatermarkComeAfterResize() {
        var s = PhotoExportSettings(); s.sizing = .longEdge; s.sharpen = true; s.watermark = true; s.watermarkText = "SAMPLE"
        var d = DevelopSettings(); d.exposure = 0.3
        let names = s.skill(develop: d).steps.map { step -> String in
            switch step {
            case .develop: return "develop"; case .resize: return "resize"; case .sharpen: return "sharpen"
            case .watermark: return "watermark"; case .encode: return "encode"; default: return "-"
            }
        }.filter { $0 != "-" }
        #expect(names == ["develop", "resize", "sharpen", "watermark", "encode"])
    }

    @Test func namingAndDestinations() throws {
        let dir = try Fixtures.makeTempDir(), url = try photo(in: dir)
        var s = PhotoExportSettings()
        let a = try s.export(url, develop: DevelopSettings(), index: 1)
        #expect(a.lastPathComponent == "shot_dev.jpg" && a.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
        s.destination = .subfolder; s.subfolderName = "Out"; s.naming = .custom; s.customName = "trip"; s.format = .png
        let b = try s.export(url, develop: DevelopSettings(), index: 3)
        #expect(b.lastPathComponent == "trip-3.png" && b.deletingLastPathComponent().lastPathComponent == "Out")
        s.subfolderName = "../escape"
        #expect(throws: (any Error).self) { try s.export(url, develop: DevelopSettings(), index: 1) }
    }

    @Test func oldSettingsStillDecode() throws {
        let s = try JSONDecoder().decode(PhotoExportSettings.self, from: Data(#"{"quality":70}"#.utf8))
        #expect(s.quality == 70 && s.suffix == "_dev")
    }
}
