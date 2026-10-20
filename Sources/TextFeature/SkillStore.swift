import AppCore
import AppKit
import SkillEngine
import SwiftUI

/// 스킬은 ~/Library/Application Support/Prism/skills.json 한 파일에 저장한다.
/// 사람이 직접 열어 고칠 수 있고, 팝업을 열 때마다 바뀐 게 있으면 다시 읽는다.
/// 설정 창에서 켜고 끄거나 순서를 바꾸면 이 파일에 바로 저장된다.
package enum SkillStoreError: LocalizedError {
    case fileHasProblem, saveFailed

    package var errorDescription: String? {
        switch self {
        case .fileHasProblem: return L("skills.json에 오류가 있어서 저장하지 않았어요. 파일을 먼저 고쳐줘", "skills.json has errors, so nothing was saved. Fix the file first")
        case .saveFailed: return L("skills.json에 저장하지 못했어요", "Couldn't save to skills.json")
        }
    }
}

@MainActor
package final class SkillStore: ObservableObject {
    private static let supportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    package static let folderURL = supportURL.appendingPathComponent("Prism", isDirectory: true)
    package static let fileURL = folderURL.appendingPathComponent("skills.json")
    /// 앱 이름이 TextPopup이던 시절의 폴더. 있으면 한 번만 새 폴더로 옮긴다.
    private static let legacyFolderURL = supportURL.appendingPathComponent("TextPopup", isDirectory: true)

    package init() {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: Self.folderURL.path),
           fileManager.fileExists(atPath: Self.legacyFolderURL.path) {
            try? fileManager.moveItem(at: Self.legacyFolderURL, to: Self.folderURL)
            log.info("moved skills folder from TextPopup to Prism")
        }
    }

    @Published package private(set) var skills: [Skill] = DefaultSkills.all
    /// skills.json을 못 읽었을 때의 이유. 이때는 마지막으로 잘 읽힌 목록을 계속 쓴다.
    @Published package private(set) var problem: String?
    private var loadedModificationDate: Date?

    package var visibleSkills: [Skill] { skills.filter(\.isVisibleInPopup) }

    package func refresh() {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: Self.fileURL.path) {
            save(DefaultSkills.all)
            return
        }
        let modified = modificationDate()
        guard modified == nil || modified != loadedModificationDate else { return }
        loadedModificationDate = modified

        do {
            let file = try SkillFile.decode(Data(contentsOf: Self.fileURL))
            skills = file.skills
            problem = nil
            log.info("loaded \(file.skills.count, privacy: .public) skills")
        } catch {
            problem = L("skills.json 오류: \(SkillFile.describe(error))", "skills.json error: \(SkillFile.describe(error))")
            log.error("skills.json failed: \(SkillFile.describe(error), privacy: .public)")
        }
    }

    // MARK: - 설정 창에서 바꾸기

    package func setVisible(_ visible: Bool, for id: String) {
        update { skills in
            guard let index = skills.firstIndex(where: { $0.id == id }) else { return }
            skills[index].showInPopup = visible ? nil : false
        }
    }

    package func move(from source: IndexSet, to destination: Int) {
        update { $0.move(fromOffsets: source, toOffset: destination) }
    }

    /// 새 스킬을 목록 맨 뒤에 추가. 저장하면 팝업에서 쓸 번호(⌘n)를 돌려준다(9번 넘으면 nil).
    @discardableResult
    package func add(_ skill: Skill) -> Result<Int?, SkillStoreError> {
        refresh()
        guard problem == nil else { return .failure(.fileHasProblem) }
        var copy = skills
        copy.append(skill)
        save(copy)
        guard problem == nil else { return .failure(.saveFailed) }
        let number = (visibleSkills.firstIndex { $0.id == skill.id } ?? 99) + 1
        return .success(number <= 9 ? number : nil)
    }

    package func delete(_ id: String) {
        update { $0.removeAll { $0.id == id } }
    }

    private func update(_ change: (inout [Skill]) -> Void) {
        refresh()
        // 파일에 오류가 있을 때 저장하면 사용자가 손으로 고치던 내용이 날아가므로 막는다.
        guard problem == nil else { return }
        var copy = skills
        change(&copy)
        save(copy)
    }

    private func save(_ newSkills: [Skill]) {
        do {
            try FileManager.default.createDirectory(at: Self.folderURL, withIntermediateDirectories: true)
            try SkillFile(skills: newSkills).encoded().write(to: Self.fileURL, options: .atomic)
            skills = newSkills
            problem = nil
            loadedModificationDate = modificationDate()
        } catch {
            problem = L("skills.json을 저장하지 못했어요: \(error.localizedDescription)", "Couldn't save skills.json: \(error.localizedDescription)")
        }
    }

    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: Self.fileURL.path))?[.modificationDate] as? Date
    }

    // MARK: - 파일 열기

    package func openInEditor() {
        refresh()
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open([Self.fileURL], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
    }

    package func revealInFinder() {
        refresh()
        NSWorkspace.shared.activateFileViewerSelecting([Self.fileURL])
    }
}
