import AppKit
import SkillEngine

// 문서 영역 4단계: Word·한글처럼 쪽마다 나뉜 화면.
//
// 구조(TextKit 1): 글 저장소(NSTextStorage) 하나 + 글 짜는 곳(NSLayoutManager) 하나 + 쪽마다 글 상자(PageTextContainer)와 텍스트 뷰(PageTextView) 하나씩.
// 글은 한 줄로 이어져 있고, 레이아웃 매니저가 1쪽 상자부터 차례로 채우다 넘치면 다음 상자로 흘린다. 그래서 편집·선택·되돌리기·찾기는
// 쪽을 넘나들어도 그대로다(텍스트 뷰들이 선택·대리자·입력 모양을 함께 쓴다). 저장은 지금처럼 저장소 하나를 읽는다.
//
// 리브레오피스 Writer(sw/source/core/layout)에서 가져온 생각(코드는 안 옮기고 방법만):
// - 쪽 나눔은 "다음 문단 앞"의 성질이다(flowfrm.cxx SwFlowFrame::IsPageBreak / CheckMoveFwd). 표시 문단 바로 뒤 문단이 표시와 같은 쪽에 있으면
//   다음 쪽으로 민다. 표시가 이미 쪽 맨 위에 있으면(앞 쪽이 꽉 차서 저절로 넘어왔으면) 또 밀지 않는다 → 빈 쪽이 생기지 않는다. 문서 맨 앞 쪽 나눔도 무시.
// - 글이 넘치면 쪽을 뒤에 붙이고(flowfrm.cxx GetNextLeaf → pagechg.cxx InsertPage), 다 짠 뒤 뒤에서부터 빈 쪽을 떼어 낸다
//   (pagechg.cxx SwRootFrame::RemoveSuperfluous, 내용 있는 쪽을 만나면 멈춤).
// - 표는 줄 단위로 쪽을 넘긴다(tabfrm.cxx SwTabFrame::Split: 안 들어가는 첫 줄을 찾아 그 줄부터 다음 쪽). 쪽 끝에서 잘리는 줄은 통째로 다음 쪽으로.
//   쪽 맨 위에서 시작했는데도 안 들어가는(한 쪽보다 큰) 줄은 더 밀지 않는다(calcmove.cxx MakeAll의 bDontMoveMe: 무한히 쪽을 늘리지 않게).
//   머리줄(첫 줄)이 쪽 끝에 홀로 남으면 머리줄째 넘긴다(Split의 머리줄·첫 줄 함께 두기).
// - 레이아웃을 고치고 다시 짜는 일은 횟수를 정해 둔다(layact.cxx InternalAction의 루프 제한).
// - 두 쪽 보기는 1쪽을 오른쪽에 혼자 두고 2·3, 4·5…를 짝짓는다(pagechg.cxx CheckViewLayout의 책 보기). 이어 보기는 쪽 나눔을 띠로만 보인다(Browse 모드처럼).

// MARK: - 보기 방식

/// 문서를 펼치는 방식. 한 쪽씩(기본) / 두 쪽씩(책처럼, 1쪽은 오른쪽에 혼자) / 이어 보기(종이 한 장이 길게, 쪽 나눔은 회색 띠)
enum DocumentPageLayout: String, CaseIterable, Identifiable, Sendable {
    case single, spread, continuous

    var id: String { rawValue }
    var title: String {
        switch self {
        case .single: return L("한 쪽씩", "One page")
        case .spread: return L("두 쪽씩 (책처럼)", "Two pages (book)")
        case .continuous: return L("이어 보기", "Continuous")
        }
    }
    var symbol: String {
        switch self {
        case .single: return "rectangle.portrait"
        case .spread: return "book"
        case .continuous: return "scroll"
        }
    }
    /// 쪽으로 나눠 보이는가(이어 보기만 아니다)
    var paginates: Bool { self != .continuous }
}

// MARK: - 쪽 나누기 규칙

/// 쪽 상자가 줄 자리를 내줄 때마다 묻는 규칙. 글 짜는 중에 불리므로 레이아웃을 다시 묻지 않고, 짜면서 적어 둔 것만 본다.
/// (레이아웃은 늘 메인 스레드에서 하지만, 상자 쪽 메서드는 액터 밖이라 이 작은 클래스에 따로 담았다)
final class PageFlowRules: @unchecked Sendable {
    /// 쪽으로 나누는 중인가(이어 보기면 false)
    var paginates = true
    /// 글자 자리 → 그 글자로 시작하는 줄이 들어가면 안 되는 쪽 번호(0부터). 쪽 끝에서 잘리는 표 줄을 다음 쪽으로 보낼 때 쓴다.
    /// "다음 쪽으로"가 아니라 "이 쪽은 안 돼"라고 적어서, 다음 쪽 위쪽 칸 여백(테두리·안쪽 여백) 때문에 또 밀리는 일이 없다
    var forbidden: [Int: Int] = [:]
    /// 쪽 나눔 표시 문단의 끝 글자(줄바꿈) 자리 → 그 줄이 놓인 쪽과 줄 위쪽 y. 글을 짜면서 적는다
    var markerLines: [Int: (page: Int, top: CGFloat)] = [:]
    /// 같은 글자·같은 쪽을 몇 번 거절했는지. 레이아웃 매니저가 거절된 줄을 같은 상자에 끝없이 다시 넣으려 할 때가 있어서
    /// (표 칸 안쪽 줄 등) 일정 횟수를 넘으면 더 거절하지 않는다(리브레오피스 layact.cxx·calcmove.cxx의 루프 제한과 같은 생각)
    var refusals: [Int: Int] = [:]
    static let maxRefusals = 2
    /// 표 줄마다 다음 쪽으로 옮긴 횟수(같은 줄을 2번 넘게 옮기지 않는다)
    var moves: [Int: Int] = [:]

    /// 한 번 맞추기를 새로 시작할 때 거절 횟수를 비운다
    func resetRefusals() { refusals.removeAll(keepingCapacity: true) }

