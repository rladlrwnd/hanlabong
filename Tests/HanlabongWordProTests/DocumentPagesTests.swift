import AppKit
import Foundation
import SkillEngine
import Testing
@testable import HanlabongWordPro

/// 문서 영역 4단계(쪽마다 나뉜 화면)를 화면 없이: 쪽 나눔 → 새 쪽 첫 줄, 넘치면 쪽이 늘고 줄기, 표 줄이 쪽 끝에서 안 잘리기, 저장 왕복.
/// HANLABONG_PAGE_SNAPSHOTS=<폴더>를 주면 기출 문서의 쪽 그림(PNG)을 거기 남긴다(눈으로 확인용, 화면을 띄우지 않는다)
@MainActor
struct DocumentPagesTests {
    private func folder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wp-pages-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func load(_ rich: RichDocument) throws -> LoadedDocument {
        let url = folder().appendingPathComponent("doc.docx")
        try RichDocumentWriter.write(rich, as: .docx).write(to: url)
        return try DocumentLoader.load(url)
    }

    private func pager(_ doc: LoadedDocument, layout: DocumentPageLayout = .single) -> DocumentPager {
        let pager = DocumentPager()
        pager.setLayout(layout)
        pager.setGeometry(pageSize: doc.pageSize, margins: doc.margins)
        pager.load(doc.attributed)
        return pager
    }

    private func pageIndex(ofCharacter location: Int, in pager: DocumentPager) -> Int? {
        let lm = pager.layoutManager
        let glyph = lm.glyphIndexForCharacter(at: location)
        return (lm.textContainer(forGlyphAt: glyph, effectiveRange: nil) as? PageTextContainer)?.pageIndex
    }

