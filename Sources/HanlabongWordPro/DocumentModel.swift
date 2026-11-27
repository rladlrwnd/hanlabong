import AppKit
import Foundation
import SkillEngine

// 문서 영역(워드·한글·노트)이 보여 줄 "읽어 온 문서"와, 파일에서 그걸 만드는 부분.
// 화면·세션과 떼어 놓았다(여기엔 SwiftUI가 없고 SkillEngine만 쓴다): 백그라운드에서 돌리고, 따로 테스트하기 쉽게.

/// 목차 한 줄(제목 문단)
struct DocumentOutlineItem: Identifiable, Equatable, Sendable {
    /// 문서 안 문단 번호(같은 제목이 여러 번 나와도 구분된다)
    let id: Int
    /// 1~3
    let level: Int
    let title: String
    /// 화면에 보이는 글(attributed) 안의 글자 위치와 길이. 못 찾았으면 nil
    let location: Int?
    let length: Int
}

/// 읽어 온 문서 하나. 화면에 보일 글과 쪽 모양, 목차, 글자 수, AI에게 줄 글 조각이 들어 있다.
/// NSAttributedString은 Sendable이 아니지만 만든 뒤에는 고치지 않고 읽기만 해서 안전하다.
struct LoadedDocument: @unchecked Sendable {
    /// 다시 읽을 때마다 바뀌는 이름표(화면이 "새 문서인가"를 알아보는 데 쓴다)
    let id = UUID()
    var title: String
    /// 화면에 보일 글(표·그림·쪽 나눔 구분선 포함)
    var attributed: NSAttributedString
    /// 종이 크기(포인트)와 여백
    var pageSize: CGSize
    var margins: NSEdgeInsets
    var outline: [DocumentOutlineItem]
    /// 제목 문단 번호(id) → 그 제목 아래 글(다음 제목 전까지, 앞 6000자). AI가 "○○ 부분은?" 같은 물음에 쓴다
    var sectionText: [Int: String]
    var paragraphCount: Int
    var characterCount: Int
    var characterCountNoSpaces: Int
    /// 쪽 나눔이 있는 만큼 센 쪽 수(없으면 1)
    var pageCount: Int
    /// 글 앞부분(AI 맥락용, 6000자까지)과 전체 길이
    var textHead: String
    var textLength: Int
    /// 옛 .hwp(읽기만 되고 저장은 .hwpx로)
    var isLegacyHwp: Bool
    /// 읽어 온 원래 문서(저장할 때 basedOn으로 넘겨 여백·머리글·꼬리글·쪽 번호·본문 글꼴을 잇는다)
    var source: RichDocument? = nil
    /// 쪽마다 위·아래 여백에 화면으로만 그릴 머리글·꼬리글(없으면 nil), 꼬리글에 쪽 번호를 넣을지
    var header: NSAttributedString? = nil
    var footer: NSAttributedString? = nil
    var showPageNumber = false
}

extension LoadedDocument {
    /// 말에 제목이 들어 있으면 그 목차 줄. 제목이 긴 것부터 맞춰 본다(“1장”보다 “1장 서론”이 먼저)
    func outlineItem(matching text: String) -> DocumentOutlineItem? {
        let query = Self.normalize(text)
        guard query.count >= 2 else { return nil }
        return outline
            .sorted { $0.title.count > $1.title.count }
            .first { item in
                let title = Self.normalize(item.title)
                return title.count >= 2 && (query.contains(title) || (query.count >= 3 && title.contains(query)))
            }
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }
}

extension LoadedDocument {
    /// 고친 글(화면의 텍스트 저장소)로 목차·글자 수·쪽 수·AI용 글을 다시 센다. 화면 글(attributed)과 id는 그대로 둔다
    /// (id가 같아야 화면이 "새 문서"로 알고 처음부터 다시 그리지 않는다)
    mutating func refresh(from text: NSAttributedString) {
        let live = DocumentLoader.liveSummary(of: text)
        outline = live.outline
        sectionText = live.sections
        paragraphCount = live.paragraphs
        characterCount = live.characters
        characterCountNoSpaces = live.noSpaces
        pageCount = live.pages
        textHead = live.head
        textLength = live.length
    }
}

