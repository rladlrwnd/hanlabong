import AppKit
import PDFKit

/// 가리기(진짜 지우기): 가리기 상자가 있는 쪽을 그림으로 다시 그려서, 상자 밑의 글자·그림을 파일에서 없앤다.
/// 검은 상자만 덮어두면 밑에 글자가 그대로 남아 복사·검색으로 다 보인다. 그래서 쪽째로 굳힌다(그 쪽 글자는 더 못 고른다).
public enum PDFRedaction {
    public static let tag = "hanlabong-redact"

    public static func hasRedactions(_ document: PDFDocument) -> Bool {
        (0..<document.pageCount).contains { document.page(at: $0)?.annotations.contains { $0.userName == tag } == true }
    }

    /// 가린 쪽만 그림으로 굳힌 사본. 가린 곳이 없으면 nil
    public static func burned(_ document: PDFDocument, ppi: CGFloat = 200) -> PDFDocument? {
        guard hasRedactions(document), let data = document.dataRepresentation(), let copy = PDFDocument(data: data) else { return nil }
        for index in 0..<copy.pageCount {
            guard let page = copy.page(at: index), page.annotations.contains(where: { $0.userName == tag }) else { continue }
            let box = page.bounds(for: .mediaBox)
            let scale = ppi / 72
            let width = Int(box.width * scale), height = Int(box.height * scale)
            guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -box.minX, y: -box.minY)
            // 쪽 내용 + 표시(다른 표시도 같이 굳는다)를 그리고, 가리기 상자는 확실히 검정으로 다시 칠한다
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            page.draw(with: .mediaBox, to: ctx)
            NSGraphicsContext.restoreGraphicsState()
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            for a in page.annotations where a.userName == tag { ctx.fill(a.bounds) }
            guard let cg = ctx.makeImage() else { continue }
            let image = NSImage(cgImage: cg, size: box.size)
            guard let flat = PDFPage(image: image) else { continue }
            copy.removePage(at: index)
            copy.insert(flat, at: index)
        }
        return copy
    }
}
