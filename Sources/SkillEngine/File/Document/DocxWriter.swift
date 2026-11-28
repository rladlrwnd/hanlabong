import CoreGraphics
import Foundation

/// 문단·제목·표·그림·글자 모양을 담은 Word(.docx) 파일을 직접 만든다(Office Open XML을 zip으로).
/// 제목은 Word의 "제목 1·2·3" 스타일로 들어가서 Word의 탐색 창·목차에 그대로 잡힌다.
/// 문단 모양(정렬·들여쓰기·간격·줄 간격), 글자 모양(밑줄·취소선·첨자·색·크기·글꼴·링크), 탭·줄바꿈,
/// 표(칸 너비·합친 칸·머리줄·테두리 유무), 쪽 여백, 머리글·꼬리글·쪽 번호, 본문 글꼴·크기를 쓴다.
enum DocxWriter {
    /// 쓸 문서 내용(RichDocument·ExtractedDocument 어느 쪽에서든 이걸로 모은다)
    struct Input {
        var paragraphs: [DocumentParagraph]
        var pageSize: CGSize
        var margins: DocumentMargins?
        var header: [DocumentParagraph] = []
        var footer: [DocumentParagraph] = []
        var showPageNumber = false
        /// 본문 글자 크기(반 포인트 단위)
        var bodyHalf = 22
        var bodyFont: String?
    }

    struct Built {
        var xml: String
        var images: [Data]
        var links: [String] = []
        var headerXML: String?
        var footerXML: String?
    }

    static func make(_ document: ExtractedDocument, title: String, date: Date = Date()) -> Data {
        let body = Int((min(max(document.bodyFontSize, 8), 16) * 2).rounded())
        return make(Input(paragraphs: document.paragraphs, pageSize: document.pageSize, bodyHalf: body), title: title, date: date)
    }

    /// 새 문서 틀에서 바로: 여백·머리글·꼬리글·쪽 번호·본문 글꼴과 크기까지 쓴다
    static func make(_ document: RichDocument, date: Date = Date()) -> Data {
        let half = document.bodyFontSize.map { Int((min(max($0, 5), 40) * 2).rounded()) } ?? 22
        let input = Input(paragraphs: document.paragraphs, pageSize: document.resolvedPageSize, margins: document.margins,
                          header: document.header, footer: document.footer, showPageNumber: document.showPageNumber,
                          bodyHalf: half, bodyFont: document.bodyFontName)
        return make(input, title: document.title, date: date)
    }

    static func make(_ input: Input, title: String, date: Date = Date()) -> Data {
        let built = build(input)
        var zip = ZipWriter(date: date)
        zip.add("[Content_Types].xml", contentTypes(header: built.headerXML != nil, footer: built.footerXML != nil))
        zip.add("_rels/.rels", packageRelationships)
        zip.add("docProps/core.xml", core(title: title, date: date))
        zip.add("docProps/app.xml", app)
        zip.add("word/_rels/document.xml.rels", documentRelationships(imageCount: built.images.count, links: built.links,
                                                                      header: built.headerXML != nil, footer: built.footerXML != nil))
        zip.add("word/styles.xml", styles(bodyHalf: input.bodyHalf, font: input.bodyFont))
        zip.add("word/document.xml", built.xml)
        if let header = built.headerXML { zip.add("word/header1.xml", header) }
        if let footer = built.footerXML { zip.add("word/footer1.xml", footer) }
        for (index, png) in built.images.enumerated() { zip.add("word/media/image\(index + 1).png", png) }
        return zip.finish()
    }

    // MARK: 쪽 설정

    /// 여백(트윕): 쪽 짧은 변의 8%, 다만 0.25인치~1인치 사이
    static func margin(for pageSize: CGSize) -> Int {
        let short = min(pageSize.width, pageSize.height)
        return min(max(Int((short * 0.08 * 20).rounded()), 360), 1440)
    }

    /// 본문 폭(트윕)
    static func textWidth(for pageSize: CGSize) -> Int {
        max(Int((pageSize.width * 20).rounded()) - 2 * margin(for: pageSize), 720)
    }

