import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import SkillEngine

/// 파일 블록 검증: 16비트 값, 색 프로필, EXIF 모드, 목표 파일 크기, 이름 겹침, 원본 보존
struct FileSkillTests {
    private let executor = FileSkillExecutor()

    private func skill(_ steps: [FileStep], suffix: String = "_t") -> FileSkill {
        FileSkill(id: "t", name: "t", input: [.image, .raw], steps: [.decode] + steps, output: FileOutput(suffix: suffix))
    }

    // MARK: 16비트 흑백 TIFF (DragShift는 이걸 변환하면 새하얗게 나왔다)

    @Test func gray16TiffKeepsEveryValue() throws {
        let dir = try Fixtures.makeTempDir()
        let source = Fixtures.gray16(width: 64, height: 48) { x, y in UInt16(x * 1000 + y * 10) }
        let url = try Fixtures.write(source, to: dir.appendingPathComponent("g.tif"), type: .tiff)

        let result = try executor.run(skill([.encode(EncodeSpec(format: .tiff))]), input: url)
        let output = Fixtures.cgImage(of: result.data)

        #expect(output.bitsPerComponent == 16)
        #expect(output.colorSpace?.model == .monochrome)
        let before = Fixtures.gray16Samples(source), after = Fixtures.gray16Samples(output)
        #expect(before.count == after.count)
        let worst = zip(before, after).map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(worst <= 2, "회색 값이 \(worst)만큼 바뀌었어요 (16비트 기준)")
    }

    @Test func gray16SurvivesResizeWithoutGoingWhite() throws {
        let dir = try Fixtures.makeTempDir()
        let source = Fixtures.gray16(width: 200, height: 200) { _, _ in 20000 }   // 어두운 단색
        let url = try Fixtures.write(source, to: dir.appendingPathComponent("g.tif"), type: .tiff)

        let result = try executor.run(skill([.resize(.longEdge(100)), .encode(EncodeSpec(format: .tiff))]), input: url)
        let samples = Fixtures.gray16Samples(Fixtures.cgImage(of: result.data))
        #expect(result.width == 100 && result.height == 100)
        let mean = samples.map(Double.init).reduce(0, +) / Double(samples.count)
        #expect(abs(mean - 20000) < 50, "평균 회색이 \(mean)로 바뀌었어요")
    }

    // MARK: 색 프로필

    @Test(arguments: [("Display P3", "displayP3"), ("Adobe RGB", "adobeRGB")])
    func profileSurvivesWhenColorSpaceIsKept(expectedName: String, which: String) throws {
        let space = which == "displayP3" ? Fixtures.displayP3 : Fixtures.adobeRGB
        let dir = try Fixtures.makeTempDir()
        let source = Fixtures.rgb(width: 80, height: 60, space: space) { x, y in (UInt8(x * 3), UInt8(y * 4), 120, 255) }
        let url = try Fixtures.write(source, to: dir.appendingPathComponent("p.jpg"), type: .jpeg)

        let result = try executor.run(skill([.resize(.longEdge(40)), .encode(EncodeSpec(format: .jpg, quality: 0.9))]), input: url)
        let profile = Fixtures.properties(of: result.data)[kCGImagePropertyProfileName as String] as? String ?? ""
        #expect(profile.contains(expectedName), "프로필이 “\(profile)”로 바뀌었어요")
    }

