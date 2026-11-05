import AppKit
import Foundation
import PDFKit
import Testing
@testable import SkillEngine

/// 책 구조: AI 답 읽기, 큰 파트 › 작은 파트, 연결, AI 없을 때 짐작, 쪽끼리 잇기
struct BookIndexTests {
    private func book(_ pages: [String]) -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let ctx = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
        for text in pages {
            ctx.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 9)])
                .draw(in: CGRect(x: 10, y: 10, width: 280, height: 380))
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return PDFDocument(data: data as Data)!
    }

    @Test func parsesAIAnswerWithFreeRolesLevelsAndLinks() {
        let answer = """
        Here you go: {"sections":[
          {"id":"a","title":"01 단원","role":"개념","level":0,"start":3,"end":20,"related":["c","zz"]},
          {"id":"a1","title":"기본 문제","role":"기본 문제","level":1,"start":10,"end":20},
          {"id":"b","title":"02 단원","role":"개념","level":0,"start":18,"end":40},
          {"id":"c","title":"01 해설","role":"해설","level":0,"start":41,"end":999},
          {"id":"x","title":"","role":"부록","start":1,"end":2},
          {"id":"y","title":"이상한 쪽","role":"문제","start":0}
        ]}
        """
        let index = try! #require(BookIndexer.parse(answer, pageCount: 60))
        #expect(index.sections.map(\.id) == ["a", "a1", "b", "c"])
        #expect(index.sections[0].start == 2 && index.sections[0].end == 16)     // 0부터, 같은 단계 다음 파트와 안 겹치게
        #expect(index.sections[3].end == 59)                                      // 쪽 수 넘으면 끝 쪽으로
        #expect(index.sections[0].related == ["c"])                               // 없는 id는 빼고
        #expect(index.sections[3].related == ["a"])                               // 양쪽으로
        #expect(BookIndexer.parse("모르겠어요", pageCount: 10) == nil)
    }

    @Test func findsDeepestSectionAndInheritsLinks() {
        let index = BookIndex(sections: [
            BookSection(id: "u1", title: "1단원", role: "개념", level: 0, start: 0, end: 9, related: ["h1"]),
            BookSection(id: "u1b", title: "기본 문제", role: "기본 문제", level: 1, start: 5, end: 9),
            BookSection(id: "h1", title: "1단원 해설", role: "해설", level: 0, start: 10, end: 14, related: ["u1"]),
        ], source: .ai, pageCount: 15)
        let here = try! #require(index.section(at: 6))
        #expect(here.id == "u1b")
        #expect(index.ancestors(of: here).map(\.id) == ["u1"])
        #expect(index.destinations(from: here).map(\.id) == ["h1"])               // 작은 파트는 큰 파트의 연결을 물려받는다
    }

    @Test func findsSectionsFromWordsWithoutAI() {
        let index = BookIndex(sections: [
            BookSection(id: "b9", title: "09 과학 기술과 윤리", role: "본문", level: 0, start: 93, end: 102),
            BookSection(id: "b9k", title: "기본 수능 문제", role: "기본 문제", level: 1, start: 97, end: 98),
            BookSection(id: "q", title: "한눈에 보는 정답", role: "빠른 정답", level: 0, start: 168, end: 169),
            BookSection(id: "h9", title: "09 과학 기술과 윤리", role: "해설", level: 0, start: 198, end: 200),
            BookSection(id: "h9s", title: "실전 해설", role: "실전 해설", level: 1, start: 199, end: 200),
        ], source: .guess, pageCount: 224)
        #expect(index.section(matching: "9단원 해설페이지로 가줘")?.id == "h9")
        #expect(index.section(matching: "9단원 실전 해설 보여줘")?.id == "h9s")
        #expect(index.section(matching: "9단원으로 가줘")?.id == "b9")
        #expect(index.section(matching: "빠른 정답 열어줘")?.id == "q")
        #expect(index.section(matching: "3단원 해설") == nil)
        #expect(index.section(matching: "이 쪽 요약해줘") == nil)
    }

    @Test func guessSplitsAtTheAnswerSection() {
        let pages = (1...12).map { "문제 \($0) 다음 중 옳은 것은?" } + ["정답과 해설", "1번 해설", "2번 해설"]
        let index = try! #require(BookIndexer.guess(book(pages)))
        #expect(index.sections.count == 2 && index.sections[1].start == 12 && index.sections[1].role == "해설")
        #expect(index.destinations(from: index.sections[0]).map(\.id) == [index.sections[1].id])
    }

    @Test func answerBookletSplitsIntoQuickAnswersAndUnits() {
        // 답지만 있는 파일: 1쪽 "한눈에 보는 정답"(모든 단원과 본문 쪽), 그 뒤로 단원 › 기본/실전 해설
        let summary = "한눈에 보는 정답 01 실천 윤리 기본 수능 문제 본문 11~12쪽 1 ① 2 ② 실전 수능 문제 본문 13~16쪽 1 ③ 02 생명 윤리 기본 수능 문제 본문 21~22쪽 1 ④ 실전 수능 문제 본문 23~26쪽 1 ⑤"
        let pages = [summary,
                     "01 실천 윤리 기본 수능 문제 본문 11~12쪽 1 해설",
                     "이어지는 해설 실전 수능 문제 본문 13~16쪽 1 해설",
                     "이어지는 해설",
                     "02 생명 윤리 기본 수능 문제 본문 21~22쪽 해설",
                     "실전 수능 문제 본문 23~26쪽 해설"]
        let index = try! #require(BookIndexer.guess(book(pages)))
        let summaryLine = index.sections.map { "\($0.level)|\($0.title)|\($0.start)-\($0.end)" }
        #expect(index.sections.first?.role == "빠른 정답", "\(summaryLine)")
        #expect(index.sections.filter { $0.level == 0 && $0.role == "해설" }.map(\.title) == ["01 실천 윤리", "02 생명 윤리"], "\(summaryLine)")
        #expect(index.sections.filter { $0.level == 1 }.map(\.title) == ["기본 해설", "실전 해설", "기본 해설", "실전 해설"], "\(summaryLine)")
        #expect(index.section(at: 3)?.title == "실전 해설")
    }

    @Test func digestMarksAnswerPagesAndStaysShort() {
        let pages = (1...30).map { "본문 \($0) " + String(repeating: "가", count: 300) } + ["정답과 해설 시작"]
        let digest = BookIndexer.pageDigest(book(pages), maxCharacters: 2000)
        #expect(digest.count < 2600)
        #expect(digest.contains("[정답/해설?]"))
    }

    @Test func linksProblemPagesAndAnswerPagesBothWays() {
        // 문제 1~8쪽(위에 "정답과 해설 n쪽"), 해설 9~12쪽(앞에 "본문 x~y쪽"), 앞쪽 2쪽엔 헷갈리게 "본문 3쪽" 안내
        var pages = (1...8).map { "정답과 해설 \(($0 + 1) / 2)쪽 문제 \($0)" }
        pages[1] = "책의 구성 본문 3쪽을 보세요"
        pages += ["본문 1~2쪽 해설", "본문 3~4쪽 해설", "본문 5~6쪽 해설", "(이어지는 해설)"]
        var index = BookIndex(sections: [], source: .ai, pageCount: 12)
        BookLinker.link(book(pages), into: &index)
        #expect(index.pageLinks[0] == 8 && index.pageLinks[3] == 9 && index.pageLinks[4] == 10)
        #expect(index.pageLinks[6] == 11)                 // "본문" 참조가 없는 7쪽은 "정답과 해설 4쪽" + 배운 차이(8)로
        #expect(index.pageLinks[9] == 2 && index.pageLinks[11] == 4)   // 참조 없는 해설 쪽은 앞 해설 쪽의 문제를 이어받는다
    }
}
