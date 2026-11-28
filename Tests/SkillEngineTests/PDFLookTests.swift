import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import SkillEngine

/// PDF → 한글(HWPX)·워드로 바꿀 때 모양(가운데 정렬·글자색·좌우 들여쓰기·구분선·소제목)이 살아 있는가
struct PDFLookTests {
    private struct Line {
        var text: String
        var size: CGFloat = 10
        var bold = false
        var color: CGColor = CGColor(gray: 0, alpha: 1)
        var x: CGFloat
        /// 양쪽 정렬로 이 폭에 맞춰 늘린다(nil = 그대로)
        var justify: CGFloat?
        var baseline: CGFloat   // 쪽 위쪽에서 잰 기준선
    }

    private func font(_ size: CGFloat, bold: Bool) -> CTFont {
        CTFontCreateWithName((bold ? "Georgia-Bold" : "Georgia") as CFString, size, nil)
    }

    private func width(_ line: Line) -> CGFloat {
        let attributed = NSAttributedString(string: line.text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font(line.size, bold: line.bold)])
        return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), nil, nil, nil))
    }

    /// 쪽 하나짜리 논문 첫머리: 가운데 굵은 제목(남색) · 가운데 회색 저자 · 가로선 · 가운데 굵은 "Abstract" ·
    /// 좌우로 18pt 들여쓴 양쪽 정렬 요약 · 가로선 · 남색 소제목 · 본문
    private func makePaper(at url: URL) {
        let page = CGSize(width: 595, height: 842)
        let left: CGFloat = 72, right: CGFloat = 523, column = right - left
        let navy = CGColor(srgbRed: 0.2, green: 0.2, blue: 0.4, alpha: 1), gray = CGColor(srgbRed: 0.47, green: 0.47, blue: 0.47, alpha: 1)
        func centered(_ text: String, size: CGFloat, bold: Bool = false, color: CGColor = CGColor(gray: 0, alpha: 1), baseline: CGFloat) -> Line {
            var line = Line(text: text, size: size, bold: bold, color: color, x: 0, baseline: baseline)
            line.x = left + (column - width(line)) / 2
            return line
        }
        let abstract = [
            "Validating autonomous driving systems against rare but safety critical",
            "scenarios is a fundamental challenge because a vehicle would need to drive",
            "hundreds of millions of kilometres to meet enough natural exposure to them.",
        ]
        let body = [
            "Level four vehicles must show safety performance better than human drivers",
            "across the whole operational design domain before they can be certified. The",
            "RAND study estimated that statistical confidence in lower fatality rates would",
            "need billions of miles of testing, which is clearly out of reach for real fleets.",
        ]
        var lines: [Line] = [
            centered("Scenario Generation for Validation", size: 17, bold: true, color: navy, baseline: 100),
            centered("Jae-Won Lim, Tobias Richter, Olga Volkov", size: 11, color: gray, baseline: 128),
            centered("Abstract", size: 10, bold: true, baseline: 172),
        ]
        for (i, text) in abstract.enumerated() {
            lines.append(Line(text: text, size: 9.5, x: left + 18, justify: i < abstract.count - 1 ? column - 36 : nil, baseline: 190 + CGFloat(i) * 15))
        }
        lines.append(Line(text: "1.1 The Validation Problem", size: 10.5, bold: true, color: navy, x: left, baseline: 270))
        for (i, text) in body.enumerated() {
            lines.append(Line(text: text, size: 10, x: left, justify: i < body.count - 1 ? column : nil, baseline: 290 + CGFloat(i) * 16))
        }
        var media = CGRect(origin: .zero, size: page)
        let context = CGContext(url as CFURL, mediaBox: &media, nil)!
        context.beginPDFPage(nil)
        for line in lines {
            let attributed = NSAttributedString(string: line.text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font(line.size, bold: line.bold),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): line.color,
            ])
            if let target = line.justify {
                // 양쪽 정렬: 남는 폭을 낱말 사이에 똑같이 나눠 낱말마다 그린다
                let words = line.text.components(separatedBy: " ")
                let widths = words.map { width(Line(text: $0, size: line.size, bold: line.bold, x: 0, baseline: 0)) }
                let gap = (target - widths.reduce(0, +)) / CGFloat(max(words.count - 1, 1))
                var x = line.x
                for (word, w) in zip(words, widths) {
                    let piece = NSAttributedString(string: word, attributes: attributed.attributes(at: 0, effectiveRange: nil))
                    context.textPosition = CGPoint(x: x, y: page.height - line.baseline)
                    CTLineDraw(CTLineCreateWithAttributedString(piece), context)
                    x += w + gap
                }
                continue
            }
            context.textPosition = CGPoint(x: line.x, y: page.height - line.baseline)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        // 가로선 두 개: 저자 아래, 요약 아래
        context.setLineWidth(1)
        context.setStrokeColor(CGColor(srgbRed: 0.67, green: 0.67, blue: 0.8, alpha: 1))
        context.move(to: CGPoint(x: left, y: page.height - 150)); context.addLine(to: CGPoint(x: right, y: page.height - 150)); context.strokePath()
        context.setStrokeColor(CGColor(srgbRed: 0.8, green: 0.8, blue: 0.8, alpha: 1))
        context.move(to: CGPoint(x: left, y: page.height - 245)); context.addLine(to: CGPoint(x: right, y: page.height - 245)); context.strokePath()
        context.endPDFPage()
        context.closePDF()
    }

    /// 색이 거의 같은가(PDF를 만들고 읽는 동안 색 관리로 한두 단계 달라질 수 있다)
    private func near(_ hex: String?, _ expected: String) -> Bool {
        guard let hex, let a = UInt32(hex, radix: 16), let b = UInt32(expected, radix: 16) else { return false }
        return [16, 8, 0].allSatisfy { abs(Int((a >> $0) & 0xFF) - Int((b >> $0) & 0xFF)) <= 12 }
    }

    private func extracted() throws -> ExtractedDocument {
        let url = try Fixtures.makeTempDir().appendingPathComponent("paper.pdf")
        makePaper(at: url)
        return try PDFTextExtractor.extract(PDFDocument(url: url)!)
    }

    @Test func scannerFindsRulesAndRealFonts() throws {
        let url = try Fixtures.makeTempDir().appendingPathComponent("paper.pdf")
        makePaper(at: url)
        let scan = PDFContentScan.scan(PDFDocument(url: url)!.page(at: 0)!, index: 0)
        #expect(scan.rules.count == 2)
        #expect(scan.rules.map { ($0.y).rounded() } == [150, 245])
        #expect(near(scan.rules.first?.colorHex, "AAAACC"))
        #expect(scan.pieces.contains { PDFContentScan.isBold(PDFContentScan.strippedName($0.fontName)) })
    }

    @Test func paperKeepsAlignmentColorIndentAndRules() throws {
        let doc = try extracted()
        let texts = doc.paragraphs.map(\.text)
        #expect(texts.contains { $0.hasPrefix("Validating") }, "\(texts)")
        // 소제목은 본문에 붙지 않고 따로
        #expect(texts.contains("1.1 The Validation Problem"))
        let title = try #require(doc.paragraphs.first)
        #expect(title.alignment == .center)
        #expect(near(title.runs.first?.colorHex, "333366"))
        #expect(title.runs.allSatisfy { $0.bold })

        let authors = try #require(doc.paragraphs.first { $0.text.hasPrefix("Jae-Won") })
        #expect(authors.alignment == .center)
        #expect(near(authors.runs.first?.colorHex, "787878"))
        #expect(near(authors.ruleBelow?.colorHex, "AAAACC"))

        let heading = try #require(doc.paragraphs.first { $0.text == "Abstract" })
        #expect(heading.alignment == .center)
        #expect(heading.runs.allSatisfy { $0.bold })

        let summary = try #require(doc.paragraphs.first { $0.text.hasPrefix("Validating") })
        #expect(summary.alignment == .justify)
        #expect(abs(summary.leftIndent - 18) < 1.5)
        #expect(abs(summary.rightIndent - 18) < 1.5)
        #expect(summary.ruleBelow != nil)
        #expect(summary.runs.first?.fontSize == 9.5)

        let sub = try #require(doc.paragraphs.first { $0.text.hasPrefix("1.1") })
        #expect(near(sub.runs.first?.colorHex, "333366"))
        #expect(doc.bodyFontSize == 10)
        #expect(doc.bodyFontName == "Georgia")
        #expect(abs((doc.margins?.left ?? 0) - 72) < 1)
    }

    @Test func hwpxCarriesTheLook() throws {
        let doc = try extracted().richDocument(title: "paper")
        let data = try RichDocumentWriter.write(doc, as: .hwpx)
        let zip = try #require(MiniZipReader(data))
        let header = String(decoding: try #require(zip.entries.first { $0.name == "Contents/header.xml" }).data, as: UTF8.self)
        let section = String(decoding: try #require(zip.entries.first { $0.name == "Contents/section0.xml" }).data, as: UTF8.self)
        #expect(header.contains(#"<hh:align horizontal="CENTER""#))
        #expect(header.contains(#"<hc:right value="1800""#))
        #expect(header.contains(##"<hh:bottomBorder type="SOLID" width="0.4 mm" color="#"##))
        #expect(header.contains(##"textColor="#3"##))
        #expect(header.contains("face=\"Georgia\""))
        // Georgia에는 한글이 없으니 한글 글자는 같은 세리프 계열인 함초롬바탕으로
        #expect(header.contains("face=\"함초롬바탕\""))
        #expect(section.contains("1.1 The Validation Problem</hp:t>"))

        // 한라봉이 다시 읽어도 같은 모양
        let url = try Fixtures.makeTempDir().appendingPathComponent("paper.hwpx")
        try data.write(to: url)
        let back = try RichDocumentReader.read(url)
        let summary = try #require(back.paragraphs.first { $0.text.hasPrefix("Validating") })
        #expect(abs(summary.rightIndent - 18) < 1.5)
        #expect(summary.ruleBelow != nil)
        #expect(back.paragraphs.first?.alignment == .center)
    }
}
