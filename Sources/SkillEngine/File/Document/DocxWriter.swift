import CoreGraphics
import Foundation

/// 문단·제목·굵게·기울임을 담은 Word(.docx) 파일을 직접 만든다(Office Open XML을 zip으로).
/// 제목은 Word의 "제목 1·2·3" 스타일로 들어가서 Word의 탐색 창·목차에 그대로 잡힌다.
enum DocxWriter {
    static func make(_ document: ExtractedDocument, title: String, date: Date = Date()) -> Data {
        var zip = ZipWriter(date: date)
        zip.add("[Content_Types].xml", contentTypes)
        zip.add("_rels/.rels", packageRelationships)
        zip.add("docProps/core.xml", core(title: title, date: date))
        zip.add("docProps/app.xml", app)
        zip.add("word/_rels/document.xml.rels", documentRelationships)
        zip.add("word/styles.xml", styles(bodySize: document.bodyFontSize))
        zip.add("word/document.xml", body(document))
        return zip.finish()
    }

    // MARK: 본문

    static func body(_ document: ExtractedDocument) -> String {
        var xml = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
        xml += #"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>"#
        for paragraph in document.paragraphs {
            xml += "<w:p>"
            if let level = paragraph.headingLevel { xml += #"<w:pPr><w:pStyle w:val="Heading\#(level)"/></w:pPr>"# }
            for run in paragraph.runs where !run.text.isEmpty {
                xml += "<w:r>"
                if run.bold || run.italic {
                    xml += "<w:rPr>" + (run.bold ? "<w:b/>" : "") + (run.italic ? "<w:i/>" : "") + "</w:rPr>"
                }
                xml += #"<w:t xml:space="preserve">"# + escape(run.text) + "</w:t></w:r>"
            }
            xml += "</w:p>"
        }
        // 쪽 크기는 원본 PDF 첫 쪽 크기, 여백은 2.54cm (1포인트 = 20트윕)
        let width = Int((document.pageSize.width * 20).rounded()), height = Int((document.pageSize.height * 20).rounded())
        xml += #"<w:sectPr><w:pgSz w:w="\#(width)" w:h="\#(height)"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="708" w:footer="708" w:gutter="0"/></w:sectPr>"#
        xml += "</w:body></w:document>"
        return xml
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

    // MARK: 스타일 (본문 크기는 PDF 본문 크기를 따른다)

    static func styles(bodySize: CGFloat) -> String {
        let body = Int((min(max(bodySize, 8), 16) * 2).rounded())   // 반 포인트 단위
        func heading(_ level: Int, _ name: String, _ size: Int) -> String {
            #"<w:style w:type="paragraph" w:styleId="Heading\#(level)"><w:name w:val="\#(name)"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:uiPriority w:val="9"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="240" w:after="120"/><w:outlineLvl w:val="\#(level - 1)"/></w:pPr><w:rPr><w:b/><w:sz w:val="\#(size)"/><w:szCs w:val="\#(size)"/></w:rPr></w:style>"#
        }
        return #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
            + #"<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">"#
            + #"<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="맑은 고딕" w:cs="Calibri"/><w:sz w:val="\#(body)"/><w:szCs w:val="\#(body)"/><w:lang w:val="ko-KR" w:eastAsia="ko-KR"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>"#
            + #"<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>"#
            + heading(1, "heading 1", body + 16)
            + heading(2, "heading 2", body + 6)
            + heading(3, "heading 3", body)
            + "</w:styles>"
    }

    // MARK: 묶음 구성 파일

    static let contentTypes = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
        + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">"#
        + #"<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>"#
        + #"<Default Extension="xml" ContentType="application/xml"/>"#
        + #"<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>"#
        + #"<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>"#
        + #"<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>"#
        + #"<Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>"#
        + "</Types>"

    static let packageRelationships = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
        + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
        + #"<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>"#
        + #"<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>"#
        + #"<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>"#
        + "</Relationships>"

    static let documentRelationships = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
        + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
        + #"<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>"#
        + "</Relationships>"

    static let app = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
        + #"<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>DragEdit</Application></Properties>"#

    static func core(title: String, date: Date) -> String {
        let stamp = ISO8601DateFormatter().string(from: date)
        return #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
            + #"<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">"#
            + "<dc:title>\(escape(title))</dc:title><dc:creator>DragEdit</dc:creator>"
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
