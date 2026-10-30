import Foundation

/// 사진 내보내기 설정(라이트룸 "내보내기" 창을 참고): 위치·이름·형식·크기·선명하게·메타데이터·워터마크.
/// 마지막에 쓴 값을 기억해 두고 다음에 그대로 연다.
public struct PhotoExportSettings: Codable, Equatable, Sendable {
    public enum Destination: String, Codable, CaseIterable, Sendable { case beside, subfolder, folder }
    public enum Naming: String, Codable, CaseIterable, Sendable { case suffix, custom }
    public enum Sizing: String, Codable, CaseIterable, Sendable { case original, longEdge, shortEdge, fit, megapixels, percent }
    public enum Metadata: String, Codable, CaseIterable, Sendable { case all, noLocation, cameraOnly, copyrightOnly, none }

    // 위치
    public var destination = Destination.beside
    public var subfolderName = "Hanlabong Export"
    public var folderPath = ""
    // 이름: 원본 이름 + 붙일 글자, 또는 새 이름 + 번호(-1, -2…)
    public var naming = Naming.suffix
    public var suffix = "_dev"
    public var customName = "photo"
    // 형식
    public var format = OutputFormat.jpg
    public var quality = 90.0                 // 0~100
    public var limitFileSize = false
    public var maxKilobytes = 2000
    public var colorSpace = ColorSpaceTarget.sRGB
    // 크기
    public var sizing = Sizing.original
    public var size = 2048                    // 긴 변·짧은 변
    public var fitWidth = 1920, fitHeight = 1080
    public var megapixels = 12.0
    public var percent = 50.0
    public var dontEnlarge = true
    public var ppi = 300
    // 출력 선명하게
    public var sharpen = false
    public var sharpenMedium = OutputSharpening.Medium.screen
    public var sharpenAmount = OutputSharpening.Amount.standard
    // 메타데이터
    public var metadata = Metadata.noLocation
    public var artist = ""
    public var copyright = ""
    // 워터마크
    public var watermark = false
    public var watermarkText = ""
    public var watermarkPosition = WatermarkPosition.bottomRight
    public var watermarkOpacity = 0.6
    public var watermarkSize = 20.0
    // 내보낸 뒤
    public var revealInFinder = false

    public init() {}