    /// 쓸 여백(트윕): 문서에 여백이 있으면 그것(본문이 720트윕 밑으로 줄지 않게 한도만), 없으면 위 규칙
    static func margins(for input: Input) -> (top: Int, left: Int, bottom: Int, right: Int) {
        let width = Int((input.pageSize.width * 20).rounded()), height = Int((input.pageSize.height * 20).rounded())
        guard let m = input.margins else {
            let value = margin(for: input.pageSize)
            return (value, value, value, value)
        }
        func twips(_ pt: CGFloat) -> Int { max(Int((pt * 20).rounded()), 0) }
        var left = twips(m.left), right = twips(m.right), top = twips(m.top), bottom = twips(m.bottom)
        if left + right > width - 720 { let scale = Double(max(width - 720, 0)) / Double(max(left + right, 1)); left = Int(Double(left) * scale); right = Int(Double(right) * scale) }
        if top + bottom > height - 720 { let scale = Double(max(height - 720, 0)) / Double(max(top + bottom, 1)); top = Int(Double(top) * scale); bottom = Int(Double(bottom) * scale) }
        return (top, left, bottom, right)
    }

    // MARK: 본문

    static func body(_ document: ExtractedDocument) -> String { build(document).xml }

    /// 본문 XML과, word/media에 넣을 그림(번호 순서대로, 관계 번호는 rId(10+순번))
    static func build(_ document: ExtractedDocument) -> (xml: String, images: [Data]) {
        let body = Int((min(max(document.bodyFontSize, 8), 16) * 2).rounded())
        let built = build(Input(paragraphs: document.paragraphs, pageSize: document.pageSize, bodyHalf: body))
        return (built.xml, built.images)
    }

    /// 쓰는 동안 모으는 것: 그림·링크, 본문 폭·높이
    private final class Context {
        var images: [Data] = []
        var links: [String] = []
        let textWidth: Int
        let textHeight: Int
        let cellHalf: Int
        init(textWidth: Int, textHeight: Int, bodyHalf: Int) {
            self.textWidth = textWidth
            self.textHeight = textHeight
            cellHalf = max(bodyHalf - 3, 14)        // 표 안 글은 본문보다 1.5pt 작게(11pt → 9.5pt)
        }
        /// 링크 주소 → 관계 번호(rId100~)
        func linkID(_ url: String) -> String {
            if let index = links.firstIndex(of: url) { return "rId\(100 + index)" }
            links.append(url)
            return "rId\(100 + links.count - 1)"
        }
    }

    private static let namespaces = #"xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture""#

