import AppCore
import AppKit
import PDFKit
import SwiftUI

/// 트랙패드로 서명 쓰기(미리보기 앱의 "트랙패드" 서명처럼): 시작하면 마우스 포인터를 그 자리에 묶고,
/// 트랙패드 판 전체를 서명 칸으로 쓴다 — 손가락이 닿은 자리(0~1)가 곧 칸 안의 자리.
/// 굵기: 빠르게 그으면 가늘게, 천천히 그으면 굵게, 꾹 눌러 클릭한 채로 쓰면 누르는 힘만큼 더 굵게.
/// 끝내기: 아무 키나. Esc = 방금 쓴 것 지우기.
final class TrackpadCaptureView: NSView {
    var onStroke: (([CGPoint], [CGFloat]) -> Void)?
    var onLive: (([CGPoint], [CGFloat]) -> Void)?
    var onStateChange: ((Bool) -> Void)?
    var onClear: (() -> Void)?

    private(set) var capturing = false
    private var points: [CGPoint] = []
    private var widths: [CGFloat] = []
    private var lastTime: TimeInterval = 0
    private var smoothedWidth: CGFloat = 2.2
    private var pressure: CGFloat = 0
    private var activeTouch: NSObjectProtocol?

    static let baseWidth: CGFloat = 2.4

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    func start() {
        guard !capturing else { return }
        capturing = true
        allowedTouchTypes = [.indirect]
        wantsRestingTouches = false
        window?.makeFirstResponder(self)
        // 손가락 입력은 포인터 밑의 화면으로 가서, 포인터를 이 칸 가운데로 옮기고 묶는다
        if let window {
            let rect = window.convertToScreen(convert(bounds, to: nil))
            let top = NSScreen.screens.first?.frame.maxY ?? rect.maxY
            CGWarpMouseCursorPosition(CGPoint(x: rect.midX, y: top - rect.midY))
        }
        NSCursor.hide()
        CGAssociateMouseAndMouseCursorPosition(0)     // 손가락을 움직여도 포인터는 그대로
        onStateChange?(true)
    }

