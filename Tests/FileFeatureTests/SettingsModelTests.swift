import AppCore
import Foundation
import SkillEngine
import Testing
@testable import FileFeature

/// 설정(8단계): 프리셋 편집 모양, 휠 구성 저장·편집, 기능별 AI
@MainActor
struct SettingsModelTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("wheels-\(UUID().uuidString).json")
    }

    // MARK: 프리셋 편집 모양

    @Test(arguments: DefaultFileSkills.photoPresets)
    func defaultPresetsSurviveTheEditorUnchanged(preset: FileSkill) {
        // 열기만 해도 파일이 바뀌면 안 된다
        #expect(PhotoPresetDraft(preset).skill == preset)
    }

    @Test func editorBuildsCleanBlocks() {
        var draft = PhotoPresetDraft(DefaultFileSkills.clientSample)
        draft.resizeMode = .none
        draft.watermarkText = "   "                          // 빈 글자 워터마크는 넣지 않는다
        draft.format = .png
        draft.limitSize = false
        draft.suffix = "/../밖으로"
        let skill = draft.skill
        #expect(!skill.steps.contains { if case .resize = $0 { return true } else { return false } })
        #expect(!skill.steps.contains { if case .watermark = $0 { return true } else { return false } })
        #expect(skill.steps.last == .encode(EncodeSpec(format: .png, quality: nil, maxBytes: nil)))
        #expect(skill.output.suffix == "밖으로")
        #expect(throws: Never.self) { try skill.validate() }
    }

    @Test func sizeLimitInMegabytesBecomesBytes() {
        var draft = PhotoPresetDraft(DefaultFileSkills.preview)
        draft.limitSize = true
        draft.maxMegabytes = 1.5
        #expect(draft.skill.steps.last == .encode(EncodeSpec(format: .jpg, quality: 0.85, maxBytes: 1_500_000)))
    }

    // MARK: 휠 구성

    @Test func defaultConfigIsTheWheelWeShipped() {
        #expect(WheelLayout.build(.image, config: .default, ai: nil) == WheelLayout.image())
        #expect(WheelLayout.build(.pdf, config: .default, ai: nil) == WheelLayout.pdf())
        #expect(WheelLayout.image().slots.compactMap { $0?.id } == ["jpg", "pdf", "txt", "형식"])
    }

    @Test func editsAreSavedAndComeBackAfterRestart() {
        let url = tempURL()
        let store = WheelConfigStore(url: url)
        store.update { config in
            config.setSlots([.action(DefaultFileSkills.web.id), .group("내 묶음", symbol: "star", [DefaultFileSkills.imageToText.id])], for: .image)
        }
        let reopened = WheelConfigStore(url: url)
        #expect(reopened.config == store.config)
        let layout = WheelLayout.build(.image, config: reopened.config, ai: nil)
        #expect(layout.slots[0]?.skill == DefaultFileSkills.web)                      // 2단계 없이 바로 놓는 칸
        #expect(layout.slots[1]?.title == "내 묶음" && layout.slots[1]?.children.count == 1)
        #expect(layout.slots[2] == nil)
    }

    @Test func duplicatedPresetJoinsItsGroupAndDeletingRemovesItEverywhere() throws {
        let store = WheelConfigStore(url: tempURL())
        let newID = try #require(store.duplicatePreset(DefaultFileSkills.web.id))
        #expect(store.config.presets.count == 4)
        #expect(store.config.image[0].children?.last == newID)                       // JPG 묶음에 같이 들어간다
        let copy = try #require(store.config.presets.first { $0.id == newID })
        #expect(copy.output.suffix != DefaultFileSkills.web.output.suffix)          // 결과 파일 이름이 겹치지 않게
        store.deletePreset(newID)
        #expect(store.config.presets.count == 3)
        #expect(store.config.image[0].children == DefaultFileSkills.photoPresets.map(\.id))
    }

    @Test func wheelsAreCappedAtEightSlotsAndSixChildren() {
        let store = WheelConfigStore(url: tempURL())
        store.update { config in
            config.setSlots(Array(repeating: .action(DefaultFileSkills.web.id), count: 12), for: .pdf)
            config.image[0].children = Array(repeating: DefaultFileSkills.web.id, count: 10)
        }
        #expect(store.config.pdf.count == WheelConfig.maxSlots)
        #expect(store.config.image[0].children?.count == WheelConfig.maxChildren)
    }

    @Test func editedPresetIsWhatTheWheelRuns() {
        let store = WheelConfigStore(url: tempURL())
        var draft = PhotoPresetDraft(DefaultFileSkills.web)
        draft.resizeValue = 1080
        draft.name = "인스타"
        store.savePreset(draft.skill)
        let jpg = WheelLayout.build(.image, config: store.config, ai: nil).slots[0]
        #expect(jpg?.children.first?.title == "인스타")
        #expect(jpg?.children.first?.skill?.steps.contains(.resize(.longEdge(1080))) == true)
        store.resetDefaultPresets()
        #expect(store.config.presets.first == DefaultFileSkills.web)
    }

    @Test func brokenConfigFileFallsBackToDefaultsWithoutLosingTheFile() throws {
        let url = tempURL()
        try Data("{ 망가진 json".utf8).write(to: url)
        let store = WheelConfigStore(url: url)
        #expect(store.config == .default)
        #expect(store.problem != nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == "{ 망가진 json")      // 사용자가 고칠 수 있게 덮어쓰지 않는다
    }

    @Test func unknownActionsBecomeEmptySlotsInsteadOfCrashing() {
        var config = WheelConfig.default
        config.setSlots([.action("없는-스킬"), .action(DefaultFileSkills.pdfToWord.id)], for: .pdf)
        let layout = WheelLayout.build(.pdf, config: config, ai: nil)
        #expect(layout.slots[0] == nil)
        #expect(layout.slots[1]?.skill == DefaultFileSkills.pdfToWord)
    }

    // MARK: 기능별 AI · 클라우드로 자동으로 넘기지 않기

    private let qwen = Agent(provider: .ollama, model: "qwen3.6:27b", detail: "")
    private let gemma = Agent(provider: .ollama, model: "gemma4:12b", detail: "")
    private let claude = Agent(provider: .anthropic, model: "claude-haiku-5-5", detail: "")

    @Test func chosenLocalModelOffFallsBackOnlyToAnotherLocal() {
        #expect(AgentStore.resolveDefault(selectedID: qwen.id, local: [qwen, gemma], cloud: [claude]) == qwen)
        #expect(AgentStore.resolveDefault(selectedID: qwen.id, local: [gemma], cloud: [claude]) == gemma)
        #expect(AgentStore.resolveDefault(selectedID: qwen.id, local: [], cloud: [claude]) == nil)     // 클라우드로 안 넘어간다
        #expect(AgentStore.resolveDefault(selectedID: claude.id, local: [qwen], cloud: [claude]) == claude)
        #expect(AgentStore.resolveDefault(selectedID: nil, local: [], cloud: [claude]) == claude)    // 클라우드를 직접 켜고 키를 넣은 경우
    }

    @Test func featureOverrideNeverFallsBackToAnotherAgent() {
        #expect(AgentStore.resolve(overrideID: nil, defaultAgent: claude, available: [qwen, claude]) == claude)
        #expect(AgentStore.resolve(overrideID: qwen.id, defaultAgent: claude, available: [qwen, claude]) == qwen)
        #expect(AgentStore.resolve(overrideID: qwen.id, defaultAgent: claude, available: [claude]) == nil)  // 꺼져 있으면 멈춘다
    }
}