    /// 이 글자로 시작하는 줄이 이 쪽에 오면 안 되는가
    func mustLeave(_ index: Int, page: Int, storage: NSTextStorage) -> Bool {
        guard paginates, index > 0, index < storage.length else { return false }
        // 표 줄 넘기기: 같은 글자·같은 쪽 거절은 몇 번까지만
        if let bad = forbidden[index], bad == page {
            let key = index &* 4096 &+ page
            let count = (refusals[key] ?? 0) + 1
            refusals[key] = count
            if count <= Self.maxRefusals { return true }
        }
        // 쪽 나눔 표시 바로 뒤 문단의 첫 줄: 표시가 같은 쪽 중간에 있으면 다음 쪽으로(표시가 쪽 맨 위면 이미 새 쪽이다)
        guard storage.attribute(.hanlabongPageBreak, at: index - 1, effectiveRange: nil) != nil,
              storage.attribute(.hanlabongPageBreak, at: index, effectiveRange: nil) == nil,
              let line = markerLines[index - 1] else { return false }
        return line.page == page && line.top > 0.5
    }
}

/// 쪽 하나의 글 상자. 규칙이 "이 쪽은 안 돼"라고 하면 빈 자리를 돌려줘서 레이아웃 매니저가 다음 상자(다음 쪽)로 넘어가게 한다
final class PageTextContainer: NSTextContainer {
    var pageIndex = 0
    weak var rules: PageFlowRules?

    // 단순한 사각형이라고 하면 줄마다 묻지 않고 건너뛸 수 있어서 false
    override var isSimpleRectangularTextContainer: Bool { false }

    override func lineFragmentRect(forProposedRect proposedRect: NSRect, at characterIndex: Int,
                                   writingDirection baseWritingDirection: NSWritingDirection,
                                   remaining remainingRect: UnsafeMutablePointer<NSRect>?) -> NSRect {
        let rect = super.lineFragmentRect(forProposedRect: proposedRect, at: characterIndex,
                                          writingDirection: baseWritingDirection, remaining: remainingRect)
        guard !rect.isEmpty, let rules, let storage = layoutManager?.textStorage,
              rules.mustLeave(characterIndex, page: pageIndex, storage: storage) else { return rect }
        remainingRect?.pointee = .zero
        return .zero
    }
}

// MARK: - 쪽 뷰

/// 쪽 하나의 글 뷰. 이어 보기에서는 쪽 나눔 자리에 회색 띠와 쪽 번호를 그린다(글이 아니라 그림이라 저장에 안 들어간다)
final class PageTextView: NSTextView {
    weak var pager: DocumentPager?

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        pager?.drawBands(in: rect, of: self)
    }
}

/// 문서의 머리글·꼬리글·쪽 번호(원본에 있으면). 종이 위·아래 여백에 화면으로만 그린다(PDF로 쓸 때와 같은 자리)
struct PageDecorations {
    var header: NSAttributedString?
    var footer: NSAttributedString?
    var showPageNumber = false
    var isEmpty: Bool { header == nil && footer == nil && !showPageNumber }
}

/// 표가 쪽을 넘어 이어질 때 그 쪽 맨 위에 다시 보여 줄 머리줄(화면에만 그린다. 글에는 안 들어간다).
/// 처음 머리줄이 놓인 쪽의 글자 모양을 그대로 빌려 그리므로, 고치면 같이 바뀐다
struct RepeatedTableHeader: Equatable {
    /// 머리줄 칸들의 글자 모양(glyph) 범위
    var glyphs: NSRange
    /// 원래 쪽 글 상자 안에서 머리줄 위쪽 y
    var top: CGFloat
    /// 머리줄 높이(이만큼 이 쪽 글 상자를 줄이고 글 뷰를 내린다)
    var height: CGFloat
}

/// 종이 한 장: 흰 바탕 + 아래쪽 가운데 작은 쪽 번호(화면에만). 문서에 머리글·꼬리글이 있으면 그걸 위·아래 여백에 그린다. 글 뷰는 여백 안쪽에 놓인다
final class DocumentPaperView: NSView {
    let textView: PageTextView
    var number: Int { didSet { if number != oldValue { needsDisplay = true } } }
    var showsNumber = true { didSet { if showsNumber != oldValue { needsDisplay = true } } }
    var bottomMargin: CGFloat = 48
    var margins = NSEdgeInsets(top: 48, left: 48, bottom: 48, right: 48)
    var decorations = PageDecorations() { didSet { needsDisplay = true } }
    /// 이 쪽 위에 다시 그릴 표 머리줄(없으면 nil)과, 그 글자 모양을 빌려 올 레이아웃 매니저
    var repeatedHeader: RepeatedTableHeader? { didSet { if repeatedHeader != oldValue { needsDisplay = true } } }
    weak var headerSource: NSLayoutManager?

    init(textView: PageTextView, number: Int) {
        self.textView = textView
        self.number = number
        super.init(frame: .zero)
        // macOS 14부터 뷰는 기본으로 자기 테두리 밖까지 그릴 수 있다 → 흰 바탕이 다른 쪽의 글과 배경을 덮지 않게 자른다
        clipsToBounds = true
        addSubview(textView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.intersection(dirtyRect).fill()
        drawRepeatedHeader(dirtyRect)
        guard showsNumber else { return }
        if !decorations.isEmpty { drawDecorations(); return }
        let label = "\(number)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor(white: 0.55, alpha: 1),
        ]
        let size = label.size(withAttributes: attributes)
        let y = bounds.height - max(bottomMargin, size.height + 4) / 2 - size.height / 2
        let spot = NSRect(x: (bounds.width - size.width) / 2, y: y, width: size.width, height: size.height)
        if spot.intersects(dirtyRect) { label.draw(in: spot, withAttributes: attributes) }
    }