    static func build(_ input: Input) -> Built {
        let pageWidth = Int((input.pageSize.width * 20).rounded()), pageHeight = Int((input.pageSize.height * 20).rounded())
        let m = margins(for: input)
        let textWidth = max(pageWidth - m.left - m.right, 720)
        let textHeight = max(pageHeight - m.top - m.bottom, 720)
        let context = Context(textWidth: textWidth, textHeight: textHeight, bodyHalf: input.bodyHalf)
        let prolog = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
        var xml = prolog + "<w:document \(namespaces)><w:body>"
        for paragraph in input.paragraphs { xml += blockXML(paragraph, context) }

        // 머리글·꼬리글(글 문단만. 쪽 번호는 꼬리글 맨 아래 가운데)
        let headerParagraphs = input.header.filter { $0.table == nil && $0.image == nil }
        let footerParagraphs = input.footer.filter { $0.table == nil && $0.image == nil }
        var headerXML: String?, footerXML: String?
        if !headerParagraphs.isEmpty {
            headerXML = prolog + "<w:hdr \(namespaces)>" + headerParagraphs.map { textParagraphXML($0, context, links: false) }.joined() + "</w:hdr>"
        }
        if !footerParagraphs.isEmpty || input.showPageNumber {
            var inner = footerParagraphs.map { textParagraphXML($0, context, links: false) }.joined()
            if input.showPageNumber { inner += pageNumberParagraph }
            footerXML = prolog + "<w:ftr \(namespaces)>" + inner + "</w:ftr>"
        }

        // 쪽 크기는 원본 그대로(w·h를 맞바꾸지 않는다). 가로 쪽(폭 > 높이)이면 orient="landscape"를 단다 (1포인트 = 20트윕)
        let orient = pageWidth > pageHeight ? #" w:orient="landscape""# : ""
        var sect = "<w:sectPr>"
        if headerXML != nil { sect += #"<w:headerReference w:type="default" r:id="rId2"/>"# }
        if footerXML != nil { sect += #"<w:footerReference w:type="default" r:id="rId3"/>"# }
        let headerDistance = min(720, m.top / 2), footerDistance = min(720, m.bottom / 2)
        sect += #"<w:pgSz w:w="\#(pageWidth)" w:h="\#(pageHeight)"\#(orient)/><w:pgMar w:top="\#(m.top)" w:right="\#(m.right)" w:bottom="\#(m.bottom)" w:left="\#(m.left)" w:header="\#(headerDistance)" w:footer="\#(footerDistance)" w:gutter="0"/></w:sectPr>"#
        xml += sect + "</w:body></w:document>"
        return Built(xml: xml, images: context.images, links: context.links, headerXML: headerXML, footerXML: footerXML)
    }

    /// 쪽 번호(PAGE 필드)가 든 가운데 문단
    private static let pageNumberParagraph = #"<w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText xml:space="preserve"> PAGE </w:instrText></w:r><w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>1</w:t></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>"#

    /// 앞에서 쪽을 넘기기 위한 1pt짜리 빈 문단(표 앞에 쓴다)
    private static let pageBreakParagraph = #"<w:p><w:pPr><w:pageBreakBefore/><w:spacing w:before="0" w:after="0" w:line="20" w:lineRule="exact"/></w:pPr></w:p>"#

    /// 덩어리 하나(표·그림·글 문단)
    private static func blockXML(_ paragraph: DocumentParagraph, _ context: Context) -> String {
        if let table = paragraph.table, table.contains(where: { !$0.isEmpty }) {
            var xml = paragraph.pageBreakBefore ? pageBreakParagraph : ""
            xml += tableXML(table, width: context.textWidth, layout: paragraph.tableLayout, cellHalf: context.cellHalf)
            xml += #"<w:p><w:pPr><w:spacing w:before="0" w:after="120"/></w:pPr></w:p>"#   // 표 뒤에는 문단이 꼭 있어야 한다
            return xml
        }
        if let image = paragraph.image, image.size.width > 0, image.size.height > 0, !image.png.isEmpty {
            context.images.append(image.png)
            let index = context.images.count
            // 포인트 → EMU(1pt = 12700). 본문 폭·높이보다 크면 비율을 지키며 줄인다
            var cx = Double(image.size.width) * 12700, cy = Double(image.size.height) * 12700
            let maxX = Double(context.textWidth) * 635, maxY = Double(context.textHeight) * 635     // 트윕 → EMU(1트윕 = 635)
            let scale = min(1, maxX / cx, maxY / cy)
            cx = max((cx * scale).rounded(), 1); cy = max((cy * scale).rounded(), 1)
            return "<w:p><w:pPr>" + (paragraph.pageBreakBefore ? "<w:pageBreakBefore/>" : "")
                + #"<w:spacing w:before="0" w:after="120" w:line="240" w:lineRule="auto"/>"# + justification(paragraph.alignment) + "</w:pPr>"
                + drawing(index: index, cx: Int(cx), cy: Int(cy)) + "</w:p>"
        }
        return textParagraphXML(paragraph, context, links: true)
    }

    private static func justification(_ alignment: DocumentAlignment?) -> String {
        switch alignment {
        case .center: return #"<w:jc w:val="center"/>"#
        case .right: return #"<w:jc w:val="right"/>"#
        case .justify: return #"<w:jc w:val="both"/>"#
        case .left: return #"<w:jc w:val="left"/>"#
        case nil: return ""
        }
    }

    /// 문단 속성(순서는 스키마대로: 스타일, 쪽 나눔, 간격, 들여쓰기, 정렬)
    private static func paragraphProperties(_ paragraph: DocumentParagraph) -> String {
        var xml = ""
        if let level = paragraph.headingLevel { xml += #"<w:pStyle w:val="Heading\#(level)"/>"# }
        if paragraph.pageBreakBefore { xml += "<w:pageBreakBefore/>" }
        if paragraph.ruleAbove != nil || paragraph.ruleBelow != nil {
            // 문단 위·아래 선: 굵기는 1/8pt, 글자와의 거리는 pt(워드 한도 31pt)
            func edge(_ name: String, _ rule: DocumentRule?) -> String {
                guard let rule else { return "" }
                let size = min(max(Int((rule.width * 8).rounded()), 2), 96), space = min(max(Int(rule.gap.rounded()), 0), 31)
                return #"<w:\#(name) w:val="single" w:sz="\#(size)" w:space="\#(space)" w:color="\#(rule.colorHex)"/>"#
            }
            xml += "<w:pBdr>" + edge("top", paragraph.ruleAbove) + edge("bottom", paragraph.ruleBelow) + "</w:pBdr>"
        }
        var spacing = ""
        if let before = paragraph.spaceBefore { spacing += #" w:before="\#(Int((before * 20).rounded()))""# }
        if let after = paragraph.spaceAfter { spacing += #" w:after="\#(Int((after * 20).rounded()))""# }
        if let line = paragraph.lineSpacing, line > 0 { spacing += #" w:line="\#(Int((line * 240).rounded()))" w:lineRule="auto""# }
        if !spacing.isEmpty { xml += "<w:spacing\(spacing)/>" }
        let left = Int((paragraph.leftIndent * 20).rounded()), first = Int((paragraph.firstLineIndent * 20).rounded())
        let right = Int((max(0, paragraph.rightIndent) * 20).rounded())
        if left != 0 || first != 0 || right != 0 {
            var ind = #" w:left="\#(left)""#
            if right != 0 { ind += #" w:right="\#(right)""# }
            if first > 0 { ind += #" w:firstLine="\#(first)""# } else if first < 0 { ind += #" w:hanging="\#(-first)""# }
            xml += "<w:ind\(ind)/>"
        }
        xml += justification(paragraph.alignment)
        return xml
    }

    private static func textParagraphXML(_ paragraph: DocumentParagraph, _ context: Context, links: Bool) -> String {
        var xml = "<w:p>"
        let properties = paragraphProperties(paragraph)
        if !properties.isEmpty { xml += "<w:pPr>" + properties + "</w:pPr>" }
        for run in paragraph.runs where !run.text.isEmpty {
            var piece = runXML(run, hyperlinkStyle: links && run.linkURL != nil)
            if links, let url = run.linkURL { piece = #"<w:hyperlink r:id="\#(context.linkID(url))">"# + piece + "</w:hyperlink>" }
            xml += piece
        }
        return xml + "</w:p>"
    }

    /// 글 조각: 탭은 `<w:tab/>`, 줄바꿈은 `<w:br/>`
    private static func runXML(_ run: DocumentRun, hyperlinkStyle: Bool = false, forcedBold: Bool = false, halfPoints: Int? = nil) -> String {
        var rPr = ""
        if hyperlinkStyle && run.colorHex == nil && !run.underline { rPr += #"<w:rStyle w:val="Hyperlink"/>"# }
        if let font = run.fontName, !font.isEmpty {
            let name = escape(font)
            rPr += #"<w:rFonts w:ascii="\#(name)" w:hAnsi="\#(name)" w:eastAsia="\#(name)" w:cs="\#(name)"/>"#
        }
        if run.bold || forcedBold { rPr += "<w:b/>" }
        if run.italic { rPr += "<w:i/>" }
        if run.strike { rPr += "<w:strike/>" }
        if let color = run.colorHex { rPr += #"<w:color w:val="\#(color)"/>"# }
        if let size = run.fontSize ?? halfPoints.map({ CGFloat($0) / 2 }), size > 0 {
            let half = Int((size * 2).rounded())
            rPr += #"<w:sz w:val="\#(half)"/><w:szCs w:val="\#(half)"/>"#
        }
        if run.underline { rPr += #"<w:u w:val="single"/>"# }
        if run.script > 0 { rPr += #"<w:vertAlign w:val="superscript"/>"# } else if run.script < 0 { rPr += #"<w:vertAlign w:val="subscript"/>"# }
        var xml = "<w:r>" + (rPr.isEmpty ? "" : "<w:rPr>\(rPr)</w:rPr>")
        var buffer = ""
        func flush() {
            guard !buffer.isEmpty else { return }
            xml += #"<w:t xml:space="preserve">"# + escape(buffer) + "</w:t>"
            buffer = ""
        }
        var previousWasReturn = false
        for scalar in run.text.unicodeScalars {
            switch scalar {
            case "\t": flush(); xml += "<w:tab/>"; previousWasReturn = false
            case "\r": flush(); xml += "<w:br/>"; previousWasReturn = true
            case "\n":
                if !previousWasReturn { flush(); xml += "<w:br/>" }
                previousWasReturn = false
            case "\u{0B}", "\u{2028}": flush(); xml += "<w:br/>"; previousWasReturn = false
            default: buffer.unicodeScalars.append(scalar); previousWasReturn = false
            }
        }
        flush()
        return xml + "</w:r>"
    }

    private static func drawing(index: Int, cx: Int, cy: Int) -> String {
        "<w:r><w:drawing>"
            + #"<wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\#(cx)" cy="\#(cy)"/><wp:effectExtent l="0" t="0" r="0" b="0"/>"#
            + #"<wp:docPr id="\#(index)" name="그림 \#(index)"/><wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>"#
            + #"<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic>"#
            + #"<pic:nvPicPr><pic:cNvPr id="\#(index)" name="image\#(index).png"/><pic:cNvPicPr/></pic:nvPicPr>"#
            + #"<pic:blipFill><a:blip r:embed="rId\#(9 + index)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>"#
            + #"<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\#(cx)" cy="\#(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>"#
            + "</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>"
    }

    // MARK: 표

    /// 글자 길이(한글·한자 등 넓은 글자는 2칸으로 센다)
    private static func displayLength(_ text: String) -> Int {
        text.components(separatedBy: "\n").map { line in
            line.unicodeScalars.reduce(0) { $0 + ($1.value >= 0x1100 ? 2 : 1) }
        }.max() ?? 0
    }

    /// 칸 너비(트윕): 글자 길이에 비례하되 너무 좁거나 넓지 않게, 합은 본문 폭에 정확히 맞춘다
    static func columnWidths(_ rows: [[String]], count: Int, total: Int) -> [Int] {
        var weights = [Double](repeating: 4, count: count)
        for row in rows {
            for (column, cell) in row.enumerated() where column < count {
                weights[column] = max(weights[column], Double(min(displayLength(cell), 40)))
            }
        }
        return distribute(weights, total: total, count: count)
    }

    /// 비율(weights)대로 본문 폭에 나눈다. 너무 좁은 칸은 늘리고 차이는 가장 넓은 칸이 받는다
    private static func distribute(_ weights: [Double], total: Int, count: Int) -> [Int] {
        let sum = max(weights.reduce(0, +), 0.0001)
        let minWidth = min(total / (count * 2), 600)
        var widths = weights.map { max(Int((Double(total) * $0 / sum).rounded()), minWidth) }
        let diff = total - widths.reduce(0, +)
        if let widest = widths.indices.max(by: { widths[$0] < widths[$1] }) { widths[widest] = max(widths[widest] + diff, minWidth) }
        return widths
    }

    /// 표. `layout`이 있으면 그대로(머리줄은 headerRows만, 테두리 유무, 칸 너비 비율, 합친 칸), 없으면 옛 방식(첫 줄 머리줄·테두리)
    static func tableXML(_ rows: [[String]], width: Int, layout: DocumentTableLayout? = nil, cellHalf: Int = 19) -> String {
        let count = max(rows.map(\.count).max() ?? 1, 1)
        let widths: [Int]
        if let ratios = layout?.columnWidths, ratios.count == count, ratios.allSatisfy({ $0 > 0 }) {
            widths = distribute(ratios.map(Double.init), total: width, count: count)
        } else {
            widths = columnWidths(rows, count: count, total: width)
        }
        let headerRows = layout?.headerRows ?? 1
        let borders = layout?.borders ?? true
        let spans = layout?.spans ?? []

        let border = { (side: String) in
            borders ? #"<w:\#(side) w:val="single" w:sz="4" w:space="0" w:color="808080"/>"# : #"<w:\#(side) w:val="nil"/>"#
        }
        var xml = "<w:tbl><w:tblPr>"
            + #"<w:tblW w:w="\#(widths.reduce(0, +))" w:type="dxa"/>"#
            + "<w:tblBorders>" + ["top", "left", "bottom", "right", "insideH", "insideV"].map(border).joined() + "</w:tblBorders>"
            + #"<w:tblLayout w:type="fixed"/>"#
            + #"<w:tblCellMar><w:top w:w="40" w:type="dxa"/><w:left w:w="80" w:type="dxa"/><w:bottom w:w="40" w:type="dxa"/><w:right w:w="80" w:type="dxa"/></w:tblCellMar>"#
            + #"<w:tblLook w:val="\#(headerRows > 0 ? "0420" : "0400")" w:firstRow="\#(headerRows > 0 ? 1 : 0)" w:lastRow="0" w:firstColumn="0" w:lastColumn="0" w:noHBand="1" w:noVBand="1"/>"#
            + "</w:tblPr><w:tblGrid>" + widths.map { #"<w:gridCol w:w="\#($0)"/>"# }.joined() + "</w:tblGrid>"
        for (rowIndex, row) in rows.enumerated() {
            let header = rowIndex < headerRows
            xml += "<w:tr>" + (header ? "<w:trPr><w:tblHeader/></w:trPr>" : "")
            var column = 0
            while column < count {
                // 이 자리를 덮는 합친 칸
                let cover = spans.first { $0.row <= rowIndex && rowIndex < $0.row + $0.rows && $0.column <= column && column < $0.column + $0.columns }
                var span = 1
                var merge = ""
                if let cover, cover.column == column {
                    span = max(min(cover.columns, count - column), 1)
                    if cover.rows > 1 { merge = cover.row == rowIndex ? #"<w:vMerge w:val="restart"/>"# : "<w:vMerge/>" }
                }
                let continued = cover != nil && cover!.row != rowIndex && cover!.column == column
                let cellWidth = widths[column..<min(column + span, count)].reduce(0, +)
                let text = (!continued && column < row.count) ? row[column] : ""
                xml += #"<w:tc><w:tcPr><w:tcW w:w="\#(cellWidth)" w:type="dxa"/>"#
                    + (span > 1 ? #"<w:gridSpan w:val="\#(span)"/>"# : "") + merge
                    + (header ? #"<w:shd w:val="clear" w:color="auto" w:fill="EDEDED"/>"# : "") + "</w:tcPr>"
                for line in text.components(separatedBy: "\n") {
                    xml += #"<w:p><w:pPr><w:spacing w:before="0" w:after="0" w:line="252" w:lineRule="auto"/></w:pPr>"#
                    if !line.isEmpty {
                        xml += runXML(DocumentRun(line, bold: header), halfPoints: cellHalf)
                    }
                    xml += "</w:p>"
                }
                xml += "</w:tc>"
                column += span
            }
            xml += "</w:tr>"
        }
        return xml + "</w:tbl>"
    }

    /// XML에 못 들어가는 글자를 바꾸거나 뺀다
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\u{9}", "\u{A}", "\u{D}": out += " "
            default:
                // XML 1.0에서 허용되는 글자만
                let v = scalar.value
                if (0x20...0xD7FF).contains(v) || (0xE000...0xFFFD).contains(v) || (0x10000...0x10FFFF).contains(v) {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    // MARK: 스타일 (본문 크기·글꼴은 문서의 본문을 따른다)

    static func styles(bodySize: CGFloat) -> String {
        styles(bodyHalf: Int((min(max(bodySize, 8), 16) * 2).rounded()), font: nil)
    }

    static func styles(bodyHalf body: Int, font: String?) -> String {
        func heading(_ level: Int, _ name: String, _ size: Int) -> String {
            #"<w:style w:type="paragraph" w:styleId="Heading\#(level)"><w:name w:val="\#(name)"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:uiPriority w:val="9"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="240" w:after="120"/><w:outlineLvl w:val="\#(level - 1)"/></w:pPr><w:rPr><w:b/><w:sz w:val="\#(size)"/><w:szCs w:val="\#(size)"/></w:rPr></w:style>"#
        }
        let fonts: String
        if let font, !font.isEmpty {
            let name = escape(font)
            fonts = #"<w:rFonts w:ascii="\#(name)" w:hAnsi="\#(name)" w:eastAsia="\#(name)" w:cs="\#(name)"/>"#
        } else {
            fonts = #"<w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="맑은 고딕" w:cs="Calibri"/>"#
        }
        return #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
            + #"<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">"#
            + "<w:docDefaults><w:rPrDefault><w:rPr>\(fonts)" + #"<w:sz w:val="\#(body)"/><w:szCs w:val="\#(body)"/><w:lang w:val="ko-KR" w:eastAsia="ko-KR"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>"#
            + #"<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>"#
            + #"<w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/><w:uiPriority w:val="99"/><w:rPr><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr></w:style>"#
            + heading(1, "heading 1", body + 16)
            + heading(2, "heading 2", body + 6)
            + heading(3, "heading 3", body)
            + "</w:styles>"
    }

    // MARK: 묶음 구성 파일

    static func contentTypes(header: Bool = false, footer: Bool = false) -> String {
        #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
            + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">"#
            + #"<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>"#
            + #"<Default Extension="xml" ContentType="application/xml"/>"#
            + #"<Default Extension="png" ContentType="image/png"/>"#
            + #"<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>"#
            + #"<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>"#
            + (header ? #"<Override PartName="/word/header1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"/>"# : "")
            + (footer ? #"<Override PartName="/word/footer1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/>"# : "")
            + #"<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>"#
            + #"<Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>"#
            + "</Types>"
    }

    static let packageRelationships = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
        + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
        + #"<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>"#
        + #"<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>"#
        + #"<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>"#
        + "</Relationships>"

    /// 본문 관계: styles(rId1), 머리글(rId2)·꼬리글(rId3), 그림(rId10~), 링크(rId100~)
    static func documentRelationships(imageCount: Int, links: [String] = [], header: Bool = false, footer: Bool = false) -> String {
        var xml = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
            + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
            + #"<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>"#
        if header { xml += #"<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header" Target="header1.xml"/>"# }
        if footer { xml += #"<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer1.xml"/>"# }
        for index in 1...max(imageCount, 1) where index <= imageCount {
            xml += #"<Relationship Id="rId\#(9 + index)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/image\#(index).png"/>"#
        }
        for (index, url) in links.enumerated() {
            xml += #"<Relationship Id="rId\#(100 + index)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="\#(escape(url))" TargetMode="External"/>"#
        }
        return xml + "</Relationships>"
    }

    static let app = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
        + #"<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>Hanlabong</Application></Properties>"#

    static func core(title: String, date: Date) -> String {
        let stamp = ISO8601DateFormatter().string(from: date)
        return #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
            + #"<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">"#
            + "<dc:title>\(escape(title))</dc:title><dc:creator>Hanlabong</dc:creator>"
            + #"<dcterms:created xsi:type="dcterms:W3CDTF">\#(stamp)</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">\#(stamp)</dcterms:modified>"#
            + "</cp:coreProperties>"
    }
}

/// 문단을 빈 줄로 나눈 UTF-8 텍스트. `keepLineBreaks`면 PDF의 줄바꿈을 그대로 둔다.
enum PlainTextWriter {
    static func make(_ document: ExtractedDocument, keepLineBreaks: Bool) -> Data {
        let text: String
        if keepLineBreaks {
            text = document.rawPages
                .map { $0.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") }
                .joined(separator: "\n\n")
        } else {
            text = document.paragraphs.map(\.text).joined(separator: "\n\n")
        }
        return Data((text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").utf8)
    }
}
