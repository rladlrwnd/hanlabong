import Foundation
import SkillEngine
import UniformTypeIdentifiers

/// AI가 끼는 작업(검토 화면을 거친다)
package enum AITask: Equatable, Sendable {
    /// 사진 → 글자 인식 → 불확실한 곳만 AI가 고침 → 검토 → .txt
    case ocrTypoFix
    /// 글 파일·PDF → 요약 화면(Tab으로 심층 분석)
    case whatIs
}

/// 놓으면 편집 창이 열리는 칸(결과는 창에서 "저장"을 눌러야 만들어진다)
package enum EditKind: Equatable, Sendable {
    case image, video
}

/// 동작 휠(⌃) 칸: 파일을 바꾸지 않고 다루는 일. 폴더·여러 종류가 섞인 선택에도 쓴다.
package enum FileAction: Equatable, Sendable {
    case airDrop, float, copyPath, terminal
    /// 폴더로 복사·이동. 폴더가 nil이면 고르는 창을 띄운다.
    case copy(to: URL?)
    case move(to: URL?)
}

/// 휠 칸에 보여줄 "AI가 어디서 도는지"
package struct AIDestination: Equatable, Sendable {
    package var name: String
    package var isCloud: Bool

    package init(name: String, isCloud: Bool) {
        self.name = name
        self.isCloud = isCloud
    }

    package var label: String { isCloud ? L("\(name) · 클라우드로 보냄", "\(name) · sent to cloud") : L("\(name) · 이 컴퓨터", "\(name) · this computer") }
}

/// 휠 칸 하나. 놓으면 실행되는 스킬이 있거나(리프), 자식 칸을 펼치거나, 아직 준비 안 된 자리다.
package struct WheelItem: Identifiable, Equatable {
    package let id: String
    package let title: String
    package let symbol: String
    /// 휠 가운데에 보여주는 설명
    package var subtitle: String?
    /// 이 칸에 놓았을 때 실행할 스킬
    package var skill: FileSkill?
    package var children: [WheelItem] = []
    /// 자리만 잡아둔 칸(다음 단계에서 채운다)
    package var isComingSoon = false
    /// 놓으면 AI 작업을 시작하는 칸
    package var aiTask: AITask?
    /// 놓으면 편집 창을 여는 칸
    package var edit: EditKind?
    /// 동작 휠 칸
    package var fileAction: FileAction?

    package init(id: String, title: String, symbol: String, subtitle: String? = nil,
                 skill: FileSkill? = nil, children: [WheelItem] = [], isComingSoon: Bool = false, aiTask: AITask? = nil, edit: EditKind? = nil, fileAction: FileAction? = nil) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.subtitle = subtitle
        self.skill = skill
        self.children = children
        self.isComingSoon = isComingSoon
        self.aiTask = aiTask
        self.edit = edit
        self.fileAction = fileAction
    }

    /// 스킬 칸: 프리셋 이름 + 한 줄 설명
    package init(skill: FileSkill) {
        self.init(id: skill.id, title: skill.name, symbol: skill.symbol ?? "wand.and.stars", subtitle: skill.summary, skill: skill)
    }

    package var isDroppable: Bool { skill != nil || aiTask != nil || edit != nil || fileAction != nil }
}

