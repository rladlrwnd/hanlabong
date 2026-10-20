import Testing
@testable import SkillEngine

/// 문장 나누기에서 틀리기 쉬운 경우들 (3.5배, Mr. Kim, 말줄임표, 한국어 "다." 등)
struct SentenceSplitterTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let input: String
        let expected: String
        var testDescription: String { input }
    }

    static let cases: [Case] = [
        // 소수점
        Case(input: "3.5배 늘었다. 다음 문장.", expected: "3.5배 늘었다.\n다음 문장."),
        Case(input: "It costs $3.50. Cheap?! Yes.", expected: "It costs $3.50.\nCheap?!\nYes."),
        // 호칭·약어
        Case(input: "Mr. Kim went home. He slept.", expected: "Mr. Kim went home.\nHe slept."),
        Case(input: "Dr. Lee and Prof. Park met.", expected: "Dr. Lee and Prof. Park met."),
        Case(input: "Try e.g. apples and i.e. pears. Done.", expected: "Try e.g. apples and i.e. pears.\nDone."),
        Case(input: "The U.S. Army left. Then quiet.", expected: "The U.S. Army left.\nThen quiet."),
        // 문장 끝에도 올 수 있는 약어
        Case(input: "We met at 5 p.m. Then we left.", expected: "We met at 5 p.m.\nThen we left."),
        Case(input: "We met at 5 p.m. today.", expected: "We met at 5 p.m. today."),
        Case(input: "Apples, pears, etc. and more.", expected: "Apples, pears, etc. and more."),
        Case(input: "See No. 5 and no. That's it.", expected: "See No. 5 and no.\nThat's it."),
        // 이니셜
        Case(input: "J. K. Rowling wrote it. Good.", expected: "J. K. Rowling wrote it.\nGood."),
        // 말줄임표
        Case(input: "그게... 좀 그래. 알겠지?", expected: "그게... 좀 그래.\n알겠지?"),
        Case(input: "음… 글쎄요. 모르겠어.", expected: "음… 글쎄요.\n모르겠어."),
        Case(input: "좋았다... 그래서 갔다.", expected: "좋았다...\n그래서 갔다."),
        Case(input: "Wait... what? No... Stop.", expected: "Wait... what?\nNo...\nStop."),
        // 한국어 "다." — 띄어쓰기 없이 붙은 경우
        Case(input: "했다.그리고 갔다.", expected: "했다.\n그리고 갔다."),
        Case(input: "완료함.다음 할 일", expected: "완료함.\n다음 할 일"),
        Case(input: "진짜?그럼 가자.", expected: "진짜?\n그럼 가자."),
        // 인용: 따옴표가 닫힌 뒤 바로 이어지면 한 문장
        Case(input: "그가 \"좋다.\"라고 말했다. 끝.", expected: "그가 \"좋다.\"라고 말했다.\n끝."),
        Case(input: "He said \"Stop.\" Then left.", expected: "He said \"Stop.\"\nThen left."),
        Case(input: "(정말 그랬다.) 다음.", expected: "(정말 그랬다.)\n다음."),
        // 도메인·숫자
        Case(input: "Visit example.com today. Thanks!", expected: "Visit example.com today.\nThanks!"),
        Case(input: "In 2024. Things changed.", expected: "In 2024.\nThings changed."),
        // 번호 목록은 그대로
        Case(input: "1. 첫째\n2. 둘째", expected: "1. 첫째\n2. 둘째"),
        // 공백 여러 개는 줄바꿈 하나로, 문단(빈 줄)은 유지
        Case(input: "하나다.    둘이다.\n\n셋이다.", expected: "하나다.\n둘이다.\n\n셋이다."),
    ]

    @Test(arguments: cases)
    func splits(_ c: Case) {
        #expect(SentenceSplitter.breakAfterSentences(c.input) == c.expected)
    }

    @Test func blankLineSeparator() {
        #expect(SentenceSplitter.breakAfterSentences("Hi. Bye.", separator: "\n\n") == "Hi.\n\nBye.")
    }
}