    /// 앞 쪽에서 시작한 표의 머리줄을 이 쪽 글 맨 위에 그린다(배경·테두리·글자). 저장소를 건드리지 않는 그림이다.
    /// 레이아웃이 아직 안 짜인 틈에는 다시 짜게 만들지 않도록 그리지 않는다
    private func drawRepeatedHeader(_ dirtyRect: NSRect) {
        guard let header = repeatedHeader, header.height > 0, let lm = headerSource,
              header.glyphs.length > 0, NSMaxRange(header.glyphs) <= lm.numberOfGlyphs,
              lm.textContainer(forGlyphAt: header.glyphs.location, effectiveRange: nil, withoutAdditionalLayout: true) != nil,
              lm.textContainer(forGlyphAt: NSMaxRange(header.glyphs) - 1, effectiveRange: nil, withoutAdditionalLayout: true) != nil
        else { return }
        let strip = NSRect(x: margins.left, y: margins.top, width: max(72, bounds.width - margins.left - margins.right), height: header.height)
        guard strip.intersects(dirtyRect) else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: strip).addClip()
        let origin = NSPoint(x: margins.left, y: margins.top - header.top)
        lm.drawBackground(forGlyphRange: header.glyphs, at: origin)
        lm.drawGlyphs(forGlyphRange: header.glyphs, at: origin)
    }

    /// 머리글(위 여백 안쪽)·꼬리글 + 쪽 번호(아래 여백 안쪽, 가운데). RichDocumentWriter가 PDF에 그리는 자리와 같게
    private func drawDecorations() {
        let width = max(72, bounds.width - margins.left - margins.right)
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin]
        if let header = decorations.header {
            let h = ceil(header.boundingRect(with: CGSize(width: width, height: 10_000), options: options).height)
            header.draw(with: NSRect(x: margins.left, y: max(6, margins.top - 8 - h), width: width, height: h + 2), options: options)
        }
        let footer = NSMutableAttributedString()
        if let text = decorations.footer { footer.append(text) }
        if decorations.showPageNumber {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            if footer.length > 0, !footer.string.hasSuffix("\n") { footer.append(NSAttributedString(string: "\n")) }
            footer.append(NSAttributedString(string: "\(number)", attributes: [
                .font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.black, .paragraphStyle: style,
            ]))
        }
        guard footer.length > 0 else { return }
        let h = ceil(footer.boundingRect(with: CGSize(width: width, height: 10_000), options: options).height)
        let y = min(bounds.height - h - 6, bounds.height - margins.bottom + 8)
        footer.draw(with: NSRect(x: margins.left, y: y, width: width, height: h + 2), options: options)
    }

    // 여백을 눌러도 가장 가까운 글자 자리로(워드처럼)
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(textView)
        textView.mouseDown(with: event)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .iBeam) }
}

/// 스크롤 뷰의 문서 뷰: 어두운 배경 + 종이 그림자. 종이(DocumentPaperView)들을 쪽 보기 방식에 맞춰 늘어놓는다
final class DocumentPagesView: NSView {
    static let backdropColor = NSColor(white: 0.16, alpha: 1)
    /// 쪽 사이 위아래 간격, 두 쪽 보기의 좌우 간격(문서 단위)
    static let rowGap: CGFloat = 22
    static let columnGap: CGFloat = 14

    var layout: DocumentPageLayout = .single

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    var papers: [DocumentPaperView] { subviews.compactMap { $0 as? DocumentPaperView } }

    override func draw(_ dirtyRect: NSRect) {
        Self.backdropColor.setFill()
        dirtyRect.fill()
        let near = dirtyRect.insetBy(dx: -40, dy: -40)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = 14
        shadow.shadowOffset = .zero
        shadow.set()
        NSColor.white.setFill()
        for paper in papers where paper.frame.intersects(near) { paper.frame.fill() }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 한 줄(쪽 하나 또는 두 쪽)의 폭
    static func rowWidth(pageWidth: CGFloat, layout: DocumentPageLayout, pageCount: Int) -> CGFloat {
        layout == .spread && pageCount > 1 ? pageWidth * 2 + columnGap : pageWidth
    }

    /// 종이들을 늘어놓는다. minWidth: 창 폭(문서 단위), gutter: 양옆 최소 여백
    func arrange(minWidth: CGFloat, gutter: CGFloat) {
        let papers = self.papers.sorted { $0.number < $1.number }
        guard let first = papers.first else { return }
        let pageWidth = first.frame.width
        let rowWidth = Self.rowWidth(pageWidth: pageWidth, layout: layout, pageCount: papers.count)
        let width = max(minWidth, rowWidth + 2 * gutter)
        let center = (width / 2).rounded()
        // 줄 나누기: 두 쪽 보기는 [1], [2, 3], [4, 5] … (1쪽은 표지처럼 오른쪽에 혼자)
        var rows: [[DocumentPaperView]] = []
        if layout == .spread, papers.count > 1 {
            rows.append([papers[0]])
            var i = 1
            while i < papers.count {
                rows.append(Array(papers[i..<min(i + 2, papers.count)]))
                i += 2
            }
        } else {
            rows = papers.map { [$0] }
        }
        var y: CGFloat = 0
        for (index, row) in rows.enumerated() {
            let height = row.map(\.frame.height).max() ?? 0
            for (k, paper) in row.enumerated() {
                let x: CGFloat
                if layout == .spread, papers.count > 1 {
                    let isRight = index == 0 || k == 1
                    x = isRight ? center + Self.columnGap / 2 : center - Self.columnGap / 2 - pageWidth
                } else {
                    x = ((width - paper.frame.width) / 2).rounded()
                }
                let origin = NSPoint(x: x, y: y)
                if paper.frame.origin != origin { paper.setFrameOrigin(origin) }   // 같으면 안 건드린다(알림이 돌고 돌지 않게)
            }
            y += height + Self.rowGap
        }
        let size = NSSize(width: width, height: max(y - Self.rowGap, 1))
        if frame.size != size { setFrameSize(size) }
        needsDisplay = true
    }
}

// MARK: - 쪽 나누는 일

/// 글 저장소·레이아웃 매니저·쪽들을 들고, 넘치면 쪽을 붙이고 남으면 떼고, 쪽 나눔·표 줄을 다음 쪽으로 보낸다.
/// 화면 없이도 돈다(테스트가 이것만 만들어 syncNow()로 쪽을 나눠 본다).
@MainActor
final class DocumentPager: NSObject, NSLayoutManagerDelegate {
    let storage = NSTextStorage()
    let layoutManager = NSLayoutManager()
    let rules = PageFlowRules()
    /// 스크롤 뷰에 들어갈 문서 뷰(종이들이 여기 붙는다)
    let documentView = DocumentPagesView(frame: NSRect(x: 0, y: 0, width: 595, height: 842))
    private(set) var pages: [DocumentPaperView] = []
    private(set) var layout: DocumentPageLayout = .single
    private(set) var pageSize = CGSize(width: 595, height: 842)
    private(set) var margins = NSEdgeInsets(top: 48, left: 48, bottom: 48, right: 48)