    @Test func convertingToSRGBConvertsTheColors() throws {
        let dir = try Fixtures.makeTempDir()
        let p3Color = (r: 0.8, g: 0.3, b: 0.3)
        let source = Fixtures.rgb(width: 16, height: 16, space: Fixtures.displayP3) { _, _ in
            (UInt8(p3Color.r * 255), UInt8(p3Color.g * 255), UInt8(p3Color.b * 255), 255)
        }
        let url = try Fixtures.write(source, to: dir.appendingPathComponent("p3.png"), type: .png)

        let result = try executor.run(skill([.colorspace(.sRGB), .encode(EncodeSpec(format: .png))]), input: url)
        let output = Fixtures.cgImage(of: result.data)
        #expect((Fixtures.properties(of: result.data)[kCGImagePropertyProfileName as String] as? String ?? "").contains("sRGB"))

        let expected = CGColor(colorSpace: Fixtures.displayP3, components: [0.8039, 0.3019, 0.3019, 1])!
            .converted(to: Fixtures.sRGB, intent: .defaultIntent, options: nil)!.components!
        let pixels = Fixtures.rgba(output, in: Fixtures.sRGB)
        let p = Fixtures.pixel(pixels, width: 16, x: 8, y: 8)
        #expect(abs(p.r - Int((expected[0] * 255).rounded())) <= 2)
        #expect(abs(p.g - Int((expected[1] * 255).rounded())) <= 2)
        #expect(abs(p.b - Int((expected[2] * 255).rounded())) <= 2)
    }

    // MARK: 메타데이터(EXIF) 모드

