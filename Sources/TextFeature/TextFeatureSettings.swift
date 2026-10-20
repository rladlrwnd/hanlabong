import SkillEngine
import AppCore
import SwiftUI

/// 글자 팝업이 AppCore의 설정 창에 끼워 넣는 것들: 스킬 탭, 일반 탭의 모양 미리보기·단축키·스킬 파일 경로.
@MainActor
package enum TextFeatureSettings {
    package static func skillsTab(store: SkillStore, agents: AgentStore) -> SettingsTab {
        SettingsTab(id: "skills", title: L("스킬", "Skills"), systemImage: "wand.and.stars", onShow: { store.refresh() }) {
            AnyView(SkillsTab(store: store, agents: agents))
        }
    }

    package static func generalExtras() -> GeneralSettingsExtras {
        GeneralSettingsExtras(
            appearanceEditing: { AppearancePreview.shared.editing($0) },
            shortcuts: [
                SettingsInfoRow(L("팝업 열기", "Open popup"), "⌥ Space"),
                SettingsInfoRow(L("스킬 실행", "Run skill"), L("⌘1 ~ ⌘9 · 숫자 · ↑↓ + ⏎", "⌘1–⌘9 · numbers · ↑↓ + ⏎")),
                SettingsInfoRow(L("원래대로", "Undo"), "⌘Z"),
            ],
            info: [SettingsInfoRow(L("스킬 파일", "Skills file"), SkillStore.fileURL.path(percentEncoded: false))]
        )
    }
}