@MainActor
struct WhatIsWheelTests {
    @Test func whatIsLivesOnlyInTheToolsWheel() {
        let ai = AIDestination(name: "gemma4:12b", isCloud: false)
        for ext in ["txt", "md", "pdf", "docx"] {
            let tools = WheelLayout.layout(mode: .tools, extensions: [ext], containsFolders: false, ai: ai)
            #expect(tools.slots.contains { $0?.aiTask == .whatIs }, "\(ext)")
            #expect(tools.slots.compactMap { $0 }.first { $0.aiTask == .whatIs }?.subtitle?.contains("이 컴퓨터") == true)
            let convert = WheelLayout.layout(forDraggedFileExtensions: [ext], ai: ai)
            #expect(!convert.slots.contains { $0?.aiTask == .whatIs || $0?.edit != nil }, "\(ext)")   // 휠끼리 겹치는 칸 없음
        }
        let locked = WheelLayout.layout(mode: .tools, extensions: ["txt"], containsFolders: false, ai: nil)
        #expect(locked.slots[0]?.isDroppable == false)                                                  // AI 없으면 잠김
    }

    @Test func convertAndToolsWheelsNeverShareASlot() {
        for ext in ["jpg", "pdf", "md", "docx", "mp4"] {
            let convert = Set(WheelLayout.layout(forDraggedFileExtensions: [ext]).slots.compactMap { $0 }.flatMap { [$0.id] + $0.children.map(\.id) })
            let tools = Set(WheelLayout.tools(forDraggedFileExtensions: [ext]).slots.compactMap { $0 }.flatMap { [$0.id] + $0.children.map(\.id) })
            #expect(convert.isDisjoint(with: tools), "\(ext): \(convert.intersection(tools))")
        }
    }

