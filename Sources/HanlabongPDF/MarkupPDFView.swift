import AppCore
import AppKit
import PDFKit
import SkillEngine

/// 표시 도구(미리보기 앱의 마크업 막대와 같은 묶음 + 가리기)
enum MarkupTool: String, CaseIterable, Identifiable {
    case select, highlight, underline, strike, pen, rect, oval, line, arrow, text, note, signature, redact
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .highlight: return "highlighter"
        case .underline: return "underline"
        case .strike: return "strikethrough"
        case .pen: return "scribble"
        case .rect: return "rectangle"
        case .oval: return "circle"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .text: return "character.textbox"
        case .note: return "note.text"
        case .signature: return "signature"
        case .redact: return "rectangle.inset.filled"
        }
    }

    var title: String {
        switch self {
        case .select: return L("고르기·옮기기", "Select & move")
        case .highlight: return L("형광펜", "Highlight")
        case .underline: return L("밑줄", "Underline")
        case .strike: return L("취소선", "Strikethrough")
        case .pen: return L("펜", "Pen")
        case .rect: return L("네모", "Rectangle")
        case .oval: return L("동그라미", "Oval")
        case .line: return L("선", "Line")
        case .arrow: return L("화살표", "Arrow")
        case .text: return L("글자", "Text")
        case .note: return L("메모", "Note")
        case .signature: return L("서명", "Signature")
        case .redact: return L("가리기(진짜 지우기)", "Redact")
        }
    }

    /// 글자를 골라서 쓰는 도구(형광펜·밑줄·취소선): 고르는 건 PDF 화면이 하고, 손을 떼면 표시를 붙인다
    var marksText: Bool { self == .highlight || self == .underline || self == .strike }
}

/// 가리기 표시를 알아보는 이름표(저장할 때 이 칸의 내용을 실제로 지운다)
let redactionTag = PDFRedaction.tag

/// PDF 화면 + 마우스로 그리기·옮기기·크기 바꾸기·지우기.
/// 고르기 도구에서 표시가 아닌 곳을 누르면 원래 PDF 화면처럼 글자를 고르고 서식 칸을 채운다.
final class MarkupPDFView: PDFView {
    weak var session: PDFSession?

