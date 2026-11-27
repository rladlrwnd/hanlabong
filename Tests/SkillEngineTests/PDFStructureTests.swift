import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import SkillEngine

// PDF → 문단으로 짤 때 표·그래프·문단 나눔·쪽 나눔을 되찾는지

struct PDFStructureTests {
    // MARK: 합성 PDF

    private struct Piece {
        var text: String
        var x: CGFloat
        var bold = false
        /// 같은 줄에 이어서 굵게 쓰는 앞부분(굵은 첫 문장)
        var lead = ""
    }

    /// 한 줄 = 여러 조각(칸 위치 x). 줄마다 baseline을 `lineHeight`씩 내린다. `gapAfter`는 그 줄 뒤에 더 띄울 간격.
    private struct Line {
        var pieces: [Piece]
        var size: CGFloat = 10
        var gapAfter: CGFloat = 0
    }

    private func font(_ size: CGFloat, bold: Bool) -> CTFont {
        CTFontCreateWithName((bold ? "AppleSDGothicNeo-Bold" : "AppleSDGothicNeo-Regular") as CFString, size, nil)
    }

    /// 쪽마다 줄 목록을 받아, 칸 위치에 맞춰 CoreText로 그린 PDF. `scale`을 주면 같은 내용을 줄여서 가운데 그린다.
    private func makePDF(_ pages: [[Line]], at url: URL, size: CGSize = CGSize(width: 595, height: 842),
                         content: CGSize = CGSize(width: 595, height: 842)) {
        var media = CGRect(origin: .zero, size: size)
        let context = CGContext(url as CFURL, mediaBox: &media, nil)!
        let scale = min(size.width / content.width, size.height / content.height)
        for lines in pages {
            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: (size.width - content.width * scale) / 2, y: (size.height - content.height * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            var baseline = content.height - 72
            for line in lines {
                for piece in line.pieces {
                    let attributed = NSMutableAttributedString(string: piece.lead, attributes: [
                        NSAttributedString.Key(kCTFontAttributeName as String): font(line.size, bold: true),
                    ])
                    attributed.append(NSAttributedString(string: piece.text, attributes: [
                        NSAttributedString.Key(kCTFontAttributeName as String): font(line.size, bold: piece.bold),
                    ]))
                    context.textPosition = CGPoint(x: piece.x, y: baseline)
                    CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
                }
                baseline -= line.size * 1.45 + line.gapAfter
            }
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// 굵은 첫 문장 + 보통 글로 된 짧은 문단 셋(줄 사이 간격은 문단 안과 같다), 그 뒤에 표 제목과 4칸 × 5줄 표.
    private var synthetic: [[Line]] {
        let left: CGFloat = 72
        func para(_ bold: String, _ rest: String, _ more: String) -> [Line] {
            [Line(pieces: [Piece(text: rest, x: left, lead: bold)]),
             Line(pieces: [Piece(text: more, x: left)])]
        }
        var first: [Line] = []
        first += para("표준점수가 크게 올랐다.", " 평균이 낮고 점수가 넓게 퍼진 시험일수록 최고점이", "올라가는데 이번 시험이 바로 그런 경우였다.")
        first += para("만점의 가치가 커졌다.", " 최고점과 1등급 컷의 차이가 예전에는 거의 없었는데", "최근 시험에서는 다섯 점 넘게 벌어졌다.")
        first += para("등급 폭이 넓어졌다.", " 예전에는 1등급부터 4등급까지 좁게 몰려 있었는데", "지금은 등급 안에서 버틸 여지가 생겼다.")
        first[first.count - 1].gapAfter = 18
        first.append(Line(pieces: [Piece(text: "표 1. 시험별 등급 컷", x: left, bold: true)], size: 11, gapAfter: 4))
        let columns: [CGFloat] = [left, 190, 260, 330]
        let table = [["시험", "1컷", "2컷", "주제"],
                     ["2018 수능", "50", "47", "분배 정의"],
                     ["2019 수능", "50", "47", "시민 불복종"],
                     ["2025 6월 모평", "45", "40", "롤스 vs 노직"],
                     ["2026 수능", "44", "42", "사회 계약"]]
        for (r, row) in table.enumerated() {
            first.append(Line(pieces: zip(row, columns).map { Piece(text: $0, x: $1, bold: r == 0) }, gapAfter: 4))
        }
        first[first.count - 1].gapAfter = 18
        first.append(Line(pieces: [Piece(text: "표 아래에 이어지는 설명 문장이다. 이 문장은 표에 들어가면 안 된다.", x: left)]))
        // 둘째 쪽: 첫 쪽 끝 문장이 이어지지 않으니 쪽 나눔이 첫 덩어리에 붙는다
        let second = [Line(pieces: [Piece(text: "둘째 쪽의 첫 문단이다.", x: left)])]
        return [first, second]
    }

    @Test func syntheticTableAndBoldOpenedParagraphsAreRecovered() throws {
        let dir = try Fixtures.makeTempDir()
        let url = dir.appendingPathComponent("합성.pdf")
        makePDF(synthetic, at: url)
        let blocks = try PDFTextExtractor.extract(PDFDocument(url: url)!).paragraphs
        report("\n▶︎ 합성 PDF 덩어리 \(blocks.count)개\n" + describe(blocks))

        let tables = blocks.compactMap(\.table)
        #expect(tables.count == 1)
        #expect(tables.first == [["시험", "1컷", "2컷", "주제"],
                                 ["2018 수능", "50", "47", "분배 정의"],
                                 ["2019 수능", "50", "47", "시민 불복종"],
                                 ["2025 6월 모평", "45", "40", "롤스 vs 노직"],
                                 ["2026 수능", "44", "42", "사회 계약"]])

        let texts = blocks.filter { $0.table == nil }.map(\.text)
        #expect(texts.count == 6)
        #expect(texts.first?.hasPrefix("표준점수가 크게 올랐다.") == true)
        #expect(texts.first?.hasSuffix("그런 경우였다.") == true)
        #expect(texts.dropFirst().first?.hasPrefix("만점의 가치가 커졌다.") == true)
        #expect(texts.dropFirst(2).first?.hasPrefix("등급 폭이 넓어졌다.") == true)
        #expect(blocks.first?.runs.first?.bold == true)

        // 표 제목은 표 밖의 굵은 보통 문단, 표 아래 설명은 글
        let caption = try #require(blocks.first { $0.text.hasPrefix("표 1.") })
        #expect(caption.headingLevel == nil && caption.runs.allSatisfy(\.bold))
        let captionIndex = try #require(blocks.firstIndex(of: caption))
        #expect(blocks[captionIndex + 1].table != nil)
        #expect(blocks[captionIndex + 2].text.hasPrefix("표 아래에 이어지는"))

        // 쪽 나눔은 둘째 쪽 첫 덩어리에만
        #expect(blocks.filter(\.pageBreakBefore).map(\.text) == ["둘째 쪽의 첫 문단이다."])
    }

    @Test func shrunkPageGivesTheSameStructure() throws {
        let dir = try Fixtures.makeTempDir()
        let original = dir.appendingPathComponent("원래.pdf"), shrunk = dir.appendingPathComponent("축소.pdf")
        makePDF(synthetic, at: original)
        makePDF(synthetic, at: shrunk, size: CGSize(width: 842, height: 595))
        let a = try PDFTextExtractor.extract(PDFDocument(url: original)!).paragraphs
        let b = try PDFTextExtractor.extract(PDFDocument(url: shrunk)!).paragraphs
        #expect(a.count == b.count)
        #expect(a.map(\.text) == b.map(\.text))
        #expect(a.map(\.pageBreakBefore) == b.map(\.pageBreakBefore))
    }

    @Test func sentenceRunningOverThePageKeepsThePageBreakForTheNextBlock() {
        func line(_ text: String, page: Int, row: Int, width: CGFloat = 450) -> PDFLine {
            let top = 80 + CGFloat(row) * 14
            return PDFLine(page: page, runs: [DocumentRun(text)], minX: 72, top: top, bottom: top + 11,
                           width: width, fontSize: 11, pageHeight: 800)
        }
        let blocks = PDFTextExtractor.assemble([
            line("첫 쪽 문단입니다.", page: 0, row: 0, width: 100),
            line("이 문장은 쪽 끝에서 끊겼지만", page: 0, row: 2),
            line("다음 쪽에서 이어진다.", page: 1, row: 0, width: 150),
            line("새 문단.", page: 1, row: 2, width: 60),
        ])
        #expect(blocks.map(\.text) == ["첫 쪽 문단입니다.", "이 문장은 쪽 끝에서 끊겼지만 다음 쪽에서 이어진다.", "새 문단."])
        #expect(blocks.map(\.pageBreakBefore) == [false, false, true])
    }

    @Test func twoColumnProseIsNotATable() {
        // 왼쪽 단·오른쪽 단의 긴 문장 줄이 나란히 놓여도 표로 묶지 않는다
        var lines: [PDFLine] = []
        for row in 0..<6 {
            let top = 80 + CGFloat(row) * 14
            for (x, text) in [(CGFloat(50), "왼쪽 단에 들어간 긴 본문 문장이 이렇게 이어지고"), (CGFloat(310), "오른쪽 단에도 다른 긴 본문 문장이 이렇게 이어지는데")] {
                lines.append(PDFLine(page: 0, runs: [DocumentRun(text)], minX: x, top: top, bottom: top + 11,
                                     width: 235, fontSize: 11, pageHeight: 800))
            }
        }
        let blocks = PDFTextExtractor.assemble(lines)
        #expect(blocks.allSatisfy { $0.table == nil })
    }

    // MARK: 실제 기출 분석 PDF (있을 때만)

    private static let realPDF = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/CloudStorage/SynologyDrive-A/공부/생윤/기출8회 분석/생활과윤리_기출8회_종합.pdf")
    private static var hasRealPDF: Bool { FileManager.default.fileExists(atPath: realPDF.path) }

    /// 원본에서 [1, 3, 6, 10]쪽만 뽑은 PDF. `size`를 주면 그 쪽 크기에 같은 배율로 줄여 가운데 그린다.
    private func excerpt(at url: URL, size: CGSize? = nil) throws -> PDFDocument {
        let source = try #require(PDFDocument(url: Self.realPDF))
        let pages = [1, 3, 6, 10].compactMap { source.page(at: $0) }
        guard let size else {
            let document = PDFDocument()
            for (i, page) in pages.enumerated() { document.insert(page.copy() as! PDFPage, at: i) }
            #expect(document.write(to: url))
            return try #require(PDFDocument(url: url))
        }
        var media = CGRect(origin: .zero, size: size)
        let context = try #require(CGContext(url as CFURL, mediaBox: &media, nil))
        for page in pages {
            let box = page.bounds(for: .mediaBox)
            let scale = min(size.width / box.width, size.height / box.height)
            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: (size.width - box.width * scale) / 2, y: (size.height - box.height * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -box.minX, y: -box.minY)
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        return try #require(PDFDocument(url: url))
    }

    /// 결과 요약을 표준 오류로(테스트가 실패해도 남게)
    private func report(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    private func describe(_ blocks: [DocumentParagraph]) -> String {
        blocks.enumerated().map { i, b in
            let mark = b.pageBreakBefore ? "⤓ " : ""
            if let t = b.table { return "\(i) \(mark)[표 \(t.count)×\(t.first?.count ?? 0)] \(t.first ?? [])" }
            if let image = b.image { return "\(i) \(mark)[그림 \(Int(image.size.width))×\(Int(image.size.height))pt, \(image.png.count)B]" }
            return "\(i) \(mark)\(b.headingLevel.map { "H\($0) " } ?? "")\(b.text.prefix(70))"
        }.joined(separator: "\n")
    }

    @Test(.enabled(if: PDFStructureTests.hasRealPDF)) func realExamAnalysisPagesKeepTablesFiguresAndPages() throws {
        let dir = try Fixtures.makeTempDir()
        let document = try excerpt(at: dir.appendingPathComponent("기출4쪽.pdf"))
        let blocks = try PDFTextExtractor.extract(document).paragraphs
        report("\n▶︎ 기출 4쪽 (원래 비율) 덩어리 \(blocks.count)개\n" + describe(blocks))

        let tables = blocks.compactMap(\.table)
        #expect(tables.contains { $0.count == 9 && $0.first?.count == 9 })     // 8회 요약표: 머리줄 + 8줄, 9칸
        #expect(tables.contains { $0.count == 10 && $0.first?.count == 5 })    // 표 5: 머리줄 + 9줄, 5칸
        let summary = try #require(tables.first { $0.first?.count == 9 })
        #expect(summary[0] == ["시험", "1컷", "2컷", "3컷", "4컷", "표점 최고", "TOP15 평균 오답률", "최고 오답", "그 문항 주제"])
        #expect(summary[1] == ["2018 수능", "50", "47", "45", "39", "63", "30.6%", "9번 60.2%", "아리스토텔레스 · 롤스 · 노직 — 분배 정의"])

        // 그래프 두 개(그림 2, 문항별 오답률)는 그림으로, 숫자 더미 줄은 남지 않는다
        #expect(blocks.filter { $0.image != nil }.count == 2)
        let texts = blocks.filter { $0.table == nil && $0.image == nil }.map(\.text)
        #expect(!texts.contains { $0.hasPrefix("68 67") || $0.hasPrefix("50 18 수능") || $0.hasPrefix("65 65") })
        #expect(texts.contains { $0.hasPrefix("그림 2. 표준점수 최고점과 1등급 컷 표준점수") })
        #expect(texts.contains { $0.hasPrefix("두 막대의 차이가 클수록") })

        // 굵은 첫 문장으로 여는 짧은 문단들이 따로
        #expect(texts.contains { $0.hasPrefix("표준점수 최고점이 63 → 77로 14점 뛰었어.") && $0.hasSuffix("14점 높았어.") })
        #expect(texts.contains { $0.hasPrefix("만점의 가치가 커졌어.") })
        #expect(texts.contains { $0.hasPrefix("1→4등급 폭이") })

        // 쪽 나눔 세 번(2·3·4쪽 첫 덩어리)
        #expect(blocks.filter(\.pageBreakBefore).count == 3)
    }

    @Test(.enabled(if: PDFStructureTests.hasRealPDF)) func realExamAnalysisGivesTheSameStructureWhenShrunk() throws {
        let dir = try Fixtures.makeTempDir()
        let original = try PDFTextExtractor.extract(try excerpt(at: dir.appendingPathComponent("원래.pdf"))).paragraphs
        for size in [CGSize(width: 842, height: 595), CGSize(width: 960, height: 540)] {
            let shrunk = try PDFTextExtractor.extract(try excerpt(at: dir.appendingPathComponent("축소\(Int(size.width)).pdf"), size: size)).paragraphs
            report("\n▶︎ 기출 4쪽 (\(Int(size.width))×\(Int(size.height))) 덩어리 \(shrunk.count)개\n" + describe(shrunk))
            #expect(shrunk.count == original.count)
            #expect(shrunk.compactMap(\.table).map { [$0.count, $0.first?.count ?? 0] } == original.compactMap(\.table).map { [$0.count, $0.first?.count ?? 0] })
            #expect(shrunk.filter { $0.image != nil }.count == original.filter { $0.image != nil }.count)
            #expect(shrunk.map(\.pageBreakBefore) == original.map(\.pageBreakBefore))
            #expect(shrunk.map(\.headingLevel) == original.map(\.headingLevel))
        }
    }
}
