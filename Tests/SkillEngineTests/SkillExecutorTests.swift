import Foundation
import Testing
@testable import SkillEngine

struct SkillExecutorTests {
    private func run(_ steps: [Step], _ text: String) throws -> String {
        try SkillExecutor.run(steps, on: text)
    }

    // 사용자 예시: "기존 줄바꿈을 모두 없애고 문장 단위로 줄바꿈해줘"
    @Test func sentenceLinesSkill() throws {
        let skill = DefaultSkills.all.first { $0.id == "sentence-lines" }!
        let input = "기존 줄바꿈을\n모두 없애고. 문장\r\n단위로 바꾼다.  Mr. Kim은\n3.5배 빨랐다."
        #expect(try SkillExecutor.run(skill, on: input)
            == "기존 줄바꿈을 모두 없애고.\n문장 단위로 바꾼다.\nMr. Kim은 3.5배 빨랐다.")
    }

    @Test func removeLineBreaksKeepsParagraphs() throws {
        let text = "첫 줄\n이어짐\n\n두 번째\n문단"
        #expect(try run([.removeLineBreaks()], text) == "첫 줄 이어짐 두 번째 문단")
        #expect(try run([.removeLineBreaks(keepParagraphs: true)], text) == "첫 줄 이어짐\n\n두 번째 문단")
        #expect(try run([.removeLineBreaks(replacement: "")], "가나\n다라") == "가나다라")
    }

    @Test func trimAndSpaces() throws {
        #expect(try run([.collapseSpaces], "a    b\t\tc d") == "a b c d")
        #expect(try run([.trim()], "  \n hi \n ") == "hi")
        #expect(try run([.trim(perLine: true)], "  a  \n  b ") == "a\nb")
        #expect(try run([.removeEmptyLines], "a\n\n  \nb") == "a\nb")
        // 줄 끝 공백만 지우기: 앞쪽 들여쓰기는 남는다
        #expect(try run([.replace(find: "\t", with: "    "), .trim(perLine: true, side: .end)], "\tx  \n\ty\t") == "    x\n    y")
        #expect(try run([.trim(perLine: true, side: .start)], "  a  \n b ") == "a  \nb ")
        #expect(try run([.trim(side: .end)], "\n a \n\n") == "\n a")
    }

    @Test func regexAnchorsMatchEachLine() throws {
        #expect(try run([.replace(find: "^", with: "> ", regex: true)], "a\nb") == "> a\n> b")
        #expect(try run([.replace(find: "[ \\t]+$", with: "", regex: true)], "a  \nb\t") == "a\nb")
    }

    @Test func replace() throws {
        #expect(try run([.replace(find: "사과", with: "배")], "사과 사과") == "배 배")
        #expect(try run([.replace(find: "HELLO", with: "hi", caseSensitive: false)], "hello Hello") == "hi hi")
        #expect(try run([.replace(find: "(\\d+)원", with: "$1 KRW", regex: true)], "3000원") == "3000 KRW")
        #expect(try run([.replace(find: "", with: "x")], "abc") == "abc")
        #expect(throws: SkillError.invalidRegex("(")) { try run([.replace(find: "(", with: "", regex: true)], "a") }
    }

    @Test func caseAndLines() throws {
        #expect(try run([.changeCase(.upper)], "hello world") == "HELLO WORLD")
        #expect(try run([.changeCase(.lower)], "HeLLo") == "hello")
        #expect(try run([.addToLines(prefix: "- ", suffix: ";")], "a\n\nb") == "- a;\n\n- b;")
        #expect(try run([.addToLines(prefix: "> ", skipEmpty: false)], "a\n") == "> a\n> ")
    }

    @Test func conditions() throws {
        let joinIfMultiline: [Step] = [.ifCondition(.hasLineBreaks, then: [.removeLineBreaks()], else: [.changeCase(.upper)])]
        #expect(try run(joinIfMultiline, "a\nb") == "a b")
        #expect(try run(joinIfMultiline, "a b") == "A B")

        #expect(try SkillExecutor.evaluate(.contains("KIM", caseSensitive: false), on: "mr. kim"))
        #expect(try SkillExecutor.evaluate(.matches("^\\d{3}-\\d{4}$"), on: "010-1234"))
        #expect(try SkillExecutor.evaluate(.matches("^\\d{3}-\\d{4}$"), on: "010-12345") == false)
        #expect(try SkillExecutor.evaluate(.not(.startsWith("http")), on: "ftp://x"))
        #expect(try SkillExecutor.evaluate(.endsWith("다."), on: "했다."))
    }

    @Test func tooDeepIsRejected() {
        var steps: [Step] = [.changeCase(.upper)]
        for _ in 0..<20 { steps = [.ifCondition(.hasLineBreaks, then: [], else: steps)] }
        #expect(throws: SkillError.tooDeep) { try SkillExecutor.run(steps, on: "x") }
    }
}

struct SkillFileTests {
    @Test func defaultsRoundTrip() throws {
        let file = SkillFile(skills: DefaultSkills.all)
        #expect(try SkillFile.decode(file.encoded()) == file)
    }

    @Test func readsHandWrittenJSON() throws {
        let json = """
        { "version": 1, "skills": [ {
            "id": "x", "name": "문장 단위로 정리",
            "steps": [ { "block": "removeLineBreaks" },
                       { "block": "if", "condition": { "type": "contains", "text": "http" },
                         "then": [ { "block": "trim" } ],
                         "else": [ { "block": "changeCase", "to": "upper" } ] } ] } ] }
        """
        let file = try SkillFile.decode(Data(json.utf8))
        #expect(file.skills[0].steps == [
            .removeLineBreaks(),
            .ifCondition(.contains("http"), then: [.trim()], else: [.changeCase(.upper)]),
        ])
    }

    @Test func popupVisibilityIsOnlyWrittenWhenHidden() throws {
        let shown = String(decoding: try SkillFile(skills: [Skill(id: "a", name: "a", steps: [])]).encoded(), as: UTF8.self)
        #expect(!shown.contains("showInPopup"))
        let hidden = try SkillFile(skills: [Skill(id: "a", name: "a", showInPopup: false, steps: [])]).encoded()
        #expect(try SkillFile.decode(hidden).skills[0].isVisibleInPopup == false)
    }

    @Test func toleratesSmartQuotesFromTextEdit() throws {
        let json = "{ “version”: 1, “skills”: [ { “id”: “a”, “name”: “대문자”, “steps”: [ { “block”: “changeCase”, “to”: “upper” } ] } ] }"
        #expect(try SkillFile.decode(Data(json.utf8)).skills[0].name == "대문자")
    }

    @Test func unknownBlockGivesReadableError() {
        let json = #"{ "version": 1, "skills": [ { "id": "a", "name": "b", "steps": [ { "block": "teleport" } ] } ] }"#
        do {
            _ = try SkillFile.decode(Data(json.utf8))
            Issue.record("should fail")
        } catch {
            #expect(SkillFile.describe(error).contains("teleport"))
        }
    }
}
