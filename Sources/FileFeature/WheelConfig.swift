import AppCore
import Foundation
import SkillEngine

/// 어떤 휠인지(입력 파일 종류에 따라 내용이 바뀐다)
package enum WheelKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case image, pdf, text, video

    package var id: String { rawValue }
    package var title: String {
        switch self {
        case .image: return L("사진 휠", "Photo wheel")
        case .pdf: return L("PDF 휠", "PDF wheel")
        case .text: return L("글 휠", "Text wheel")
        case .video: return L("영상 휠", "Video wheel")
        }
    }
}

/// 휠 칸 하나의 설정: 놓으면 실행되는 것 하나(`action`) 또는 2단계 묶음(`group` + `children`)
package struct WheelSlotConfig: Codable, Equatable, Identifiable, Sendable {
    package var id = UUID()
    package var action: String?
    package var group: String?
    package var symbol: String?
    package var children: [String]?

    private enum CodingKeys: String, CodingKey { case action, group, symbol, children }

    package static func action(_ id: String) -> WheelSlotConfig { WheelSlotConfig(action: id) }
    package static func group(_ title: String, symbol: String, _ children: [String]) -> WheelSlotConfig {
        WheelSlotConfig(group: title, symbol: symbol, children: children)
    }

    package var isGroup: Bool { group != nil }

    /// 같은 칸인지는 내용으로 본다(id는 설정 화면 목록용이라 저장하지 않는다)
    package static func == (lhs: WheelSlotConfig, rhs: WheelSlotConfig) -> Bool {
        lhs.action == rhs.action && lhs.group == rhs.group && lhs.symbol == rhs.symbol && lhs.children == rhs.children
    }
}