    /// 원본 문서의 머리글·꼬리글·쪽 번호(쪽마다 화면에만 그린다)
    var decorations = PageDecorations() { didSet { for paper in pages { paper.decorations = decorations } } }

    /// 쪽이 늘거나 줄거나 종이 크기가 바뀌었을 때(화면이 종이를 다시 늘어놓는다)
    var onPagesChanged: (() -> Void)?

    /// 이어 보기에서 쪽 나눔 띠 높이(문서 단위)
    nonisolated static let bandHeight: CGFloat = 22
    /// 한 번 맞출 때 표 줄 고치기·쪽 붙이기의 최대 횟수(리브레오피스처럼 레이아웃이 끝없이 돌지 않게)
    static let maxFixRounds = 400
    static let maxPages = 5000
    /// 표 머리줄 반복을 맞추려고 쪽을 다시 짜는 최대 횟수(머리줄 때문에 쪽 모양이 바뀌어 또 바뀌는 되풀이를 끊는다)
    static let maxHeaderPasses = 4
    /// 머리줄이 쪽 높이의 이 비율보다 크면 반복하지 않는다(쪽이 머리줄로 다 차 버리지 않게)
    static let maxHeaderShare: CGFloat = 0.4

    private var syncScheduled = false
    private var syncing = false
    /// 마지막으로 맞춘 뒤 글이 바뀐 가장 앞 자리
    private var dirtyFrom: Int?
    /// 쪽 나눔 표시 자리(앞에서부터). 글이 바뀌면 다시 센다
    private var markerCache: [Int]?
    private var observers: [NSObjectProtocol] = []

    var contentSize: CGSize {
        CGSize(width: max(72, pageSize.width - margins.left - margins.right),
               height: max(72, pageSize.height - margins.top - margins.bottom))
    }

