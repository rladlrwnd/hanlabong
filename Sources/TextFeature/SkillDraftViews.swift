import AppCore
import SkillEngine
import SwiftUI

/// 스킬의 블록들을 번호와 함께 보여준다. 조건 블록 안쪽은 들여써서 "그러면/아니면"으로 나눈다.
package struct StepList: View {
    package let steps: [Step]
    package var fontSize: CGFloat = 12

    private struct Line: Identifiable {
        let id: Int
        let depth: Int
        let number: String?
        let text: String
        let isBranchLabel: Bool
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let number = line.number {
                        Text(number)
                            .font(.system(size: fontSize - 2, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(.primary.opacity(0.08)))
                    }
                    Text(line.text)
                        .font(.system(size: line.isBranchLabel ? fontSize - 1 : fontSize, weight: line.isBranchLabel ? .semibold : .regular))
                        .foregroundStyle(line.isBranchLabel ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, CGFloat(line.depth) * 18)
            }
        }
    }

    private var lines: [Line] {
        var result: [Line] = []
        func walk(_ steps: [Step], depth: Int) {
            for (index, step) in steps.enumerated() {
                result.append(Line(id: result.count, depth: depth, number: "\(index + 1)", text: step.displayName, isBranchLabel: false))
                if case .ifCondition(_, let then, let otherwise) = step {
                    result.append(Line(id: result.count, depth: depth + 1, number: nil, text: L("그러면", "then"), isBranchLabel: true))
                    walk(then, depth: depth + 1)
                    if !otherwise.isEmpty {
                        result.append(Line(id: result.count, depth: depth + 1, number: nil, text: L("아니면", "otherwise"), isBranchLabel: true))
                        walk(otherwise, depth: depth + 1)
                    }
                }
            }
        }
        walk(steps, depth: 0)
        return result
    }
}

/// 팝업 안: AI가 설계한 새 스킬 미리보기. 저장해야만 목록에 들어간다.
package struct DraftPanel: View {
    package let preview: SkillGenerator.Preview
    package let onSave: () -> Void
    package let onSaveAndApply: () -> Void
    package let onDiscard: () -> Void

    package var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: preview.skill.symbol ?? "wand.and.stars")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.08)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("새 스킬 미리보기", "New skill preview"))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(preview.skill.name)
                        .font(.system(size: 14, weight: .semibold))
                }
                Spacer(minLength: 0)
            }

            StepList(steps: preview.skill.steps)

            VStack(alignment: .leading, spacing: 4) {
                Text(preview.changesSample ? L("이 글자에 쓰면", "On this text") : L("이 글자에는 바뀌는 게 없어요 (다른 글에는 쓸 수 있어요)", "Nothing changes for this text (it may for other text)"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                if preview.changesSample {
                    Text(preview.result)
                        .font(.system(size: 12))
                        .lineLimit(4)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.05)))
                }
            }

            HStack(spacing: 6) {
                Button(action: onSave) { Text(L("저장  ⏎", "Save  ⏎")).font(.system(size: 12, weight: .semibold)) }
                    .buttonStyle(.glassProminent)
                if preview.changesSample {
                    Button(action: onSaveAndApply) { Text(L("저장하고 적용  ⌘⏎", "Save & apply  ⌘⏎")).font(.system(size: 12, weight: .medium)) }
                        .buttonStyle(.glass)
                }
                Spacer(minLength: 0)
                Button(action: onDiscard) { Text(L("취소  Esc", "Cancel  Esc")).font(.system(size: 12)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .controlSize(.small)
        }
        .padding(10)
    }
}
