import Testing
@testable import SkillEngine

struct SkillAuthoringTests {
    @Test(arguments: [
        ("문장마다 줄바꿈하는 스킬 만들어줘", true),
        ("빈 줄 지우는 스킬 추가해줘", true),
        ("이걸 스킬로 저장해줘", true),
        ("make a skill that removes tabs", true),
        ("존댓말로 바꿔줘", false),
        ("스킬 목록 좀 보여줘", false),
        ("이 텍스트 정리해줘", false),
    ])
    func detectsCreationRequests(text: String, expected: Bool) {
        #expect(SkillAuthoring.isCreationRequest(text) == expected)
    }

    @Test func parsesDraftWrappedInNoise() throws {
        let raw = """
        <think>let me think</think>
        ```json
        {"possible": true, "name": "문장마다 줄바꿈", "symbol": "text.alignleft",
         "steps": [{"block":"removeLineBreaks"},{"block":"breakAfterSentences"}]}
        ```
        """
        #expect(try SkillAuthoring.parse(raw) == .draft(SkillDraft(
            name: "문장마다 줄바꿈", symbol: "text.alignleft",
            steps: [.removeLineBreaks(), .breakAfterSentences()]
        )))
    }

    @Test func parsesConditionAndDropsUnknownSymbol() throws {
        let raw = #"{"possible":true,"name":"x","symbol":"made.up.symbol","steps":[{"block":"if","condition":{"type":"hasLineBreaks"},"then":[{"block":"removeLineBreaks"}]}]}"#
        guard case .draft(let draft) = try SkillAuthoring.parse(raw) else { Issue.record("expected draft"); return }
        #expect(draft.symbol == nil)
        #expect(draft.steps == [.ifCondition(.hasLineBreaks, then: [.removeLineBreaks()])])
    }

    @Test func impossibleRequest() throws {
        let raw = #"{"possible": false, "reason": "번역은 기본 블록으로 못 만들어요"}"#
        #expect(try SkillAuthoring.parse(raw) == .impossible(reason: "번역은 기본 블록으로 못 만들어요"))
    }

    @Test func rejectsInventedBlocksWithReadableError() {
        let raw = #"{"possible": true, "name": "요약", "steps": [{"block":"summarize"}]}"#
        #expect {
            try SkillAuthoring.parse(raw)
        } throws: { error in
            (error as? SkillAuthoringError)?.errorDescription?.contains("summarize") == true
        }
    }

    @Test func rejectsEmptyAndNonJSON() {
        #expect(throws: SkillAuthoringError.noSteps) { try SkillAuthoring.parse(#"{"possible":true,"name":"a","steps":[]}"#) }
        #expect(throws: SkillAuthoringError.notJSON) { try SkillAuthoring.parse("죄송하지만 만들 수 없어요") }
    }

    /// 설명서 속 예시들이 실제로 읽히는 올바른 JSON인지(AI가 그대로 따라 하므로 틀리면 안 됨)
    @Test func promptExamplesAreValid() throws {
        let examples = SkillAuthoring.systemPrompt
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("{\"possible\"") }
        #expect(examples.count == 5)
        for example in examples {
            _ = try SkillAuthoring.parse(example)
        }
    }
}
