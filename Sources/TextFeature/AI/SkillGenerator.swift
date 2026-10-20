import AppCore
import AppKit
import SkillEngine

/// 자연어 요청 → AI가 기본 블록을 골라 스킬을 설계 → 검사 → 시험용 글자에 미리 돌려본다.
/// AI 답이 형식에 안 맞거나 실행 중 오류가 나면, 무엇이 틀렸는지 알려주고 한 번 더 시킨다.
package enum SkillGenerator {
    package struct Preview: Equatable {
        package var skill: Skill
        package let sample: String
        package let result: String
        package var changesSample: Bool { SkillExecutor.normalizedForComparison(sample) != result }
    }

    package enum Outcome: Equatable {
        case ready(Preview)
        case impossible(String)
    }

    package static func generate(request: String, sample: String, agent: Agent, apiKey: String?, cloudEnabled: Bool) async throws -> Outcome {
        var messages: [AIClient.Message] = [.user(SkillAuthoring.userPrompt(request: request))]
        var lastError: Error = SkillAuthoringError.notJSON

        for attempt in 0..<2 {
            let raw = try await AIClient.complete(
                system: SkillAuthoring.systemPrompt, messages: messages, agent: agent,
                apiKey: apiKey, cloudEnabled: cloudEnabled, json: true, temperature: 0.1
            )
            try Task.checkCancellation()
            do {
                switch try SkillAuthoring.parse(raw) {
                case .impossible(let reason):
                    log.info("skill design: impossible")
                    return .impossible(reason)
                case .draft(let draft):
                    let skill = Skill(
                        id: "custom-" + UUID().uuidString.prefix(8).lowercased(),
                        name: draft.name,
                        symbol: validSymbol(draft.symbol),
                        steps: draft.steps
                    )
                    // 저장 전에 실제로 돌려봐서 오류(잘못된 정규식 등)가 없는지 확인
                    let result = try SkillExecutor.run(skill, on: sample)
                    log.info("skill design ok: \(draft.steps.count, privacy: .public) steps, attempt \(attempt + 1, privacy: .public)")
                    return .ready(Preview(skill: skill, sample: sample, result: result))
                }
            } catch {
                lastError = error
                log.error("skill design attempt \(attempt + 1, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                messages.append(.assistant(raw))
                messages.append(.user(
                    "That reply could not be used: \(error.localizedDescription). "
                    + "Reply again with one valid JSON object that uses only the listed blocks and conditions."
                ))
            }
        }
        throw lastError
    }

    private static func validSymbol(_ name: String?) -> String? {
        guard let name, NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil else { return nil }
        return name
    }
}
