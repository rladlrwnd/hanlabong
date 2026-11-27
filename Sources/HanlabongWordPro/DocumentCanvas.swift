import AppKit
import SwiftUI

/// 문서 영역의 쪽 화면(4단계): 어두운 배경 위에 쪽 크기(pageSize·margins) 그대로의 흰 종이들이 쌓인다(쪽 사이 간격, 그림자).
/// - 글 짜기·쪽 나누기는 DocumentPager가 한다(글 저장소 하나 + 쪽마다 글 상자·텍스트 뷰). 이 화면은 스크롤·확대·종이 늘어놓기·쪽 위치 알리기를 맡는다.
/// - 보기 방식: 한 쪽씩 / 두 쪽씩(1쪽은 오른쪽에 혼자, 책처럼) / 이어 보기(종이 한 장이 길게, 쪽 나눔은 회색 띠)
/// - 창 폭에 맞춰 확대해 두고(직접 확대·축소하면 풀린다), 창 크기가 바뀌면 다시 맞춘다. 트랙패드 확대도 된다.
/// - ⌘F 찾기는 NSTextView 기본 찾기 막대를 쓴다(여러 쪽 뷰에 걸쳐 찾는다).
/// - 2단계: 종이에서 바로 고친다(서식 있는 글, 그림 붙여넣기, ⌘Z). 고치는 일·쪽 나눔 보호는 세션의 DocumentEditor가 맡는다.
struct DocumentCanvas: NSViewRepresentable {
    @ObservedObject var session: DocumentSession

    @MainActor final class Coordinator: NSObject {
        var session: DocumentSession?
        weak var scroll: NSScrollView?
        /// 글과 쪽들
        let pager = DocumentPager()
        /// 1쪽 텍스트 뷰(늘 있다. 편집기가 이걸 붙잡는다)
        var textView: NSTextView? { pager.pages.first?.textView }
        /// 종이들이 놓인 어두운 배경(스크롤 뷰의 문서 뷰)
        var backdrop: DocumentPagesView? { pager.documentView }
        /// 지금 보여 주는 문서·보기(세션 없이도 화면이 맞춰지게 따로 들고 있다)
        var shownDocument: LoadedDocument?
        var shownID: UUID?
        var lastCommand: UUID?
        var fitsWidth = true
        var shownMode: DocumentSession.Mode?
        private var observers: [NSObjectProtocol] = []
        private var lastPosition: DocumentPagePosition?

        override init() {
            super.init()
            pager.onPagesChanged = { [weak self] in self?.layoutPaper() }
        }

        deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