/// 휠 구성 + 사진 프리셋. `~/Library/Application Support/Prism/file-wheels.json`에 저장한다(사람이 읽고 고칠 수 있는 JSON).
package struct WheelConfig: Codable, Equatable, Sendable {
    package static let maxSlots = 8
    /// 2단계 묶음 안의 칸 수 상한(이보다 많으면 바깥 링이 한 바퀴를 넘는다)
    package static let maxChildren = 6

    package var version = WheelConfig.currentVersion
    /// 2: 변환 휠은 형식 바꾸기만(편집·What is it·글자 넣기는 도구 휠로)
    package static let currentVersion = 3   // 3: 벡터 재구성·한글 칸
    /// 사진 프리셋(기본 3개 포함, 고칠 수 있다)
    package var presets: [FileSkill]
    package var image: [WheelSlotConfig]
    package var pdf: [WheelSlotConfig]
    package var text: [WheelSlotConfig] = WheelConfig.defaultText
    package var video: [WheelSlotConfig] = WheelConfig.defaultVideo

    private enum CodingKeys: String, CodingKey { case version, presets, image, pdf, text, video }

    package init(presets: [FileSkill], image: [WheelSlotConfig], pdf: [WheelSlotConfig],
                 text: [WheelSlotConfig] = WheelConfig.defaultText, video: [WheelSlotConfig] = WheelConfig.defaultVideo) {
        self.presets = presets
        self.image = image
        self.pdf = pdf
        self.text = text
        self.video = video
    }

    /// 예전 파일(글 휠 칸이 없던 때)도 읽는다
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        presets = try c.decode([FileSkill].self, forKey: .presets)
        image = try c.decode([WheelSlotConfig].self, forKey: .image)
        pdf = try c.decode([WheelSlotConfig].self, forKey: .pdf)
        text = try c.decodeIfPresent([WheelSlotConfig].self, forKey: .text) ?? Self.defaultText
        video = try c.decodeIfPresent([WheelSlotConfig].self, forKey: .video) ?? Self.defaultVideo
        if version < Self.currentVersion {
            // 변환 휠과 도구 휠에 같은 칸이 겹치지 않게 새 기본 휠로 바꾼다(사진 프리셋은 그대로)
            image = Self.defaultImage; pdf = Self.defaultPDF; text = Self.defaultText; video = Self.defaultVideo
            version = Self.currentVersion
        }
    }

    package static let defaultImage: [WheelSlotConfig] = [
        .group("JPG", symbol: "photo", DefaultFileSkills.photoPresets.map(\.id)),
        .group("PDF", symbol: "doc.richtext", [DefaultFileSkills.imageToPlainPDF.id, DefaultFileSkills.imageToSearchablePDF.id, DefaultFileSkills.vectorPDF.id, DefaultFileSkills.vectorSVG.id]),
        .group("TXT", symbol: "text.alignleft", [DefaultFileSkills.imageToText.id, "ocr-ai"]),
        .group(L("형식", "Format"), symbol: "arrow.triangle.2.circlepath", DefaultFileSkills.formatPresets.map(\.id)),
    ]

    package static let defaultPDF: [WheelSlotConfig] = [
        .action(DefaultFileSkills.pdfToWord.id),
        .group(L("텍스트", "Text"), symbol: "text.alignleft", [DefaultFileSkills.pdfToPlainText.id, "doc-md"]),
        .group(L("이미지", "Image"), symbol: "photo", [DefaultFileSkills.pdfToJPG.id, DefaultFileSkills.pdfToPNG.id]),
        .action(DefaultFileSkills.pdfToPPTX.id),
        .action(DefaultFileSkills.pdfToXLSX.id),
        .action("doc-epub"),
        .group(L("기타", "More"), symbol: "ellipsis.circle", ["doc-html", "doc-rtf", "doc-odt"]),
        .action("doc-hwpx"),
    ]

    /// 글·문서(Word·RTF·ODT·HTML·Markdown·텍스트·EPUB…): 서로 아무거나로. 같은 형식 칸은 휠에서 뺀다.
    package static let defaultText: [WheelSlotConfig] = [
        .action("doc-pdf"),
        .action("doc-docx"),
        .group(L("텍스트", "Text"), symbol: "text.alignleft", ["doc-txt", "doc-md"]),
        .action("doc-html"),
        .action("doc-epub"),
        .group(L("기타", "More"), symbol: "ellipsis.circle", ["doc-hwpx", "doc-rtf", "doc-odt"]),
    ]

    package static let defaultVideo: [WheelSlotConfig] = [
        .group("MP4", symbol: "film", DefaultFileSkills.videoPresets.map(\.id)),
        .action("video-mov"),
        .action("video-mkv"),
        .action("video-webm"),
        .action("video-avi"),
        .action("video-wmv"),
        .action("video-gif"),
        .group(L("소리", "Audio"), symbol: "music.note", [DefaultFileSkills.videoToMP3.id, DefaultFileSkills.videoAudio.id]),
    ]

    package static var `default`: WheelConfig {
        WheelConfig(presets: DefaultFileSkills.photoPresets, image: defaultImage, pdf: defaultPDF)
    }

    package func slots(for kind: WheelKind) -> [WheelSlotConfig] {
        switch kind {
        case .image: return image
        case .pdf: return pdf
        case .text: return text
        case .video: return video
        }
    }

    package mutating func setSlots(_ slots: [WheelSlotConfig], for kind: WheelKind) {
        let capped = Array(slots.prefix(Self.maxSlots)).map { slot -> WheelSlotConfig in
            var slot = slot
            if let children = slot.children { slot.children = Array(children.prefix(Self.maxChildren)) }
            return slot
        }
        switch kind {
        case .image: image = capped
        case .pdf: pdf = capped
        case .text: text = capped
        case .video: video = capped
        }
    }

    /// 휠에 놓을 수 있는 것 하나를 휠 칸으로 만든다(없는 이름이면 nil)
    package func item(_ id: String, ai: AIDestination?) -> WheelItem? {
        if let preset = presets.first(where: { $0.id == id }) { return WheelItem(skill: preset) }
        return WheelActionCatalog.builtin(id, ai: ai)
    }

    /// 이 휠에 넣을 수 있는 것들(설정의 "칸 추가" 목록)
    package func availableActions(for kind: WheelKind) -> [(id: String, title: String, symbol: String)] {
        let presetEntries = kind == .image ? presets.map { ($0.id, $0.name, $0.symbol ?? "photo") } : []
        return presetEntries + WheelActionCatalog.builtins(for: kind).map { ($0.id, $0.title, $0.symbol) }
    }

    /// 이름 → 사람이 읽는 이름(설정 목록용)
    package func title(of id: String) -> String {
        presets.first { $0.id == id }?.name ?? WheelKind.allCases.lazy.compactMap { WheelActionCatalog.builtins(for: $0).first { $0.id == id }?.title }.first ?? id
    }

    package func symbol(of id: String) -> String {
        presets.first { $0.id == id }?.symbol ?? WheelKind.allCases.lazy.compactMap { WheelActionCatalog.builtins(for: $0).first { $0.id == id }?.symbol }.first ?? "questionmark"
    }
}