    /// 쪽 나눔 표시마다: 바로 뒤 문단이 새 쪽의 첫 줄인가(표시가 이미 쪽 맨 위면 같은 쪽이어도 된다)
    private func checkBreaks(_ pager: DocumentPager) {
        let storage = pager.storage
        let lm = pager.layoutManager
        for band in DocumentEditor.bandRanges(in: storage) where NSMaxRange(band) < storage.length {
            let follower = NSMaxRange(band)
            guard let markerPage = pageIndex(ofCharacter: band.location, in: pager),
                  let followerPage = pageIndex(ofCharacter: follower, in: pager) else {
                Issue.record("쪽 나눔 자리가 어느 쪽에도 없다: \(band)")
                continue
            }
            let markerTop = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: band.location), effectiveRange: nil).minY
            let followerTop = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: follower), effectiveRange: nil).minY
            #expect(followerPage > markerPage || markerTop < 0.5, "쪽 나눔 뒤 글이 같은 쪽에 남았다(\(follower))")
            // 새 쪽의 첫 줄(표면 위 칸 여백만큼은 괜찮다)
            #expect(followerTop <= 8, "쪽 나눔 뒤 글이 쪽 맨 위가 아니다: y=\(followerTop)")
        }
    }

    /// 표 줄마다: 한 쪽 안에 있고 쪽 끝에서 잘리지 않았는가(한 쪽보다 큰 줄은 빼고)
    private func checkRows(_ pager: DocumentPager) -> (rows: Int, pagesTouched: Set<Int>) {
        let storage = pager.storage
        let lm = pager.layoutManager
        var rows: [String: (pages: Set<Int>, top: CGFloat, bottom: CGFloat, limit: CGFloat)] = [:]
        var location = 0
        while location < storage.length {
            var effective = NSRange()
            let style = storage.attribute(.paragraphStyle, at: location, effectiveRange: &effective) as? NSParagraphStyle
            guard let cell = style?.textBlocks.first as? NSTextTableBlock else { location = max(NSMaxRange(effective), location + 1); continue }
            let range = storage.range(of: cell, at: location)
            let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            if glyphs.length > 0, let head = lm.textContainer(forGlyphAt: glyphs.location, effectiveRange: nil) as? PageTextContainer,
               let tail = lm.textContainer(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil) as? PageTextContainer {
                let bounds = lm.boundsRect(for: cell, glyphRange: glyphs)
                let key = "\(ObjectIdentifier(cell.table).hashValue)-\(cell.startingRow)"
                var row = rows[key] ?? ([], .greatestFiniteMagnitude, 0, head.size.height)
                row.pages.formUnion([head.pageIndex, tail.pageIndex])
                row.top = min(row.top, bounds.minY)
                row.bottom = max(row.bottom, bounds.maxY)
                rows[key] = row
            }
            location = max(NSMaxRange(range), location + 1)
        }
        var touched = Set<Int>()
        for (key, row) in rows {
            touched.formUnion(row.pages)
            guard row.bottom - row.top <= row.limit else { continue }     // 한 쪽보다 큰 줄은 어쩔 수 없다
            #expect(row.pages.count == 1, "표 줄 \(key)이 두 쪽에 걸쳤다")
            #expect(row.bottom <= row.limit + DocumentPager.rowSlack, "표 줄 \(key)이 쪽 끝에서 잘렸다: \(row.bottom) > \(row.limit)")
        }
        return (rows.count, touched)
    }

    // MARK: 기출 문서(쪽 나눔 3개 + 넘침)

    @Test func realExamDocumentPaginates() throws {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Desktop/Tasking/DRAGEDIT/테스트/변환 점검(수정 후)/1_원래비율_595x744/기출4쪽_pdf-word.docx")
        guard FileManager.default.fileExists(atPath: url.path) else { return }     // 다른 맥에서는 건너뛴다
        let doc = try DocumentLoader.load(url)
        let pager = pager(doc)
        let breaks = DocumentEditor.bandRanges(in: pager.storage).count
        print("기출: 쪽 나눔 \(breaks)개, 나뉜 쪽 \(pager.pages.count)쪽, 쪽 크기 \(doc.pageSize), 표 줄 고친 곳 \(pager.rules.forbidden.count)")
        #expect(breaks == doc.pageCount - 1)
        #expect(pager.pages.count >= breaks + 1)
        #expect(pager.pages.count <= (breaks + 1) * 4)          // 쪽 나눔마다 넘쳐도 몇 쪽 안쪽
        checkBreaks(pager)
        _ = checkRows(pager)
        #expect(pager.firstClippedRow(from: 0) == nil)
        // 모든 글이 어느 쪽에든 놓였다
        let last = try #require(pager.pages.last?.textView.textContainer)
        #expect(NSMaxRange(pager.layoutManager.glyphRange(for: last)) == pager.layoutManager.numberOfGlyphs)
        // 쪽 번호는 1, 2, 3 … 차례로(글에는 안 들어간다)
        #expect(pager.pages.map(\.number) == Array(1...pager.pages.count))
        #expect(!pager.storage.string.contains("1쪽"))

        if let out = ProcessInfo.processInfo.environment["HANLABONG_PAGE_SNAPSHOTS"] {
            let dir = URL(fileURLWithPath: out, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for paper in pager.pages {
                guard let rep = paper.bitmapImageRepForCachingDisplay(in: paper.bounds) else { continue }
                paper.cacheDisplay(in: paper.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("page-\(paper.number).png"))
            }
        }
    }

    // MARK: 큰 표

    @Test func bigTableFlowsRowByRowWithoutCuttingRows() throws {
        // 표 앞 글 양을 바꿔 가며(줄이 쪽 끝에 걸리는 자리가 매번 달라지게) 여러 번
        var moved = 0
        for intro in [0, 3, 7, 12, 18, 25] {
            var paragraphs: [DocumentParagraph] = (0..<intro).map { DocumentParagraph(runs: [DocumentRun("표 앞 문단 \($0). 표가 쪽 가운데에서 시작하게 글을 채운다.")]) }
            var table: [[String]] = [["번호", "내용"]]
            for i in 1...70 { table.append(["\(i)", i % 3 == 0 ? "여러 줄 칸\n둘째 줄\n셋째 줄\n넷째 줄\n다섯째 줄" : "칸 \(i)"]) }
            paragraphs.append(DocumentParagraph(runs: [], table: table))
            paragraphs.append(DocumentParagraph(runs: [DocumentRun("표 뒤 문단.")]))
            let doc = try load(RichDocument(title: "표", paragraphs: paragraphs))
            let pager = pager(doc)
            #expect(pager.pages.count >= 2)
            let (rows, touched) = checkRows(pager)
            #expect(rows == 71)
            #expect(touched.count >= 2)                 // 표가 여러 쪽에 걸쳐 흘렀다
            #expect(pager.firstClippedRow(from: 0) == nil)
            moved += pager.rules.forbidden.count
            print("큰 표(앞 문단 \(intro)개): \(pager.pages.count)쪽, 통째로 넘긴 줄 \(pager.rules.forbidden.count)개")
        }
        _ = moved
    }

    /// 칸 안에 문단이 여러 개인 표(직접 만든 표·붙여 넣은 표): TextKit은 쪽 끝에서 그 줄을 잘라 버리므로 통째로 넘겨야 한다
    @Test func clippedRowsWithParagraphCellsMoveWhole() throws {
        var moved = 0
        for intro in [0, 2, 5, 9] {
            let text = NSMutableAttributedString()
            for i in 0..<intro { text.append(NSAttributedString(string: "표 앞 문단 \(i).\n", attributes: DocumentEditor.bodyAttributes())) }
            let table = NSTextTable()
            table.numberOfColumns = 2
            table.setContentWidth(100, type: .percentageValueType)
            for r in 0..<40 {
                for c in 0..<2 {
                    let block = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                    block.setWidth(0.5, type: .absoluteValueType, for: .border)
                    block.setWidth(3, type: .absoluteValueType, for: .padding)
                    let style = NSMutableParagraphStyle()
                    style.textBlocks = [block]
                    let body = c == 1 && r % 3 == 1 ? "줄1\n줄2\n줄3\n줄4\n줄5\n줄6\n줄7" : "칸 \(r)-\(c)"
                    text.append(NSAttributedString(string: body + "\n", attributes: [.font: NSFont.systemFont(ofSize: 11), .paragraphStyle: style]))
                }
            }
            text.append(NSAttributedString(string: "표 뒤.\n", attributes: DocumentEditor.bodyAttributes()))
            let pager = DocumentPager()
            pager.setGeometry(pageSize: CGSize(width: 420, height: 420), margins: NSEdgeInsets(top: 30, left: 30, bottom: 30, right: 30))
            pager.load(text)
            let (rows, touched) = checkRows(pager)
            #expect(rows == 40)
            #expect(touched.count >= 2)
            #expect(pager.firstClippedRow(from: 0) == nil)
            moved += pager.rules.forbidden.count
        }
        _ = moved                                       // 이 배치에선 글이 잘리는 줄이 안 생긴다(멈추지 않고 잘림이 없는지만 본다)
    }

    // MARK: 표 머리줄 반복 · 키 큰 줄

    /// 표가 쪽을 넘어 이어지면 이어지는 쪽 맨 위에 머리줄이 다시 보인다(화면에만: 저장 글에는 안 들어가고, 글 뷰는 그만큼 내려간다)
    @Test func tableHeaderRepeatsOnContinuationPages() throws {
        var table: [[String]] = [["머리번호", "머리내용"]]
        for i in 1...90 { table.append(["\(i)", "칸 \(i)"]) }
        let doc = try load(RichDocument(title: "표", paragraphs: [
            DocumentParagraph(runs: [DocumentRun("표 앞 문단.")]),
            DocumentParagraph(runs: [], table: table),
            DocumentParagraph(runs: [DocumentRun("표 뒤 문단.")]),
        ]))
        let pager = pager(doc)
        #expect(pager.pages.count >= 3)
        #expect(pager.pages[0].repeatedHeader == nil)
        let content = pager.contentSize
        var repeated = 0
        for (index, paper) in pager.pages.enumerated() where index > 0 {
            let container = try #require(paper.textView.textContainer)
            let glyphs = pager.layoutManager.glyphRange(for: container)
            guard glyphs.length > 0 else { continue }
            let first = pager.layoutManager.characterIndexForGlyph(at: glyphs.location)
            let inTable = (pager.storage.attribute(.paragraphStyle, at: first, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.first is NSTextTableBlock
            guard inTable else { continue }
            let header = try #require(paper.repeatedHeader, "표가 이어지는 \(index + 1)쪽에 머리줄이 없다")
            repeated += 1
            #expect(header.height > 5 && header.height < content.height * DocumentPager.maxHeaderShare)
            // 글 상자는 머리줄만큼 줄고 글 뷰는 그만큼 내려갔다
            #expect(abs(container.size.height - (content.height - header.height)) < 0.5)
            #expect(abs(paper.textView.frame.minY - (pager.margins.top + header.height)) < 0.5)
            // 종이를 그려 보면 머리줄 자리에 옅은 회색 배경이 있다(흰색이 아니다)
            let rep = try #require(paper.bitmapImageRepForCachingDisplay(in: paper.bounds))
            paper.cacheDisplay(in: paper.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / paper.bounds.width
            let color = try #require(rep.colorAt(x: Int((pager.margins.left + content.width * 0.9) * scale), y: Int((pager.margins.top + header.height / 2) * scale)))
            #expect((color.usingColorSpace(.deviceRGB)?.redComponent ?? 1) < 0.97, "머리줄 배경이 안 그려졌다")
        }
        #expect(repeated >= 2)
        // 보이기만 한다: 저장소에 머리줄 글이 한 번만 있고, 표 줄은 91개 그대로
        #expect(pager.storage.string.components(separatedBy: "머리번호").count == 2)
        let rich = RichDocumentEditing.document(from: pager.storage, title: "표", pageSize: doc.pageSize)
        #expect(rich.paragraphs.first { $0.table != nil }?.table?.count == 91)
        // 모든 글이 놓였고, 잘린 줄이 없다
        let last = try #require(pager.pages.last?.textView.textContainer)
        #expect(NSMaxRange(pager.layoutManager.glyphRange(for: last)) == pager.layoutManager.numberOfGlyphs)
        #expect(pager.firstClippedRow(from: 0) == nil)
        // 이어 보기로 바꾸면 머리줄 반복은 사라지고, 다시 쪽 보기로 오면 돌아온다
        pager.setLayout(.continuous)
        #expect(pager.pages.allSatisfy { $0.repeatedHeader == nil })
        pager.setLayout(.single)
        #expect(pager.pages.dropFirst().contains { $0.repeatedHeader != nil })
    }

    /// 머리줄 배경이 없는 표(직접 만든 표)는 머리줄로 보지 않아 반복하지 않는다
    @Test func tableWithoutShadedHeaderDoesNotRepeat() throws {
        let text = NSMutableAttributedString()
        let table = NSTextTable()
        table.numberOfColumns = 2
        table.setContentWidth(100, type: .percentageValueType)
        for r in 0..<60 {
            for c in 0..<2 {
                let block = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                block.setWidth(0.5, type: .absoluteValueType, for: .border)
                let style = NSMutableParagraphStyle()
                style.textBlocks = [block]
                text.append(NSAttributedString(string: "칸 \(r)-\(c)\n", attributes: [.font: NSFont.systemFont(ofSize: 11), .paragraphStyle: style]))
            }
        }
        let pager = DocumentPager()
        pager.setGeometry(pageSize: CGSize(width: 420, height: 420), margins: NSEdgeInsets(top: 30, left: 30, bottom: 30, right: 30))
        pager.load(text)
        #expect(pager.pages.count >= 2)
        #expect(pager.pages.allSatisfy { $0.repeatedHeader == nil })
    }

    /// 한 쪽보다 키 큰 표 줄: 지금은 접힌 줄을 이어 보내지 못한다(시도하면 AppKit 레이아웃이 끝없이 돈다 → DocumentPager.firstClippedRow 주석).
    /// 그래도 멈추지 않고, 모든 글이 상자에 놓이고, 표 뒤 글이 이어지고, 머리줄 반복이 틀어지지 않는지만 지킨다
    @Test func tallRowDoesNotHangOrLoseFollowingText() throws {
        let text = NSMutableAttributedString()
        let table = NSTextTable()
        table.numberOfColumns = 2
        table.setContentWidth(100, type: .percentageValueType)
        for r in 0..<5 {
            for c in 0..<2 {
                let block = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                block.setWidth(0.5, type: .absoluteValueType, for: .border)
                if r == 0 { block.backgroundColor = NSColor(white: 0.9, alpha: 1) }
                let style = NSMutableParagraphStyle()
                style.textBlocks = [block]
                let body = c == 1 && r == 2 ? (1...120).map { "키 큰 칸 줄 \($0)" }.joined(separator: "\n") : "칸 \(r)-\(c)"
                text.append(NSAttributedString(string: body + "\n", attributes: [.font: NSFont.systemFont(ofSize: 11), .paragraphStyle: style]))
            }
        }
        text.append(NSAttributedString(string: "표 뒤.\n", attributes: DocumentEditor.bodyAttributes()))
        let pager = DocumentPager()
        pager.setGeometry(pageSize: CGSize(width: 420, height: 420), margins: NSEdgeInsets(top: 30, left: 30, bottom: 30, right: 30))
        pager.load(text)
        let lm = pager.layoutManager
        let lastContainer = try #require(pager.pages.last?.textView.textContainer)
        #expect(NSMaxRange(lm.glyphRange(for: lastContainer)) == lm.numberOfGlyphs)
        let after = (pager.storage.string as NSString).range(of: "표 뒤.")
        #expect(after.location != NSNotFound)
        #expect(pager.pages.count >= 2)
    }

    // MARK: 고치면 쪽이 늘고 줄기

    @Test func editingGrowsAndShrinksPages() throws {
        let doc = try load(RichDocument(title: "짧은 글", paragraphs: [
            DocumentParagraph(runs: [DocumentRun("첫째 문단.")]),
            DocumentParagraph(runs: [DocumentRun("둘째 문단.")]),
            DocumentParagraph(runs: [DocumentRun("셋째 문단.")]),
        ]))
        let pager = pager(doc)
        let editor = DocumentEditor()
        let tv = try #require(pager.pages.first?.textView)
        editor.attach(tv)
        editor.pager = pager
        editor.documentLoaded(pageSize: doc.pageSize, margins: doc.margins)
        #expect(pager.pages.count == 1)

        // 긴 글을 넣으면 쪽이 늘어난다
        let long = String(repeating: "쪽을 넘치게 하는 긴 문장이야. ", count: 40) + "\n"
        let text = NSAttributedString(string: String(repeating: long, count: 12), attributes: DocumentEditor.bodyAttributes())
        editor.replace(NSRange(location: 0, length: 0), with: text)
        pager.syncNow()
        let grown = pager.pages.count
        #expect(grown >= 3)
        // 커서(넣은 글 끝)가 놓인 쪽의 뷰를 찾는다
        let cursorView = editor.textView(containing: tv.selectedRange().location)
        #expect(cursorView !== tv)

        // 되돌리면 다시 한 쪽
        editor.undo.undo()
        pager.syncNow()
        #expect(pager.pages.count == 1)
        #expect(pager.storage.string.hasPrefix("첫째 문단."))

        // 쪽 나눔을 넣으면 그 뒤 글이 2쪽 첫 줄로, ⌫로 지우면 다시 한 쪽
        let second = (pager.storage.string as NSString).range(of: "둘째 문단.").location
        tv.setSelectedRange(NSRange(location: second, length: 0))
        editor.insertPageBreak()
        pager.syncNow()
        #expect(pager.pages.count == 2)
        let follower = (pager.storage.string as NSString).range(of: "둘째 문단.").location
        #expect(pageIndex(ofCharacter: follower, in: pager) == 1)
        checkBreaks(pager)
        tv.setSelectedRange(NSRange(location: follower, length: 0))
        tv.deleteBackward(nil)
        pager.syncNow()
        #expect(DocumentEditor.bandRanges(in: pager.storage).isEmpty)
        #expect(pager.pages.count == 1)
    }

    // MARK: 저장 왕복

    @Test func saveRoundTripKeepsPageBreaks() throws {
        let doc = try load(RichDocument(title: "왕복", paragraphs: [
            DocumentParagraph(runs: [DocumentRun("1쪽 글.")]),
            DocumentParagraph(runs: [DocumentRun("2쪽 제목")], headingLevel: 1, pageBreakBefore: true),
            DocumentParagraph(runs: [], table: [["가", "나"], ["1", "2"]]),
            DocumentParagraph(runs: [DocumentRun("3쪽 글.")], pageBreakBefore: true),
        ]))
        let pager = pager(doc)
        #expect(pager.pages.count == 3)
        checkBreaks(pager)
        let rich = RichDocumentEditing.document(from: pager.storage, title: "왕복", pageSize: doc.pageSize)
        #expect(rich.paragraphs.filter(\.pageBreakBefore).count == 2)
        #expect(!rich.paragraphs.contains { $0.text.contains(DocumentLoader.pageBreakMark) })
        #expect(rich.paragraphs.first { $0.text.contains("2쪽 제목") }?.pageBreakBefore == true)
        #expect(rich.paragraphs.contains { $0.table?.first == ["가", "나"] })
        // 다시 써서 읽어도 같은 쪽 수
        let again = try load(rich)
        #expect(DocumentEditor.bandRanges(in: again.attributed).count == 2)
        #expect(self.pager(again).pages.count == 3)
    }

    // MARK: 보기 방식

    @Test func spreadAndContinuousLayouts() throws {
        var paragraphs: [DocumentParagraph] = []
        for i in 0..<5 {
            paragraphs.append(DocumentParagraph(runs: [DocumentRun("\(i + 1)쪽 글.")], pageBreakBefore: i > 0))
        }
        let doc = try load(RichDocument(title: "다섯 쪽", paragraphs: paragraphs))
        let pager = pager(doc, layout: .spread)
        #expect(pager.pages.count == 5)
        pager.documentView.arrange(minWidth: 1600, gutter: 20)
        let frames = pager.pages.map(\.frame)
        let center = pager.documentView.frame.width / 2
        // 1쪽은 오른쪽에 혼자, 2·3과 4·5는 나란히(왼쪽·오른쪽)
        #expect(frames[0].minX > center)
        #expect(frames[1].maxX < center && frames[2].minX > center)
        #expect(frames[1].minY == frames[2].minY && frames[1].minY > frames[0].maxY)
        #expect(frames[3].minY == frames[4].minY && frames[3].minY > frames[1].maxY)

        // 이어 보기: 종이 한 장, 쪽 나눔은 띠 높이의 줄
        pager.setLayout(.continuous)
        #expect(pager.pages.count == 1)
        let band = try #require(DocumentEditor.bandRanges(in: pager.storage).first)
        let lm = pager.layoutManager
        let line = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: band.location), effectiveRange: nil)
        #expect(abs(line.height - DocumentPager.bandHeight) < 0.5)
        #expect(pager.pages[0].frame.height > doc.pageSize.height * 0.5)
        #expect(!pager.pages[0].showsNumber)

        // 다시 한 쪽씩: 다섯 쪽
        pager.setLayout(.single)
        #expect(pager.pages.count == 5)
        checkBreaks(pager)
        pager.documentView.arrange(minWidth: 800, gutter: 20)
        let single = pager.pages.map(\.frame)
        #expect(Set(single.map(\.minX)).count == 1)
        #expect(zip(single, single.dropFirst()).allSatisfy { $0.maxY < $1.minY })
    }
}