        func observe(_ scroll: NSScrollView) {
            scroll.postsFrameChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refit() }
            })
            // 손가락으로 확대·축소하면 "창에 맞추기"가 풀린다
            observers.append(NotificationCenter.default.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: scroll, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.fitsWidth = false; self?.layoutPaper() }
            })
            // 스크롤하면 상태 막대의 "지금 쪽"을 바꾼다
            scroll.contentView.postsBoundsChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.publishPosition() }
            })
        }

        // MARK: 문서 · 보기 바꾸기

        func show(_ document: LoadedDocument?, mode: DocumentSession.Mode) {
            guard let scroll else { return }
            if shownMode != mode {
                shownMode = mode
                // 종이가 창 맨 위까지 이어지게 위 여백은 스크롤 뷰 여백으로 둔다(간단히 보기는 신호등 단추 밑에서 종이가 시작).
                // 간단히 보기는 아래 AI 요청칸이 떠 있어서 끝 글이 안 가려지게 아래를 넓게 비운다
                scroll.contentInsets = NSEdgeInsets(top: mode == .simple ? Self.simpleTopGap : 20, left: 0, bottom: mode == .simple ? 130 : 28, right: 0)
                refit()
            }
            guard document?.id != shownID else { return }
            shownID = document?.id
            shownDocument = document
            guard let document else {
                pager.decorations = PageDecorations()
                pager.load(NSAttributedString())
                layoutPaper()
                return
            }
            pager.setGeometry(pageSize: document.pageSize, margins: document.margins)
            pager.decorations = PageDecorations(header: document.header, footer: document.footer, showPageNumber: document.showPageNumber)
            pager.load(document.attributed)
            textView?.setSelectedRange(NSRange(location: 0, length: 0))
            session?.editor.documentLoaded(pageSize: document.pageSize, margins: document.margins)
            fitsWidth = true
            refit()
            scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x, y: -scroll.contentInsets.top))
            scroll.reflectScrolledClipView(scroll.contentView)
            publishPosition()
        }

        /// 쪽 보기 방식 바꾸기. 보던 글자 자리를 지켜서 바꾼 뒤에도 같은 곳을 보여 준다
        func apply(layout: DocumentPageLayout) {
            guard pager.layout != layout else { return }
            let anchor = shownDocument == nil ? nil : pager.visibleCharacterRange()?.location
            pager.setLayout(layout)
            refit()
            if let anchor { scroll(toCharacter: anchor, length: 0, animated: false, indicate: false) }
        }

        /// 간단히 보기에서 종이 위쪽이 신호등 단추 밑에서 시작하는 높이(화면 포인트)
        static let simpleTopGap: CGFloat = 40
        /// 창 양옆에 남길 어두운 배경의 최소 너비(화면 포인트). 간단히 보기는 오른쪽 유리 기둥에 안 겹치게 더 비운다
        static func sideGap(for mode: DocumentSession.Mode?) -> CGFloat { mode == .simple ? 76 : 28 }

        // MARK: 종이 배치

        /// 창 폭에 쪽 폭이 맞게 하는 확대 배율: (창 폭 − 양옆 여백 × 2) / 쪽 폭(두 쪽 보기면 두 쪽 + 사이 간격)
        static func fitMagnification(viewportWidth: CGFloat, pageWidth: CGFloat, side: CGFloat) -> CGFloat? {
            let available = viewportWidth - 2 * side
            guard available > 50, pageWidth > 0 else { return nil }
            return min(max(available / pageWidth, 0.4), 2.5)
        }

        /// 한 줄 폭(문서 단위)
        private var rowWidth: CGFloat {
            DocumentPagesView.rowWidth(pageWidth: pager.pageSize.width, layout: pager.layout, pageCount: pager.pages.count)
        }

        /// 배경(문서 뷰)을 창 폭 이상으로 넓히고 종이들을 늘어놓는다. 확대·창 크기·쪽 수가 바뀔 때마다 부른다
        func layoutPaper() {
            guard let scroll else { return }
            let mag = max(scroll.magnification, 0.01)
            let viewport = scroll.contentSize.width / mag               // 창 폭을 문서 단위로
            let gutter = Self.sideGap(for: shownMode) / mag * 0.5       // 좁아져도 종이 양옆엔 최소 반쪽 여백(가로 스크롤)
            pager.documentView.arrange(minWidth: viewport, gutter: gutter)
            publishPosition()
        }

        /// 상태 막대의 "지금 쪽 / 전체 쪽". 화면을 그리는 중에 SwiftUI 값을 바꾸지 않게 한 박자 늦게 알린다
        func publishPosition() {
            let position = DocumentPagePosition(current: pager.currentPage(), total: pager.pages.count)
            guard position != lastPosition else { return }
            lastPosition = position
            DispatchQueue.main.async { [weak self] in self?.session?.setPagePosition(position) }
        }

        // MARK: 확대·축소

        /// 창 폭에 쪽 폭(두 쪽 보기면 두 쪽)이 맞게(양옆에 어두운 배경이 최소 sideGap만큼 보이게)
        func refit() {
            if fitsWidth, let scroll, shownDocument != nil || session?.document != nil,
               let mag = Self.fitMagnification(viewportWidth: scroll.contentSize.width, pageWidth: rowWidth, side: Self.sideGap(for: shownMode)) {
                scroll.magnification = mag
            }
            layoutPaper()
        }

        func zoom(by factor: CGFloat) {
            guard let scroll else { return }
            fitsWidth = false
            scroll.magnification = min(max(scroll.magnification * factor, 0.4), 4)
            layoutPaper()
        }

        // MARK: 시킨 일

        func run(_ kind: CanvasCommand.Kind) {
            switch kind {
            case .zoomIn: zoom(by: 1.18)
            case .zoomOut: zoom(by: 1 / 1.18)
            case .fit: fitsWidth = true; refit()
            case .actualSize: fitsWidth = false; scroll?.magnification = 1; layoutPaper()
            case .find: showFind()
            case .scroll(let location, let length): scroll(toCharacter: location, length: length)
            }
        }

        /// 찾기 막대: 커서가 있는 쪽의 뷰에서 연다(NSTextView 찾기는 여러 쪽 뷰에 걸쳐 찾는다)
        func showFind() {
            guard let first = textView else { return }
            let tv = pager.paper(containing: first.selectedRange().location)?.textView ?? first
            tv.window?.makeFirstResponder(tv)
            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.showFindInterface.rawValue
            tv.performTextFinderAction(item)
        }

        /// 그 글자가 있는 줄이 화면 위쪽에 오게 부드럽게 내려가고(그 글자가 있는 쪽으로), 그 글자를 잠깐 반짝여 보여 준다
        func scroll(toCharacter location: Int, length: Int, animated: Bool = true, indicate: Bool = true) {
            guard let scroll else { return }
            let total = pager.storage.length
            guard total > 0, location < total else { return }
            pager.syncIfNeeded()            // 방금 고친 글이 아직 쪽에 안 나뉘었으면 먼저
            guard let (paper, rect) = pager.rect(forCharacter: location) else { return }
            let inDocument = paper.convert(rect, to: pager.documentView)
            let clip = scroll.contentView
            let wanted = inDocument.minY - 26
            let target = clip.constrainBoundsRect(NSRect(origin: NSPoint(x: clip.bounds.origin.x, y: wanted), size: clip.bounds.size)).origin.y
            let range = NSRange(location: location, length: max(1, min(length, total - location)))
            guard animated else {
                clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: target))
                scroll.reflectScrolledClipView(clip)
                if indicate { paper.textView.showFindIndicator(for: range) }
                publishPosition()
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                context.allowsImplicitAnimation = true
                clip.animator().setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: target))
            } completionHandler: {
                scroll.reflectScrolledClipView(clip)
                if indicate { paper.textView.showFindIndicator(for: range) }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        Self.build(coordinator: context.coordinator, session: session)
    }

    /// 스크롤 뷰·배경·종이를 만들어 Coordinator에 이어 준다(화면 없이 레이아웃을 점검하는 테스트도 이걸 쓴다)
    @MainActor static func build(coordinator: Coordinator, session: DocumentSession?) -> NSScrollView {
        let backdrop = DocumentPagesView.backdropColor
        let scroll = NSScrollView()
        let clip = CenteringClipView()
        clip.drawsBackground = true
        clip.backgroundColor = backdrop
        scroll.contentView = clip
        scroll.drawsBackground = true
        scroll.backgroundColor = backdrop
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.4
        scroll.maxMagnification = 4
        scroll.automaticallyAdjustsContentInsets = false
        scroll.findBarPosition = .aboveContent
        scroll.documentView = coordinator.pager.documentView

        coordinator.scroll = scroll
        coordinator.session = session
        if let session {
            coordinator.pager.setLayout(session.pageLayout)
            if let tv = coordinator.textView { session.editor.attach(tv) }
            session.editor.pager = coordinator.pager
        }
        coordinator.lastCommand = session?.command?.id       // 화면이 새로 만들어질 때 옛 명령을 다시 하지 않게
        coordinator.observe(scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.session = session
        coordinator.apply(layout: session.pageLayout)
        coordinator.show(session.document, mode: session.mode)
        if let command = session.command, command.id != coordinator.lastCommand {
            coordinator.lastCommand = command.id
            coordinator.run(command.kind)
        }
    }
}

/// 문서가 창보다 좁을 때(축소했을 때) 가운데에 오게 하는 클립 뷰
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        if let document = documentView, rect.width > document.frame.width {
            rect.origin.x = (document.frame.width - rect.width) / 2
        }
        return rect
    }
}