    @Test func documentsConvertBothWaysButNotToThemselves() {
        let md = WheelLayout.layout(forDraggedFileExtensions: ["md"])
        let ids = Set(md.slots.compactMap { $0 }.flatMap { [$0.id] + $0.children.map(\.id) })
        #expect(ids.contains("doc-pdf") && ids.contains("doc-docx") && ids.contains("doc-txt") && !ids.contains("doc-md"))
        let docx = WheelLayout.layout(forDraggedFileExtensions: ["docx"])
        #expect(docx.slots[0]?.skill?.id == "doc-pdf" && !docx.slots.contains { $0?.id == "doc-docx" })   // Word → PDF
        #expect(WheelLayout.layout(forDraggedFileExtensions: ["pptx"]) == .unsupported)
    }

    @Test func oldConfigFilesWithoutTextWheelStillLoad() throws {
        var config = WheelConfig.default
        let data = try JSONEncoder().encode(config)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object["text"] = nil
        let old = try JSONSerialization.data(withJSONObject: object)
        config = try JSONDecoder().decode(WheelConfig.self, from: old)
        #expect(config.text == WheelConfig.defaultText)
    }
}

@MainActor
struct VideoWheelTests {
    private func offset(_ degrees: Double, _ radius: CGFloat) -> CGPoint {
        let r = degrees * .pi / 180
        return CGPoint(x: radius * CGFloat(sin(r)), y: radius * CGFloat(cos(r)))
    }

    @Test func videoFilesGetTheirOwnWheel() {
        for ext in ["mp4", "m4v"] {
            #expect(WheelLayout.layout(forDraggedFileExtensions: [ext]) == WheelLayout.video().withoutSameFormat([ext]))
        }
        let mov = WheelLayout.layout(forDraggedFileExtensions: ["mov"])
        #expect(!mov.slots.contains { $0?.id == "video-mov" } && mov.slots.contains { $0?.id == "video-mkv" })   // 같은 형식 칸은 빠짐
        #expect(WheelLayout.layout(forDraggedFileExtensions: ["mp4", "jpg"]).slots[0]?.id == "jpg")      // 사진이 우선
    }

    @Test func videoWheelHasPresetsFormatsAndSound() {
        var nav = WheelNavigator(layout: .video())
        nav.move(to: offset(0, 100))
        #expect(nav.expandedParent == 0 && nav.hoveredItem?.id == "mp4")
        #expect(WheelLayout.video().slots[0]?.children.compactMap(\.skill) == DefaultFileSkills.videoPresets)
        #expect(WheelLayout.video().slots.compactMap { $0?.id } == ["mp4", "video-mov", "video-mkv", "video-webm", "video-avi", "video-wmv", "video-gif", L("소리", "Audio").lowercased()])
        #expect(WheelLayout.video().slots[7]?.children.compactMap(\.skill) == [DefaultFileSkills.videoToMP3, DefaultFileSkills.videoAudio])
    }

    @Test func gifGetsAnMP4Slot() {
        #expect(WheelLayout.layout(forDraggedFileExtensions: ["gif"]).slots.contains { $0?.skill == DefaultFileSkills.gifToMP4 })
        #expect(!WheelLayout.layout(forDraggedFileExtensions: ["png"]).slots.contains { $0?.skill == DefaultFileSkills.gifToMP4 })
    }

    @Test func editOpensFromTheToolsWheel() {
        var nav = WheelNavigator(layout: WheelLayout.tools(forDraggedFileExtensions: ["jpg"]))
        nav.move(to: offset(0, 100))
        #expect(nav.droppable?.edit == .image)
        var video = WheelNavigator(layout: WheelLayout.tools(forDraggedFileExtensions: ["mp4"]))
        video.move(to: offset(0, 100))
        #expect(video.droppable?.edit == .video)
    }

    @Test func oldVersionConfigIsMigratedSoWheelsDontOverlap() throws {
        var old = WheelConfig.default
        old.version = 1
        old.image = [.action("crop")]
        let migrated = try JSONDecoder().decode(WheelConfig.self, from: JSONEncoder().encode(old))
        #expect(migrated.image == WheelConfig.defaultImage && migrated.version == WheelConfig.currentVersion)
    }

