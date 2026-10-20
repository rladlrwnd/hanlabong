import Foundation

/// 문장 끝을 찾아 그 뒤에 줄바꿈을 넣는다.
///
/// 기본 규칙: 마침표·물음표·느낌표(와 뒤따르는 닫는 따옴표/괄호) 다음에 공백이 오면 문장 끝.
/// 틀리기 쉬운 경우들:
/// - `3.5배`, `$3.50`, `example.com` — 뒤에 공백이 없으니 끊지 않는다.
/// - `Mr. Kim`, `Dr. Lee`, `e.g.`, `U.S.` — 약어 목록이면 끊지 않는다.
/// - `etc.`, `p.m.`, `No.` — 문장 끝일 수도 있어서, 다음 단어가 대문자나 한글로 시작할 때만 끊는다.
/// - `J. K. Rowling` — 대문자 한 글자 + 마침표(이름 이니셜)는 끊지 않는다.
/// - `1. 첫째` — 줄 맨 앞의 번호 목록은 끊지 않는다.
/// - 말줄임표 `...` / `…` — 문장 중간에도 흔히 쓰여서, 다음 단어가 대문자로 시작하거나
///   바로 앞이 한국어 종결어미(다·요·죠·까·네)일 때만 끊는다. (`그게... 좀` 은 안 끊음)
/// - 한국어 `했다.그리고` — 띄어쓰기 없이 붙어 있어도 종결어미 뒤 마침표면 끊는다.
///   단, `"좋다."라고` 처럼 따옴표가 닫힌 뒤 바로 이어지면 인용이라 끊지 않는다.
enum SentenceSplitter {
    static func breakAfterSentences(_ text: String, separator: String = "\n") -> String {
        let chars = Array(text)
        let count = chars.count
        var output = String()
        output.reserveCapacity(text.utf8.count + 32)

        var i = 0
        while i < count {
            guard isTerminator(chars[i]) else {
                output.append(chars[i])
                i += 1
                continue
            }

            // 마침표 여러 개(말줄임표)나 ?! 같은 연속 부호는 한 덩어리로 본다.
            let runStart = i
            var runEnd = i
            while runEnd < count, isTerminator(chars[runEnd]) { runEnd += 1 }
            // 문장을 닫는 따옴표·괄호는 앞 문장에 붙인다.
            var afterClosers = runEnd
            while afterClosers < count, isCloser(chars[afterClosers]) { afterClosers += 1 }

            output.append(contentsOf: chars[runStart..<afterClosers])
            i = afterClosers
            guard afterClosers < count else { break }

            let next = chars[afterClosers]
            if next.isWhitespace {
                var wordStart = afterClosers
                while wordStart < count, chars[wordStart].isWhitespace { wordStart += 1 }
                let gap = chars[afterClosers..<wordStart]
                if wordStart < count,
                   isBoundary(chars, runStart: runStart, runEnd: runEnd, nextWordStart: wordStart) {
                    // 원래 빈 줄(문단 구분)이 있었다면 그대로 살린다.
                    output.append(gap.filter(\.isNewline).count >= 2 ? "\n\n" : separator)
                } else {
                    output.append(contentsOf: gap)
                }
                i = wordStart
            } else if afterClosers == runEnd, isHangul(next),
                      isAttachedKoreanBoundary(chars, runStart: runStart, runEnd: runEnd) {
                output.append(separator)
            }
        }
        return output
    }

    // MARK: - 판단 규칙

    /// 부호 뒤에 공백이 있을 때, 여기가 진짜 문장 끝인가?
    private static func isBoundary(_ c: [Character], runStart: Int, runEnd: Int, nextWordStart: Int) -> Bool {
        let run = c[runStart..<runEnd]
        let next = c[nextWordStart]

        if isEllipsis(run) {
            return isUppercaseLatin(next) || endsWithKoreanEnding(c, before: runStart, strict: true)
        }
        // ? ! 가 섞여 있으면 항상 문장 끝
        guard run.count == 1, run.first == "." || run.first == "。" else { return true }

        let (token, tokenStart) = wordBefore(c, index: runStart)
        if token.isEmpty { return true }

        if token.allSatisfy(\.isNumber) {
            // 줄 맨 앞의 "1." "12." 는 번호 목록
            return !(token.count <= 3 && isLineStart(c, index: tokenStart))
        }
        if token.count == 1, let only = token.first, isUppercaseLatin(only) {
            return false  // 이니셜 (J. K. Rowling)
        }
        let lower = token.lowercased()
        if neverSentenceEnd.contains(lower) { return false }
        if maybeSentenceEnd.contains(lower) {
            return isUppercaseLatin(next) || isHangulOrCJK(next)
        }
        return true
    }

