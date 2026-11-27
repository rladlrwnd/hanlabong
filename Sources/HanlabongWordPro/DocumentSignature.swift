import AppCore
import AppKit
import SkillEngine
import SwiftUI
import UniformTypeIdentifiers

// 문서 영역 3단계: 서명 넣기.
// 서명(Signature: 0~1로 맞춘 획·굵기)을 투명 배경 PNG 그림으로 그려서, 종이에 그림 문단(NSTextAttachment)으로 넣는다.
// 저장하면 되돌리기 변환기(RichDocumentEditing)가 첨부 그림을 PNG로 남겨 준다.
//
// 자리: 문서 변환기는 표 칸 안에는 그림을 못 담고(표는 글 칸만), 글 가운데 낀 그림은 앞뒤 글과 문단으로 갈라 저장한다.
// 그래서 화면에 보이는 것과 저장 결과가 같도록 서명은 늘 "자기 줄을 가진 그림 문단"으로 넣는다(기존 그림 넣기와 같은 규칙):
// - 서명 빈칸이 정해져 있으면: 그 칸이 표 안이면 표 바로 뒤, 글이면 그 문단 바로 뒤
// - 아니면 커서 자리(문단 가운데면 줄을 바꿔서, 표 칸·쪽 띠 안이면 그 덩어리 뒤)

enum DocumentSignatureImage {
    /// 글 한 줄 높이(본문 글꼴 + 줄 간격)
    @MainActor static func lineHeight(for textView: NSTextView?) -> CGFloat {
        let font = (DocumentEditor.bodyAttributes()[.font] as? NSFont) ?? NSFont.systemFont(ofSize: 11)
        let line = textView?.layoutManager?.defaultLineHeight(for: font) ?? font.pointSize * 1.25
        return line + 3
    }

    /// 종이에 놓을 크기(포인트): 줄 높이의 2.5배(최대 3배), 너비는 본문 폭 안(그리고 줄 높이의 12배 이내)
    static func size(for signature: Signature, lineHeight: CGFloat, content: CGSize) -> CGSize {
        let aspect = CGFloat(max(signature.aspect, 0.05))
        var height = lineHeight * 2.5
        var width = height / aspect
        let maxWidth = max(40, min(content.width, lineHeight * 12))
        if width > maxWidth { width = maxWidth; height = width * aspect }
        if height > lineHeight * 3 { height = lineHeight * 3; width = height / aspect }
        return CGSize(width: max(24, width.rounded()), height: max(12, height.rounded()))
    }

    /// 서명 → 투명 배경 PNG(검은 잉크). 점마다 굵기를 반영하고(굵기 정보가 없던 옛 서명은 일정한 굵기), 가장자리가 잘리지 않게 안쪽 여백을 둔다.
    /// 화면 점 크기의 4배 해상도로 그린다.
    static func png(_ signature: Signature, size: CGSize) -> Data? {
        let scale: CGFloat = 4
        let pixelsWide = Int((size.width * scale).rounded(.up)), pixelsHigh = Int((size.height * scale).rounded(.up))
        guard pixelsWide > 0, pixelsHigh > 0, !signature.strokes.isEmpty,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        // 픽셀 좌표로 그리고(크기를 픽셀과 같게), 내보내기 직전에 점 크기로 돌려 놓는다
        rep.size = NSSize(width: pixelsWide, height: pixelsHigh)
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        let cg = context.cgContext
        let width = CGFloat(pixelsWide), height = CGFloat(pixelsHigh)
        cg.clear(CGRect(x: 0, y: 0, width: width, height: height))

        // 서명 전체를 여백 안에 맞춰 가운데에(서명은 가로가 1, 세로가 aspect)
        let pad = 2 * scale
        let aspect = CGFloat(max(signature.aspect, 0.01))
        let s = min(width - 2 * pad, (height - 2 * pad) / aspect)
        let offsetX = (width - s) / 2, offsetY = (height - aspect * s) / 2
        func point(_ p: CGPoint) -> CGPoint { CGPoint(x: offsetX + p.x * s, y: height - offsetY - p.y * s) }   // 서명은 위가 0, 그림은 아래가 0

        cg.setStrokeColor(NSColor.black.cgColor)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        let fallbackWidth = max(0.9 * scale, s * 0.012)
        for (n, stroke) in signature.strokes.enumerated() where stroke.count > 1 {
            let ws = signature.widths.flatMap { n < $0.count && $0[n].count == stroke.count ? $0[n] : nil }
            for i in 1..<stroke.count {
                let w = ws.map { CGFloat(($0[i - 1] + $0[i]) / 2) * s } ?? fallbackWidth
                cg.setLineWidth(max(w, 0.7 * scale))
                cg.move(to: point(stroke[i - 1]))
                cg.addLine(to: point(stroke[i]))
                cg.strokePath()
            }
        }
        rep.size = size
        return rep.representation(using: .png, properties: [:])
    }
}