    private func photoWithMetadata(in dir: URL) throws -> URL {
        let image = Fixtures.rgb(width: 60, height: 40) { x, y in (UInt8(x * 4), UInt8(y * 5), 90, 255) }
        let properties: [String: Any] = [
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFMake as String: "TestCam", kCGImagePropertyTIFFModel as String: "T-1",
                kCGImagePropertyTIFFArtist as String: "Old Artist",
            ],
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifDateTimeOriginal as String: "2026:10:19 10:00:00",
                kCGImagePropertyExifISOSpeedRatings as String: [400],
                kCGImagePropertyExifLensModel as String: "50mm F1.4",
                kCGImagePropertyExifBodySerialNumber as String: "SN-SECRET-123",
            ],
            kCGImagePropertyGPSDictionary as String: [
                kCGImagePropertyGPSLatitude as String: 37.5, kCGImagePropertyGPSLatitudeRef as String: "N",
                kCGImagePropertyGPSLongitude as String: 127.0, kCGImagePropertyGPSLongitudeRef as String: "E",
            ],
            kCGImagePropertyIPTCDictionary as String: [
                kCGImagePropertyIPTCCity as String: "Seoul", kCGImagePropertyIPTCCaptionAbstract as String: "caption",
            ],
        ]
        return try Fixtures.write(image, to: dir.appendingPathComponent("m.jpg"), type: .jpeg, properties: properties)
    }

    private func run(_ mode: MetadataMode, artist: String? = nil, copyright: String? = nil, input: URL) throws -> [String: Any] {
        let steps: [FileStep] = [
            .metadata(MetadataSpec(mode: mode, artist: artist, copyright: copyright)),
            .encode(EncodeSpec(format: .jpg, quality: 0.9)),
        ]
        return Fixtures.properties(of: try executor.run(skill(steps), input: input).data)
    }

    private func dict(_ props: [String: Any], _ key: CFString) -> [String: Any] { props[key as String] as? [String: Any] ?? [:] }

    @Test func metadataKeepAllKeepsEverything() throws {
        let props = try run(.keepAll, input: photoWithMetadata(in: Fixtures.makeTempDir()))
        #expect(dict(props, kCGImagePropertyGPSDictionary)[kCGImagePropertyGPSLatitude as String] != nil)
        #expect(dict(props, kCGImagePropertyTIFFDictionary)[kCGImagePropertyTIFFMake as String] as? String == "TestCam")
        #expect(dict(props, kCGImagePropertyExifDictionary)[kCGImagePropertyExifDateTimeOriginal as String] as? String == "2026:10:19 10:00:00")
        #expect(dict(props, kCGImagePropertyExifDictionary)[kCGImagePropertyExifBodySerialNumber as String] as? String == "SN-SECRET-123")
    }

    @Test func metadataRemoveGPSOnlyRemovesLocation() throws {
        let props = try run(.removeGPS, input: photoWithMetadata(in: Fixtures.makeTempDir()))
        #expect(dict(props, kCGImagePropertyGPSDictionary).isEmpty)
        #expect(dict(props, kCGImagePropertyIPTCDictionary)[kCGImagePropertyIPTCCity as String] == nil)
        #expect(dict(props, kCGImagePropertyTIFFDictionary)[kCGImagePropertyTIFFMake as String] as? String == "TestCam")
        #expect(dict(props, kCGImagePropertyExifDictionary)[kCGImagePropertyExifLensModel as String] as? String == "50mm F1.4")
    }

    @Test func metadataKeepCameraOnlyDropsPersonalAndLocationInfo() throws {
        let props = try run(.keepCameraOnly, input: photoWithMetadata(in: Fixtures.makeTempDir()))
        let exif = dict(props, kCGImagePropertyExifDictionary), tiff = dict(props, kCGImagePropertyTIFFDictionary)
        #expect(tiff[kCGImagePropertyTIFFMake as String] as? String == "TestCam")
        #expect(tiff[kCGImagePropertyTIFFModel as String] as? String == "T-1")
        #expect(exif[kCGImagePropertyExifDateTimeOriginal as String] as? String == "2026:10:19 10:00:00")
        #expect(exif[kCGImagePropertyExifLensModel as String] as? String == "50mm F1.4")
        #expect(exif[kCGImagePropertyExifISOSpeedRatings as String] != nil)
        #expect(exif[kCGImagePropertyExifBodySerialNumber as String] == nil)
        #expect(tiff[kCGImagePropertyTIFFArtist as String] == nil)
        #expect(dict(props, kCGImagePropertyGPSDictionary).isEmpty)
        #expect(dict(props, kCGImagePropertyIPTCDictionary).isEmpty)
    }

    @Test func metadataRemoveAllThenWritesArtistAndCopyright() throws {
        let props = try run(.removeAll, artist: "Jane Doe", copyright: "© Jane Doe", input: photoWithMetadata(in: Fixtures.makeTempDir()))
        let tiff = dict(props, kCGImagePropertyTIFFDictionary), exif = dict(props, kCGImagePropertyExifDictionary)
        #expect(tiff[kCGImagePropertyTIFFMake as String] == nil)
        #expect(exif[kCGImagePropertyExifDateTimeOriginal as String] == nil)
        #expect(dict(props, kCGImagePropertyGPSDictionary).isEmpty)
        #expect(tiff[kCGImagePropertyTIFFArtist as String] as? String == "Jane Doe")
        #expect(tiff[kCGImagePropertyTIFFCopyright as String] as? String == "© Jane Doe")
    }

    @Test func orientationIsAppliedToPixelsAndResetInMetadata() throws {
        let dir = try Fixtures.makeTempDir()
        let image = Fixtures.rgb(width: 60, height: 40) { _, _ in (10, 200, 30, 255) }
        let url = try Fixtures.write(image, to: dir.appendingPathComponent("o.jpg"), type: .jpeg,
                                     properties: [kCGImagePropertyOrientation as String: 6])   // 90도 돌려서 봐야 하는 사진
        let result = try executor.run(skill([.encode(EncodeSpec(format: .jpg, quality: 0.9))]), input: url)
        #expect(result.width == 40 && result.height == 60)
        #expect(Fixtures.properties(of: result.data)[kCGImagePropertyOrientation as String] as? Int ?? 1 == 1)
    }

    // MARK: 크기·자르기·위치

    @Test func resizeRules() throws {
        let dir = try Fixtures.makeTempDir()
        let url = try Fixtures.write(Fixtures.noise(width: 400, height: 200), to: dir.appendingPathComponent("r.png"), type: .png)
        func size(_ steps: [FileStep]) throws -> (Int, Int) {
            let r = try executor.run(skill(steps + [.encode(EncodeSpec(format: .png))]), input: url)
            return (r.width, r.height)
        }
        #expect(try size([.resize(.longEdge(100))]) == (100, 50))
        #expect(try size([.resize(.shortEdge(50))]) == (100, 50))
        #expect(try size([.resize(.percent(25))]) == (100, 50))
        #expect(try size([.resize(.longEdge(800))]) == (400, 200))                       // 키우지 않는다
        #expect(try size([.resize(.longEdge(800), allowUpscale: true)]) == (800, 400))
    }

    @Test func cropByAspectAndByRect() throws {
        let dir = try Fixtures.makeTempDir()
        let url = try Fixtures.write(Fixtures.noise(width: 300, height: 200), to: dir.appendingPathComponent("c.png"), type: .png)
        func size(_ spec: CropSpec) throws -> (Int, Int) {
            let r = try executor.run(skill([.crop(spec), .encode(EncodeSpec(format: .png))]), input: url)
            return (r.width, r.height)
        }
        #expect(try size(CropSpec(aspect: "1:1")) == (200, 200))
        #expect(try size(CropSpec(aspect: "3:2")) == (300, 200))
        #expect(try size(CropSpec(rect: .init(x: 0.1, y: 0.25, width: 0.5, height: 0.5))) == (150, 100))
    }

    @Test func pixelsStayTheRightWayUp() throws {
        // 왼쪽 위만 빨간 4×2 사진이 위아래·좌우가 뒤집히지 않아야 한다
        let dir = try Fixtures.makeTempDir()
        let image = Fixtures.rgb(width: 4, height: 2) { x, y in (x == 0 && y == 0) ? (255, 0, 0, 255) : (0, 0, 255, 255) }
        let url = try Fixtures.write(image, to: dir.appendingPathComponent("u.png"), type: .png)
        let result = try executor.run(skill([.encode(EncodeSpec(format: .png))]), input: url)
        let pixels = Fixtures.rgba(Fixtures.cgImage(of: result.data), in: Fixtures.sRGB)
        let topLeft = Fixtures.pixel(pixels, width: 4, x: 0, y: 0), bottomLeft = Fixtures.pixel(pixels, width: 4, x: 0, y: 1)
        let topRight = Fixtures.pixel(pixels, width: 4, x: 3, y: 0)
        #expect(topLeft.r > 240 && topLeft.b < 15)
        #expect(bottomLeft.b > 240 && topRight.b > 240)
    }

    @Test func textWatermarkLandsInTheChosenCorner() throws {
        let dir = try Fixtures.makeTempDir()
        let black = Fixtures.rgb(width: 400, height: 200) { _, _ in (0, 0, 0, 255) }
        let url = try Fixtures.write(black, to: dir.appendingPathComponent("w.png"), type: .png)
        let mark = WatermarkSpec(text: "© Jane Doe", position: .bottomRight, opacity: 1, sizePercent: 30, marginPercent: 4)
        let result = try executor.run(skill([.watermark(mark), .encode(EncodeSpec(format: .png))]), input: url)
        let pixels = Fixtures.rgba(Fixtures.cgImage(of: result.data), in: Fixtures.sRGB)
        func brightness(_ xs: Range<Int>, _ ys: Range<Int>) -> Int {
            var sum = 0
            for y in ys { for x in xs { sum += Fixtures.pixel(pixels, width: 400, x: x, y: y).r } }
            return sum
        }
        #expect(brightness(200..<400, 100..<200) > 2000)   // 오른쪽 아래에는 글자가 있다
        #expect(brightness(0..<200, 0..<100) == 0)         // 왼쪽 위는 그대로 까맣다
    }

    @Test func transparentPngBecomesWhiteWhenSavedAsJpeg() throws {
        let dir = try Fixtures.makeTempDir()
        let clear = Fixtures.rgb(width: 20, height: 20, alpha: true) { _, _ in (0, 0, 0, 0) }
        let url = try Fixtures.write(clear, to: dir.appendingPathComponent("a.png"), type: .png)
        let result = try executor.run(skill([.encode(EncodeSpec(format: .jpg, quality: 0.95))]), input: url)
        let p = Fixtures.pixel(Fixtures.rgba(Fixtures.cgImage(of: result.data), in: Fixtures.sRGB), width: 20, x: 10, y: 10)
        #expect(p.r > 245 && p.g > 245 && p.b > 245)
    }

    // MARK: 목표 파일 크기

    @Test(arguments: [300_000, 120_000, 40_000])
    func jpegStaysUnderTargetBytes(limit: Int) throws {
        let dir = try Fixtures.makeTempDir()
        let url = try Fixtures.write(Fixtures.noise(width: 1200, height: 900), to: dir.appendingPathComponent("n.png"), type: .png)
        let result = try executor.run(skill([.encode(EncodeSpec(format: .jpg, quality: 0.95, maxBytes: limit))]), input: url)
        #expect(result.data.count <= limit, "\(result.data.count)바이트로 \(limit)를 넘었어요")
        #expect(result.data.count > limit / 4, "필요 이상으로 많이 줄였어요 (\(result.data.count))")
        #expect(result.width <= 1200 && result.height <= 900)
        _ = Fixtures.cgImage(of: result.data)             // 열리는 파일이어야 한다
    }

    @Test func webpIsReportedHonestlyWhenTheMacCannotWriteIt() throws {
        let dir = try Fixtures.makeTempDir()
        let url = try Fixtures.write(Fixtures.noise(width: 40, height: 40), to: dir.appendingPathComponent("w.png"), type: .png)
        if FileSkillExecutor.canWrite(.webp) {
            _ = try executor.run(skill([.encode(EncodeSpec(format: .webp))]), input: url)
        } else {
            #expect(throws: FileSkillError.unsupportedFormat("WebP")) {
                try executor.run(skill([.encode(EncodeSpec(format: .webp))]), input: url)
            }
        }
    }

    @Test func unreadableAndWrongKindFilesAreRefusedWithDifferentErrors() throws {
        let dir = try Fixtures.makeTempDir()
        let fake = dir.appendingPathComponent("not-a-photo.jpg")           // 이름만 .jpg, 내용은 글자
        try "hello".write(to: fake, atomically: true, encoding: .utf8)
        #expect(throws: FileSkillError.unreadable("not-a-photo.jpg")) {
            try executor.run(skill([.encode(EncodeSpec(format: .jpg))]), input: fake)
        }

        // 진짜 PDF는 읽을 수 있는 파일이지만 사진 스킬로 바꿀 수는 없다
        let pdf = dir.appendingPathComponent("doc.pdf")
        var box = CGRect(x: 0, y: 0, width: 100, height: 100)
        let context = CGContext(pdf as CFURL, mediaBox: &box, nil)!
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        #expect(FileKindDetector.kind(of: pdf) == .pdf)
        #expect(throws: FileSkillError.wrongKind(file: "doc.pdf")) {
            try executor.run(skill([.encode(EncodeSpec(format: .jpg))]), input: pdf)
        }
    }

    // MARK: 원본 옆 저장

    @Test func savesBesideOriginalWithoutOverwritingAndLeavesOriginalUntouched() throws {
        let dir = try Fixtures.makeTempDir()
        let original = try Fixtures.write(Fixtures.noise(width: 300, height: 200), to: dir.appendingPathComponent("DSC0001.jpg"), type: .jpeg)
        let before = try Fixtures.sha256(original)
        let modified = try FileManager.default.attributesOfItem(atPath: original.path)[.modificationDate] as? Date

        var outputs: [URL] = []
        for _ in 0..<3 { outputs.append(try FileJob.run(DefaultFileSkills.web, input: original, executor: executor)) }

        #expect(outputs.map(\.lastPathComponent) == ["DSC0001_web.jpg", "DSC0001_web (1).jpg", "DSC0001_web (2).jpg"])
        #expect(outputs.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL })
        #expect(try Fixtures.sha256(original) == before)
        #expect(try FileManager.default.attributesOfItem(atPath: original.path)[.modificationDate] as? Date == modified)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test func existingFilesAreNeverOverwritten() throws {
        let dir = try Fixtures.makeTempDir()
        let original = try Fixtures.write(Fixtures.noise(width: 50, height: 50), to: dir.appendingPathComponent("a.jpg"), type: .jpeg)
        let precious = dir.appendingPathComponent("a_web.jpg")
        try Data("내 소중한 파일".utf8).write(to: precious)
        let output = try FileJob.run(DefaultFileSkills.web, input: original, executor: executor)
        #expect(output.lastPathComponent == "a_web (1).jpg")
        #expect(try String(contentsOf: precious, encoding: .utf8) == "내 소중한 파일")
    }

    @Test func unsafeSuffixAndReadOnlyFolderAreRefused() throws {
        let dir = try Fixtures.makeTempDir()
        let original = try Fixtures.write(Fixtures.noise(width: 20, height: 20), to: dir.appendingPathComponent("a.jpg"), type: .jpeg)
        #expect(throws: FileSkillError.unsafeOutputPath) {
            try FileOutputWriter.save(Data([1]), fileExtension: "jpg", suffix: "/../escape", besideOriginal: original)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        #expect(throws: FileSkillError.self) {
            try FileOutputWriter.save(Data([1]), fileExtension: "jpg", suffix: "_x", besideOriginal: original)
        }
    }

    // MARK: 스킬 JSON

    @Test func defaultPresetsRoundTripThroughJSON() throws {
        for preset in DefaultFileSkills.photoPresets {
            try preset.validate()
            let data = try JSONEncoder().encode(preset)
            #expect(try JSONDecoder().decode(FileSkill.self, from: data) == preset)
        }
    }

    @Test func planExampleJSONDecodes() throws {
        let json = """
        { "name": "웹용", "id": "web", "input": ["image", "raw"],
          "steps": [
            { "block": "decode" },
            { "block": "colorspace", "to": "sRGB" },
            { "block": "resize", "longEdge": 2048 },
            { "block": "metadata", "mode": "removeGPS", "artist": "Jane Doe", "copyright": "© Jane Doe" },
            { "block": "encode", "format": "jpg", "maxBytes": 2000000 } ],
          "output": { "suffix": "_web" } }
        """
        let skill = try JSONDecoder().decode(FileSkill.self, from: Data(json.utf8))
        try skill.validate()
        #expect(skill.steps.count == 5)
        #expect(skill.steps[2] == .resize(.longEdge(2048)))
        #expect(skill.output.suffix == "_web")
    }

    @Test func unknownBlockAndBrokenSkillsAreRejected() throws {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(FileStep.self, from: Data(#"{"block":"deleteOriginal"}"#.utf8))
        }
        let noEncode = FileSkill(id: "x", name: "x", input: [.image], steps: [.decode, .resize(.longEdge(10))], output: FileOutput(suffix: "_x"))
        #expect(throws: FileSkillError.self) { try noEncode.validate() }
        let encodeNotLast = FileSkill(id: "x", name: "x", input: [.image], steps: [.encode(EncodeSpec(format: .jpg)), .resize(.longEdge(10))], output: FileOutput(suffix: "_x"))
        #expect(throws: FileSkillError.self) { try encodeNotLast.validate() }
        let decodeNotFirst = FileSkill(id: "x", name: "x", input: [.image], steps: [.resize(.longEdge(10)), .decode, .encode(EncodeSpec(format: .jpg))], output: FileOutput(suffix: "_x"))
        #expect(throws: FileSkillError.self) { try decodeNotFirst.validate() }
    }

    @Test func fileKindComesFromContentNotExtension() throws {
        let dir = try Fixtures.makeTempDir()
        let png = try Fixtures.write(Fixtures.noise(width: 8, height: 8), to: dir.appendingPathComponent("really-a-png.jpg"), type: .png)
        #expect(FileKindDetector.kind(of: png) == .image)
        let text = dir.appendingPathComponent("note.png")
        try "hello".write(to: text, atomically: true, encoding: .utf8)
        #expect(FileKindDetector.kind(of: text) == nil)
    }
}
