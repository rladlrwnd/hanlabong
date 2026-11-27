import AppKit
import SkillEngine
import UniformTypeIdentifiers

/// 지금 커서 자리의 글 모양(도구 막대 단추에 비춘다)
struct DocumentFormatState: Equatable {
    var bold = false
    var italic = false
    /// 1~3, 본문은 nil
    var heading: Int?
    var bullet = false
    /// 표 칸·쪽 띠 안(제목·목록을 못 바꾸는 자리)
    var inBlock = false
    /// 커서 자리 글자 크기(pt). 모르면 0
    var fontSize: CGFloat = 0
    /// 글꼴 가족 이름. 한라봉 기본 글꼴이면 nil
    var fontFamily: String?
    /// 문단 정렬(natural은 왼쪽으로 본다)
    var alignment: NSTextAlignment = .left
    /// 커서가 표 칸 안
    var inTable = false
}

/// 문서 영역 2단계: 종이(NSTextView)를 고치는 일을 한곳에 모았다. 세션이 하나씩 갖고, 화면(DocumentCanvas)이 만든 NSTextView를 이어 준다.
/// 4단계부터 종이가 쪽마다 따로라 텍스트 뷰도 쪽마다 하나씩이지만, 모두 같은 글 저장소·선택·대리자를 쓴다. textView는 1쪽 뷰(늘 있다)이고,
/// 커서가 있는 쪽의 뷰가 필요하면 textView(containing:)·focusSelection()을 쓴다.
/// - 쪽 나눔 표시(`.hanlabongPageBreak` 문단)는 안쪽 글자를 못 고친다. 표시에 걸쳐 지우면 표시 전체가 지워진다(=쪽 나눔 없앰).
///   커서는 표시 줄에 멈추지 않고 건너뛴다(거의 안 보이는 1pt 줄이라).
/// - 고친 것은 모두 NSTextView를 거쳐서(shouldChangeText → 바꾸기 → didChangeText) ⌘Z로 되돌릴 수 있다. 되돌리기 기록은 문서마다 따로(창의 요청칸과 섞이지 않게).
/// - 화면 없이도 돈다(테스트가 NSTextView만 만들어 이어 붙여 쓴다).
@MainActor
final class DocumentEditor: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
    private(set) weak var textView: NSTextView?
    /// 쪽마다 텍스트 뷰가 따로 있을 때(화면의 DocumentPager). 화면 없는 테스트에선 nil이고 textView 하나로 돈다
    weak var pager: DocumentPager?
    let undo = UndoManager()
    /// 본문 폭·높이(쪽 − 여백). 그림을 이 안에 맞춘다
    private(set) var contentSize = CGSize(width: 595 - 2 * 48, height: 842 - 2 * 67)

    /// 사용자가 글을 고쳤을 때(되돌리기 포함)
    var onChange: (() -> Void)?
    /// 커서·선택이 움직였을 때(도구 막대 상태)
    var onFormat: ((DocumentFormatState) -> Void)?

    /// 우리가 직접 고치는 중(띠 보호를 건너뛴다)
    private var internalEdit = false

    // MARK: 잇기

    func attach(_ tv: NSTextView) {
        textView = tv
        tv.delegate = self
        tv.textStorage?.delegate = self
    }

    /// 그 글자가 놓인 쪽의 텍스트 뷰(쪽이 하나뿐이면 textView)
    func textView(containing location: Int) -> NSTextView? {
        pager?.paper(containing: location)?.textView ?? textView
    }

    /// 커서가 있는 쪽의 텍스트 뷰가 입력을 받게(넣기·서명 뒤 바로 이어 쓰게)
    func focusSelection() {
        guard let tv = textView else { return }
        let target = textView(containing: tv.selectedRange().location) ?? tv
        target.window?.makeFirstResponder(target)
    }

    /// 새 문서가 종이에 올라간 뒤: 되돌리기 기록을 비우고 쓰기 모양을 본문으로
    func documentLoaded(pageSize: CGSize, margins: NSEdgeInsets) {
        contentSize = CGSize(width: max(72, pageSize.width - margins.left - margins.right),
                             height: max(72, pageSize.height - margins.top - margins.bottom))
        undo.removeAllActions()
        if let tv = textView { tv.typingAttributes = Self.bodyAttributes() }
        publishFormat()
    }

    // MARK: 본문·표 모양(writer와 같은 값)

    static func bodyStyle(heading: Int? = nil) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.tabStops = (1...6).map { NSTextTab(textAlignment: .left, location: CGFloat($0) * 72) }
        style.defaultTabInterval = 72
        style.lineSpacing = 3
        style.paragraphSpacing = heading == nil ? 8 : 6
        style.paragraphSpacingBefore = heading == nil ? 0 : 10
        return style
    }

    static func bodyAttributes() -> [NSAttributedString.Key: Any] {
        [.font: RichDocumentEditing.headingFont(level: nil, bold: false, italic: false),
         .paragraphStyle: bodyStyle(), .foregroundColor: NSColor.black]
    }

    /// 빈 표: 얇은 테두리, 머리줄 옅은 배경·굵게, 글자 9.5pt(RichDocumentWriter가 만드는 표와 같은 모양)
    static func emptyTable(rows: Int, columns: Int) -> NSAttributedString {
        let rows = min(max(rows, 1), 50), columns = min(max(columns, 1), 20)
        let out = NSMutableAttributedString()
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.collapsesBorders = true
        table.setContentWidth(100, type: .percentageValueType)
        for r in 0..<rows {
            for c in 0..<columns {
                let block = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                block.setWidth(0.5, type: .absoluteValueType, for: .border)
                block.setBorderColor(NSColor(white: 0.55, alpha: 1))
                block.setWidth(3, type: .absoluteValueType, for: .padding)
                if r == 0 { block.backgroundColor = NSColor(white: 0.92, alpha: 1) }
                let style = NSMutableParagraphStyle()
                style.textBlocks = [block]
                style.lineSpacing = 1
                style.paragraphSpacing = 0
                let font = RichDocumentEditing.headingFont(level: nil, bold: r == 0, italic: false)
                out.append(NSAttributedString(string: "\n", attributes: [
                    .font: NSFontManager.shared.convert(font, toSize: 9.5), .paragraphStyle: style, .foregroundColor: NSColor.black,
                ]))
            }
        }
        // 표 뒤에 이어 쓸 본문 문단
        out.append(NSAttributedString(string: "\n", attributes: bodyAttributes()))
        return out
    }

    // MARK: 쪽 나눔 표시 찾기

    /// 쪽 나눔 표시 문단들의 자리(줄바꿈까지), 앞에서부터
    static func bandRanges(in text: NSAttributedString) -> [NSRange] {
        let ns = text.string as NSString
        var out: [NSRange] = []
        text.enumerateAttribute(.hanlabongPageBreak, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard value != nil else { return }
            let paragraph = ns.paragraphRange(for: range)
            if let last = out.last, NSMaxRange(last) >= paragraph.location {
                out[out.count - 1] = NSUnionRange(last, paragraph)
            } else {
                out.append(paragraph)
            }
        }
        return out
    }

    // MARK: 글 고치기 길목(NSTextViewDelegate)

    func undoManager(for view: NSTextView) -> UndoManager? { undo }

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        guard !internalEdit, let storage = textView.textStorage else { return true }
        guard let replacement = replacementString else { return true }    // 모양만 바꾸기는 그대로
        let bands = Self.bandRanges(in: storage)
        if bands.isEmpty || textView.hasMarkedText() && range.length == 0 {
            return handleReturnKey(textView, range: range, replacement: replacement)
        }
        // 띠에 걸리는 자리: 띠 안에 끼워 넣기 / 띠에 걸친 지우기·바꾸기 / 띠 바로 앞 줄바꿈 지우기(띠가 앞 문단에 붙어 버리는 것)
        var hits: [NSRange] = []
        var keepRange = range
        for band in bands {
            if range.length == 0 {
                if NSLocationInRange(range.location, band) { NSSound.beep(); return false }
            } else if NSIntersectionRange(range, band).length > 0 {
                hits.append(band)
            } else if NSMaxRange(range) == band.location, replacement.isEmpty,
                      (storage.string as NSString).character(at: band.location - 1) == 10, range.length == 1 {
                // 띠 바로 앞 줄 끝에서 앞으로 지우기(⌦): 줄바꿈 대신 띠를 지운다
                hits.append(band)
                keepRange = NSRange(location: band.location, length: 0)
            }
        }
        if hits.isEmpty { return handleReturnKey(textView, range: range, replacement: replacement) }
        var expanded = keepRange
        for band in hits { expanded = expanded.length == 0 && expanded.location == band.location ? band : NSUnionRange(expanded, band) }
        var attributes = textView.typingAttributes
        attributes[.hanlabongPageBreak] = nil
        if (attributes[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.isEmpty == false { attributes[.paragraphStyle] = Self.bodyStyle() }
        replace(expanded, with: NSAttributedString(string: replacement, attributes: attributes))
        return false
    }

    /// 커서가 쪽 나눔 표시 줄에 멈추지 않게: 앞으로 가면 표시 뒤(다음 쪽 첫 자리), 뒤로 가면 표시 앞 문단 끝으로
    func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange oldSelectedCharRange: NSRange,
                  toCharacterRange newSelectedCharRange: NSRange) -> NSRange {
        guard newSelectedCharRange.length == 0, let storage = textView.textStorage,
              newSelectedCharRange.location < storage.length,
              storage.attribute(.hanlabongPageBreak, at: newSelectedCharRange.location, effectiveRange: nil) != nil else { return newSelectedCharRange }
        let ns = storage.string as NSString
        var band = ns.paragraphRange(for: NSRange(location: newSelectedCharRange.location, length: 0))
        // 표시가 여러 개 붙어 있으면 한 덩어리로
        while NSMaxRange(band) < storage.length, storage.attribute(.hanlabongPageBreak, at: NSMaxRange(band), effectiveRange: nil) != nil {
            band = NSUnionRange(band, ns.paragraphRange(for: NSRange(location: NSMaxRange(band), length: 0)))
        }
        while band.location > 0, storage.attribute(.hanlabongPageBreak, at: band.location - 1, effectiveRange: nil) != nil {
            band = NSUnionRange(band, ns.paragraphRange(for: NSRange(location: band.location - 1, length: 0)))
        }
        let backward = newSelectedCharRange.location < oldSelectedCharRange.location && oldSelectedCharRange.length == 0
        if backward, band.location > 0 { return NSRange(location: band.location - 1, length: 0) }
        return NSRange(location: NSMaxRange(band), length: 0)
    }

    /// 줄바꿈 칠 때: 목록("• ") 문단이면 다음 줄도 목록으로(빈 목록 줄이면 목록을 끝낸다)
    private func handleReturnKey(_ tv: NSTextView, range: NSRange, replacement: String) -> Bool {
        guard replacement == "\n", range.length == 0, !tv.hasMarkedText(), let storage = tv.textStorage else { return true }
        let ns = storage.string as NSString
        let paragraph = ns.paragraphRange(for: NSRange(location: range.location, length: 0))
        let body = ns.substring(with: paragraph).trimmingCharacters(in: .newlines)
        guard body.hasPrefix(Self.bullet) else { return true }
        if body == Self.bullet || body == "•" {
            // 빈 목록 줄에서 줄바꿈: 표시를 떼고 목록을 끝낸다
            replace(NSRange(location: paragraph.location, length: (body as NSString).length), with: NSAttributedString(string: ""))
            return false
        }
        var attributes = tv.typingAttributes
        attributes[.hanlabongHeading] = nil
        replace(range, with: NSAttributedString(string: "\n" + Self.bullet, attributes: attributes))
        return false
    }

    func textView(_ textView: NSTextView, shouldChangeTypingAttributes oldTypingAttributes: [String: Any] = [:],
                  toAttributes newTypingAttributes: [NSAttributedString.Key: Any] = [:]) -> [NSAttributedString.Key: Any] {
        // 쪽 나눔 표시 바로 뒤에서 쓰기 시작해도 표시 모양(1pt·투명·가운데)이 따라오지 않게
        if newTypingAttributes[.hanlabongPageBreak] != nil { return Self.bodyAttributes() }
        // 제목 끝에서 줄바꿈해 생긴 빈 문단은 본문으로(제목 표시를 물려받지 않게)
        if newTypingAttributes[.hanlabongHeading] != nil, let storage = textView.textStorage {
            let ns = storage.string as NSString
            let loc = min(textView.selectedRange().location, ns.length)
            if loc > 0, ns.character(at: loc - 1) == 10, loc == ns.length || ns.character(at: loc) == 10 {
                return Self.bodyAttributes()
            }
        }
        return newTypingAttributes
    }

    func textDidChange(_ notification: Notification) {
        // 제목 끝에서 줄바꿈하면 다음 문단은 본문으로(워드처럼)
        if let tv = textView, tv.selectedRange().length == 0, let storage = tv.textStorage {
            let loc = tv.selectedRange().location
            let ns = storage.string as NSString
            if loc > 0, loc <= ns.length, ns.character(at: loc - 1) == 10,
               loc == ns.length || ns.paragraphRange(for: NSRange(location: loc, length: 0)).length <= 1,
               tv.typingAttributes[.hanlabongHeading] != nil {
                tv.typingAttributes = Self.bodyAttributes()
            }
        }
        onChange?()
        publishFormat()
    }

    func textViewDidChangeSelection(_ notification: Notification) { publishFormat() }

    // MARK: 붙여 넣은 그림을 본문 폭 안으로(NSTextStorageDelegate)

    nonisolated func textStorage(_ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
                                 range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters), editedRange.length > 0 else { return }
        MainActor.assumeIsolated {
            let content = contentSize
            textStorage.enumerateAttribute(.attachment, in: editedRange) { value, _, _ in
                guard let attachment = value as? NSTextAttachment else { return }
                Self.fit(attachment, in: content)
            }
        }
    }

    /// 첨부 그림의 크기를 본문 폭·높이 안에서 비율을 지켜 맞춘다(키우지는 않는다)
    static func fit(_ attachment: NSTextAttachment, in content: CGSize) {
        var size = attachment.bounds.size
        if size.width <= 0 || size.height <= 0 {
            if let image = attachment.image { size = image.size }
            else if let data = attachment.contents ?? attachment.fileWrapper?.regularFileContents, let image = NSImage(data: data) {
                attachment.image = image
                size = image.size
            }
        }
        guard size.width > 0, size.height > 0 else { return }
        let scale = min(1, content.width / size.width, content.height / size.height)
        let fitted = CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
        if attachment.bounds.size != fitted { attachment.bounds = CGRect(origin: .zero, size: fitted) }
    }

    // MARK: 바꾸기(되돌리기 되게)

    /// 한 자리를 글로 바꾼다(되돌리기 한 묶음)
    func replace(_ range: NSRange, with text: NSAttributedString) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        internalEdit = true
        defer { internalEdit = false }
        undo.beginUndoGrouping()
        defer { undo.endUndoGrouping() }
        guard tv.shouldChangeText(in: range, replacementString: text.string) else { return }
        storage.replaceCharacters(in: range, with: text)
        tv.didChangeText()
        let end = range.location + text.length
        tv.setSelectedRange(NSRange(location: min(end, storage.length), length: 0))
    }

    /// 여러 자리를 한꺼번에(앞에서부터, 겹치지 않게). strings가 nil이면 모양만 바꾼다
    private func change(_ ranges: [NSRange], strings: [String]?, _ body: (NSTextStorage) -> Void) {
        guard let tv = textView, let storage = tv.textStorage, !ranges.isEmpty else { return }
        internalEdit = true
        defer { internalEdit = false }
        guard tv.shouldChangeText(inRanges: ranges.map { NSValue(range: $0) }, replacementStrings: strings) else { return }
        storage.beginEditing()
        body(storage)
        storage.endEditing()
        tv.didChangeText()
    }

    // MARK: 문단 고르기

    /// 선택이 걸친 문단들(쪽 띠·표 칸 문단은 skipBlocks면 뺀다)
    private func selectedParagraphs(skipBlocks: Bool) -> [NSRange] {
        guard let tv = textView, let storage = tv.textStorage else { return [] }
        let ns = storage.string as NSString
        let selection = tv.selectedRange()
        var out: [NSRange] = []
        let span = ns.paragraphRange(for: NSRange(location: min(selection.location, ns.length), length: selection.length))
        if span.length == 0 { return [span] }
        ns.enumerateSubstrings(in: span, options: [.byParagraphs, .substringNotRequired]) { _, range, enclosing, _ in
            if skipBlocks, self.isBlock(at: range.length > 0 ? range.location : enclosing.location, in: storage) { return }
            out.append(enclosing)
        }
        // 맨 끝 빈 줄(글 끝 커서)
        if out.isEmpty, !skipBlocks || !isBlock(at: max(0, span.location - 1), in: storage) { out.append(span) }
        return out
    }

    private func isBlock(at location: Int, in storage: NSAttributedString) -> Bool {
        guard location < storage.length else { return false }
        if storage.attribute(.hanlabongPageBreak, at: location, effectiveRange: nil) != nil { return true }
        return (storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.isEmpty == false
    }

    // MARK: 굵게 · 기울임

    static func isBold(_ font: NSFont?) -> Bool {
        guard let font else { return false }
        if font.fontDescriptor.symbolicTraits.contains(.bold) { return true }
        if let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any],
           let weight = (traits[.weight] as? NSNumber)?.doubleValue, weight >= 0.3 { return true }
        return false
    }

    static func isItalic(_ font: NSFont?) -> Bool { font?.fontDescriptor.symbolicTraits.contains(.italic) ?? false }

    /// 같은 크기에서 굵게·기울임만 바꾼 글꼴(한라봉 기본 글꼴로)
    static func font(like font: NSFont?, bold: Bool, italic: Bool) -> NSFont {
        // 사용자가 고른 글꼴 가족이면 그 가족 안에서 굵기·기울임만 바꾼다(기본 글꼴로 되돌리지 않게)
        if let font, let family = font.familyName, !family.hasPrefix("."), family != defaultFamily {
            let manager = NSFontManager.shared
            var out = manager.convert(font, toNotHaveTrait: [.boldFontMask, .italicFontMask])
            if bold { out = manager.convert(out, toHaveTrait: .boldFontMask) }
            if italic { out = manager.convert(out, toHaveTrait: .italicFontMask) }
            return manager.convert(out, toSize: font.pointSize)
        }
        let base = RichDocumentEditing.headingFont(level: nil, bold: bold, italic: italic)
        return NSFontManager.shared.convert(base, toSize: font?.pointSize ?? base.pointSize)
    }

    /// 지금 글 입력을 받는 칸이 문서 종이인가(요청칸 같은 글 칸이면 false). 단축키가 엉뚱한 칸에서 문서를 고치지 않게
    var documentHasFocus: Bool {
        guard let responder = textView?.window?.firstResponder as? NSTextView else { return false }
        return responder.delegate === self
    }

    /// ⌘B·⌘I 단축키 길목: 종이에 커서가 있을 때만 먹는다
    func toggleBoldShortcut() { if documentHasFocus { toggleBold() } }
    func toggleItalicShortcut() { if documentHasFocus { toggleItalic() } }

    func toggleBold() { toggle(bold: true) }
    func toggleItalic() { toggle(bold: false) }

    private func toggle(bold: Bool) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let selection = tv.selectedRange()
        let state = currentFormat()
        let on = bold ? !state.bold : !state.italic
        func restyle(_ font: NSFont?) -> NSFont {
            Self.font(like: font, bold: bold ? on : Self.isBold(font), italic: bold ? Self.isItalic(font) : on)
        }
        if selection.length == 0 {
            tv.typingAttributes[.font] = restyle(tv.typingAttributes[.font] as? NSFont)
            publishFormat()
            return
        }
        // 쪽 띠 글자는 건드리지 않는다
        var ranges: [NSRange] = []
        storage.enumerateAttribute(.hanlabongPageBreak, in: selection) { value, range, _ in if value == nil { ranges.append(range) } }
        change(ranges, strings: nil) { storage in
            for range in ranges {
                storage.enumerateAttribute(.font, in: range) { value, sub, _ in
                    storage.addAttribute(.font, value: restyle(value as? NSFont), range: sub)
                }
            }
        }
        publishFormat()
    }

    // MARK: 글자 크기 · 글꼴 · 색 · 정렬

    /// 크기 올리고 내릴 때 밟는 단계
    static let sizeSteps: [CGFloat] = [8, 9, 10, 10.5, 11, 12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 72]

    /// 한 단계 위·아래 크기. 단계표 밖이면 가장 가까운 단계로 붙는다
    static func steppedSize(_ size: CGFloat, up: Bool) -> CGFloat {
        if up { return sizeSteps.first(where: { $0 > size + 0.01 }) ?? min(size + 4, 200) }
        return sizeSteps.last(where: { $0 < size - 0.01 }) ?? max(size - 1, 4)
    }

    /// 한라봉 기본 글꼴 가족 이름(글꼴 목록의 "기본")
    static var defaultFamily: String { RichDocumentEditing.headingFont(level: nil, bold: false, italic: false).familyName ?? "" }

    /// 글꼴 목록: 기본 + 이 맥에 깔린 것만
    static func availableFamilies() -> [String] {
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        let wanted = ["Apple SD Gothic Neo", "AppleMyungjo", "NanumGothic", "NanumBarunGothic", "NanumMyeongjo", "Nanum Gothic",
                      "Helvetica Neue", "Times New Roman", "Georgia", "Menlo"]
        return wanted.filter { installed.contains($0) }
    }

    /// 선택에서 쪽 띠 글자를 뺀 자리들(띠는 안쪽 글자를 못 고친다)
    private func styledRanges(in selection: NSRange) -> [NSRange] {
        guard let storage = textView?.textStorage else { return [] }
        var ranges: [NSRange] = []
        storage.enumerateAttribute(.hanlabongPageBreak, in: selection) { value, range, _ in if value == nil { ranges.append(range) } }
        return ranges
    }

    /// 글꼴·글자 모양 바꾸기의 공통 길목. 선택이 비면 앞으로 쓸 글 모양만, 아니면 고른 글자(되돌리기 한 묶음).
    /// attributes 값이 nil이면 그 속성을 뗀다
    private func restyle(font transform: ((NSFont?) -> NSFont)? = nil, attributes: [NSAttributedString.Key: Any?] = [:]) {
        guard let tv = textView else { return }
        let selection = tv.selectedRange()
        if selection.length == 0 {
            if let transform {
                tv.typingAttributes[.font] = transform(tv.typingAttributes[.font] as? NSFont)
                if tv.typingAttributes[.hanlabongHeading] == nil { tv.typingAttributes[.hanlabongPlainBody] = true }
            }
            for (key, value) in attributes { tv.typingAttributes[key] = value }
            publishFormat()
            return
        }
        let ranges = styledRanges(in: selection)
        change(ranges, strings: nil) { storage in
            for range in ranges {
                if let transform {
                    storage.enumerateAttribute(.font, in: range) { value, sub, _ in
                        storage.addAttribute(.font, value: transform(value as? NSFont), range: sub)
                        // 크기를 키운 본문 글이 저장 때 제목으로 짐작되지 않게 "본문" 표시를 단다
                        if storage.attribute(.hanlabongHeading, at: sub.location, effectiveRange: nil) == nil {
                            storage.addAttribute(.hanlabongPlainBody, value: true, range: sub)
                        }
                    }
                }
                for (key, value) in attributes {
                    if let value { storage.addAttribute(key, value: value, range: range) } else { storage.removeAttribute(key, range: range) }
                }
            }
        }
        publishFormat()
    }

    private static func baseFont(_ font: NSFont?) -> NSFont { font ?? RichDocumentEditing.headingFont(level: nil, bold: false, italic: false) }

    /// 글자 크기를 정확히(pt)
    func setFontSize(_ size: CGFloat) {
        let size = min(max(size, 4), 200)
        restyle(font: { NSFontManager.shared.convert(Self.baseFont($0), toSize: size) })
    }

    /// 글자 크기 한 단계 키우기·줄이기(고른 글자마다 제 크기에서)
    func changeFontSize(up: Bool) {
        restyle(font: { font in
            let base = Self.baseFont(font)
            return NSFontManager.shared.convert(base, toSize: Self.steppedSize(base.pointSize, up: up))
        })
    }

    /// 글꼴 가족을 바꾼다. nil이면 한라봉 기본 글꼴로. 굵기·기울임·크기는 그대로, 이름은 저장 때 쓰게 `.hanlabongFontName`에도 단다
    func setFontFamily(_ name: String?) {
        restyle(font: { font in
            let base = Self.baseFont(font)
            guard let name else {
                let plain = RichDocumentEditing.headingFont(level: nil, bold: Self.isBold(base), italic: Self.isItalic(base))
                return NSFontManager.shared.convert(plain, toSize: base.pointSize)
            }
            let converted = NSFontManager.shared.convert(base, toFamily: name)
            if converted.familyName == name { return converted }
            return NSFont(name: name, size: base.pointSize) ?? base
        }, attributes: [.hanlabongFontName: name])
    }

    /// 글자 색. nil이면 검정(기본)
    func setTextColor(_ color: NSColor?) {
        let value = color.map { $0.usingColorSpace(.sRGB) ?? $0 } ?? NSColor.black
        restyle(attributes: [.foregroundColor: value])
    }

    /// 고른 문단들의 정렬(표 칸 문단 포함, 쪽 띠는 뺀다). 글 끝 빈 줄이면 앞으로 쓸 글에
    func setAlignment(_ alignment: NSTextAlignment) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let typing = (tv.typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? Self.bodyStyle()
        typing.alignment = alignment
        tv.typingAttributes[.paragraphStyle] = typing
        let paragraphs = selectedParagraphs(skipBlocks: false).filter {
            $0.length > 0 && storage.attribute(.hanlabongPageBreak, at: min($0.location, storage.length - 1), effectiveRange: nil) == nil
        }
        change(paragraphs, strings: nil) { storage in
            for range in paragraphs {
                let style = (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?
                    .mutableCopy() as? NSMutableParagraphStyle ?? Self.bodyStyle()
                style.alignment = alignment
                storage.addAttribute(.paragraphStyle, value: style, range: range)
            }
        }
        publishFormat()
    }

    // MARK: 제목 단계

    /// 고른 문단들을 제목 1~3 또는 본문(nil)으로. 글꼴 크기·굵기와 `.hanlabongHeading`, 문단 간격을 writer와 같게
    func setHeading(_ level: Int?) {
        guard let tv = textView else { return }
        let paragraphs = selectedParagraphs(skipBlocks: true).filter { $0.length > 0 }
        guard !paragraphs.isEmpty else {
            // 글 끝 빈 자리: 앞으로 쓸 글 모양만
            tv.typingAttributes[.font] = RichDocumentEditing.headingFont(level: level, bold: false, italic: false)
            tv.typingAttributes[.hanlabongHeading] = level
            tv.typingAttributes[.paragraphStyle] = Self.bodyStyle(heading: level)
            publishFormat()
            return
        }
        change(paragraphs, strings: nil) { storage in
            for range in paragraphs {
                storage.enumerateAttribute(.font, in: range) { value, sub, _ in
                    let font = value as? NSFont
                    // 제목에서 본문으로 내리면 제목 때문에 굵던 글은 보통 굵기로
                    let wasHeading = storage.attribute(.hanlabongHeading, at: sub.location, effectiveRange: nil) != nil
                    let bold = level == nil ? (!wasHeading && Self.isBold(font)) : false
                    storage.addAttribute(.font, value: RichDocumentEditing.headingFont(level: level, bold: bold, italic: Self.isItalic(font)), range: sub)
                }
                if let level { storage.addAttribute(.hanlabongHeading, value: level, range: range) }
                else { storage.removeAttribute(.hanlabongHeading, range: range) }
                let style = (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?
                    .mutableCopy() as? NSMutableParagraphStyle ?? Self.bodyStyle()
                style.paragraphSpacing = level == nil ? 8 : 6
                style.paragraphSpacingBefore = level == nil ? 0 : 10
                storage.addAttribute(.paragraphStyle, value: style, range: range)
            }
        }
        tv.typingAttributes[.hanlabongHeading] = level
        tv.typingAttributes[.font] = RichDocumentEditing.headingFont(level: level, bold: false, italic: false)
        publishFormat()
    }

    // MARK: 글머리 목록

    static let bullet = "• "

    /// 고른 문단 앞에 "• "를 넣거나(하나라도 없으면) 모두 뺀다(모두 있으면)
    func toggleBullet() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let ns = storage.string as NSString
        var paragraphs = selectedParagraphs(skipBlocks: true)
        // 글 끝 빈 줄 하나는 그 자리에 표시만 넣는다
        if paragraphs.isEmpty { return }
        paragraphs = paragraphs.filter { $0.location <= ns.length }
        let marked = paragraphs.map { ns.substring(with: $0).hasPrefix(Self.bullet) }
        let remove = marked.allSatisfy { $0 }
        var ranges: [NSRange] = [], strings: [String] = []
        for (range, has) in zip(paragraphs, marked) {
            if remove { ranges.append(NSRange(location: range.location, length: (Self.bullet as NSString).length)); strings.append("") }
            else if !has { ranges.append(NSRange(location: range.location, length: 0)); strings.append(Self.bullet) }
        }
        let selection = tv.selectedRange()
        change(ranges, strings: strings) { storage in
            for (range, string) in zip(ranges, strings).reversed() {
                let probe = min(range.location, max(storage.length - 1, 0))
                var attributes = storage.length > 0 && range.location < storage.length ? storage.attributes(at: probe, effectiveRange: nil) : tv.typingAttributes
                attributes[.attachment] = nil
                storage.replaceCharacters(in: range, with: NSAttributedString(string: string, attributes: attributes))
            }
        }
        let delta = (Self.bullet as NSString).length * (remove ? -1 : 1)
        let movedBefore = ranges.filter { $0.location <= selection.location }.count
        let start = max(0, selection.location + delta * min(movedBefore, 1))
        tv.setSelectedRange(NSRange(location: min(start, storage.length), length: max(0, selection.length + delta * max(ranges.count - 1, 0))))
        publishFormat()
    }

    // MARK: 표 줄·칸 넣고 빼기

    enum TableEdit: Equatable {
        case addRow(below: Bool)
        case deleteRow
        case addColumn(right: Bool)
        case deleteColumn
    }

    /// 커서가 있는 표의 줄 수·칸 수(표 밖이면 nil)
    static func tableSize(in storage: NSAttributedString, at location: Int) -> (rows: Int, columns: Int)? {
        guard let block = tableBlock(at: location, in: storage) else { return nil }
        let range = storage.range(of: block.table, at: location)
        var rows = 0
        var cursor = range.location
        while cursor < NSMaxRange(range), let cell = tableBlock(at: cursor, in: storage) {
            rows = max(rows, cell.startingRow + 1)
            let cellRange = storage.range(of: cell, at: cursor)
            guard cellRange.length > 0 else { break }
            cursor = NSMaxRange(cellRange)
        }
        return (rows, block.table.numberOfColumns)
    }

    private static func copy(_ block: NSTextTableBlock, into table: NSTextTable, row: Int, column: Int,
                             clearBackground: Bool = false) -> NSTextTableBlock {
        let new = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
        for layer in [NSTextBlock.Layer.border, .padding, .margin] {
            for edge in [NSRectEdge.minX, .minY, .maxX, .maxY] {
                new.setWidth(block.width(for: layer, edge: edge), type: block.widthValueType(for: layer, edge: edge), for: layer, edge: edge)
            }
        }
        for edge in [NSRectEdge.minX, .minY, .maxX, .maxY] { new.setBorderColor(block.borderColor(for: edge) ?? .clear, for: edge) }
        new.backgroundColor = clearBackground ? nil : block.backgroundColor
        new.verticalAlignment = block.verticalAlignment
        return new
    }

    /// 표 한 줄·한 칸 더하거나 빼서 새로 짠 표. 순수 계산이라 화면 없이 시험한다.
    /// 합친 칸이 있거나 마지막 줄·칸을 지우려 하면 nil. 돌려주는 caret은 그 뒤 커서를 둘 글자 자리(문서 전체 기준)
    static func editedTable(in storage: NSAttributedString, at location: Int, _ edit: TableEdit)
        -> (range: NSRange, replacement: NSAttributedString, caret: Int)? {
        guard let current = tableBlock(at: location, in: storage) else { return nil }
        let oldTable = current.table
        let tableRange = storage.range(of: oldTable, at: location)
        guard tableRange.length > 0 else { return nil }
        // 칸 모으기
        struct Cell { var text: NSAttributedString; var block: NSTextTableBlock; var clear = false }
        var found: [Cell] = []
        var cursor = tableRange.location
        while cursor < NSMaxRange(tableRange) {
            guard let block = tableBlock(at: cursor, in: storage), block.table === oldTable else { return nil }
            let range = storage.range(of: block, at: cursor)
            guard range.length > 0, block.rowSpan == 1, block.columnSpan == 1 else { return nil }
            found.append(Cell(text: storage.attributedSubstring(from: range), block: block))
            cursor = NSMaxRange(range)
        }
        let rowCount = (found.map { $0.block.startingRow }.max() ?? -1) + 1
        let columnCount = oldTable.numberOfColumns
        var grid: [[Cell?]] = Array(repeating: Array(repeating: nil, count: columnCount), count: rowCount)
        for cell in found {
            guard cell.block.startingColumn < columnCount else { return nil }
            grid[cell.block.startingRow][cell.block.startingColumn] = cell
        }
        var rows = grid.map { $0.compactMap { $0 } }
        guard rows.allSatisfy({ $0.count == columnCount }) else { return nil }
        let row = current.startingRow, column = current.startingColumn

        /// 같은 모양의 빈 칸. 머리줄을 본뜨면 배경·굵기는 빼서 본문 칸으로
        func blank(like cell: Cell, header: Bool) -> Cell {
            var attrs = cell.text.length > 0 ? cell.text.attributes(at: 0, effectiveRange: nil) : bodyAttributes()
            if header, let font = attrs[.font] as? NSFont { attrs[.font] = Self.font(like: font, bold: false, italic: isItalic(font)) }
            return Cell(text: NSAttributedString(string: "\n", attributes: attrs), block: cell.block, clear: header)
        }
        var target = (row: row, column: column)
        switch edit {
        case .addRow(let below):
            let at = below ? row + 1 : row
            // 첫 줄 위에 넣으면 아래 줄(본문 칸)을, 아니면 그 자리 줄을 본뜬다
            let templateRow = at == 0 ? (rows.count > 1 ? 1 : 0) : min(at, rows.count - 1) == at ? at : row
            rows.insert(rows[templateRow].map { blank(like: $0, header: templateRow == 0) }, at: at)
            target = (at, column)
        case .deleteRow:
            guard rows.count > 1 else { return nil }
            rows.remove(at: row)
            target = (min(row, rows.count - 1), column)
        case .addColumn(let right):
            let at = right ? column + 1 : column
            for r in rows.indices { rows[r].insert(blank(like: rows[r][column], header: false), at: at) }
            target = (row, at)
        case .deleteColumn:
            guard rows[0].count > 1 else { return nil }
            for r in rows.indices { rows[r].remove(at: column) }
            target = (row, min(column, rows[0].count - 1))
        }

        // 새 표로 다시 짜기
        let table = NSTextTable()
        table.numberOfColumns = rows[0].count
        table.collapsesBorders = oldTable.collapsesBorders
        table.layoutAlgorithm = oldTable.layoutAlgorithm
        table.setContentWidth(oldTable.contentWidth, type: oldTable.contentWidthValueType)
        let out = NSMutableAttributedString()
        var caret = tableRange.location
        for (r, line) in rows.enumerated() {
            for (c, cell) in line.enumerated() {
                let block = copy(cell.block, into: table, row: r, column: c, clearBackground: cell.clear)
                if r == target.row, c == target.column { caret = tableRange.location + out.length }
                let text = NSMutableAttributedString(attributedString: cell.text)
                text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                    let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                    style.textBlocks = [block]
                    text.addAttribute(.paragraphStyle, value: style, range: range)
                }
                out.append(text)
            }
        }
        return (tableRange, out, caret)
    }

    /// 커서가 든 표를 고친다(되돌리기 한 묶음). 못 고치면 false
    @discardableResult
    func editTable(_ edit: TableEdit) -> Bool {
        guard let tv = textView, let storage = tv.textStorage,
              let result = Self.editedTable(in: storage, at: tv.selectedRange().location, edit) else { return false }
        replace(result.range, with: result.replacement)
        tv.setSelectedRange(NSRange(location: min(result.caret, storage.length), length: 0))
        focusSelection()
        publishFormat()
        return true
    }

    // MARK: 넣기(표 · 그림 · 쪽 나눔)

    /// 덩어리를 넣을 자리: 커서가 문단 가운데면 줄을 바꿔서, 표 칸·쪽 띠 안이면 그 덩어리 뒤에.
    /// 돌려주는 prefix는 앞에 붙일 줄바꿈("" 또는 "\n")
    private func blockInsertionPoint() -> (location: Int, prefix: String)? {
        guard let tv = textView, let storage = tv.textStorage else { return nil }
        let ns = storage.string as NSString
        var location = min(tv.selectedRange().location, ns.length)
        // 표 안이면 표 끝으로, 쪽 띠 안이면 띠 끝으로
        if location < storage.length, let style = storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle,
           let block = style.textBlocks.first {
            if let cell = block as? NSTextTableBlock {
                location = NSMaxRange(storage.range(of: cell.table, at: location))
            } else {
                location = NSMaxRange(storage.range(of: block, at: location))
            }
        }
        if let band = Self.bandRanges(in: storage).first(where: { NSLocationInRange(location, $0) }) { location = NSMaxRange(band) }
        let atLineStart = location == 0 || ns.character(at: location - 1) == 10
        return (location, atLineStart ? "" : "\n")
    }

    private func insertBlock(_ block: NSAttributedString) {
        guard let (location, prefix) = blockInsertionPoint() else { return }
        let piece = NSMutableAttributedString(string: prefix, attributes: Self.bodyAttributes())
        piece.append(block)
        replace(NSRange(location: location, length: 0), with: piece)
        focusSelection()
    }

    func insertTable(rows: Int, columns: Int) {
        guard let (location, prefix) = blockInsertionPoint() else { return }
        let piece = NSMutableAttributedString(string: prefix, attributes: Self.bodyAttributes())
        piece.append(Self.emptyTable(rows: rows, columns: columns))
        replace(NSRange(location: location, length: 0), with: piece)
        // 첫 칸에 커서
        textView?.setSelectedRange(NSRange(location: location + (prefix as NSString).length, length: 0))
        focusSelection()
        publishFormat()
    }

    /// 그림 파일 → 본문 폭 안에서 비율 유지. 못 읽으면 false
    @discardableResult
    func insertImage(from url: URL) -> Bool {
        guard let image = NSImage(contentsOf: url), image.size.width > 0,
              let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return false }
        insertBlock(Self.picture(png: png, size: image.size, content: contentSize))
        return true
    }

    /// 그림 한 문단(첨부 + 줄바꿈)
    static func picture(png: Data, size: CGSize, content: CGSize) -> NSAttributedString {
        let attachment = NSTextAttachment(data: png, ofType: UTType.png.identifier)
        attachment.image = NSImage(data: png)
        attachment.bounds = CGRect(origin: .zero, size: size)
        fit(attachment, in: content)
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 8
        let out = NSMutableAttributedString(attachment: attachment)
        out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: out.length))
        out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style, .font: RichDocumentEditing.headingFont(level: nil, bold: false, italic: false)]))
        return out
    }

    /// 쪽 나눔 표시를 커서 자리 문단 앞(가운데면 줄을 바꿔서)에. 그 뒤 글은 다음 쪽 첫 줄로 간다
    func insertPageBreak() {
        insertBlock(DocumentLoader.pageDivider())
    }

    // MARK: 지금 모양

    func currentFormat() -> DocumentFormatState {
        guard let tv = textView, let storage = tv.textStorage else { return DocumentFormatState() }
        let selection = tv.selectedRange()
        var state = DocumentFormatState()
        let font: NSFont?
        if selection.length == 0 || storage.length == 0 {
            font = tv.typingAttributes[.font] as? NSFont
        } else {
            font = storage.attribute(.font, at: min(selection.location, storage.length - 1), effectiveRange: nil) as? NSFont
        }
        let ns = storage.string as NSString
        let paragraph = ns.paragraphRange(for: NSRange(location: min(selection.location, ns.length), length: 0))
        let probe = paragraph.location < storage.length ? paragraph.location : nil
        let heading = probe.flatMap { storage.attribute(.hanlabongHeading, at: $0, effectiveRange: nil) as? NSNumber }?.intValue
            ?? (probe == nil ? (tv.typingAttributes[.hanlabongHeading] as? NSNumber)?.intValue : nil)
        state.heading = heading
        state.bold = heading == nil && Self.isBold(font)
        state.italic = Self.isItalic(font)
        state.bullet = ns.substring(with: paragraph).hasPrefix(Self.bullet)
        state.inBlock = probe.map { isBlock(at: $0, in: storage) } ?? false
        state.fontSize = font?.pointSize ?? 0
        let attrs: [NSAttributedString.Key: Any] = (selection.length == 0 || storage.length == 0)
            ? tv.typingAttributes : storage.attributes(at: min(selection.location, storage.length - 1), effectiveRange: nil)
        let family = (attrs[.hanlabongFontName] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? font?.familyName
        state.fontFamily = (family == nil || family!.hasPrefix(".") || family == Self.defaultFamily) ? nil : family
        let paragraphStyle = (probe.flatMap { storage.attribute(.paragraphStyle, at: $0, effectiveRange: nil) } ?? tv.typingAttributes[.paragraphStyle]) as? NSParagraphStyle
        state.alignment = paragraphStyle.map { $0.alignment == .natural ? .left : $0.alignment } ?? .left
        state.inTable = probe.map { Self.tableBlock(at: $0, in: storage) != nil } ?? false
        return state
    }

    /// 그 자리의 표 칸(표 밖이면 nil)
    static func tableBlock(at location: Int, in storage: NSAttributedString) -> NSTextTableBlock? {
        guard location >= 0, location < storage.length,
              let style = storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle else { return nil }
        return style.textBlocks.first as? NSTextTableBlock
    }

    private func publishFormat() { onFormat?(currentFormat()) }
}
