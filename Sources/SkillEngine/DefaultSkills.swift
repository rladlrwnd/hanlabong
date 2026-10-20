/// 처음 실행할 때 skills.json에 넣어주는 기본 스킬들. 순서가 ⌘1~⌘9.
public enum DefaultSkills {
    public static let all: [Skill] = [
        Skill(
            id: "sentence-lines",
            name: L("문장마다 줄바꿈", "Line break per sentence"),
            symbol: "text.alignleft",
            steps: [
                .removeLineBreaks(),
                .collapseSpaces,
                .breakAfterSentences(),
                .trim(perLine: true),
                .trim(),
            ]
        ),
        Skill(
            id: "one-line",
            name: L("한 줄로 합치기", "Join into one line"),
            symbol: "arrow.right.to.line",
            steps: [
                .ifCondition(.hasLineBreaks, then: [.removeLineBreaks()]),
                .collapseSpaces,
                .trim(),
            ]
        ),
        Skill(
            id: "tidy-spaces",
            name: L("공백·빈 줄 정리", "Tidy spaces & blank lines"),
            symbol: "sparkles",
            steps: [
                .collapseSpaces,
                .trim(perLine: true),
                .removeEmptyLines,
                .trim(),
            ]
        ),
        Skill(
            id: "bullets",
            name: L("줄마다 글머리표", "Bullet every line"),
            symbol: "list.bullet",
            steps: [
                .trim(perLine: true),
                .removeEmptyLines,
                .addToLines(prefix: "• "),
            ]
        ),
        Skill(
            id: "uppercase",
            name: L("대문자로", "UPPERCASE"),
            symbol: "textformat.size.larger",
            steps: [.changeCase(.upper)]
        ),
        Skill(
            id: "lowercase",
            name: L("소문자로", "lowercase"),
            symbol: "textformat.size.smaller",
            steps: [.changeCase(.lower)]
        ),
    ]
}
