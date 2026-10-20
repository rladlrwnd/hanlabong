import AppCore
import SkillEngine
import SwiftUI

// 설정 창의 "스킬" 탭: 스킬 켜고 끄기·순서·삭제·새로 만들기. (AppCore의 설정 창 틀에 끼워 넣는다)

struct SkillsTab: View {
    @ObservedObject var store: SkillStore
    @ObservedObject var agents: AgentStore
    @State private var creating = false
    @State private var pendingDelete: Skill?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Text(L("팝업에 보여줄 스킬을 켜고, 끌어서 순서를 바꿔. 켜진 스킬만 위에서부터 ⌘1~⌘9가 붙어. 지우려면 오른쪽 클릭.", "Turn on the skills to show in the popup and drag to reorder. Enabled skills get ⌘1–⌘9 from the top. Right-click to delete."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button {
                    creating = true
                } label: {
                    Label(L("새 스킬 만들기", "New skill"), systemImage: "plus")
                }
                .buttonStyle(.glassProminent)
            }

            if let problem = store.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            List {
                ForEach(store.skills) { skill in
                    SkillSettingsRow(skill: skill, number: number(for: skill)) { visible in
                        store.setVisible(visible, for: skill.id)
                    }
                    .contextMenu {
                        Button(L("“\(skill.name)” 삭제…", "Delete “\(skill.name)”…"), role: .destructive) { pendingDelete = skill }
                    }
                }
                .onMove { store.move(from: $0, to: $1) }
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .sheet(isPresented: $creating) {
                SkillCreatorView(store: store, agents: agents) { creating = false }
            }
            .confirmationDialog(
                L("“\(pendingDelete?.name ?? "")” 스킬을 지울까?", "Delete the “\(pendingDelete?.name ?? "")” skill?"),
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
            ) {
                Button(L("삭제", "Delete"), role: .destructive) {
                    if let skill = pendingDelete { store.delete(skill.id) }
                    pendingDelete = nil
                }
            } message: {
                Text(L("skills.json에서 빠져. 되돌리려면 다시 만들어야 해.", "It's removed from skills.json. To get it back you'd have to recreate it."))
            }

            HStack {
                Button(L("스킬 파일 편집…", "Edit skills file…")) { store.openInEditor() }
                Button(L("파일 위치 보기", "Show file")) { store.revealInFinder() }
                Spacer()
                Text(L("\(store.visibleSkills.count)개 표시 중", "\(store.visibleSkills.count) shown"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func number(for skill: Skill) -> Int? {
        guard let index = store.visibleSkills.firstIndex(where: { $0.id == skill.id }), index < 9 else { return nil }
        return index + 1
    }
}

struct SkillSettingsRow: View {
    let skill: Skill
    let number: Int?
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: skill.symbol ?? "wand.and.stars")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.primary.opacity(0.07)))
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name)
                    .font(.system(size: 13.5, weight: .medium))
                Text(skill.steps.map(\.displayName).joined(separator: " → ") + (skill.id.hasPrefix("custom-") ? L("  · AI가 만듦", "  · made by AI") : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if let number {
                Text("⌘\(number)")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Toggle(L("팝업에 표시", "Show in popup"), isOn: Binding(get: { skill.isVisibleInPopup }, set: onToggle))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
        .padding(.vertical, 4)
        .opacity(skill.isVisibleInPopup ? 1 : 0.55)
    }
}