    /// 빠진 값은 기본값으로(나중에 칸이 늘어도 예전 설정이 열리게)
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ current: inout T) throws { if let v = try c.decodeIfPresent(T.self, forKey: key) { current = v } }
        try read(.destination, &destination); try read(.subfolderName, &subfolderName); try read(.folderPath, &folderPath)
        try read(.naming, &naming); try read(.suffix, &suffix); try read(.customName, &customName)
        try read(.format, &format); try read(.quality, &quality); try read(.limitFileSize, &limitFileSize); try read(.maxKilobytes, &maxKilobytes)
        try read(.colorSpace, &colorSpace); try read(.sizing, &sizing); try read(.size, &size); try read(.fitWidth, &fitWidth); try read(.fitHeight, &fitHeight)
        try read(.megapixels, &megapixels); try read(.percent, &percent); try read(.dontEnlarge, &dontEnlarge); try read(.ppi, &ppi)
        try read(.sharpen, &sharpen); try read(.sharpenMedium, &sharpenMedium); try read(.sharpenAmount, &sharpenAmount)
        try read(.metadata, &metadata); try read(.artist, &artist); try read(.copyright, &copyright)
        try read(.watermark, &watermark); try read(.watermarkText, &watermarkText); try read(.watermarkPosition, &watermarkPosition)
        try read(.watermarkOpacity, &watermarkOpacity); try read(.watermarkSize, &watermarkSize); try read(.revealInFinder, &revealInFinder)
    }

    /// 현상 값 + 이 설정 → 한 장을 만드는 스킬
    public func skill(develop: DevelopSettings) -> FileSkill {
        var steps: [FileStep] = [.decode]
        if !develop.isNeutral { steps.append(.develop(develop)) }
        let resize: ResizeSpec?
        switch sizing {
        case .original: resize = nil
        case .longEdge: resize = .longEdge(max(1, size))
        case .shortEdge: resize = .shortEdge(max(1, size))
        case .fit: resize = .fit(width: max(1, fitWidth), height: max(1, fitHeight))
        case .megapixels: resize = .megapixels(max(0.1, megapixels))
        case .percent: resize = .percent(max(1, percent))
        }
        if let resize { steps.append(.resize(resize, allowUpscale: !dontEnlarge)) }
        if sharpen { steps.append(.sharpen(OutputSharpening(medium: sharpenMedium, amount: sharpenAmount))) }
        let text = watermarkText.trimmingCharacters(in: .whitespaces)
        if watermark, !text.isEmpty {
            steps.append(.watermark(WatermarkSpec(text: text, position: watermarkPosition, opacity: watermarkOpacity, sizePercent: watermarkSize)))
        }
        steps.append(.colorspace(colorSpace))
        steps.append(.metadata(metadataSpec))
        steps.append(.encode(EncodeSpec(format: format, quality: format.isLossy ? min(max(quality, 1), 100) / 100 : nil,
                                        maxBytes: limitFileSize && format.isLossy ? max(10, maxKilobytes) * 1000 : nil, dpi: ppi > 0 ? ppi : nil)))
        return FileSkill(id: "photo-export", name: L("내보내기", "Export"), symbol: "square.and.arrow.up", input: [.image, .raw], steps: steps,
                         output: FileOutput(suffix: naming == .suffix ? suffix : ""))
    }

    var metadataSpec: MetadataSpec {
        let a = artist.trimmingCharacters(in: .whitespaces), c = copyright.trimmingCharacters(in: .whitespaces)
        let who = (a.isEmpty ? nil : a, c.isEmpty ? nil : c)
        switch metadata {
        case .all: return MetadataSpec(mode: .keepAll, artist: who.0, copyright: who.1)
        case .noLocation: return MetadataSpec(mode: .removeGPS, artist: who.0, copyright: who.1)
        case .cameraOnly: return MetadataSpec(mode: .keepCameraOnly, artist: who.0, copyright: who.1)
        case .copyrightOnly: return MetadataSpec(mode: .removeAll, artist: who.0, copyright: who.1)
        case .none: return MetadataSpec(mode: .removeAll)
        }
    }

    /// 결과를 둘 곳과 이름. `index`는 여러 장을 새 이름으로 내보낼 때의 번호(1부터)
    /// 반환값은 "이 자리에 원본이 있다고 치고" 쓰는 기준 경로라서, 저장할 때 같은 이름이 있으면 번호를 붙여 피한다.
    public func target(for original: URL, index: Int) throws -> URL {
        let folder: URL
        switch destination {
        case .beside: folder = original.deletingLastPathComponent()
        case .subfolder:
            let name = subfolderName.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains("/"), !name.contains("..") else { throw FileSkillError.unsafeOutputPath }
            folder = original.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        case .folder:
            guard !folderPath.isEmpty else { throw FileSkillError.outputFolderNotWritable("—") }
            folder = URL(fileURLWithPath: folderPath, isDirectory: true)
        }
        switch naming {
        case .suffix:
            return folder.appendingPathComponent(original.lastPathComponent)
        case .custom:
            let base = customName.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
            return folder.appendingPathComponent("\(base.isEmpty ? "photo" : base)-\(index).\(original.pathExtension)")
        }
    }

    /// 한 장 내보내기: 만들고, 정한 곳에 정한 이름으로 저장(같은 이름이 있으면 번호를 붙여 피한다)
    @discardableResult
    public func export(_ input: URL, develop: DevelopSettings, index: Int, executor: FileSkillExecutor = FileSkillExecutor()) throws -> URL {
        let skill = skill(develop: develop)
        let result = try executor.run(skill, input: input)
        let place = try target(for: input, index: index)
        return try FileOutputWriter.save(result.data, fileExtension: result.fileExtension, suffix: skill.output.suffix, besideOriginal: place)
    }
}
