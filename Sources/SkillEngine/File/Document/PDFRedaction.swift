import AppKit
import PDFKit

/// 가리기(진짜 지우기): 가리기 상자가 있는 쪽을 그림으로 다시 그려서, 상자 밑의 글자·그림을 파일에서 없앤다.
/// 검은 상자만 덮어두면 밑에 글자가 그대로 남아 복사·검색으로 다 보인다. 그래서 쪽째로 굳힌다(그 쪽 글자는 더 못 고른다).
/// 굳히다가 하나라도 실패하면 에러를 던진다. 실패한 채로 원본을 저장하면 가린 글자가 그대로 새어 나가기 때문.
public enum PDFRedaction {
    public static let tag = "hanlabong-redact"

    public enum Failure: LocalizedError, Equatable {
        case copyFailed
        case pageFailed(Int)
        case leftover

        public var errorDescription: String? {
            switch self {
            case .copyFailed: return L("가린 곳을 지우지 못해서 저장을 멈췄어요", "Stopped saving: couldn't remove the redacted parts")
            case .pageFailed(let page): return L("\(page)쪽의 가린 곳을 지우지 못해서 저장을 멈췄어요", "Stopped saving: couldn't remove the redacted parts on page \(page)")
            case .leftover: return L("가린 곳이 다 지워졌는지 확인하지 못해서 저장을 멈췄어요", "Stopped saving: couldn't confirm all redactions were removed")
            }
        }
    }

    public static func hasRedactions(_ document: PDFDocument) -> Bool {
        (0..<document.pageCount).contains { isRedacted(document.page(at: $0)) }
    }

    private static func isRedacted(_ page: PDFPage?) -> Bool {
        page?.annotations.contains { $0.userName == tag } == true
    }

    /// 한 쪽 그림 크기 상한(픽셀). 넘으면 ppi를 낮춰서 그린다(메모리 부족으로 실패하지 않게)
    static let maxPixels: CGFloat = 60_000_000

    /// 가린 쪽만 그림으로 굳힌 사본. 가린 곳이 없으면 nil. 굳히다 실패하면 에러
    public static func burned(_ document: PDFDocument, ppi: CGFloat = 200) throws -> PDFDocument? {
        guard hasRedactions(document) else { return nil }
        guard let data = document.dataRepresentation(), let copy = PDFDocument(data: data) else { throw Failure.copyFailed }
        // 다시 읽은 사본에서 가리기 표시가 사라졌으면(표시 이름이 저장 안 됨) 굳힐 쪽을 못 찾으니 멈춘다
        guard hasRedactions(copy) else { throw Failure.copyFailed }
        for index in 0..<copy.pageCount {
            guard let page = copy.page(at: index), isRedacted(page) else { continue }
            guard let flat = flatten(page, ppi: ppi) else { throw Failure.pageFailed(index + 1) }
            copy.removePage(at: index)
            copy.insert(flat, at: index)
        }
        guard !hasRedactions(copy) else { throw Failure.leftover }
        return copy
    }

    private static func flatten(_ page: PDFPage, ppi: CGFloat) -> PDFPage? {
        // 화면에 보이는 영역(cropBox)만 굳힌다. mediaBox로 굳히면 잘라서 숨겨 둔 부분이 드러난다
        let box = page.bounds(for: .cropBox)
        guard box.width > 0, box.height > 0, box.width.isFinite, box.height.isFinite else { return nil }
        // 돌린 쪽: 돌림을 잠시 풀고 원래 방향으로 그린 뒤, 굳힌 쪽에 같은 돌림을 다시 준다
        // (가리기 상자 좌표는 돌리기 전 쪽 좌표라 이래야 상자 자리가 맞는다)
        let rotation = page.rotation
        page.rotation = 0
        defer { page.rotation = rotation }
        var scale = ppi / 72
        let pixels = box.width * scale * box.height * scale
        if pixels > maxPixels { scale *= (maxPixels / pixels).squareRoot() }
        let width = Int((box.width * scale).rounded(.up)), height = Int((box.height * scale).rounded(.up))
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        // 쪽 내용 + 표시(다른 표시도 같이 굳는다)를 그리고, 가리기 상자는 확실히 검정으로 다시 칠한다
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        page.draw(with: .cropBox, to: ctx)
        NSGraphicsContext.restoreGraphicsState()
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        for a in page.annotations where a.userName == tag { ctx.fill(a.bounds) }
        guard let cg = ctx.makeImage() else { return nil }
        let image = NSImage(cgImage: cg, size: box.size)
        guard let flat = PDFPage(image: image) else { return nil }
        flat.rotation = rotation
        return flat
    }
}
