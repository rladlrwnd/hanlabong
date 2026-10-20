import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// PDF → 사진(쪽마다), PowerPoint(쪽마다 한 장), Excel(줄은 행, 넓은 빈칸은 칸으로)
public enum PDFExports {
    // MARK: 쪽 → 그림

    /// 한 쪽을 `dpi`로 그린다(흰 바탕). 가장 긴 변은 10,000px까지.
    static func render(_ page: PDFPage, dpi: Double) -> CGImage? {
        let box = page.bounds(for: .cropBox)
        var scale = dpi / 72
        scale = min(scale, 10_000 / max(box.width, box.height))
        let width = Int((box.width * scale).rounded()), height = Int((box.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        page.draw(with: .cropBox, to: context)
        return context.makeImage()
    }

    static func encode(_ image: CGImage, as type: UTType, quality: Double = 0.92) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality,
                                                        kCGImagePropertyDPIWidth: 300, kCGImagePropertyDPIHeight: 300] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// 쪽마다 그림. 한 쪽이면 파일 하나, 여러 쪽이면 폴더 하나에 "이름-001.png"…로 담아서 돌려준다.
    static func images(_ document: PDFDocument, name: String, format: OutputFormat, dpi: Int, cancellation: FileCancellation) throws -> FileResult {
        let type: UTType = format == .png ? .png : .jpeg
        let ext = format == .png ? "png" : "jpg"
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("dragedit-\(UUID().uuidString)")
        if document.pageCount == 1 {
            guard let page = document.page(at: 0), let image = render(page, dpi: Double(dpi)), let data = encode(image, as: type) else {
                throw FileSkillError.encodeFailed(L("쪽을 그리지 못했어요", "Couldn't render the page"))
            }
            return FileResult(data: data, fileExtension: ext, width: image.width, height: image.height)
        }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let digits = max(3, String(document.pageCount).count)
        for index in 0..<document.pageCount {
            try cancellation.check()
            try autoreleasepool {
                guard let page = document.page(at: index), let image = render(page, dpi: Double(dpi)), let data = encode(image, as: type) else {
                    throw FileSkillError.encodeFailed(L("\(index + 1)쪽을 그리지 못했어요", "Couldn't render page \(index + 1)"))
                }
                let number = String(format: "%0\(digits)d", index + 1)
                try data.write(to: temp.appendingPathComponent("\(name)-\(number).\(ext)"))
            }
        }
        return FileResult(data: Data(), fileExtension: "", width: 0, height: 0, fileURL: temp)
    }

    // MARK: PowerPoint

    private static let emuPerPoint = 12_700

    /// 쪽마다 슬라이드 한 장(쪽 그림을 꽉 채움). 슬라이드 크기는 첫 쪽 비율.
    static func slides(_ document: PDFDocument, title: String, cancellation: FileCancellation) throws -> Data {
        guard let first = document.page(at: 0) else { throw FileSkillError.unreadable(title) }
        let box = first.bounds(for: .cropBox)
        let cx = Int(box.width) * emuPerPoint, cy = Int(box.height) * emuPerPoint
        var zip = ZipWriter()
        let count = document.pageCount
        var slideTypes = "", presRels = "", slideIDs = ""
        for n in 1...count {
            slideTypes += "<Override PartName=\"/ppt/slides/slide\(n).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
            presRels += "<Relationship Id=\"rId\(n + 2)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" Target=\"slides/slide\(n).xml\"/>"
            slideIDs += "<p:sldId id=\"\(255 + n)\" r:id=\"rId\(n + 2)\"/>"
        }
        zip.add("[Content_Types].xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="jpeg" ContentType="image/jpeg"/><Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/><Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/><Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/><Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>\(slideTypes)<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/></Types>
        """)
        zip.add("_rels/.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/></Relationships>
        """)
        zip.add("docProps/core.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>\(RichDocumentWriter.escape(title))</dc:title></cp:coreProperties>
        """)
        zip.add("ppt/presentation.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst><p:sldIdLst>\(slideIDs)</p:sldIdLst><p:sldSz cx="\(cx)" cy="\(cy)"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>
        """)
        zip.add("ppt/_rels/presentation.xml.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="theme/theme1.xml"/>\(presRels)</Relationships>
        """)
        let emptyTree = "<p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld>"
        let ns = "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\""
        zip.add("ppt/slideMasters/slideMaster1.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldMaster \(ns)>\(emptyTree)<p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/><p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst></p:sldMaster>
        """)
        zip.add("ppt/slideMasters/_rels/slideMaster1.xml.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/></Relationships>
        """)
        zip.add("ppt/slideLayouts/slideLayout1.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldLayout \(ns) type="blank" preserve="1">\(emptyTree)<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>
        """)
        zip.add("ppt/slideLayouts/_rels/slideLayout1.xml.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/></Relationships>
        """)
        zip.add("ppt/theme/theme1.xml", theme)
        for n in 1...count {
            try cancellation.check()
            try autoreleasepool {
                guard let page = document.page(at: n - 1), let image = render(page, dpi: 200), let data = encode(image, as: .jpeg, quality: 0.88) else {
                    throw FileSkillError.encodeFailed(L("\(n)쪽을 그리지 못했어요", "Couldn't render page \(n)"))
                }
                zip.add("ppt/media/image\(n).jpeg", data)
            }
            zip.add("ppt/slides/slide\(n).xml", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <p:sld \(ns)><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/><p:pic><p:nvPicPr><p:cNvPr id="2" name="Page \(n)"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed="rId2"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
            """)
            zip.add("ppt/slides/_rels/slide\(n).xml.rels", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/image\(n).jpeg"/></Relationships>
            """)
        }
        return zip.finish()
    }

    private static let theme = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Office"><a:themeElements><a:clrScheme name="Office"><a:dk1><a:srgbClr val="000000"/></a:dk1><a:lt1><a:srgbClr val="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="44546A"/></a:dk2><a:lt2><a:srgbClr val="E7E6E6"/></a:lt2><a:accent1><a:srgbClr val="4472C4"/></a:accent1><a:accent2><a:srgbClr val="ED7D31"/></a:accent2><a:accent3><a:srgbClr val="A5A5A5"/></a:accent3><a:accent4><a:srgbClr val="FFC000"/></a:accent4><a:accent5><a:srgbClr val="5B9BD5"/></a:accent5><a:accent6><a:srgbClr val="70AD47"/></a:accent6><a:hlink><a:srgbClr val="0563C1"/></a:hlink><a:folHlink><a:srgbClr val="954F72"/></a:folHlink></a:clrScheme><a:fontScheme name="Office"><a:majorFont><a:latin typeface="Calibri Light"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont><a:minorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme><a:fmtScheme name="Office"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst><a:lnStyleLst><a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="12700"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="19050"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>
    """

    // MARK: Excel

    /// 쪽마다 시트 하나. 한 줄 = 한 행, 글자 사이가 넓게 벌어진 곳(글자 두 개 폭 이상)에서 칸을 나눈다. 숫자는 숫자 칸으로.
    static func sheet(_ document: PDFDocument, title: String, cancellation: FileCancellation) throws -> Data {
        var sheets: [[[String]]] = []
        for index in 0..<min(document.pageCount, 200) {
            try cancellation.check()
            guard let page = document.page(at: index) else { continue }
            sheets.append(rows(of: page))
        }
        guard sheets.contains(where: { !$0.isEmpty }) else { throw FileSkillError.noTextInPDF(title) }
        return xlsx(sheets)
    }

    /// 쪽의 글자를 줄·칸으로(글자 위치를 보고 나눈다)
    static func rows(of page: PDFPage) -> [[String]] {
        guard let text = page.string as NSString?, text.length > 0 else { return [] }
        var result: [[String]] = []
        var cells: [String] = [], cell = ""
        var lastMaxX: CGFloat?
        var widths: [CGFloat] = []   // 최근 글자 높이들
        func endCell() { let t = cell.trimmingCharacters(in: .whitespaces); if !t.isEmpty || !cells.isEmpty { cells.append(t) }; cell = "" }
        func endRow() { endCell(); while cells.last == "" { cells.removeLast() }; if !cells.isEmpty { result.append(cells) }; cells = []; lastMaxX = nil }
        // page.string의 줄바꿈은 PDFKit이 끼워 넣은 글자라 글자 위치 목록에는 없다 → 그만큼 빼고 찾는다
        var inserted = 0
        for i in 0..<text.length {
            let ch = text.character(at: i)
            if ch == 10 || ch == 13 { endRow(); inserted += 1; continue }
            if ch == 9 { endCell(); lastMaxX = nil; continue }
            let bounds = page.characterBounds(at: i - inserted)
            let scalar = Unicode.Scalar(ch).map { Character($0) } ?? " "
            if scalar == " " { cell.append(" "); continue }
            if bounds.height > 0 { widths.append(bounds.height); if widths.count > 200 { widths.removeFirst() } }
            let lineHeight = widths.isEmpty ? 12 : widths.sorted()[widths.count / 2]
            // 보통 띄어쓰기는 글자 높이의 4분의 1쯤 — 그 서너 배 넘게 벌어지면 다른 칸
            if let last = lastMaxX, bounds.minX - last > lineHeight * 0.9 { endCell() }
            if bounds.width > 0 { lastMaxX = bounds.maxX }
            cell.append(scalar)
        }
        endRow()
        return result
    }

    static func column(_ index: Int) -> String {
        var n = index + 1, name = ""
        while n > 0 { let r = (n - 1) % 26; name = String(UnicodeScalar(65 + r)!) + name; n = (n - 1) / 26 }
        return name
    }

    static func xlsx(_ sheets: [[[String]]]) -> Data {
        var zip = ZipWriter()
        let count = sheets.count
        let overrides = (1...count).map { "<Override PartName=\"/xl/worksheets/sheet\($0).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>" }.joined()
        zip.add("[Content_Types].xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\(overrides)</Types>
        """)
        zip.add("_rels/.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """)
        let sheetList = (1...count).map { "<sheet name=\"\(L("\($0)쪽", "Page \($0)"))\" sheetId=\"\($0)\" r:id=\"rId\($0)\"/>" }.joined()
        zip.add("xl/workbook.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>\(sheetList)</sheets></workbook>
        """)
        let rels = (1...count).map { "<Relationship Id=\"rId\($0)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\($0).xml\"/>" }.joined()
        zip.add("xl/_rels/workbook.xml.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(rels)<Relationship Id="rId\(count + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
        """)
        zip.add("xl/styles.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs></styleSheet>
        """)
        for (index, rows) in sheets.enumerated() {
            var body = ""
            for (r, row) in rows.enumerated() {
                body += "<row r=\"\(r + 1)\">"
                for (c, value) in row.enumerated() where !value.isEmpty {
                    let ref = "\(column(c))\(r + 1)"
                    let plain = value.replacingOccurrences(of: ",", with: "")
                    if let number = Double(plain), plain.range(of: "^-?\\d+(\\.\\d+)?$", options: .regularExpression) != nil, number.isFinite {
                        body += "<c r=\"\(ref)\"><v>\(plain)</v></c>"
                    } else {
                        body += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(RichDocumentWriter.escape(value))</t></is></c>"
                    }
                }
                body += "</row>"
            }
            zip.add("xl/worksheets/sheet\(index + 1).xml", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>\(body)</sheetData></worksheet>
            """)
        }
        return zip.finish()
    }
}
