import CoreGraphics
import Foundation
import Testing
@testable import SkillEngine

/// OCR 오타수정: 불확실한 곳만 골라 AI에게 보내고, 답을 읽어 고친 곳으로 만든다(실제 AI 없이 확인)
struct OCRReviewTests {
    private func line(_ text: String, row: Int, confidence: Float = 0.9, alternatives: [String] = []) -> OCRLine {
        OCRLine(text: text, rect: CGRect(x: 50, y: 50 + row * 40, width: 600, height: 30), confidence: confidence, alternatives: alternatives)
    }
    private let source = URL(fileURLWithPath: "/tmp/스캔.jpg")

    @Test func onlyWordsTheCandidatesDisagreeOnAreSuspicious() {
        let spots = OCRReview.spots(in: [
            line("사잔 작업 보고서", row: 0, alternatives: ["사진 작업 보고서"]),
            line("모든 줄이 확실하다", row: 1),
            line("인화지벌 테스트 결과", row: 2, alternatives: ["인화지별 테스트 결과", "인화지벌 데스트 결과"]),
        ])
        #expect(spots.map(\.word) == ["사잔", "인화지벌", "테스트"])
        #expect(spots.map(\.id) == [1, 2, 3])
        #expect(spots[0].alternatives == ["사진"])
        #expect(spots[1].alternatives == ["인화지별"])
        #expect(spots[0].range == 0..<2 && spots[1].line == 2)
    }

    @Test func punctuationCaseAndDroppedWordsAreNotSuspicious() {
        // 실제 사진에서 많이 나온 헛짚기들: 문장부호만 다름, 붙여 읽음, 다른 후보가 단어를 빠뜨림
        let spots = OCRReview.spots(in: [
            line("오늘 테스트 인화를 했다.", row: 0, alternatives: ["오늘 테스트 인화를 했다"]),
            line("Kodak Tri-X 400, f/8", row: 1, alternatives: ["Kodak TriX 400. f/8"]),
            line("노광 시간은 12초, 현상은 90초", row: 2, alternatives: ["노광 시간은 현상은 90초"]),
        ])
        #expect(spots.isEmpty)
    }

    @Test func realLetterDifferencesAreStillCaughtWhenWordCountsDiffer() {
        let spots = OCRReview.spots(in: [
            line("섀도우가 조금 뭉개져서 노광을", row: 0, alternatives: ["새도우가 조금 뭉개 져서 노광을"]),
        ])
        #expect(spots.map(\.word) == ["섀도우가", "뭉개져서"])
        #expect(spots.first?.alternatives == ["새도우가"])
        #expect(spots.last?.alternatives == ["뭉개", "져서"])
    }

    @Test func lowConfidenceLineWithoutAlternativesIsCheckedWhole() {
        let spots = OCRReview.spots(in: [line("흐릿하게 찍힌 줄", row: 0, confidence: 0.2)])
        #expect(spots.count == 1)
        #expect(spots[0].word == "흐릿하게 찍힌 줄")
    }

    @Test func promptSendsOnlySuspiciousLinesWithNeighbours() throws {
        let lines = [
            line("첫 줄은 보내지 않는다", row: 0),
            line("둘째 줄", row: 1),
            line("사잔 작업 보고서", row: 2, alternatives: ["사진 작업 보고서"]),
            line("넷째 줄", row: 3),
            line("다섯째 줄도 보내지 않는다", row: 4),
        ]
        let prompt = OCRReview.prompt(for: OCRReview.spots(in: lines), lines: lines)
        #expect(prompt.contains("⟦사잔⟧ 작업 보고서"))
        #expect(prompt.contains("둘째 줄") && prompt.contains("넷째 줄"))
        #expect(!prompt.contains("첫 줄은 보내지 않는다") && !prompt.contains("다섯째 줄도"))   // 문서 전체를 보내지 않는다
    }

    @Test func parsesFixesEvenWithChatterAroundTheJSON() {
        let output = """
        <think>음…</think>
        ```json
        {"fixes":[{"id":1,"word":"사진"},{"id":"2","word":"인화지별"}]}
        ```
        """
        #expect(OCRReview.parseFixes(output) == [1: "사진", 2: "인화지별"])
        #expect(OCRReview.parseFixes("못 하겠어요").isEmpty)
    }

    @Test func untrustworthyAnswersAreDropped() {
        let spots = OCRReview.spots(in: [line("사잔 작업 보고서", row: 0, alternatives: ["사진 작업 보고서"])])
        #expect(OCRReview.changes(from: spots, fixes: [1: "사잔"]).isEmpty)                      // 그대로
        #expect(OCRReview.changes(from: spots, fixes: [1: "사진\n추가"]).isEmpty)               // 줄바꿈
        #expect(OCRReview.changes(from: spots, fixes: [1: "엄청나게 긴 문장으로 바꿔버렸다"]).isEmpty)   // 엉뚱하게 김
        #expect(OCRReview.changes(from: spots, fixes: [99: "사진"]).isEmpty)                    // 없는 번호
        #expect(OCRReview.changes(from: spots, fixes: [1: "사진"]).map(\.replacement) == ["사진"])
    }

    @Test func reviewDocumentAppliesOnlyAcceptedChangesAndBuildsTheFinalText() {
        var document = OCRReview.document(source: source, lines: [
            line("사잔 작업 보고서", row: 0, alternatives: ["사진 작업 보고서"]),
            line("인화지벌 데스트 결과.", row: 1, alternatives: ["인화지별 테스트 결과."]),
        ])
        #expect(document.spotCount == 3)
        // 가짜 AI: 묶음마다 답을 준다
        let answers = document.prompts(batchSize: 2).map { prompt -> String in
            var fixes: [String] = []
            if prompt.contains("⟦사잔⟧") { fixes.append(#"{"id":1,"word":"사진"}"#) }
            if prompt.contains("⟦인화지벌⟧") { fixes.append(#"{"id":2,"word":"인화지별"}"#) }
            if prompt.contains("⟦데스트⟧") { fixes.append(#"{"id":3,"word":"테스트"}"#) }
            return #"{"fixes":["# + fixes.joined(separator: ",") + "]}"
        }
        #expect(answers.count == 2)                                                           // 2개씩 두 묶음
        document.apply(aiOutputs: answers)
        #expect(document.changes.map(\.replacement) == ["사진", "인화지별", "테스트"])
        #expect(document.correctedLines == ["사진 작업 보고서", "인화지별 테스트 결과."])

        document.changes[1].accepted = false                                                  // 하나는 끈다
        #expect(document.correctedLines == ["사진 작업 보고서", "인화지벌 테스트 결과."])
        #expect(document.finalText == "사진 작업 보고서 인화지벌 테스트 결과.\n")
        #expect(document.originalLines == ["사잔 작업 보고서", "인화지벌 데스트 결과."])        // 원래 인식은 그대로 남는다
    }

    @Test func twoChangesInOneLineDoNotShiftEachOther() {
        var document = OCRReview.document(source: source, lines: [
            line("가나 다라 마바", row: 0, alternatives: ["가나다 다라 마바사"]),
        ])
        document.apply(aiOutputs: [#"{"fixes":[{"id":1,"word":"가나다"},{"id":2,"word":"마바사"}]}"#])
        #expect(document.correctedLines == ["가나다 다라 마바사"])
    }

    @Test func spotsAreCappedSoWeNeverSendTheWholeDocument() {
        let many = (0..<200).map { line("단어\($0) 하나", row: $0, alternatives: ["다른\($0) 하나"]) }
        #expect(OCRReview.spots(in: many).count == OCRReview.maxSpots)
    }
}