/// 앱이 원래 가진, 휠에 놓을 수 있는 것들(사진 프리셋은 설정에 따로 있다)
package enum WheelActionCatalog {
    package struct Entry {
        package let id: String
        package let title: String
        package let symbol: String
    }

    package static func builtins(for kind: WheelKind) -> [Entry] {
        switch kind {
        case .image:
            return [
                Entry(id: DefaultFileSkills.imageToPlainPDF.id, title: L("그냥 PDF", "Plain PDF"), symbol: "doc"),
                Entry(id: DefaultFileSkills.imageToSearchablePDF.id, title: L("글자 넣은 PDF", "Searchable PDF"), symbol: "doc.text.magnifyingglass"),
                Entry(id: DefaultFileSkills.imageToText.id, title: L("OCR 텍스트", "OCR text"), symbol: "text.viewfinder"),
                Entry(id: "ocr-ai", title: L("AI 오타수정", "AI typo fix"), symbol: "sparkles"),
                Entry(id: DefaultFileSkills.vectorPDF.id, title: L("벡터 PDF (로고·선화)", "Vector PDF (logos · line art)"), symbol: "scribble"),
                Entry(id: DefaultFileSkills.vectorSVG.id, title: L("벡터 SVG (로고·선화)", "Vector SVG (logos · line art)"), symbol: "scribble.variable"),
            ] + DefaultFileSkills.allFormatConversions.map { Entry(id: $0.id, title: L("\($0.name)로 바꾸기", "Convert to \($0.name)"), symbol: $0.symbol ?? "photo") }
        case .pdf:
            return [
                Entry(id: DefaultFileSkills.pdfToWord.id, title: "Word", symbol: "doc.text"),
                Entry(id: DefaultFileSkills.pdfToPlainText.id, title: L("텍스트", "Text"), symbol: "text.alignleft"),
            ] + ([DefaultFileSkills.pdfToJPG, DefaultFileSkills.pdfToPNG, DefaultFileSkills.pdfToPPTX, DefaultFileSkills.pdfToXLSX]
                 + DefaultFileSkills.documentConversions.filter { $0.id != "doc-pdf" && $0.id != "doc-docx" && $0.id != "doc-txt" })
                .map { Entry(id: $0.id, title: $0.name, symbol: $0.symbol ?? "doc") }
        case .text:
            return DefaultFileSkills.documentConversions.map { Entry(id: $0.id, title: $0.name, symbol: $0.symbol ?? "doc") }
        case .video:
            return (DefaultFileSkills.videoPresets + DefaultFileSkills.videoFormats + [DefaultFileSkills.videoToMP3, DefaultFileSkills.videoAudio])
                .map { Entry(id: $0.id, title: $0.name, symbol: $0.symbol ?? "film") }
        }
    }

    static func builtin(_ id: String, ai: AIDestination?) -> WheelItem? {
        let skills = [DefaultFileSkills.imageToPlainPDF, DefaultFileSkills.imageToSearchablePDF, DefaultFileSkills.imageToText,
                      DefaultFileSkills.pdfToWord, DefaultFileSkills.pdfToPlainText, DefaultFileSkills.pdfAddText]
            + DefaultFileSkills.videoPresets + [DefaultFileSkills.videoAudio] + DefaultFileSkills.allFormatConversions
            + DefaultFileSkills.documentConversions + DefaultFileSkills.videoFormats
            + [DefaultFileSkills.videoToMP3, DefaultFileSkills.pdfToJPG, DefaultFileSkills.pdfToPNG, DefaultFileSkills.pdfToPPTX, DefaultFileSkills.pdfToXLSX, DefaultFileSkills.gifToMP4, DefaultFileSkills.vectorPDF, DefaultFileSkills.vectorSVG]
        if let skill = skills.first(where: { $0.id == id }) { return WheelItem(skill: skill) }
        switch id {
        case "ocr-ai": return WheelLayout.aiTypoFixItem(ai)
        case "whatis": return WheelLayout.whatIsItem(ai)
        case "vector": return WheelItem(id: "vector", title: L("벡터 재구성", "Vectorize"), symbol: "scribble.variable", subtitle: L("곧 지원해요", "Coming soon"), isComingSoon: true)
        case "crop": return WheelItem(id: "crop", title: L("편집", "Edit"), symbol: "crop", subtitle: L("자르기·회전·보정", "Crop · rotate · adjust"), edit: .image)
        case "vedit": return WheelItem(id: "vedit", title: L("편집", "Edit"), symbol: "scissors", subtitle: L("구간 자르기·소리 끄기", "Trim · mute"), edit: .video)
        case "hwp": return WheelItem(id: "hwp", title: L("한글", "Hangul"), symbol: "doc.richtext", subtitle: L("곧 지원해요 (.hwpx)", "Coming soon (.hwpx)"), isComingSoon: true)
        default: return nil
        }
    }
}