enum DocumentLoader {
    /// 파일을 읽는다(오래 걸릴 수 있어서 백그라운드에서 부른다). 못 읽으면 FileSkillError 등을 던진다.
    /// 영역(워드·한글·노트)과 상관없이 같은 길: 파일 → RichDocument(글·표·그림·제목·쪽 크기) → RichDocumentWriter.attributedString.
    /// 그래서 글꼴(한라봉 기본 시스템 글꼴)·표·그림 폭 맞춤이 모든 형식에서 같다.
    static func load(_ url: URL) throws -> LoadedDocument {
        let rich = try RichDocumentReader.read(url)
        let ext = url.pathExtension.lowercased()

        let (pageSize, margins) = pageMetrics(of: rich)
        // 쪽 나눔 자리마다 묶음을 끊어서 PDF 쪽과 같은 방법으로 글을 짠다(그림은 본문 폭 안에서 비율을 지켜 줄어든다)
        let content = CGSize(width: max(72, pageSize.width - margins.left - margins.right),
                             height: max(72, pageSize.height - margins.top - margins.bottom))
        var groups: [[DocumentParagraph]] = [[]]
        for paragraph in rich.paragraphs {
            if paragraph.pageBreakBefore, !groups[groups.count - 1].isEmpty { groups.append([]) }
            groups[groups.count - 1].append(paragraph)
        }
        let out = NSMutableAttributedString()
        var number = 0
        for group in groups where !group.isEmpty {
            number += 1
            if number > 1 { out.append(pageDivider(number)) }
            out.append(RichDocumentWriter.attributedString(paragraphs: group, content: content, target: .pdf,
                                                           bodyFontSize: rich.bodyFontSize, bodyFontName: rich.bodyFontName).0)
        }
        let pages = max(number, 1)
        let shown: NSAttributedString = out

        var characters = 0, noSpaces = 0
        var head = ""
        var textLength = 0
        for paragraph in rich.paragraphs {
            let text = paragraph.text
            if textLength < 6000 { head += text + "\n" }
            textLength += text.count + 1
            for ch in text where !ch.isNewline {
                characters += 1
                if !ch.isWhitespace { noSpaces += 1 }
            }
        }
        let (outline, sections) = outline(of: rich, in: shown)
        // 머리글·꼬리글: PDF로 쓸 때와 같은 9pt 글(쪽 나눔·문단 간격은 뺀다)
        func band(_ paragraphs: [DocumentParagraph]) -> NSAttributedString? {
            guard !paragraphs.isEmpty else { return nil }
            let trimmed = paragraphs.map { p -> DocumentParagraph in
                var q = p; q.spaceAfter = q.spaceAfter ?? 0; q.spaceBefore = q.spaceBefore ?? 0; q.pageBreakBefore = false; return q
            }
            return RichDocumentWriter.attributedString(paragraphs: trimmed, content: content, target: .pdf,
                                                       bodyFontSize: 9, bodyFontName: rich.bodyFontName).0
        }
        return LoadedDocument(
            title: rich.title, attributed: shown, pageSize: pageSize, margins: margins,
            outline: outline, sectionText: sections, paragraphCount: rich.paragraphs.count,
            characterCount: characters, characterCountNoSpaces: noSpaces, pageCount: pages,
            textHead: String(head.prefix(6000)), textLength: textLength,
            isLegacyHwp: ext == "hwp", source: rich,
            header: band(rich.header), footer: band(rich.footer), showPageNumber: rich.showPageNumber)
    }

    /// 쪽 크기와 여백. RichDocumentWriter.metrics와 같은 규칙(그 함수는 SkillEngine 안에서만 보여서 여기 똑같이 둔다):
    /// 문서에 여백이 있으면 그것(쪽의 40%까지), 없으면 짧은 변의 약 8%. 쪽 크기가 이상하면 A4
    static func pageMetrics(of rich: RichDocument) -> (CGSize, NSEdgeInsets) {
        var size = rich.resolvedPageSize
        if size.width < 100 || size.height < 100 || !size.width.isFinite || !size.height.isFinite { size = CGSize(width: 595, height: 842) }
        if let m = rich.margins {
            func clamp(_ v: CGFloat, _ limit: CGFloat) -> CGFloat { v.isFinite ? min(max(0, v), limit * 0.4) : 0 }
            return (size, NSEdgeInsets(top: clamp(m.top, size.height), left: clamp(m.left, size.width),
                                       bottom: clamp(m.bottom, size.height), right: clamp(m.right, size.width)))
        }
        let margin = (min(size.width, size.height) * 0.08).rounded()
        return (size, NSEdgeInsets(top: margin, left: margin, bottom: margin, right: margin))
    }

