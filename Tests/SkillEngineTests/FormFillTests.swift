import AppKit
import Foundation
import PDFKit
import Testing
@testable import SkillEngine

/// 계약서 빈칸 찾기·채우기
struct FormFillTests {
    /// 줄마다 (글, x, y)로 글자를 찍은 쪽 하나
    private func page(_ items: [(String, CGFloat, CGFloat)]) -> PDFPage {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let ctx = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for (text, x, y) in items {
            NSAttributedString(string: text, attributes: [.font: NSFont(name: "AppleSDGothicNeo-Regular", size: 12) ?? .systemFont(ofSize: 12)]).draw(at: CGPoint(x: x, y: y))
        }
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()
        return PDFDocument(data: data as Data)!.page(at: 0)!
    }

    @Test func findsBlanksInAContract() {
        let p = page([
            ("근 로 계 약 서", 240, 780),
            ("성명:", 60, 700),
            ("주소", 60, 670), ("연락처", 320, 670),
            ("계좌번호 ____________", 60, 640),
            ("이름 홍길동", 60, 610),                      // 이미 쓴 칸은 빼야 한다
            ("2026  년      월      일", 300, 200),
            ("서명자            (인)", 300, 160),
        ])
        let fields = FormFieldFinder.find(on: p, index: 0)
        let labels = fields.map { "\($0.kind.rawValue):\($0.label)" }
        #expect(labels.contains("text:성명"), "\(labels)")
        #expect(labels.contains("text:주소"), "\(labels)")
        #expect(labels.contains("text:연락처"), "\(labels)")
        #expect(labels.contains("text:계좌번호"), "\(labels)")
        #expect(!labels.contains("text:이름"), "\(labels)")
        #expect(labels.contains("month:월") && labels.contains("day:일"), "\(labels)")
        #expect(!labels.contains("year:년"), "\(labels)")                     // 2026이 이미 쓰여 있다
        #expect(fields.contains { $0.kind == .signature }, "\(labels)")
        // 주소 칸은 연락처 앞에서 끝난다
        let address = fields.first { $0.label == "주소" }!
        #expect(address.rect.maxX < 320)
    }

    @Test func matchesLabelsWithoutAI() {
        var profile = UserProfile.starter
        profile.entries[0].value = "김한라"
        profile.entries[1].value = "Kim Hanla"
        profile.entries[8].value = "010-0000-0000"
        let fields = [
            FormField(id: "a", page: 0, rect: .zero, label: "성명"),
            FormField(id: "b", page: 0, rect: .zero, label: "영문 성명"),
            FormField(id: "c", page: 0, rect: .zero, label: "연락처"),
            FormField(id: "d", page: 0, rect: .zero, label: "월", kind: .month),
            FormField(id: "e", page: 0, rect: .zero, label: "취미"),
        ]
        let today = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 11, day: 5))!
        let values = FormFiller.matchByLabel(fields, profile: profile, today: today)
        #expect(values == ["a": "김한라", "b": "Kim Hanla", "c": "010-0000-0000", "d": "11"])
    }

    @Test func understandsWriteRequestsWithoutAI() {
        #expect(FormFiller.parseWriteRequest("주소에 서울시 마포구 연남동을 써줘")! == ("주소", "서울시 마포구 연남동"))
        #expect(FormFiller.parseWriteRequest("학과는 사진학과로 바꿔줘")! == ("학과", "사진학과"))
        #expect(FormFiller.parseWriteRequest("이 쪽 요약해줘") == nil)
    }

    @Test func readsAIAnswerOnlyForKnownFields() {
        let fields = [FormField(id: "a", page: 0, rect: .zero, label: "성명")]
        #expect(FormFiller.parse(#"ok {"values":{"a":" 김한라 ","zz":"x"}}"#, fields: fields) == ["a": "김한라"])
        #expect(FormFiller.parse("몰라요", fields: fields).isEmpty)
    }
}

/// 진짜 서식 PDF로 빈칸 찾기 보기(선택형): DRAGEDIT_FORM=서식.pdf swift test --filter RealFormSmoke
struct RealFormSmokeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DRAGEDIT_FORM"] != nil))
    func findsBlanksInARealForm() throws {
        let doc = try #require(PDFDocument(url: URL(fileURLWithPath: ProcessInfo.processInfo.environment["DRAGEDIT_FORM"]!)))
        for i in 0..<doc.pageCount {
            for f in FormFieldFinder.find(on: doc.page(at: i)!, index: i) { print("▶︎ p\(i + 1) \(f.kind.rawValue) \"\(f.label)\" x\(Int(f.rect.minX)) y\(Int(f.rect.minY)) w\(Int(f.rect.width))") }
        }
    }
}