extension WheelLayout {
    /// 설정대로 휠을 짠다. 사라진 프리셋 같은 없는 이름은 빈칸이 된다.
    package static func build(_ kind: WheelKind, config: WheelConfig, ai: AIDestination?) -> WheelLayout {
        let slots = config.slots(for: kind).prefix(WheelConfig.maxSlots).map { slot -> WheelItem? in
            if let action = slot.action { return config.item(action, ai: ai) }
            let children = (slot.children ?? []).prefix(WheelConfig.maxChildren).compactMap { config.item($0, ai: ai) }
            let title = slot.group ?? ""
            return WheelItem(id: title.lowercased(), title: title, symbol: slot.symbol ?? "square.grid.2x2",
                             subtitle: children.isEmpty ? L("비어 있어요 · 설정에서 채워줘", "Empty · fill it in Settings") : L("바깥 칸에 놓기", "Drop on an outer slot"), children: children)
        }
        return WheelLayout(slots: Array(slots))
    }
}

// MARK: - 저장

@MainActor
package final class WheelConfigStore: ObservableObject {
    package nonisolated static let defaultURL = AppPaths.supportFolder.appendingPathComponent("file-wheels.json")

    @Published package private(set) var config: WheelConfig
    /// 파일을 못 읽었을 때의 이유(이때는 기본값을 쓰고, 파일은 덮어쓰지 않는다)
    @Published package private(set) var problem: String?
    private let url: URL

    package init(url: URL = WheelConfigStore.defaultURL) {
        self.url = url
        if let data = try? Data(contentsOf: url) {
            do {
                config = try JSONDecoder().decode(WheelConfig.self, from: data)
            } catch {
                config = .default
                problem = L("file-wheels.json을 읽지 못해서 기본 휠을 쓰고 있어요", "Couldn't read file-wheels.json, using the default wheels")
            }
        } else {
            config = .default
        }
    }

    package func update(_ change: (inout WheelConfig) -> Void) {
        var next = config
        change(&next)
        next.setSlots(next.image, for: .image)
        next.setSlots(next.pdf, for: .pdf)
        next.setSlots(next.text, for: .text)
        next.setSlots(next.video, for: .video)
        guard next != config else { return }
        config = next
        problem = nil
        save()
    }

    package func resetWheel(_ kind: WheelKind) {
        let defaults: [WheelSlotConfig]
        switch kind {
        case .image: defaults = WheelConfig.defaultImage
        case .pdf: defaults = WheelConfig.defaultPDF
        case .text: defaults = WheelConfig.defaultText
        case .video: defaults = WheelConfig.defaultVideo
        }
        update { $0.setSlots(defaults, for: kind) }
    }

    // MARK: 프리셋

    package func savePreset(_ preset: FileSkill) {
        update { config in
            if let index = config.presets.firstIndex(where: { $0.id == preset.id }) { config.presets[index] = preset }
            else { config.presets.append(preset) }
        }
    }

    /// 복제해서 새 프리셋을 만들고 사진 휠의 같은 묶음에도 넣는다. 새 id를 돌려준다.
    @discardableResult
    package func duplicatePreset(_ id: String) -> String? {
        guard let source = config.presets.first(where: { $0.id == id }) else { return nil }
        var copy = source
        copy.id = "preset-" + UUID().uuidString.prefix(8).lowercased()
        copy.name = source.name + L(" 복사본", " copy")
        copy.output.suffix = source.output.suffix + "_2"
        update { config in
            config.presets.append(copy)
            if let slot = config.image.firstIndex(where: { $0.children?.contains(id) == true }),
               (config.image[slot].children?.count ?? 0) < WheelConfig.maxChildren {
                config.image[slot].children?.append(copy.id)
            }
        }
        return copy.id
    }

    /// 프리셋을 지우면 휠에서도 뺀다
    package func deletePreset(_ id: String) {
        update { config in
            config.presets.removeAll { $0.id == id }
            config.image = config.image.compactMap { slot in
                if slot.action == id { return nil }
                var slot = slot
                slot.children?.removeAll { $0 == id }
                return slot
            }
        }
    }

    /// 기본 프리셋(웹용·클라이언트 샘플·미리보기)을 처음 값으로. 내가 만든 프리셋은 그대로 둔다.
    package func resetDefaultPresets() {
        update { config in
            for preset in DefaultFileSkills.photoPresets {
                if let index = config.presets.firstIndex(where: { $0.id == preset.id }) { config.presets[index] = preset }
                else { config.presets.insert(preset, at: 0) }
            }
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(config).write(to: url, options: .atomic)
        } catch {
            log.error("wheel config save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - 프리셋 편집용 모양

/// 사진 프리셋을 설정 화면에서 고치기 쉬운 모양으로. 블록 목록 ↔ 칸들로 오간다.
package struct PhotoPresetDraft: Equatable {
    package enum ResizeMode: String, CaseIterable, Identifiable {
        case none, longEdge, shortEdge, percent
        package var id: String { rawValue }
        package var title: String {
            switch self {
            case .none: return L("원래 크기", "Original size")
            case .longEdge: return L("긴 변", "Long edge")
            case .shortEdge: return L("짧은 변", "Short edge")
            case .percent: return L("비율(%)", "Percent (%)")
            }
        }
    }

    package var id: String
    package var name: String
    package var symbol: String
    package var suffix: String
    package var colorspace: ColorSpaceTarget = .keep
    package var resizeMode: ResizeMode = .none
    package var resizeValue: Double = 2048
    package var metadataMode: MetadataMode = .keepAll
    package var artist = ""
    package var copyright = ""
    package var watermarkOn = false
    package var watermarkText = ""
    package var watermarkPosition: WatermarkPosition = .bottomRight
    package var watermarkOpacity = 0.6
    package var watermarkSize = 20.0
    package var watermarkMargin = 2.5
    package var format: OutputFormat = .jpg
    package var quality = 0.9
    package var limitSize = false
    package var maxMegabytes = 2.0

    package init(_ skill: FileSkill) {
        id = skill.id
        name = skill.name
        symbol = skill.symbol ?? "photo"
        suffix = skill.output.suffix
        for step in skill.steps {
            switch step {
            case .colorspace(let target): colorspace = target
            case .resize(let spec, _):
                switch spec {
                case .longEdge(let n): resizeMode = .longEdge; resizeValue = Double(n)
                case .shortEdge(let n): resizeMode = .shortEdge; resizeValue = Double(n)
                case .percent(let p): resizeMode = .percent; resizeValue = p
                }
            case .metadata(let spec):
                metadataMode = spec.mode
                artist = spec.artist ?? ""
                copyright = spec.copyright ?? ""
            case .watermark(let spec):
                watermarkOn = true
                watermarkText = spec.text ?? ""
                watermarkPosition = spec.position
                watermarkOpacity = spec.opacity
                watermarkSize = spec.sizePercent
                watermarkMargin = spec.marginPercent
            case .encode(let spec):
                format = spec.format
                quality = spec.quality ?? 0.9
                if let max = spec.maxBytes { limitSize = true; maxMegabytes = Double(max) / 1_000_000 }
            default:
                break
            }
        }
    }

    /// 정해진 순서(읽기 → 색 → 크기 → 워터마크 → 메타데이터 → 저장)의 블록으로
    package var skill: FileSkill {
        var steps: [FileStep] = [.decode, .colorspace(colorspace)]
        switch resizeMode {
        case .none: break
        case .longEdge: steps.append(.resize(.longEdge(max(1, Int(resizeValue)))))
        case .shortEdge: steps.append(.resize(.shortEdge(max(1, Int(resizeValue)))))
        case .percent: steps.append(.resize(.percent(max(1, resizeValue))))
        }
        if watermarkOn, !watermarkText.trimmingCharacters(in: .whitespaces).isEmpty {
            steps.append(.watermark(WatermarkSpec(text: watermarkText, position: watermarkPosition, opacity: watermarkOpacity,
                                                  sizePercent: watermarkSize, marginPercent: watermarkMargin)))
        }
        steps.append(.metadata(MetadataSpec(mode: metadataMode, artist: artist.isEmpty ? nil : artist, copyright: copyright.isEmpty ? nil : copyright)))
        steps.append(.encode(EncodeSpec(format: format, quality: format.isLossy ? quality : nil,
                                        maxBytes: limitSize ? Int((maxMegabytes * 1_000_000).rounded()) : nil)))
        let safeSuffix = suffix.replacingOccurrences(of: "/", with: "").replacingOccurrences(of: "..", with: "")
        return FileSkill(id: id, name: name.isEmpty ? L("이름 없는 프리셋", "Untitled preset") : name, symbol: symbol,
                         input: [.image, .raw], steps: steps, output: FileOutput(suffix: safeSuffix))
    }
}