    private var dragStart: CGPoint?
    private var dragPage: PDFPage?
    private var drawing: PDFAnnotation?
    private var inkPoints: [CGPoint] = []
    private var moving: (annotation: PDFAnnotation, offset: CGPoint, resize: Bool, original: CGRect)?
    private(set) var selected: PDFAnnotation? {
        didSet {
            oldValue?.isHighlighted = false
            selected?.isHighlighted = true
            session?.selectionChanged(selected)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    private var tool: MarkupTool { session?.tool ?? .select }

    private func pagePoint(_ event: NSEvent) -> (PDFPage, CGPoint)? {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: true) else { return nil }
        return (page, convert(viewPoint, to: page))
    }

    /// 내가 다룰 수 있는 표시인지(링크·서식 칸은 PDF 화면에 맡긴다)
    private func isMarkup(_ a: PDFAnnotation) -> Bool {
        let type = a.type ?? ""
        return type != "Link" && type != "Widget" && type != "Popup"
    }

    // MARK: 마우스

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let (page, point) = pagePoint(event) else { return super.mouseDown(with: event) }

        switch tool {
        case .select:
            if let hit = page.annotations.last(where: { isMarkup($0) && $0.bounds.insetBy(dx: -4, dy: -4).contains(point) }) {
                if event.clickCount == 2, hit.type == "FreeText" || hit.type == "Text" {
                    selected = hit
                    session?.editText(of: hit)
                    return
                }
                selected = hit
                let b = hit.bounds
                let corner = CGPoint(x: b.maxX, y: b.minY)
                let resizable = ["Square", "Circle", "FreeText", "Stamp"].contains(hit.type ?? "")
                let nearCorner = hypot(point.x - corner.x, point.y - corner.y) < 10 / max(scaleFactor, 0.1)
                session?.beginEdit()
                moving = (hit, CGPoint(x: point.x - b.minX, y: point.y - b.minY), resizable && nearCorner, b)
                return
            }
            selected = nil
            super.mouseDown(with: event)
        case .highlight, .underline, .strike:
            selected = nil
            super.mouseDown(with: event)       // 글자 고르기는 PDF 화면이
        case .text:
            selected = nil
            session?.placeText(on: page, at: point)
        case .note:
            selected = nil
            session?.placeNote(on: page, at: point)
        case .signature:
            selected = nil
            session?.placeSignature(on: page, at: point)
        case .pen, .rect, .oval, .line, .arrow, .redact:
            selected = nil
            session?.beginEdit()
            dragStart = point
            dragPage = page
            inkPoints = [point]
            let annotation = makeShape(from: point, to: point, on: page)
            page.addAnnotation(annotation)
            drawing = annotation
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let (page, point) = pagePoint(event) else { return super.mouseDragged(with: event) }
        if let moving {
            let a = moving.annotation
            if moving.resize {
                let o = moving.original
                let width = max(12, point.x - o.minX), top = o.maxY, bottom = min(point.y, top - 12)
                a.bounds = CGRect(x: o.minX, y: bottom, width: width, height: top - bottom)
            } else {
                a.bounds.origin = CGPoint(x: point.x - moving.offset.x, y: point.y - moving.offset.y)
            }
            annotationsChanged(on: page)
            return
        }
        guard let start = dragStart, let drawingPage = dragPage, let old = drawing else { return super.mouseDragged(with: event) }
        let p = convert(convert(event.locationInWindow, from: nil), to: drawingPage)
        if tool == .pen { inkPoints.append(p) }
        drawingPage.removeAnnotation(old)
        let fresh = makeShape(from: start, to: p, on: drawingPage)
        drawingPage.addAnnotation(fresh)
        drawing = fresh
    }

    override func mouseUp(with event: NSEvent) {
        if let moving {
            self.moving = nil
            if moving.annotation.bounds != moving.original { session?.endEdit(L("옮겼어요", "Moved")) } else { session?.cancelEdit() }
            return
        }
        if let drawing, let start = dragStart, let page = dragPage {
            let end = convert(convert(event.locationInWindow, from: nil), to: page)
            self.drawing = nil
            dragStart = nil
            dragPage = nil
            // 거의 안 끌었으면(실수로 누른 것) 지운다
            if hypot(end.x - start.x, end.y - start.y) < 3, tool != .pen || inkPoints.count < 3 {
                page.removeAnnotation(drawing)
                session?.cancelEdit()
            } else {
                selected = drawing
                session?.endEdit(tool.title)
            }
            return
        }
        super.mouseUp(with: event)
        if tool.marksText { session?.mark(tool) }
    }

    override func keyDown(with event: NSEvent) {
        // ⌫ / Delete: 고른 표시 지우기
        if let selected, event.keyCode == 51 || event.keyCode == 117 {
            session?.remove(selected)
            self.selected = nil
            return
        }
        if event.keyCode == 53 { selected = nil; session?.tool = .select; return }   // esc
        super.keyDown(with: event)
    }

    func deselect() { selected = nil }

    // MARK: 모양 만들기

    private func makeShape(from a: CGPoint, to b: CGPoint, on page: PDFPage) -> PDFAnnotation {
        let color = session?.color ?? .systemRed
        let width = session?.lineWidth ?? 2
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        let border = PDFBorder()
        border.lineWidth = width
        switch tool {
        case .rect, .oval:
            let shape = PDFAnnotation(bounds: rect.insetBy(dx: -width, dy: -width), forType: tool == .rect ? .square : .circle, withProperties: nil)
            shape.color = color
            shape.border = border
            return shape
        case .redact:
            let box = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
            box.color = .black
            box.interiorColor = .black
            box.contents = redactionTag
            box.userName = redactionTag
            return box
        case .line, .arrow:
            let pad = width * 6
            let bounds = rect.insetBy(dx: -pad, dy: -pad)
            let line = PDFAnnotation(bounds: bounds, forType: .line, withProperties: nil)
            line.startPoint = CGPoint(x: a.x - bounds.minX, y: a.y - bounds.minY)
            line.endPoint = CGPoint(x: b.x - bounds.minX, y: b.y - bounds.minY)
            line.startLineStyle = .none
            line.endLineStyle = tool == .arrow ? .openArrow : .none
            line.color = color
            line.border = border
            return line
        default:   // 펜
            let xs = inkPoints.map(\.x), ys = inkPoints.map(\.y)
            let box = CGRect(x: (xs.min() ?? a.x) - width * 2, y: (ys.min() ?? a.y) - width * 2,
                             width: (xs.max() ?? a.x) - (xs.min() ?? a.x) + width * 4, height: (ys.max() ?? a.y) - (ys.min() ?? a.y) + width * 4)
            let ink = PDFAnnotation(bounds: box, forType: .ink, withProperties: nil)
            let path = NSBezierPath()
            for (i, p) in inkPoints.enumerated() {
                let local = CGPoint(x: p.x - box.minX, y: p.y - box.minY)
                if i == 0 { path.move(to: local) } else { path.line(to: local) }
            }
            path.lineWidth = width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            ink.add(path)
            ink.color = color
            ink.border = border
            return ink
        }
    }
}