extension DocumentFillModel {
    // MARK: 서명 시트(PDF 영역과 같은 SignaturePad)

    /// 서명 시트를 연다. target이 있으면 그 서명 칸 자리에, 없으면 커서 자리에 넣는다
    func beginSigning(target: DocumentBlank?) {
        if usesDisk { signatures = SignatureStore.load() }
        signTarget = target
        signing = true
    }

    /// 새로 쓴 서명을 이 맥에 저장해 둔다(맨 앞에)
    func addSignature(_ signature: Signature) {
        signatures.insert(signature, at: 0)
        if usesDisk { SignatureStore.save(signatures) }
    }

    func deleteSignature(_ signature: Signature) {
        signatures.removeAll { $0.id == signature.id }
        if usesDisk { SignatureStore.save(signatures) }
    }

    // MARK: 종이에 넣기

    /// 서명 그림 한 문단(그림 + 줄바꿈). 못 그리면 nil
    func signaturePiece(_ signature: Signature) -> NSAttributedString? {
        guard let editor, let tv = editor.textView else { return nil }
        let content = editor.contentSize
        let size = DocumentSignatureImage.size(for: signature, lineHeight: DocumentSignatureImage.lineHeight(for: tv), content: content)
        guard let png = DocumentSignatureImage.png(signature, size: size) else { return nil }
        return DocumentEditor.picture(png: png, size: size, content: content)
    }

    /// 서명 시트에서 고른(또는 새로 쓴) 서명을 넣는다. 넣었으면 true
    @discardableResult
    func place(_ signature: Signature) -> Bool {
        guard let editor, let tv = editor.textView, let storage = tv.textStorage else { return false }
        let target = signTarget
        signTarget = nil
        guard let piece = signaturePiece(signature) else {
            announce(L("서명을 그리지 못했어요", "Couldn't draw the signature"))
            return false
        }
        var location: Int
        var needsBreak: Bool
        let ns = storage.string as NSString
        if let target, let blank = currentBlank(matching: target) {
            // 서명 칸 자리(표 뒤·문단 뒤): 이미 문단 경계라서 안쪽 보정은 필요 없다
            location = min(blank.anchor, ns.length)
            needsBreak = !(location == 0 || ns.character(at: location - 1) == 10)
        } else {
            (location, needsBreak) = Self.cursorPoint(in: tv)
        }
        let whole = NSMutableAttributedString()
        if needsBreak { whole.append(NSAttributedString(string: "\n", attributes: DocumentEditor.bodyAttributes())) }
        whole.append(piece)
        editor.replace(NSRange(location: location, length: 0), with: whole)
        editor.focusSelection()
        announce(target == nil ? L("서명을 넣었어요", "Signature added") : L("‘\(target?.label ?? "서명")’ 자리에 서명을 넣었어요", "Signed at “\(target?.label ?? "signature")”"))
        blanks = scan()
        return true
    }

    /// 서명 칸을 다시 찾아서(그 사이 글이 조금 바뀌었어도) 같은 종류·이름에서 가장 가까운 것
    private func currentBlank(matching old: DocumentBlank) -> DocumentBlank? {
        scan().filter { $0.kind == old.kind && $0.label == old.label }
            .min { abs($0.range.location - old.range.location) < abs($1.range.location - old.range.location) }
            ?? old
    }

    /// 커서 자리에 그림 문단을 넣을 자리: 표 칸·쪽 띠 안이면 그 덩어리 뒤, 문단 가운데면 줄을 바꿔서(DocumentEditor.insertBlock과 같은 규칙)
    static func cursorPoint(in tv: NSTextView) -> (location: Int, needsBreak: Bool) {
        guard let storage = tv.textStorage else { return (0, false) }
        let ns = storage.string as NSString
        var location = min(tv.selectedRange().location, ns.length)
        if location < storage.length,
           let style = storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle,
           let block = style.textBlocks.first {
            if let cell = block as? NSTextTableBlock {
                location = NSMaxRange(storage.range(of: cell.table, at: location))
            } else {
                location = NSMaxRange(storage.range(of: block, at: location))
            }
        }
        if let band = DocumentEditor.bandRanges(in: storage).first(where: { NSLocationInRange(location, $0) }) { location = NSMaxRange(band) }
        let atLineStart = location == 0 || ns.character(at: location - 1) == 10
        return (location, !atLineStart)
    }
}