    /// 글 속 쪽 넘김 문자(\u{0C})를 얇은 구분선으로 바꾼다. 돌려주는 숫자는 쪽 수
    static func withPageDividers(_ text: NSAttributedString) -> (NSAttributedString, Int) {
        let ns = text.string as NSString
        var breaks: [Int] = []
        var search = NSRange(location: 0, length: ns.length)
        while search.length > 0 {
            let found = ns.range(of: "\u{0C}", options: .literal, range: search)
            if found.location == NSNotFound { break }
            breaks.append(found.location)
            let next = found.location + 1
            search = NSRange(location: next, length: ns.length - next)
        }
        guard !breaks.isEmpty else { return (text, 1) }
        let out = NSMutableAttributedString(attributedString: text)
        for (i, location) in breaks.enumerated().reversed() {
            let startsLine = location == 0 || ns.character(at: location - 1) == 10
            let divider = NSMutableAttributedString()
            if !startsLine { divider.append(NSAttributedString(string: "\n")) }
            divider.append(pageDivider(i + 2))
            out.replaceCharacters(in: NSRange(location: location, length: 1), with: divider)
        }
        return (out, breaks.count + 1)
    }

    /// 쪽 나눔 표시 문단의 글자: 폭 없는 빈칸(U+200B) 하나. 이 뒤에 줄바꿈이 붙는다
    static let pageBreakMark = "\u{200B}"

