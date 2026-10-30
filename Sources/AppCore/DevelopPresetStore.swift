import Foundation
import SkillEngine

/// 휠의 현상 프리셋 세 칸. 한라봉과 Hanlabong Developing이 같은 파일을 같이 읽고 쓴다.
/// ~/Library/Application Support/DragEdit/develop-presets.json (사람이 읽을 수 있는 JSON)
package enum DevelopPresetStore {
    package static let slotCount = 3
    package static var fileURL: URL { AppPaths.supportFolder.appendingPathComponent("develop-presets.json") }

    /// 항상 세 칸. 파일이 없거나 망가졌으면 기본값으로 채운다
    package static func load(from url: URL = fileURL) -> [DevelopPreset] {
        var presets = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([DevelopPreset].self, from: $0) } ?? []
        let defaults = DevelopPreset.defaults
        if presets.count < slotCount { presets += defaults[presets.count..<slotCount] }
        return Array(presets.prefix(slotCount))
    }

    package static func save(_ presets: [DevelopPreset], to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Array(presets.prefix(slotCount))).write(to: url, options: .atomic)
    }

    /// 칸 하나를 바꿔 저장
    package static func replace(slot: Int, with preset: DevelopPreset, at url: URL = fileURL) throws {
        var presets = load(from: url)
        guard presets.indices.contains(slot) else { return }
        presets[slot] = DevelopPreset(id: presets[slot].id, name: preset.name, settings: preset.settings)
        try save(presets, to: url)
    }

    /// 프리셋 → 휠에서 바로 돌리는 스킬. 원본 형식 그대로 저장하고(RAW 등 못 쓰는 형식은 JPG), 촬영 정보는 남긴다
    package static func skill(for preset: DevelopPreset) -> FileSkill {
        FileSkill(id: preset.id, name: preset.name, symbol: preset.settings.blackAndWhite ? "circle.lefthalf.filled" : "camera.filters",
                  input: [.image, .raw],
                  steps: [.decode, .develop(preset.settings), .colorspace(.keep), .metadata(MetadataSpec(mode: .keepAll)),
                          .encode(EncodeSpec(format: .jpg, quality: 0.95, sameAsInput: true))],
                  output: FileOutput(suffix: "_dev"))
    }
}