/// 입력 파일 종류에 따라 내용이 바뀌는 휠. 칸 자리는 일관되게 두고 내용만 바뀐다.
package struct WheelLayout: Equatable {
    package var slots: [WheelItem?]
    /// 지원하지 않는 파일일 때 가운데에 보여줄 말
    package var emptyMessage: String?
    /// 어느 휠인지(가운데에 표시)
    package var mode: WheelMode = .convert

    package init(slots: [WheelItem?], emptyMessage: String? = nil, mode: WheelMode = .convert) {
        self.slots = slots + Array(repeating: nil, count: max(0, 8 - slots.count))
        self.emptyMessage = emptyMessage
        self.mode = mode
    }

    /// 이미지·RAW: 1단계 JPG(사진 프리셋) · PDF(그냥/글자 넣은 PDF) · TXT(OCR) · 자르기(준비 중).
    /// AI 오타수정 칸: 쓸 수 있는 AI가 있으면 어디서 도는지(이 컴퓨터/클라우드)를 보여주고, 없으면 잠가 둔다
    static func whatIsItem(_ ai: AIDestination?) -> WheelItem {
        guard let ai else {
            return WheelItem(id: "whatis", title: "What is it?", symbol: "questionmark.bubble",
                             subtitle: L("쓸 수 있는 AI가 없어요 · Ollama를 켜거나 API 키를 넣어줘", "No AI available · start Ollama or add an API key"), isComingSoon: true)
        }
        return WheelItem(id: "whatis", title: "What is it?", symbol: "questionmark.bubble",
                         subtitle: L("요약해줘요 · Tab으로 심층 분석 · \(ai.label)", "Summarizes · Tab for a deep dive · \(ai.label)"), aiTask: .whatIs)
    }

    static func aiTypoFixItem(_ ai: AIDestination?) -> WheelItem {
        guard let ai else {
            return WheelItem(id: "ocr-ai", title: L("AI 오타수정", "AI typo fix"), symbol: "sparkles",
                             subtitle: L("쓸 수 있는 AI가 없어요 · Ollama를 켜거나 API 키를 넣어줘", "No AI available · start Ollama or add an API key"), isComingSoon: true)
        }
        return WheelItem(id: "ocr-ai", title: L("AI 오타수정", "AI typo fix"), symbol: "sparkles",
                         subtitle: L("불확실한 곳만 AI가 고쳐요 · \(ai.label)", "AI fixes only uncertain spots · \(ai.label)"), aiTask: .ocrTypoFix)
    }

    /// 영상 휠: MP4(해상도·용량 프리셋) · 소리만 · 편집(구간 자르기·소리 끄기)
    package static func video(config: WheelConfig = .default) -> WheelLayout {
        build(.video, config: config, ai: nil)
    }

    /// 기본 사진 휠: JPG(사진 프리셋) · PDF(그냥/글자 넣은 PDF/벡터 준비 중) · TXT(OCR/AI 오타수정) · 자르기(준비 중)
    package static func image(ai: AIDestination? = nil, config: WheelConfig = .default) -> WheelLayout {
        build(.image, config: config, ai: ai)
    }

    /// 기본 PDF 휠: Word · 한글(준비 중) · 텍스트 · 글자 넣기
    package static func pdf(ai: AIDestination? = nil, config: WheelConfig = .default) -> WheelLayout {
        build(.pdf, config: config, ai: ai)
    }

    /// 글 파일(.txt·.md…): What is it?
    package static func text(ai: AIDestination? = nil, config: WheelConfig = .default) -> WheelLayout {
        build(.text, config: config, ai: ai)
    }

    package static let unsupported = WheelLayout(slots: [], emptyMessage: L("아직 지원하지 않는 파일이에요", "This file type isn't supported yet"))

    /// 끌고 있는 파일들의 확장자만 보고 고른다. 드롭 전에는 파일 내용을 열지 않는다(폴더 접근 권한 안내가 끌기 중에 뜨지 않게).
    /// 실제로 바꿀 때는 내용으로 다시 확인한다.
    package static func layout(forDraggedFileExtensions extensions: [String], ai: AIDestination? = nil,
                               config: WheelConfig = .default) -> WheelLayout {
        let kinds = Set(extensions.compactMap { FileKindGuess.kind(forExtension: $0) })
        if kinds.contains(.image) || kinds.contains(.raw) {
            var layout = WheelLayout.image(ai: ai, config: config)
            // 움직이는 GIF는 MP4로도
            if !extensions.isEmpty, extensions.allSatisfy({ $0.lowercased() == "gif" }), let free = layout.slots.firstIndex(where: { $0 == nil }) {
                layout.slots[free] = WheelItem(skill: DefaultFileSkills.gifToMP4)
            }
            return layout
        }
        if kinds.contains(.video) { return WheelLayout.video(config: config).withoutSameFormat(extensions) }
        if kinds.contains(.pdf) { return .pdf(ai: ai, config: config) }
        if kinds.contains(.text) {
            // PowerPoint·Excel·한글 파일은 글만 꺼낼 수 있어서 바꾸기는 안 하고(도구 휠의 What is it?은 된다)
            if extensions.contains(where: { ["pptx", "xlsx", "odp", "ods"].contains($0.lowercased()) }) { return .unsupported }
            return WheelLayout.text(ai: ai, config: config).withoutSameFormat(extensions)
        }
        return extensions.isEmpty ? .image(ai: ai, config: config) : .unsupported
    }

    /// 끌고 온 파일과 같은 형식으로 "바꾸는" 칸은 뺀다(예: .md 파일 휠에 Markdown 칸)
    func withoutSameFormat(_ extensions: [String]) -> WheelLayout {
        guard !extensions.isEmpty else { return self }
        func same(_ item: WheelItem) -> Bool {
            guard let last = item.skill?.steps.last else { return false }
            switch last {
            case .document(let format): return extensions.allSatisfy { format.matches(extension: $0) }
            case .video(let spec):
                guard let format = spec.format, spec.preset == .passthrough else { return false }
                return extensions.allSatisfy { $0.lowercased() == format.fileExtension }
            default: return false
            }
        }
        var copy = self
        copy.slots = slots.map { slot in
            guard var item = slot else { return nil }
            if same(item) { return nil }
            if !item.children.isEmpty {
                item.children.removeAll(where: same)
                if item.children.isEmpty { return nil }
            }
            return item
        }
        return copy
    }
}