    func stop() {
        guard capturing else { return }
        capturing = false
        allowedTouchTypes = []
        finishStroke()
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
        onStateChange?(false)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stop() }
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let newWindow {
            // 다른 앱으로 가면 포인터를 풀어 준다
            NotificationCenter.default.addObserver(self, selector: #selector(windowLostFocus), name: NSWindow.didResignKeyNotification, object: newWindow)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    @objc private func windowLostFocus() { stop() }

    override func mouseDown(with event: NSEvent) {
        if !capturing { start() }
    }

    /// 꾹 누르는 힘(포스 터치 트랙패드): 클릭한 채로만 온다
    override func pressureChange(with event: NSEvent) {
        pressure = event.stage >= 1 ? min(CGFloat(event.pressure) + CGFloat(event.stage - 1), 2) : 0
    }

    override func mouseUp(with event: NSEvent) { pressure = 0 }

    override func keyDown(with event: NSEvent) {
        guard capturing else { return super.keyDown(with: event) }
        if event.keyCode == 53 { points = []; widths = []; onClear?() }    // esc: 지우기
        stop()
    }

    // MARK: 손가락

    override func touchesBegan(with event: NSEvent) {
        guard capturing, activeTouch == nil, let touch = event.touches(matching: .began, in: self).first else { return }
        activeTouch = touch.identity
        points = []; widths = []
        smoothedWidth = Self.baseWidth
        lastTime = event.timestamp
        add(touch.normalizedPosition, time: event.timestamp)
    }

    override func touchesMoved(with event: NSEvent) {
        guard capturing, let id = activeTouch,
              let touch = event.touches(matching: .moved, in: self).first(where: { $0.identity.isEqual(id) }) else { return }
        add(touch.normalizedPosition, time: event.timestamp)
    }

    override func touchesEnded(with event: NSEvent) {
        guard let id = activeTouch, event.touches(matching: .ended, in: self).contains(where: { $0.identity.isEqual(id) }) else { return }
        finishStroke()
    }

    override func touchesCancelled(with event: NSEvent) { finishStroke() }

    private func add(_ normalized: CGPoint, time: TimeInterval) {
        // 트랙패드는 아래가 0, 이 칸은 위가 0
        let p = CGPoint(x: normalized.x * bounds.width, y: (1 - normalized.y) * bounds.height)
        if let last = points.last {
            let dt = max(time - lastTime, 0.004)
            let speed = hypot(p.x - last.x, p.y - last.y) / CGFloat(dt)          // 점/초
            // 빠를수록 가늘게(0.45배까지), 느리면 굵게(1.35배까지), 꾹 누르면 더
            let speedFactor = min(max(1.35 - speed / 900, 0.45), 1.35)
            let target = Self.baseWidth * speedFactor * (1 + pressure * 0.9)
            smoothedWidth += (target - smoothedWidth) * 0.35                     // 굵기가 튀지 않게
            if hypot(p.x - last.x, p.y - last.y) < 0.6 { return }
        }
        lastTime = time
        points.append(p)
        widths.append(smoothedWidth)
        onLive?(points, widths)
    }

    private func finishStroke() {
        activeTouch = nil
        if points.count > 1 { onStroke?(points, widths) }
        points = []; widths = []
        onLive?([], [])
    }
}

struct TrackpadCanvas: NSViewRepresentable {
    @Binding var capturing: Bool
    var onStroke: ([CGPoint], [CGFloat]) -> Void
    var onLive: ([CGPoint], [CGFloat]) -> Void
    var onClear: () -> Void
    var startToken: Int

    func makeNSView(context: Context) -> TrackpadCaptureView {
        let view = TrackpadCaptureView()
        view.onStroke = onStroke
        view.onLive = onLive
        view.onClear = onClear
        view.onStateChange = { on in DispatchQueue.main.async { capturing = on } }
        return view
    }

    func updateNSView(_ view: TrackpadCaptureView, context: Context) {
        view.onStroke = onStroke
        view.onLive = onLive
        view.onClear = onClear
        if context.coordinator.token != startToken {
            context.coordinator.token = startToken
            DispatchQueue.main.async { view.start() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var token = 0 }

    static func dismantleNSView(_ view: TrackpadCaptureView, coordinator: Coordinator) { view.stop() }
}

// MARK: 굵기가 바뀌는 서명을 PDF에 넣기

extension PDFSession {
    /// 서명 → PDF 표시들. 굵기가 다른 선은 몇 단계로 나눠 단계마다 잉크 표시 하나(저장해도 그대로 남는다).
    /// 한 서명에서 나온 표시들은 같은 이름표를 달아서 옮기거나 지울 때 같이 움직인다
    func signatureAnnotations(_ signature: Signature, in box: CGRect, tint: NSColor) -> [PDFAnnotation] {
        let width = box.width, height = box.height
        let tag = signatureGroupTag + UUID().uuidString
        func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * width, y: height - p.y * width) }   // 서명은 위가 0, PDF는 아래가 0
        func ink(_ lineWidth: CGFloat, _ build: (NSBezierPath) -> Void) -> PDFAnnotation? {
            let path = NSBezierPath()
            build(path)
            guard !path.isEmpty else { return nil }
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            let a = PDFAnnotation(bounds: box, forType: .ink, withProperties: nil)
            a.add(path)
            a.color = tint
            let border = PDFBorder(); border.lineWidth = lineWidth
            a.border = border
            a.userName = tag
            return a
        }
        guard let widths = signature.widths, widths.count == signature.strokes.count else {
            // 예전 서명(굵기 하나)
            return [ink(1.8) { path in
                for stroke in signature.strokes where stroke.count > 1 {
                    for (i, p) in stroke.enumerated() { if i == 0 { path.move(to: local(p)) } else { path.line(to: local(p)) } }
                }
            }].compactMap { $0 }
        }
        // 마디마다 굵기(서명 칸 가로 기준 0~1 → 지금 칸 크기 점)
        var segments: [(CGPoint, CGPoint, CGFloat)] = []
        for (stroke, ws) in zip(signature.strokes, widths) where stroke.count > 1 && ws.count == stroke.count {
            for i in 1..<stroke.count {
                segments.append((local(stroke[i - 1]), local(stroke[i]), CGFloat((ws[i - 1] + ws[i]) / 2) * width))
            }
        }
        guard let lo = segments.map(\.2).min(), let hi = segments.map(\.2).max() else { return [] }
        let levels = hi - lo < 0.2 ? 1 : 6
        var out: [PDFAnnotation] = []
        for level in 0..<levels {
            let a = lo + (hi - lo) * CGFloat(level) / CGFloat(levels)
            let b = lo + (hi - lo) * CGFloat(level + 1) / CGFloat(levels)
            let picked = segments.filter { level == levels - 1 ? $0.2 >= a : ($0.2 >= a && $0.2 < b) }
            guard !picked.isEmpty else { continue }
            if let annotation = ink(max((a + b) / 2, 0.4), { path in for (p, q, _) in picked { path.move(to: p); path.line(to: q) } }) { out.append(annotation) }
        }
        return out
    }
}

/// 한 서명에서 나온 표시들의 이름표 앞부분
let signatureGroupTag = "hanlabong-sign:"
