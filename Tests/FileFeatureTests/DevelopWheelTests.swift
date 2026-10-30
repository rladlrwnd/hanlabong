import AppCore
import Foundation
import SkillEngine
import Testing
@testable import FileFeature

/// 도구 휠의 현상 칸: 프리셋 세 개 + "…", 프리셋 파일 저장·읽기
struct DevelopWheelTests {
    @Test func photoToolsHaveDevelopWithThreePresetsAndMore() {
        let layout = WheelLayout.tools(forDraggedFileExtensions: ["jpg"])
        guard let develop = layout.slots.compactMap({ $0 }).first(where: { $0.id == "develop" }) else { Issue.record("no develop"); return }
        #expect(develop.children.count == 4)
        #expect(develop.children.last?.edit == .addon(.developing))
        #expect(develop.children.prefix(3).allSatisfy { $0.skill?.steps.contains { if case .develop = $0 { return true } else { return false } } == true })
    }

    @Test func pdfToolsOfferTheAddon() {
        #expect(WheelLayout.tools(forDraggedFileExtensions: ["pdf"]).slots.compactMap { $0 }.contains { $0.edit == .addon(.pdf) })
    }

    @Test func presetStoreFillsMissingSlotsAndSaves() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dp-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(DevelopPresetStore.load(from: url).count == 3)          // 파일 없으면 기본 세 칸
        var mine = DevelopSettings(); mine.exposure = 1.2
        try DevelopPresetStore.replace(slot: 1, with: DevelopPreset(id: "x", name: "Mine", settings: mine), at: url)
        let loaded = DevelopPresetStore.load(from: url)
        #expect(loaded[1].name == "Mine" && loaded[1].settings.exposure == 1.2 && loaded[1].id == "develop-2")
        try Data("망가진 파일".utf8).write(to: url)
        #expect(DevelopPresetStore.load(from: url).count == 3)
    }
}