    @Test func oldConfigWithoutVideoWheelStillLoads() throws {
        let data = try JSONEncoder().encode(WheelConfig.default)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object["video"] = nil
        let config = try JSONDecoder().decode(WheelConfig.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(config.video == WheelConfig.defaultVideo)
    }
}

@MainActor
struct EverythingElseWheelTests {
    @Test func nonMediaFilesGetWhatIsAndMediaKeepTheirOwnWheels() {
        let ai = AIDestination(name: "gemma4:12b", isCloud: false)
        for ext in ["docx", "pptx", "xlsx", "hwpx", "html", "json", "csv", "swift", "rtf", "xyz", "log"] {
            #expect(WheelLayout.tools(forDraggedFileExtensions: [ext], ai: ai).slots[0]?.aiTask == .whatIs, "\(ext)")
        }
        for ext in ["mp3", "wav", "zip", "dmg", "ttf"] {
            #expect(WheelLayout.layout(forDraggedFileExtensions: [ext], ai: ai) == .unsupported, "\(ext)")
        }
        #expect(WheelLayout.layout(forDraggedFileExtensions: ["avi"]) == WheelLayout.video().withoutSameFormat(["avi"]))
        #expect(WheelLayout.layout(forDraggedFileExtensions: ["webp"]).slots[0]?.id == "jpg")
    }

    @Test func imageWheelHasAFormatGroupAndJPGOriginalSize() {
        let layout = WheelLayout.image()
        #expect(layout.slots[3]?.title == "형식")
        #expect(layout.slots[3]?.children.compactMap(\.skill) == DefaultFileSkills.formatPresets)
        #expect(layout.slots[3]?.children.first?.skill == DefaultFileSkills.toJPG)
    }
}

@MainActor
struct WheelModeTests {
    @Test func toolsAndActionsWheelsMatchTheFile() {
        let photo = WheelLayout.layout(mode: .tools, extensions: ["jpg"], containsFolders: false, ai: nil)
        #expect(photo.mode == .tools && photo.slots.compactMap { $0?.id } == ["crop", "rotate", "flip", "shrink"])
        #expect(photo.slots[1]?.children.compactMap(\.skill) == [DefaultFileSkills.rotateRight, DefaultFileSkills.rotateLeft, DefaultFileSkills.rotateHalf])
        let video = WheelLayout.layout(mode: .tools, extensions: ["mp4"], containsFolders: false, ai: nil)
        #expect(video.slots[1]?.skill == DefaultFileSkills.videoMute)
        let actions = WheelLayout.layout(mode: .actions, extensions: ["jpg"], containsFolders: false, ai: nil)
        #expect(actions.mode == .actions && actions.slots.compactMap { $0?.id } == ["airdrop", "float", "copy", "move", "copypath", "terminal"])
        #expect(actions.slots[2]?.fileAction == .copy(to: nil))                    // 최근 폴더가 없으면 바로 고르기
    }

    @Test func foldersAndUnconvertibleFilesGoStraightToActions() {
        #expect(WheelLayout.layout(mode: .convert, extensions: [""], containsFolders: true, ai: nil).mode == .actions)
        #expect(WheelLayout.layout(mode: .convert, extensions: ["zip"], containsFolders: false, ai: nil).mode == .actions)
        #expect(WheelLayout.layout(mode: .tools, extensions: ["mp3"], containsFolders: false, ai: nil).mode == .actions)
        #expect(WheelLayout.layout(mode: .convert, extensions: ["jpg"], containsFolders: false, ai: nil).mode == .convert)
    }

    @Test func recentFoldersBecomeASecondRing() {
        let folders = [URL(fileURLWithPath: "/tmp/a", isDirectory: true), URL(fileURLWithPath: "/tmp/b", isDirectory: true)]
        let layout = WheelLayout.actions(recentFolders: folders)
        let move = try! #require(layout.slots[3])
        #expect(move.children.map(\.fileAction) == [.move(to: folders[0]), .move(to: folders[1]), .move(to: nil)])
    }

    @Test func sameAsInputKeepsTheOriginalFormat() throws {
        let tool = DefaultFileSkills.rotateRight
        #expect(try JSONDecoder().decode(FileSkill.self, from: JSONEncoder().encode(tool)) == tool)
        #expect(OutputFormat.matching(extension: "PNG") == .png && OutputFormat.matching(extension: "raf") == nil)
    }
}

@MainActor
struct FileActionTests {
    @Test func uniqueNamesNeverOverwrite() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("사진.jpg")
        #expect(FileActionPerformer.uniqueURL(file) == file)
        try Data().write(to: file)
        #expect(FileActionPerformer.uniqueURL(file).lastPathComponent == "사진 (1).jpg")
        let folder = dir.appendingPathComponent("폴더", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(FileActionPerformer.uniqueURL(folder).lastPathComponent == "폴더 (1)")
    }
}
