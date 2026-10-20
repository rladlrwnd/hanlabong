import AppCore
import BotAvatarsKit
import SkillEngine
import SwiftUI
import ThinkingOrbsKit

/// 설정 › 스킬 › "새 스킬 만들기": 원하는 기능을 말로 설명 → AI가 블록을 조합 →
/// 시험용 글자로 미리보기 → 확인하고 저장.
package struct SkillCreatorView: View {
    @ObservedObject package var store: SkillStore
    @ObservedObject package var agents: AgentStore
    package let dismiss: () -> Void

    private enum Phase: Equatable {
        case idle
        case designing
        case ready(SkillGenerator.Preview)
        case impossible(String)
        case failed(String)
    }

    @State private var request = ""
    @State private var sample = """
    기존 줄바꿈이
    엉망인 문장입니다. Mr. Kim은 3.5배 빨랐다.그리고   공백도    많다...

    - 목록 하나
    - 목록 둘
    """
    @State private var phase: Phase = .idle
    @State private var name = ""
    @State private var task: Task<Void, Never>?

    package var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("새 스킬 만들기", "New skill"))
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 6) {
                Text(L("어떤 스킬이 필요해?", "What skill do you need?")).font(.headline)
                TextField(L("예: 빈 줄은 지우고 줄마다 앞에 “- ”를 붙여줘", "e.g. delete blank lines and put “- ” before every line"), text: $request, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
                    .onSubmit(design)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L("시험해볼 글자", "Test text")).font(.headline)
                TextEditor(text: $sample)
                    .font(.system(size: 12))
                    .frame(height: 84)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(0.05)))
            }

            HStack(spacing: 8) {
                if let agent = agents.agent(for: .skillAuthoring) {
                    BotAvatar(type: agent.avatar, state: phase == .designing ? .working : .default, size: 22,
                              paused: phase != .designing, shading: .smooth, interactive: false)
                        .frame(width: 26, height: 26)
                    Text(agent.isLocal ? L("\(agent.name) · 이 컴퓨터", "\(agent.name) · this computer") : L("\(agent.name) · 클라우드(요청과 시험 글자가 보내져요)", "\(agent.name) · cloud (your request and test text are sent)"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text(L("쓸 수 있는 AI가 없어요 — 에이전트 탭을 확인해줘", "No AI available — check the Agents tab"))
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button(phase == .designing ? L("만드는 중…", "Creating…") : L("만들기", "Create"), action: design)
                    .buttonStyle(.glassProminent)
                    .disabled(request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || agents.agent(for: .skillAuthoring) == nil || phase == .designing)
                    .keyboardShortcut(.return, modifiers: .command)
            }

            Divider()

            result
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack {
                Spacer()
                Button(L("닫기", "Close")) {
                    task?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                if case .ready = phase {
                    Button(L("저장", "Save"), action: save)
                        .buttonStyle(.glassProminent)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(24)
        .frame(width: 560, height: 660)
        .onDisappear { task?.cancel() }
    }

    @ViewBuilder
    private var result: some View {
        switch phase {
        case .idle:
            Text(L("만들기를 누르면 AI가 기본 블록(줄바꿈 없애기, 찾아 바꾸기, 조건 등)만 골라서 조합해. 코드를 새로 짜지 않아서 안전하고, 저장하기 전에 결과를 먼저 보여줄게.", "Create lets the AI combine only built-in blocks (remove line breaks, find & replace, conditions…). It writes no new code, so it's safe, and you see the result before saving."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .designing:
            HStack(spacing: 12) {
                ThinkingOrb(state: .shaping, size: .px64, displaySize: 44)
                    .frame(width: 44, height: 44)
                Text(L("블록 조합을 고르고, 시험 글자로 돌려보는 중…", "Choosing blocks and running them on the test text…"))
                    .foregroundStyle(.secondary)
            }
        case .impossible(let reason):
            Label(L("이건 스킬로 못 만들고 AI로만 가능해요. \(reason)", "This can't be a skill — AI only. \(reason)"), systemImage: "exclamationmark.bubble")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .ready(let preview):
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: preview.skill.symbol ?? "wand.and.stars")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .background(RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(0.08)))
                        TextField(L("스킬 이름", "Skill name"), text: $name)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 14, weight: .semibold))
                    }
                    StepList(steps: preview.skill.steps, fontSize: 12.5)
                    HStack(alignment: .top, spacing: 10) {
                        textBox(L("원래 글자", "Original text"), preview.sample)
                        textBox(preview.changesSample ? L("스킬을 쓰면", "With the skill") : L("바뀌는 게 없어요", "Nothing changes"), preview.result)
                    }
                }
            }
        }
    }

    private func textBox(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                Text(text)
                    .font(.system(size: 11.5))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 120)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(0.05)))
        }
    }

    private func design() {
        let request = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, let agent = agents.agent(for: .skillAuthoring), phase != .designing else { return }
        let apiKey = agent.provider.isCloud ? KeychainStore.key(for: agent.provider) : nil
        let cloudEnabled = agents.cloudEnabled
        let sample = sample
        phase = .designing
        task?.cancel()
        task = Task { @MainActor in
            do {
                let outcome = try await SkillGenerator.generate(
                    request: request, sample: sample, agent: agent, apiKey: apiKey, cloudEnabled: cloudEnabled
                )
                guard !Task.isCancelled else { return }
                switch outcome {
                case .ready(let preview):
                    name = preview.skill.name
                    phase = .ready(preview)
                case .impossible(let reason):
                    phase = .impossible(reason)
                }
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(L("스킬을 만들지 못했어요: \(error.localizedDescription)", "Couldn't create the skill: \(error.localizedDescription)"))
            }
        }
    }

    private func save() {
        guard case .ready(var preview) = phase else { return }
        preview.skill.name = name.trimmingCharacters(in: .whitespaces)
        switch store.add(preview.skill) {
        case .success:
            dismiss()
        case .failure(let error):
            phase = .failed(error.localizedDescription)
        }
    }
}