    /// 쪽이 바뀌는 자리(4단계): 거의 안 보이는 글자 하나짜리 문단(1pt). 문단 전체에 `.hanlabongPageBreak`가 붙어 있다.
    /// - 쪽 보기(한 쪽씩·두 쪽씩): 이 줄 뒤 문단이 다음 쪽 첫 줄로 간다(DocumentPager·PageFlowRules). 쪽 번호는 종이 아래에 따로 그린다
    /// - 이어 보기: 이 줄을 띠 높이로 늘리고 회색 띠 + "N쪽"을 그린다(그림일 뿐 글이 아니다)
    /// - 저장할 때(RichDocumentEditing.document(from:)) 내용이 아니라 쪽 나눔으로 돌아간다
    /// number는 옛 호출과 맞추려고 남겨 둔 것이다(번호는 이제 화면이 센다)
    static func pageDivider(_ number: Int = 2) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.minimumLineHeight = 1
        style.maximumLineHeight = 1
        style.paragraphSpacing = 0
        style.paragraphSpacingBefore = 0
        return NSAttributedString(string: pageBreakMark + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 1), .foregroundColor: NSColor.clear, .paragraphStyle: style,
            .hanlabongPageBreak: true,
        ])
    }

    /// 이어 보기 띠에 쓰는 쪽 번호 글
    static func pageLabel(_ number: Int) -> String { L("\(number)쪽", "Page \(number)") }

    // MARK: 고치는 중의 목차·글자 수

    struct LiveSummary {
        var outline: [DocumentOutlineItem] = []
        var sections: [Int: String] = [:]
        var paragraphs = 0, characters = 0, noSpaces = 0, pages = 1
        var head = ""
        var length = 0
    }

    /// 화면 글에서 바로 센다: 제목은 `.hanlabongHeading`이 붙은 문단(표 칸·쪽 띠 밖), 쪽은 쪽 띠 수 + 1.
    /// 그림 자리 글자(U+FFFC)와 쪽 띠 글은 글자 수에서 뺀다
    static func liveSummary(of text: NSAttributedString) -> LiveSummary {
        var out = LiveSummary()
        let ns = text.string as NSString
        var currentID: Int?
        var currentText = ""
        func closeSection() {
            if let id = currentID, !currentText.isEmpty { out.sections[id] = String(currentText.prefix(6000)) }
            currentID = nil
            currentText = ""
        }
        var index = 0
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byParagraphs) { substring, range, enclosing, _ in
            defer { index += 1 }
            let probe = range.length > 0 ? range.location : enclosing.location
            guard probe < ns.length else { return }
            if text.attribute(.hanlabongPageBreak, at: probe, effectiveRange: nil) != nil { out.pages += 1; return }
            let paragraph = (substring ?? "").replacingOccurrences(of: "\u{FFFC}", with: "")
            let inBlock = ((text.attribute(.paragraphStyle, at: probe, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.isEmpty == false)
            if !paragraph.trimmingCharacters(in: .whitespaces).isEmpty || text.attribute(.attachment, at: probe, effectiveRange: nil) != nil {
                out.paragraphs += 1
            }
            if out.length < 6000 { out.head += paragraph + "\n" }
            out.length += paragraph.count + 1
            for ch in paragraph where !ch.isNewline {
                out.characters += 1
                if !ch.isWhitespace { out.noSpaces += 1 }
            }
            let level = (text.attribute(.hanlabongHeading, at: probe, effectiveRange: nil) as? NSNumber)?.intValue
            if let level, (1...3).contains(level), !inBlock, range.length > 0, let title = headingTitle(paragraph) {
                closeSection()
                out.outline.append(DocumentOutlineItem(id: index, level: level, title: title, location: range.location,
                                                       length: min((title as NSString).length, range.length)))
                currentID = index
            } else if currentID != nil, currentText.count < 6000 {
                currentText += paragraph + "\n"
            }
        }
        closeSection()
        out.head = String(out.head.prefix(6000))
        return out
    }

    // MARK: 목차

    /// 목차에 올릴 만한 제목 글인가. 첫 줄을 돌려주고, 아니면 nil(2글자 미만, 숫자·기호뿐, 150자 넘는 긴 글)
    static func headingTitle(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
        let title = firstLine.trimmingCharacters(in: .whitespaces)
        guard title.count >= 2, title.count <= 150 else { return nil }
        guard title.contains(where: { $0.isLetter }) else { return nil }     // 숫자·기호·탭뿐인 칸은 제외
        return String(title.prefix(120))
    }

    /// 제목 문단(1~3단계)을 차례로 찾아서, 화면에 보이는 글 안의 위치를 이어서 찾는다(앞에서부터 한 번씩만 훑는다).
    /// 같이 만드는 sections: 제목 아래 글(AI 맥락용)
    static func outline(of rich: RichDocument, in display: NSAttributedString) -> ([DocumentOutlineItem], [Int: String]) {
        let ns = display.string as NSString
        var cursor = 0
        var items: [DocumentOutlineItem] = []
        var sections: [Int: String] = [:]
        var currentID: Int?
        var currentText = ""
        func closeSection() {
            if let id = currentID, !currentText.isEmpty { sections[id] = String(currentText.prefix(6000)) }
            currentID = nil
            currentText = ""
        }
        for (index, paragraph) in rich.paragraphs.enumerated() {
            // 목차는 제목 1~3단계인 "글 문단"만: 표·그림 덩어리, 너무 짧거나 숫자뿐인 글, 문단처럼 긴 글은 본문으로 친다
            guard let level = paragraph.headingLevel, (1...3).contains(level), paragraph.table == nil, paragraph.image == nil,
                  let title = headingTitle(paragraph.text) else {
                if currentID != nil, currentText.count < 6000 { currentText += paragraph.text + "\n" }
                continue
            }
            closeSection()
            // 읽을 때 붙인 목록 표시("• ", "1. ")는 화면 글과 다를 수 있어서 빼고 찾는다
            let bare = title.replacingOccurrences(of: #"^(•|\d+[.)])\s*"#, with: "", options: .regularExpression)
            var found = NSRange(location: NSNotFound, length: 0)
            for needle in [String(bare.prefix(40)), String(bare.prefix(12))] where found.location == NSNotFound && !needle.isEmpty && cursor < ns.length {
                found = ns.range(of: needle, options: .literal, range: NSRange(location: cursor, length: ns.length - cursor))
            }
            if found.location != NSNotFound { cursor = found.location + max(found.length, 1) }
            items.append(DocumentOutlineItem(id: index, level: level, title: title,
                                             location: found.location == NSNotFound ? nil : found.location,
                                             length: found.location == NSNotFound ? 0 : min(bare.count, ns.length - found.location)))
            currentID = index
        }
        closeSection()
        return (items, sections)
    }
}