/// 확장자로 하는 대략적인 종류 추정(파일을 열지 않는다). 휠 모양을 고르는 데만 쓴다.
package enum FileKindGuess {
    package static func kind(forExtension ext: String) -> FileKind? {
        if ext.lowercased() != "gif", FFmpeg.foreignVideoExtensions.contains(ext.lowercased()) { return .video }
        if ext.isEmpty { return .text }
        guard let type = UTType(filenameExtension: ext.lowercased()) else {
            return DocumentReaders.nonTextExtensions.contains(ext.lowercased()) ? nil : .text
        }
        if type.conforms(to: .rawImage) { return .raw }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .audio) || DocumentReaders.nonTextExtensions.contains(ext.lowercased()) { return nil }
        // 사진·영상·소리·압축 파일이 아니면 전부 What is it?으로(글을 못 찾으면 요약 창에서 알려준다)
        return .text
    }
}

/// 커서 위치에 따라 어느 칸이 눌려 있고 어느 칸이 펼쳐져 있는지 따라간다(화면과 분리된 순수 로직).
package struct WheelNavigator: Equatable {
    package let layout: WheelLayout
    package let geometry: WheelGeometry
    package private(set) var hover: WheelGeometry.Hit?
    /// 펼쳐진 1단계 칸. 다른 칸으로 옮겨가기 전까지 유지된다(빈틈·가운데를 지나갈 때 접히지 않게).
    package private(set) var expandedParent: Int?

    package init(layout: WheelLayout, geometry: WheelGeometry = WheelGeometry()) {
        self.layout = layout
        self.geometry = geometry
    }

    package mutating func move(to offset: CGPoint) {
        let childCount = expandedParent.flatMap { layout.slots[$0]?.children.count } ?? 0
        hover = geometry.hit(at: offset, expandedParent: expandedParent, childCount: childCount)
        if case .slot(let index) = hover {
            expandedParent = (layout.slots[index]?.children.isEmpty == false) ? index : nil
        } else if hover == nil, (offset.x * offset.x + offset.y * offset.y).squareRoot() < geometry.innerRadius {
            expandedParent = nil        // 가운데 원으로 돌아오면 2단계가 접힌다
        }
    }

    package mutating func leave() { hover = nil }

    package var hoveredItem: WheelItem? {
        switch hover {
        case .slot(let index)?: return layout.slots[index]
        case .child(let parent, let index)?: return layout.slots[parent]?.children[index]
        case nil: return nil
        }
    }

    /// 지금 놓으면 실행될 칸(스킬이 있는 칸)
    package var droppable: WheelItem? {
        guard let item = hoveredItem, item.isDroppable else { return nil }
        return item
    }
}