    /// `했다.그리고` 처럼 부호 뒤에 공백 없이 한글이 바로 붙은 경우.
    private static func isAttachedKoreanBoundary(_ c: [Character], runStart: Int, runEnd: Int) -> Bool {
        let run = c[runStart..<runEnd]
        if isEllipsis(run) { return false }
        if run.contains(where: { $0 == "?" || $0 == "!" || $0 == "？" || $0 == "！" }) { return true }
        return endsWithKoreanEnding(c, before: runStart, strict: false)
    }

    // MARK: - 약어 목록

    /// 뒤에 무엇이 와도 문장 끝이 아닌 약어 (소문자, 점 포함 형태)
    private static let neverSentenceEnd: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "st", "mt", "vs", "cf", "fig", "figs", "vol", "vols",
        "pp", "p", "approx", "dept", "est", "e.g", "i.e", "u.s", "u.k", "ph.d",
    ]

    /// 문장 끝에도 올 수 있는 약어 — 다음 단어가 대문자·한글로 시작할 때만 끊는다.
    private static let maybeSentenceEnd: Set<String> = [
        "etc", "inc", "ltd", "co", "corp", "no", "jr", "sr", "a.m", "p.m",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
    ]

    /// 한국어 종결어미. strict는 말줄임표 판단용(더 보수적).
    private static let koreanEndingsStrict: Set<Character> = ["다", "요", "죠", "까", "네"]
    private static let koreanEndingsLoose: Set<Character> = ["다", "요", "죠", "까", "네", "음", "함", "임", "됨"]

    // MARK: - 글자 도우미

    private static func isTerminator(_ ch: Character) -> Bool {
        ch == "." || ch == "!" || ch == "?" || ch == "…" || ch == "。" || ch == "！" || ch == "？"
    }

    private static func isCloser(_ ch: Character) -> Bool {
        "\"'”’)]}」』》〉»".contains(ch)
    }

    private static func isEllipsis(_ run: ArraySlice<Character>) -> Bool {
        run.contains("…") || (run.count >= 2 && run.allSatisfy { $0 == "." })
    }

    /// 부호 바로 앞 단어. 단어 안의 점(e.g, U.S, 3.50)은 포함한다.
    private static func wordBefore(_ c: [Character], index: Int) -> (String, Int) {
        var start = index
        while start > 0 {
            let previous = c[start - 1]
            if previous.isLetter || previous.isNumber {
                start -= 1
            } else if previous == ".", start >= 2, c[start - 2].isLetter || c[start - 2].isNumber {
                start -= 1
            } else {
                break
            }
        }
        return (String(c[start..<index]), start)
    }

    private static func isLineStart(_ c: [Character], index: Int) -> Bool {
        var j = index - 1
        while j >= 0, c[j] == " " || c[j] == "\t" { j -= 1 }
        return j < 0 || c[j].isNewline
    }

    private static func endsWithKoreanEnding(_ c: [Character], before index: Int, strict: Bool) -> Bool {
        guard index > 0 else { return false }
        return (strict ? koreanEndingsStrict : koreanEndingsLoose).contains(c[index - 1])
    }

    private static func isUppercaseLatin(_ ch: Character) -> Bool {
        ch.isASCII && ch.isUppercase
    }

    private static func isHangul(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first?.value else { return false }
        return (0xAC00...0xD7A3).contains(scalar) || (0x1100...0x11FF).contains(scalar) || (0x3130...0x318F).contains(scalar)
    }

    private static func isHangulOrCJK(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first?.value else { return false }
        return isHangul(ch) || (0x4E00...0x9FFF).contains(scalar) || (0x3040...0x30FF).contains(scalar)
    }
}
