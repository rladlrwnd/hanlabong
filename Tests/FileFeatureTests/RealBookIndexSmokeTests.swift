import AppCore
import Foundation
import PDFKit
import SkillEngine
import Testing

/// 진짜 책 PDF를 로컬 AI(Ollama)로 나눠 보기(선택형, 글이 이 맥 밖으로 안 나간다)
///   DRAGEDIT_BOOK=책.pdf DRAGEDIT_OLLAMA_MODEL=gemma4:12b swift test --filter RealBookIndexSmoke
struct RealBookIndexSmokeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DRAGEDIT_BOOK"] != nil), .timeLimit(.minutes(10)))
    func splitsARealBook() async throws {
        let env = ProcessInfo.processInfo.environment
        let doc = try #require(PDFDocument(url: URL(fileURLWithPath: env["DRAGEDIT_BOOK"]!)))
        let digest = BookIndexer.pageDigest(doc)
        let outline = BookIndexer.outlineEntries(doc).prefix(120).map { "\($0.title) → p\($0.page + 1)" }
        print("▶︎ 쪽 \(doc.pageCount), 요약 글자 \(digest.count), 책갈피 \(outline.count)")
        if let out = env["DRAGEDIT_PROMPT_OUT"] {   // 모델 속도 재기용: AI에게 보내는 글을 파일로
            try? (BookIndexer.system + "\n=====\n" + BookIndexer.prompt(digest: digest, outline: Array(outline), pageCount: doc.pageCount)).write(toFile: out, atomically: true, encoding: .utf8)
        }
        if var guess = BookIndexer.guess(doc) {
            BookIndexer.enrich(doc, into: &guess)
            print("▶︎ 짐작(\(guess.source))")
            for s in guess.sections { print("▶︎   " + String(repeating: "  ", count: s.level) + "\(s.title) [\(s.role)] \(s.start + 1)–\(s.end + 1)") }
            for q in ["9단원 해설페이지로 가줘", "9단원 실전 해설", "3단원으로 가줘", "빠른 정답 보여줘", "15단원 기본 문제"] {
                let hit = guess.section(matching: q)
                print("▶︎ 찾기 \"\(q)\" → \(hit.map { "\($0.title) [\($0.role)] \($0.start + 1)쪽" } ?? "없음")")
            }
        }
        guard env["DRAGEDIT_OLLAMA_MODEL"] != nil else { return }
        let agent = Agent(provider: .ollama, model: env["DRAGEDIT_OLLAMA_MODEL"] ?? "gemma4:12b", detail: "")
        let answer = try await AIClient.complete(system: BookIndexer.system,
                                                 messages: [.user(BookIndexer.prompt(digest: digest, outline: Array(outline), pageCount: doc.pageCount))],
                                                 agent: agent, apiKey: nil, cloudEnabled: false, json: true, temperature: 0.1)
        var index = try #require(BookIndexer.parse(answer, pageCount: doc.pageCount))
        print("▶︎ AI가 읽은 그대로")
        for s in index.sections { print("▶︎   " + String(repeating: "  ", count: s.level) + "\(s.title) [\(s.role)] \(s.start + 1)–\(s.end + 1) → \(index.destinations(from: s).map(\.title))") }
        BookIndexer.enrich(doc, into: &index)
        print("▶︎ 다듬은 뒤")
        for s in index.sections { print("▶︎   " + String(repeating: "  ", count: s.level) + "\(s.title) [\(s.role)] \(s.start + 1)–\(s.end + 1) → \(index.destinations(from: s).map(\.title))") }
    }
}

struct RealBookLinkSmokeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DRAGEDIT_BOOK"] != nil))
    func linksProblemAndAnswerPages() throws {
        let doc = try #require(PDFDocument(url: URL(fileURLWithPath: ProcessInfo.processInfo.environment["DRAGEDIT_BOOK"]!)))
        var index = BookIndex(sections: [], source: .guess, pageCount: doc.pageCount)
        BookLinker.link(doc, into: &index)
        print("▶︎ 이은 쪽 \(index.pageLinks.count)개")
        for p in [11, 13, 79, 100, 166, 171, 172, 180, 200, 224] { print("▶︎ p\(p) → p\(index.pageLinks[p - 1].map { $0 + 1 } ?? -1)") }
    }
}