    override init() {
        super.init()
        layoutManager.delegate = self
        layoutManager.allowsNonContiguousLayout = false
        storage.addLayoutManager(layoutManager)
        addPage()
        observers.append(NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.storageEdited() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification, object: nil, queue: nil) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let view = note.object as? PageTextView, view.pager === self else { return }
                DispatchQueue.main.async { [weak self] in self?.followSelection() }
            }
        })
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    // MARK: 문서 · 보기 바꾸기

    /// 쪽 크기·여백(문서를 올리기 전에)
    func setGeometry(pageSize: CGSize, margins: NSEdgeInsets) {
        self.pageSize = pageSize
        self.margins = margins
        for paper in pages { paper.repeatedHeader = nil }
        applyGeometry()
        invalidateAll()
    }

    /// 새 글을 올리고 처음부터 쪽을 나눈다
    func load(_ text: NSAttributedString) {
        while pages.count > 1 { removeLastPage() }
        rules.forbidden = [:]
        rules.moves = [:]
        rules.markerLines = [:]
        storage.setAttributedString(text)
        dirtyFrom = nil
        markerCache = nil
        syncNow()
    }

    func setLayout(_ newLayout: DocumentPageLayout) {
        guard newLayout != layout else { return }
        let changesPaging = newLayout.paginates != layout.paginates
        layout = newLayout
        documentView.layout = newLayout
        rules.paginates = newLayout.paginates
        if changesPaging {
            while pages.count > 1 { removeLastPage() }
            rules.forbidden = [:]
            rules.markerLines = [:]
            applyGeometry()
            invalidateAll()
        }
        syncNow()
    }

    /// 종이·글 상자·글 뷰 크기를 보기 방식에 맞춘다
    private func applyGeometry() {
        for paper in pages { geometry(of: paper) }
    }

    private func geometry(of paper: DocumentPaperView) {
        let content = contentSize
        let tv = paper.textView
        paper.bottomMargin = margins.bottom
        paper.margins = margins
        paper.decorations = decorations
        paper.showsNumber = layout.paginates
        if layout.paginates {
            // 표 머리줄을 다시 보여 주는 쪽은 그 높이만큼 글 상자를 줄이고 글 뷰를 내린다
            let headerHeight = paper.repeatedHeader?.height ?? 0
            let box = CGSize(width: content.width, height: max(36, content.height - headerHeight))
            tv.isVerticallyResizable = false
            tv.minSize = box
            tv.maxSize = box
            if tv.textContainer?.size != box { tv.textContainer?.size = box }
            tv.setFrameSize(box)
            paper.setFrameSize(pageSize)
            tv.setFrameOrigin(NSPoint(x: margins.left, y: margins.top + headerHeight))
            return
        } else {
            paper.repeatedHeader = nil
            // 이어 보기: 글 뷰가 글 길이만큼 늘어나고, 종이는 그걸 따라간다(짧아도 한 쪽 높이)
            tv.textContainer?.size = NSSize(width: content.width, height: 10_000_000)
            tv.minSize = content
            tv.maxSize = NSSize(width: content.width, height: 10_000_000)
            tv.isVerticallyResizable = true
            if tv.frame.width != content.width { tv.setFrameSize(NSSize(width: content.width, height: max(tv.frame.height, content.height))) }
            paper.setFrameSize(NSSize(width: pageSize.width, height: margins.top + max(tv.frame.height, content.height) + margins.bottom))
        }
        tv.setFrameOrigin(NSPoint(x: margins.left, y: margins.top))
    }

    private func invalidateAll() {
        guard storage.length > 0 else { return }
        layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
        for paper in pages { paper.textView.needsDisplay = true }
    }

    private func invalidate(from location: Int) {
        let start = min(max(0, location), storage.length)
        guard storage.length > start else { return }
        layoutManager.invalidateLayout(forCharacterRange: NSRange(location: start, length: storage.length - start), actualCharacterRange: nil)
    }

    // MARK: 쪽 붙이기 · 떼기

    @discardableResult
    private func addPage() -> DocumentPaperView {
        let index = pages.count
        let content = contentSize
        let container = PageTextContainer(size: layout.paginates ? content : NSSize(width: content.width, height: 10_000_000))
        container.pageIndex = index
        container.rules = rules
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        let tv = PageTextView(frame: NSRect(origin: .zero, size: content), textContainer: container)
        Self.configure(tv)
        tv.pager = self
        let paper = DocumentPaperView(textView: tv, number: index + 1)
        paper.headerSource = layoutManager
        pages.append(paper)
        geometry(of: paper)
        documentView.addSubview(paper)
        if index == 0 {
            // 이어 보기에서 글 뷰가 늘거나 줄면 종이도 따라간다
            tv.postsFrameChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: tv, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.textViewResized() }
            })
        }
        return paper
    }

    private func removeLastPage() {
        guard pages.count > 1 else { return }
        let paper = pages.removeLast()
        if let window = paper.window, window.firstResponder === paper.textView, let previous = pages.last?.textView {
            window.makeFirstResponder(previous)
        }
        if let container = paper.textView.textContainer,
           let i = layoutManager.textContainers.firstIndex(where: { $0 === container }) {
            layoutManager.removeTextContainer(at: i)
        }
        paper.removeFromSuperview()
    }

    private func textViewResized() {
        guard !layout.paginates, let paper = pages.first else { return }
        let height = margins.top + max(paper.textView.frame.height, contentSize.height) + margins.bottom
        guard abs(paper.frame.height - height) > 0.5 else { return }
        paper.setFrameSize(NSSize(width: pageSize.width, height: height))
        onPagesChanged?()
    }

    /// 쪽 글 뷰의 공통 설정(이전 한 장짜리 종이와 같은 값)
    static func configure(_ tv: NSTextView) {
        tv.isEditable = true
        tv.isSelectable = true
        tv.isRichText = true
        tv.allowsUndo = true
        tv.importsGraphics = true                            // 그림 붙여넣기·끌어 놓기
        tv.allowsImageEditing = false
        tv.isContinuousSpellCheckingEnabled = false          // 남의 문서에 빨간 밑줄이 가득하지 않게
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.insertionPointColor = .black
        tv.drawsBackground = true
        tv.backgroundColor = .white
        tv.appearance = NSAppearance(named: .aqua)          // 창은 어두워도 종이 위 글은 늘 검게
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = false
        tv.autoresizingMask = []
        tv.textContainerInset = .zero
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
    }

    // MARK: 맞추기

    /// 글이 바뀌었을 때(저장소 알림): 표 줄 표시 자리를 바뀐 만큼 밀고, 조금 뒤에 쪽을 다시 맞춘다
    private func storageEdited() {
        let edited = storage.editedRange
        guard edited.location != NSNotFound else { return }
        if storage.editedMask.contains(.editedCharacters) {
            let delta = storage.changeInLength
            let oldEnd = edited.location + edited.length - delta
            var moved: [Int: Int] = [:]
            for (key, page) in rules.forbidden {
                if key < edited.location { moved[key] = page }
                else if key >= oldEnd { moved[key + delta] = page }
            }
            rules.forbidden = moved
            rules.markerLines = rules.markerLines.filter { $0.key < edited.location }
            markerCache = nil
        }
        dirtyFrom = min(dirtyFrom ?? edited.location, edited.location)
        scheduleSync()
    }

    /// 조금 뒤에 한 번(여러 번 불려도 한 번만)
    func scheduleSync() {
        guard !syncScheduled, !syncing else { return }
        syncScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.syncScheduled else { return }
                self.syncNow()
            }
        }
    }

    /// 아직 맞추지 않은 고침이 있으면 지금 맞춘다(스크롤·찾기 전에)
    func syncIfNeeded() {
        if syncScheduled || dirtyFrom != nil { syncNow() }
    }

    /// 지금 끝까지 짜서 쪽 수를 맞춘다: 넘치면 붙이고 → 쪽 끝에 잘린 표 줄을 다음 쪽으로 → 남은 빈 쪽을 뗀다
    func syncNow() {
        guard !syncing else { return }
        syncing = true
        syncScheduled = false
        rules.resetRefusals()
        defer { syncing = false }
        guard layout.paginates else {
            dirtyFrom = nil
            if let tv = pages.first?.textView, let container = tv.textContainer {
                layoutManager.ensureLayout(for: container)
                tv.sizeToFit()
            }
            textViewResized()
            onPagesChanged?()
            return
        }
        // 바뀐 자리 뒤의 "이 쪽은 안 돼" 표시는 다시 따져 본다(글이 줄었으면 이제 들어갈 수 있다)
        var scanFrom = 0
        if let from = dirtyFrom {
            dirtyFrom = nil
            let stale = rules.forbidden.keys.filter { $0 >= from }
            if let first = stale.min() {
                for key in stale { rules.forbidden[key] = nil }
                invalidate(from: first)
            }
            scanFrom = tableScanStart(near: from)
        }
        var rounds = 0
        var headerPasses = 0
        // 한 번 맞추기에 쓰는 시간 상한(레이아웃이 수렴하지 않아도 화면이 멈추지 않게)
        let deadline = Date().addingTimeInterval(1.5)
        while true {
            while true {
                fillPages(until: deadline)
                rounds += 1
                guard rounds <= Self.maxFixRounds, Date() < deadline, let fix = firstClippedRow(from: scanFrom) else { break }
                // 이미 넘기려다 못 넘긴 줄이거나 2번 넘게 옮긴 줄이면 그대로 둔다(잘린 채로)
                let moved = rules.moves[fix.location] ?? 0
                if rules.forbidden[fix.location] == fix.page || moved >= 2 { break }
                rules.moves[fix.location] = moved + 1
                rules.forbidden[fix.location] = fix.page
                invalidate(from: fix.location)
                scanFrom = fix.location
            }
            // 표가 쪽을 넘어 이어지는 쪽 위에 머리줄을 다시 보인다. 쪽 상자가 줄면 글이 다시 흐르므로 한 번 더(최대 몇 번만)
            headerPasses += 1
            guard headerPasses <= Self.maxHeaderPasses, Date() < deadline, let changed = updateRepeatedHeaders() else { break }
            for key in rules.forbidden.keys where key >= changed { rules.forbidden[key] = nil }
            scanFrom = min(scanFrom, tableScanStart(near: changed))
        }
        trimPages()
        onPagesChanged?()
    }

    /// 마지막 쪽까지 짜 보고, 다 안 들어갔으면 쪽을 붙인다(빈 쪽에도 안 들어가는 게 있으면 멈춘다)
    private func fillPages(until deadline: Date = .distantFuture) {
        var count = 0
        // 쪽 수 상한: 글 길이에 비례(글자 20개에 한 쪽보다 많을 수는 없다)
        let limit = min(Self.maxPages, storage.length / 20 + 20)
        while count < Self.maxPages, pages.count < limit, Date() < deadline {
            count += 1
            guard let last = layoutManager.textContainers.last else { return }
            layoutManager.ensureLayout(for: last)
            let range = layoutManager.glyphRange(for: last)
            guard NSMaxRange(range) < layoutManager.numberOfGlyphs else { return }
            if range.length == 0, pages.count > 1 { return }
            addPage()
        }
    }

    /// 뒤에서부터 글이 없는 쪽을 뗀다(글 끝 빈 줄이 놓인 쪽은 남긴다)
    private func trimPages() {
        while pages.count > 1, let last = pages.last?.textView.textContainer {
            let range = layoutManager.glyphRange(for: last)
            guard range.length == 0, layoutManager.extraLineFragmentTextContainer !== last else { return }
            removeLastPage()
        }
    }

    /// 바뀐 자리가 표 안이면 그 표의 처음부터 다시 본다(앞쪽 줄이 쪽 끝에 걸릴 수도 있어서)
    private func tableScanStart(near location: Int) -> Int {
        var start = min(location, storage.length)
        if start > 0, start == storage.length { start -= 1 }
        guard start < storage.length,
              let block = (storage.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock
        else { return (storage.string as NSString).paragraphRange(for: NSRange(location: start, length: 0)).location }
        return storage.range(of: block.table, at: start).location
    }

    // MARK: 표 줄

    /// 표 줄이 쪽 끝을 이만큼까지 넘는 건 잘린 것으로 보지 않는다(칸 테두리·안쪽 여백 몫)
    static let rowSlack: CGFloat = 6

    struct RowFix: Equatable {
        /// 줄 첫 칸의 첫 글자
        let location: Int
        /// 그 줄이 들어가면 안 되는 쪽(0부터)
        let page: Int
    }

    private struct RowProbe {
        var table: ObjectIdentifier
        var row: Int
        var location: Int
        var pages: Set<Int> = []
        var firstPage = Int.max
        var top = CGFloat.greatestFiniteMagnitude
        var bottom: CGFloat = 0
        var limit: CGFloat = 0
    }

    /// from 뒤에서 쪽 끝에 걸려 잘리는 첫 표 줄. 그 줄을 통째로 다음 쪽으로 보내면 되는 경우만 돌려준다
    func firstClippedRow(from: Int) -> RowFix? {
        let length = storage.length
        var location = max(0, min(from, length))
        var current: RowProbe?
        var previous: RowProbe?

        func verdict(_ row: RowProbe, before: RowProbe?) -> RowFix? {
            guard row.firstPage != Int.max else { return nil }
            // 칸 아래 테두리·안쪽 여백만 쪽 끝을 조금 넘는 건 둔다(글은 다 보인다). 그런 줄까지 억지로 넘기면
            // AppKit 레이아웃 매니저가 같은 자리를 끝없이 다시 짜는 일이 있었다(헤드리스 테스트에서 확인)
            let clipped = row.pages.count > 1 || row.bottom > row.limit + Self.rowSlack
            // 쪽 맨 위에서 시작한 줄은 밀어도 소용없다(한 쪽보다 큰 줄 — 잘린 채로 둔다).
            // 한 쪽보다 큰 칸의 아래쪽 줄은 TextKit이 높이 0으로 접어 버린다. 그 줄들을 다음 쪽으로 보내 보려고 줄 자리를 거절해 봤더니
            // 레이아웃 매니저가 ensureLayout 안에서 끝없이 도는 것을 확인했다(상한을 걸 수 없는 안쪽 루프) → 일부러 시도하지 않는다
            guard clipped, row.top > 0.5 else { return nil }
            if row.pages.count == 1, row.bottom - row.top > row.limit { return nil }
            // 머리줄(첫 줄)만 쪽 끝에 홀로 남지 않게: 둘째 줄이 넘어가면 머리줄째 넘긴다
            if row.row == 1, let header = before, header.table == row.table, header.row == 0,
               header.pages == [row.firstPage], header.top > 0.5 {
                return RowFix(location: header.location, page: header.firstPage)
            }
            return RowFix(location: row.location, page: row.firstPage)
        }

        while location < length {
            var effective = NSRange()
            let style = storage.attribute(.paragraphStyle, at: location, effectiveRange: &effective) as? NSParagraphStyle
            guard let cell = style?.textBlocks.first as? NSTextTableBlock else {
                if let row = current {
                    if let fix = verdict(row, before: previous) { return fix }
                    previous = row
                    current = nil
                }
                location = max(NSMaxRange(effective), location + 1)
                continue
            }
            let cellRange = storage.range(of: cell, at: location)
            let key = ObjectIdentifier(cell.table)
            if current == nil || current?.table != key || current?.row != cell.startingRow {
                if let row = current {
                    if let fix = verdict(row, before: previous) { return fix }
                    previous = row
                }
                current = RowProbe(table: key, row: cell.startingRow, location: cellRange.location)
            }
            let glyphs = layoutManager.glyphRange(forCharacterRange: cellRange, actualCharacterRange: nil)
            if glyphs.length > 0,
               let head = layoutManager.textContainer(forGlyphAt: glyphs.location, effectiveRange: nil, withoutAdditionalLayout: true) as? PageTextContainer,
               let tail = layoutManager.textContainer(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil, withoutAdditionalLayout: true) as? PageTextContainer {
                let bounds = layoutManager.boundsRect(for: cell, glyphRange: glyphs)
                if var row = current {
                    row.pages.insert(head.pageIndex)
                    row.pages.insert(tail.pageIndex)
                    // 줄 위·아래는 줄이 시작한 쪽의 칸들로만 잰다(다른 쪽 좌표와 섞지 않게)
                    if head.pageIndex < row.firstPage {
                        row.firstPage = head.pageIndex
                        row.top = bounds.minY
                        row.bottom = bounds.maxY
                        row.limit = head.size.height
                    } else if head.pageIndex == row.firstPage {
                        row.top = min(row.top, bounds.minY)
                        row.bottom = max(row.bottom, bounds.maxY)
                    }
                    current = row
                }
            }
            location = max(NSMaxRange(cellRange), location + 1)
        }
        if let row = current { return verdict(row, before: previous) }
        return nil
    }

    // MARK: 표 머리줄 반복

    /// 쪽마다 머리줄 반복이 필요한지 다시 따져서 바뀐 쪽에 적용한다. 바뀐 게 없으면 nil,
    /// 있으면 글 상자 크기가 바뀐 가장 앞 글자 자리(다시 짜야 할 시작점)
    private func updateRepeatedHeaders() -> Int? {
        var earliest: Int?
        for (index, paper) in pages.enumerated() {
            let plan = index > 0 ? repeatedHeader(forPage: index) : nil
            guard plan != paper.repeatedHeader else { continue }
            let heightChanged = abs((plan?.height ?? 0) - (paper.repeatedHeader?.height ?? 0)) > 0.01
            paper.repeatedHeader = plan
            guard heightChanged, let container = paper.textView.textContainer else { continue }
            let glyphs = layoutManager.glyphRange(for: container)
            let first = glyphs.length > 0 ? layoutManager.characterIndexForGlyph(at: glyphs.location) : storage.length
            geometry(of: paper)
            invalidate(from: first)
            earliest = min(earliest ?? first, first)
        }
        return earliest
    }

    /// 이 쪽이 앞 쪽에서 시작한 표의 가운데(머리줄 아래)에서 시작하면, 그 표의 머리줄. 아니면 nil
    private func repeatedHeader(forPage index: Int) -> RepeatedTableHeader? {
        guard layout.paginates, index > 0, index < pages.count, let container = pages[index].textView.textContainer else { return nil }
        let glyphs = layoutManager.glyphRange(for: container)
        guard glyphs.length > 0 else { return nil }
        let first = layoutManager.characterIndexForGlyph(at: glyphs.location)
        guard first < storage.length,
              let start = (storage.attribute(.paragraphStyle, at: first, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock,
              start.startingRow > 0 else { return nil }
        let table = storage.range(of: start.table, at: first)
        guard table.length > 0, table.location < first else { return nil }

        // 표 맨 위에서부터 칸이 모두 배경색인 줄들 = 머리줄(원본을 읽을 때와 같은 기준)
        var headerCells: [(range: NSRange, row: Int)] = []
        var group: [(range: NSRange, row: Int)] = []
        var groupShaded = true
        var headerRows = 0
        var location = table.location
        var steps = 0
        func closeGroup() -> Bool {
            guard !group.isEmpty, groupShaded else { return false }
            headerCells += group
            headerRows += 1
            return true
        }
        scan: while location < NSMaxRange(table), steps < 10_000 {
            steps += 1
            var effective = NSRange()
            guard let cell = (storage.attribute(.paragraphStyle, at: location, effectiveRange: &effective) as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock,
                  cell.table === start.table else { break }
            let range = storage.range(of: cell, at: location)
            if let current = group.first, current.row != cell.startingRow {
                guard closeGroup() else { group = []; break scan }
                group = []
                groupShaded = true
                // 지금 쪽 첫 줄 아래까지 머리줄이 이어지면(쪽이 머리줄 안에서 시작) 반복하지 않는다
                if cell.startingRow >= start.startingRow { break scan }
            }
            if cell.backgroundColor == nil { groupShaded = false }
            group.append((range, cell.startingRow))
            location = max(NSMaxRange(range), location + 1)
        }
        guard headerRows > 0, headerRows <= start.startingRow, let firstCell = headerCells.first, let lastCell = headerCells.last else { return nil }

        // 머리줄 칸들이 한 쪽 안에 있어야 한다(그 쪽의 글 상자 좌표로 높이를 잰다)
        var pageOfHeader: Int?
        var top = CGFloat.greatestFiniteMagnitude
        var bottom: CGFloat = 0
        for item in headerCells {
            guard let block = storage.attribute(.paragraphStyle, at: item.range.location, effectiveRange: nil).flatMap({ ($0 as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock }) else { return nil }
            let cellGlyphs = layoutManager.glyphRange(forCharacterRange: item.range, actualCharacterRange: nil)
            guard cellGlyphs.length > 0,
                  let head = layoutManager.textContainer(forGlyphAt: cellGlyphs.location, effectiveRange: nil, withoutAdditionalLayout: true) as? PageTextContainer,
                  let tail = layoutManager.textContainer(forGlyphAt: NSMaxRange(cellGlyphs) - 1, effectiveRange: nil, withoutAdditionalLayout: true) as? PageTextContainer,
                  head.pageIndex == tail.pageIndex, head.pageIndex < index, pageOfHeader == nil || pageOfHeader == head.pageIndex else { return nil }
            pageOfHeader = head.pageIndex
            let rect = layoutManager.boundsRect(for: block, glyphRange: cellGlyphs)
            top = min(top, rect.minY)
            bottom = max(bottom, rect.maxY)
        }
        let height = ceil(bottom - top)
        guard height > 1, height <= contentSize.height * Self.maxHeaderShare else { return nil }
        let all = NSRange(location: firstCell.range.location, length: NSMaxRange(lastCell.range) - firstCell.range.location)
        return RepeatedTableHeader(glyphs: layoutManager.glyphRange(forCharacterRange: all, actualCharacterRange: nil), top: top, height: height)
    }

    // MARK: 글 짜기 길목(NSLayoutManagerDelegate)

    nonisolated func layoutManager(_ layoutManager: NSLayoutManager, didCompleteLayoutFor textContainer: NSTextContainer?, atEnd layoutFinishedFlag: Bool) {
        MainActor.assumeIsolated {
            guard !syncing, layout.paginates else { return }
            let last = layoutManager.textContainers.last
            // 넘쳤거나(마지막 쪽까지 찼는데 남음) 다 짰는데 뒤에 빈 쪽이 남았으면 다시 맞춘다
            if textContainer == nil || (!layoutFinishedFlag && textContainer === last) || (layoutFinishedFlag && textContainer !== last) {
                scheduleSync()
            }
        }
    }

    /// 쪽 나눔 표시 줄: 쪽 보기에서는 어느 쪽 어디에 놓였는지 적어 두고(뒤 문단을 밀지 정할 때),
    /// 이어 보기에서는 띠 높이로 늘린다
    nonisolated func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                                   lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                                   in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        guard let storage = layoutManager.textStorage, glyphRange.length > 0,
              let page = textContainer as? PageTextContainer, let rules = page.rules else { return false }
        let first = layoutManager.characterIndexForGlyph(at: glyphRange.location)
        guard first < storage.length, storage.attribute(.hanlabongPageBreak, at: first, effectiveRange: nil) != nil else { return false }
        let last = min(layoutManager.characterIndexForGlyph(at: NSMaxRange(glyphRange) - 1), storage.length - 1)
        if rules.paginates {
            rules.markerLines[last] = (page.pageIndex, lineFragmentRect.pointee.minY)
            return false
        }
        let extra = Self.bandHeight - lineFragmentRect.pointee.height
        guard extra > 0 else { return false }
        lineFragmentRect.pointee.size.height = Self.bandHeight
        lineFragmentUsedRect.pointee.size.height = Self.bandHeight
        baselineOffset.pointee += extra / 2
        return true
    }

    // MARK: 이어 보기의 쪽 나눔 띠

    /// 쪽 나눔 표시 자리들(앞에서부터)
    private var markerLocations: [Int] {
        if let markerCache { return markerCache }
        let found = DocumentEditor.bandRanges(in: storage).map(\.location)
        markerCache = found
        return found
    }

    func drawBands(in rect: NSRect, of view: PageTextView) {
        guard !layout.paginates, let container = view.textContainer, storage.length > 0 else { return }
        let glyphs = layoutManager.glyphRange(forBoundingRectWithoutAdditionalLayout: rect, in: container)
        guard glyphs.length > 0 else { return }
        let chars = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let locations = markerLocations
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .medium), .foregroundColor: NSColor(white: 0.5, alpha: 1),
        ]
        storage.enumerateAttribute(.hanlabongPageBreak, in: chars) { value, range, _ in
            guard value != nil else { return }
            let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: range.location, length: 0))
            let glyph = layoutManager.glyphIndexForCharacter(at: paragraph.location)
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
            guard line.height > 4 else { return }
            let band = NSRect(x: 0, y: line.minY + 3 + view.textContainerOrigin.y, width: view.bounds.width, height: line.height - 6)
            NSColor(white: 0.92, alpha: 1).setFill()
            band.fill()
            let ordinal = locations.firstIndex(of: paragraph.location) ?? locations.filter { $0 < paragraph.location }.count
            let label = DocumentLoader.pageLabel(ordinal + 2) as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: band.midX - size.width / 2, y: band.midY - size.height / 2), withAttributes: attributes)
        }
    }

    // MARK: 찾기 · 자리

    /// 그 글자가 놓인 종이(글 끝이면 마지막 빈 줄이 놓인 종이)
    func paper(containing location: Int) -> DocumentPaperView? {
        guard !pages.isEmpty else { return nil }
        let length = storage.length
        guard length > 0, layoutManager.numberOfGlyphs > 0 else { return pages[0] }
        let container: NSTextContainer?
        if location >= length {
            layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: length))
            container = layoutManager.extraLineFragmentTextContainer
                ?? layoutManager.textContainer(forGlyphAt: layoutManager.numberOfGlyphs - 1, effectiveRange: nil)
        } else {
            container = layoutManager.textContainer(forGlyphAt: layoutManager.glyphIndexForCharacter(at: max(0, location)), effectiveRange: nil)
        }
        return pages.first { $0.textView.textContainer === container } ?? pages.last
    }

    /// 그 글자의 자리(종이 좌표)
    func rect(forCharacter location: Int) -> (paper: DocumentPaperView, rect: NSRect)? {
        let length = storage.length
        guard let paper = paper(containing: location), let container = paper.textView.textContainer else { return nil }
        var rect: NSRect
        if length == 0 || location >= length {
            rect = layoutManager.extraLineFragmentRect.isEmpty
                ? layoutManager.boundingRect(forGlyphRange: NSRange(location: max(0, layoutManager.numberOfGlyphs - 1), length: min(1, layoutManager.numberOfGlyphs)), in: container)
                : layoutManager.extraLineFragmentRect
        } else {
            let glyph = layoutManager.glyphIndexForCharacter(at: location)
            rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        }
        rect.origin.x += paper.textView.frame.minX + paper.textView.textContainerOrigin.x
        rect.origin.y += paper.textView.frame.minY + paper.textView.textContainerOrigin.y
        return (paper, rect)
    }

    /// 지금 화면에 보이는 글자 자리(여러 쪽에 걸치면 합친다). 화면에 안 붙었으면 nil
    func visibleCharacterRange() -> NSRange? {
        let visible = documentView.visibleRect
        guard visible.width > 0, visible.height > 0 else { return nil }
        var union: NSRange?
        for paper in pages where paper.frame.intersects(visible) {
            let tv = paper.textView
            guard let container = tv.textContainer else { continue }
            let local = tv.convert(visible, from: documentView).intersection(tv.bounds)
            guard !local.isEmpty else { continue }
            let glyphs = layoutManager.glyphRange(forBoundingRectWithoutAdditionalLayout: local, in: container)
            guard glyphs.length > 0 else { continue }
            let chars = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            union = union.map { NSUnionRange($0, chars) } ?? chars
        }
        return union
    }

    /// 지금 보는 쪽(1부터): 화면 위쪽 3분의 1 높이에 걸린 종이. 두 쪽 보기면 그 줄의 앞 쪽
    func currentPage() -> Int {
        let visible = documentView.visibleRect
        guard !pages.isEmpty else { return 1 }
        guard visible.height > 0 else { return 1 }
        let probe = visible.minY + visible.height * 0.3
        let hits = pages.filter { $0.frame.minY <= probe && $0.frame.maxY >= probe }
        if let first = hits.min(by: { $0.number < $1.number }) { return first.number }
        let nearest = pages.min { distance($0.frame, probe) < distance($1.frame, probe) }
        return nearest?.number ?? 1
    }

    private func distance(_ frame: NSRect, _ y: CGFloat) -> CGFloat { y < frame.minY ? frame.minY - y : max(0, y - frame.maxY) }

    /// 커서가 다른 쪽으로 넘어가면 그 쪽의 글 뷰가 입력을 받게(커서가 보이게). 끌어서 고르는 중에는 그대로
    private func followSelection() {
        guard let first = pages.first?.textView, let window = first.window,
              let responder = window.firstResponder as? PageTextView, responder.pager === self else { return }
        let selection = first.selectedRange()
        guard selection.length == 0, let target = paper(containing: selection.location)?.textView, target !== responder else { return }
        window.makeFirstResponder(target)
    }
}
