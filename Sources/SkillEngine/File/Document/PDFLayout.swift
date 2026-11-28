import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

// PDF 쪽 안의 배치(표·그래프·읽는 순서)를 찾는 부분.
// 모든 길이 기준은 본문 글자 크기(`body`)에 대한 비율이라, 같은 내용을 축소해 넣은 쪽에서도 같은 결과가 나온다.

/// 쪽을 그린 그림. 그래프 영역을 잘라 내고, 영역 가장자리에 그림(잉크)이 더 이어지는지 볼 때 쓴다.
/// 좌표는 쪽 위쪽이 0인 포인트(PDFLine과 같은 좌표)이고, × `scale` 하면 픽셀이다.
struct PageRaster {
    let image: CGImage
    let scale: CGFloat
    let width: Int
    let height: Int
    private let pixels: [UInt8]   // RGBX, 위쪽 줄부터

    /// 쪽을 `wanted`배로 그린다(흰 바탕). 긴 변은 4,000px까지.
    static func render(_ page: PDFPage, scale wanted: CGFloat = 2) -> PageRaster? {
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = min(wanted, 4000 / max(box.width, box.height))
        let width = Int((box.width * scale).rounded(.up)), height = Int((box.height * scale).rounded(.up))
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let image: CGImage? = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -box.minX, y: -box.minY)
            page.draw(with: .mediaBox, to: context)
            return context.makeImage()
        }
        guard let image else { return nil }
        return PageRaster(image: image, scale: scale, width: width, height: height, pixels: pixels)
    }

    /// 사각형 안에 흰색(아주 옅은 회색 바탕 포함)이 아닌 점이 있나
    func hasInk(in rect: CGRect) -> Bool {
        let x0 = max(0, Int((rect.minX * scale).rounded(.down))), x1 = min(width, Int((rect.maxX * scale).rounded(.up)))
        let y0 = max(0, Int((rect.minY * scale).rounded(.down))), y1 = min(height, Int((rect.maxY * scale).rounded(.up)))
        guard x0 < x1, y0 < y1 else { return false }
        for y in y0..<y1 {
            let row = y * width * 4
            for x in x0..<x1 {
                let i = row + x * 4
                if min(pixels[i], pixels[i + 1], pixels[i + 2]) < 225 { return true }
            }
        }
        return false
    }

    /// 사각형 부분을 PNG로
    func png(of rect: CGRect) -> Data? {
        let pixelRect = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
            .integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !pixelRect.isEmpty, let cropped = image.cropping(to: pixelRect) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        let dpi = 72 * scale
        CGImageDestinationAddImage(destination, cropped, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

// MARK: - 줄 안을 칸 조각으로 (추출할 때)

extension PDFTextExtractor {
    /// 줄 안에서 글자 크기의 0.7배보다 넓게 벌어진 곳(보통 띄어쓰기는 0.25배쯤)으로 나눈 조각.
    /// 표의 한 줄이 PDFKit에서 한 줄로 합쳐져 나와도 칸을 되찾을 수 있게 한다. 나눌 곳이 없으면 빈 배열.
    static func segments(of line: PDFSelection, page: PDFPage, pageText: NSString, origin: CGRect, fontSize: CGFloat) -> [PDFLine.Segment] {
        guard line.numberOfTextRanges(on: page) == 1 else { return [] }
        let range = line.range(at: 0, on: page)
        guard range.location != NSNotFound, range.length > 1, NSMaxRange(range) <= pageText.length else { return [] }
        let text = pageText.substring(with: range) as NSString
        func isSpace(_ c: unichar) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 || c == 0xA0 || c == 0x3000 }

        var tokens: [(range: NSRange, rect: CGRect)] = []
        var i = 0
        while i < text.length {
            if isSpace(text.character(at: i)) { i += 1; continue }
            var j = i
            while j < text.length, !isSpace(text.character(at: j)) { j += 1 }
            guard let selection = page.selection(for: NSRange(location: range.location + i, length: j - i)) else { return [] }
            let rect = selection.bounds(for: page)
            guard rect.width > 0, rect.height > 0 else { return [] }
            // 글자 순서와 위치가 어긋나면(오른쪽→왼쪽 글, 이상한 순서) 나누지 않는다
            if let last = tokens.last, rect.minX < last.rect.minX - fontSize { return [] }
            if j - i >= 2, rect.width > CGFloat(j - i) * fontSize * 1.15 {
                // 글자 수에 비해 너무 넓다 = 띄어쓰기 없이 붙어 나온 두 칸("수능–"): 글자마다 재서 벌어진 곳에서 나눈다
                tokens += split(NSRange(location: i, length: j - i), in: text, base: range.location, page: page, fontSize: fontSize)
                    ?? [(NSRange(location: i, length: j - i), rect)]
            } else {
                tokens.append((NSRange(location: i, length: j - i), rect))
            }
            i = j
        }
        guard tokens.count >= 2 else { return [] }

        var groups: [[(range: NSRange, rect: CGRect)]] = [[tokens[0]]]
        for token in tokens.dropFirst() {
            if token.rect.minX - groups[groups.count - 1].last!.rect.maxX > fontSize * 0.7 {
                groups.append([token])
            } else {
                groups[groups.count - 1].append(token)
            }
        }
        guard groups.count >= 2 else { return [] }

        let attributed = line.attributedString
        return groups.map { group in
            let start = group.first!.range.location, end = NSMaxRange(group.last!.range)
            let sub = NSRange(location: start, length: end - start)
            let piece = text.substring(with: sub)
            var pieceRuns = [DocumentRun(clean(piece))]
            if let attributed, end <= attributed.length, (attributed.string as NSString).substring(with: sub) == piece {
                let found = runs(of: attributed.attributedSubstring(from: sub))
                if !found.isEmpty { pieceRuns = found }
            }
            return PDFLine.Segment(runs: pieceRuns, minX: group.map(\.rect.minX).min()! - origin.minX,
                                   maxX: group.map(\.rect.maxX).max()! - origin.minX)
        }
    }

    /// 낱말 하나를 글자마다 재서 두 칸으로 나눌 곳을 찾는다. 나눌 곳이 없거나 못 재면 nil.
    /// PDFKit은 띄어쓰기 없이 붙은 두 글자 사이의 빈 곳을 양쪽 글자 상자에 반씩 나눠 주므로, 글자 상자 사이 틈 말고도
    /// "이웃한 두 글자가 둘 다 제 폭보다 크게 부풀었으면" 그 사이를 틈으로 본다.
    private static func split(_ token: NSRange, in text: NSString, base: Int, page: PDFPage, fontSize: CGFloat) -> [(range: NSRange, rect: CGRect)]? {
        var boxes: [CGRect] = []
        for k in 0..<token.length {
            guard let selection = page.selection(for: NSRange(location: base + token.location + k, length: 1)) else { return nil }
            boxes.append(selection.bounds(for: page))
        }
        /// 글자 제 폭 어림: 한글·한자·동그라미 숫자 등은 글자 크기만큼, 나머지는 0.6배쯤
        func natural(_ k: Int) -> CGFloat {
            let scalar = text.substring(with: NSRange(location: token.location + k, length: 1)).unicodeScalars.first
            return fontSize * ((scalar?.value ?? 0) >= 0x1100 ? 1.0 : 0.6)
        }
        func excess(_ k: Int) -> CGFloat { boxes[k].isEmpty ? 0 : boxes[k].width - natural(k) }
        var cuts: [Int] = []   // 새 조각이 시작하는 글자 번호
        var parts: [(range: NSRange, rect: CGRect)] = []
        for k in 0..<token.length {
            let range = NSRange(location: token.location + k, length: 1)
            var cut = false
            if k > 0, let last = parts.last, !boxes[k].isEmpty {
                let gap = boxes[k].minX - last.rect.maxX
                let a = excess(k - 1), b = excess(k)
                cut = gap > fontSize * 0.7 || (a > fontSize * 0.2 && b > fontSize * 0.2 && gap + a + b > fontSize * 0.8)
            }
            if let last = parts.last, !cut {
                parts[parts.count - 1] = (NSRange(location: last.range.location, length: NSMaxRange(range) - last.range.location),
                                          boxes[k].isEmpty ? last.rect : last.rect.union(boxes[k]))
            } else {
                guard !boxes[k].isEmpty else { return nil }
                if k > 0 { cuts.append(k) }
                parts.append((range, boxes[k]))
            }
        }
        guard parts.count >= 2 else { return nil }
        // 나눈 자리 양쪽 글자 상자는 빈 곳을 반씩 품고 있으니 글자 제 폭으로 줄인다
        for (n, cut) in cuts.enumerated() {
            let left = n, right = n + 1
            let lastBox = boxes[cut - 1], firstBox = boxes[cut]
            if excess(cut - 1) > 0 {
                var r = parts[left].rect
                r.size.width = max(0, min(r.maxX, lastBox.minX + natural(cut - 1)) - r.minX)
                parts[left].rect = r
            }
            if excess(cut) > 0 {
                var r = parts[right].rect
                let newMin = max(r.minX, firstBox.maxX - natural(cut))
                r.size.width = r.maxX - newMin
                r.origin.x = newMin
                parts[right].rect = r
            }
        }
        return parts
    }
}

// MARK: - 쪽 배치

enum PDFLayout {
    /// 문단 짜기에 넘기는 차례: 글 줄, 또는 이미 완성된 덩어리(표·그림)
    enum Item {
        case line(PDFLine)
        case block(DocumentParagraph, page: Int)

        var page: Int {
            switch self {
            case .line(let line): line.page
            case .block(_, let page): page
            }
        }
    }

    /// 칸 하나가 될 수 있는 조각
    struct Piece {
        var text: String
        var minX: CGFloat
        var maxX: CGFloat
        var center: CGFloat { (minX + maxX) / 2 }
    }

    /// 같은 높이에 놓인 줄들(표의 한 줄 후보)
    struct Row {
        var members: [Int]
        var top: CGFloat
        var bottom: CGFloat
        var pieces: [Piece]
        /// 줄마다 높이가 들쭉날쭉하다(그래프 막대 위 값처럼). 표의 한 줄은 칸들이 같은 높이에 놓인다.
        var ragged = false
    }

    static func pieces(of line: PDFLine) -> [Piece] {
        if !line.segments.isEmpty {
            return line.segments.map { Piece(text: $0.text.trimmingCharacters(in: .whitespaces), minX: $0.minX, maxX: $0.maxX) }
        }
        return [Piece(text: line.text.trimmingCharacters(in: .whitespaces), minX: line.minX, maxX: line.minX + line.width)]
    }

    static func letters(_ text: String) -> Int { PDFTextExtractor.letterCount(text) }

    /// 두 세로 구간이 서로의 가운데를 품으면 같은 높이
    private static func sameRow(_ aTop: CGFloat, _ aBottom: CGFloat, _ bTop: CGFloat, _ bBottom: CGFloat) -> Bool {
        let aMid = (aTop + aBottom) / 2, bMid = (bTop + bBottom) / 2
        return aMid >= bTop && aMid <= bBottom && bMid >= aTop && bMid <= aBottom
    }

    /// 줄들을 높이로 묶는다(위에서 아래로). 줄 안 조각은 왼쪽부터.
    static func rows(_ indices: [Int], in lines: [PDFLine]) -> [Row] {
        var rows: [Row] = []
        var anchors: [(top: CGFloat, bottom: CGFloat)] = []
        for index in indices.sorted(by: { (lines[$0].top, lines[$0].minX) < (lines[$1].top, lines[$1].minX) }) {
            let line = lines[index]
            if let r = rows.indices.last(where: { sameRow(anchors[$0].top, anchors[$0].bottom, line.top, line.bottom) }), r >= rows.count - 3 {
                let a = anchors[r], tolerance = (a.bottom - a.top) * 0.2
                if abs(line.top - a.top) > tolerance && abs(line.bottom - a.bottom) > tolerance { rows[r].ragged = true }
                rows[r].members.append(index)
                rows[r].top = min(rows[r].top, line.top)
                rows[r].bottom = max(rows[r].bottom, line.bottom)
                rows[r].pieces += pieces(of: line)
            } else {
                rows.append(Row(members: [index], top: line.top, bottom: line.bottom, pieces: pieces(of: line)))
                anchors.append((line.top, line.bottom))
            }
        }
        for r in rows.indices { rows[r].pieces.sort { $0.minX < $1.minX } }
        return rows.sorted { $0.top < $1.top }
    }

    // MARK: 표

    /// 여러 줄의 조각이 차지하는 가로 구간을 합쳐서, 아무것도 없는 세로 틈으로 칸을 나눈다
    static func columns<C: Collection>(_ rows: C, body: CGFloat) -> [ClosedRange<CGFloat>] where C.Element == Row {
        let spans = rows.flatMap(\.pieces).map { ($0.minX, $0.maxX) }.sorted { $0.0 < $1.0 }
        var merged: [ClosedRange<CGFloat>] = []
        for (lo, hi) in spans {
            if let last = merged.last, lo <= last.upperBound + body * 0.3 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, hi)
            } else {
                merged.append(lo...hi)
            }
        }
        return merged
    }

    private static func column(of piece: Piece, in columns: [ClosedRange<CGFloat>]) -> Int {
        if let hit = columns.firstIndex(where: { $0.contains(piece.center) }) { return hit }
        return columns.indices.min { abs(columns[$0].lowerBound - piece.center) < abs(columns[$1].lowerBound - piece.center) } ?? 0
    }

    private static func usedColumns(_ row: Row, _ columns: [ClosedRange<CGFloat>]) -> Set<Int> {
        Set(row.pieces.map { column(of: $0, in: columns) })
    }

    struct TableRun {
        var rows: Range<Int>
        var columns: [ClosedRange<CGFloat>]
    }

    /// 두 칸 이상이 같은 칸 위치로 세 줄 넘게(또는 세 칸 이상이 두 줄, 칸 시작이 딱 맞게) 이어지면 표
    static func tables(in rows: [Row], body: CGFloat) -> [TableRun] {
        var found: [TableRun] = []
        var i = 0
        while i < rows.count {
            guard rows[i].pieces.count >= 2, !rows[i].ragged else { i += 1; continue }
            var end = i + 1
            var cols = columns(rows[i..<end], body: body)
            guard usedColumns(rows[i], cols).count == rows[i].pieces.count else { i += 1; continue }
            while end < rows.count {
                let next = rows[end]
                guard next.pieces.count >= 2, !next.ragged, next.top - rows[end - 1].bottom <= body * 2.2 else { break }
                // 한 줄 안의 서로 다른 조각이 같은 칸으로 합쳐지면(칸 경계를 가로지르는 줄) 거기서 멈춘다
                let widened = columns(rows[i...end], body: body)
                guard widened.count >= 2, rows[i...end].allSatisfy({ usedColumns($0, widened).count == $0.pieces.count }) else { break }
                cols = widened
                end += 1
            }
            if accept(rows[i..<end], columns: cols, body: body) {
                found.append(TableRun(rows: i..<end, columns: cols))
                i = end
            } else {
                i += 1
            }
        }
        return found
    }

    private static func accept(_ rows: ArraySlice<Row>, columns cols: [ClosedRange<CGFloat>], body: CGFloat) -> Bool {
        guard cols.count >= 2, rows.allSatisfy({ usedColumns($0, cols).count >= 2 }) else { return false }
        // 칸이 반 넘게 비면(그래프 값처럼 여기저기 흩어진 숫자) 표가 아니다
        let filled = rows.reduce(0) { $0 + usedColumns($1, cols).count }
        guard Double(filled) >= Double(rows.count * mergedCount(rows, cols)) * 0.5 else { return false }
        if rows.count == 2 {
            // 두 줄짜리는 칸이 셋 이상이고 모든 칸이 차 있고 칸 시작(또는 가운데)이 딱 맞을 때만
            guard cols.count >= 3, rows.allSatisfy({ usedColumns($0, cols).count == cols.count }) else { return false }
            let a = rows[rows.startIndex].pieces, b = rows[rows.startIndex + 1].pieces
            guard a.count == cols.count, b.count == cols.count else { return false }
            let aligned = zip(a, b).allSatisfy { abs($0.minX - $1.minX) <= body * 0.4 || abs($0.center - $1.center) <= body * 0.4 }
            guard aligned else { return false }
        } else if rows.count < 2 {
            return false
        }
        // 두 단 짜기 본문(왼쪽 단 줄 | 오른쪽 단 줄)은 표가 아니다: 긴 문장 칸이 대부분이면 버린다
        var prose = 0
        for (c, _) in cols.enumerated() {
            let cells = rows.flatMap { row in row.pieces.filter { column(of: $0, in: cols) == c } }
            guard !cells.isEmpty else { continue }
            let lengths = cells.map { letters($0.text) }.sorted()
            let widths = cells.map { $0.maxX - $0.minX }.sorted()
            if lengths[lengths.count / 2] >= 15 && widths[widths.count / 2] >= body * 8 { prose += 1 }
        }
        if prose >= 2 && prose * 2 >= cols.count { return false }
        return true
    }

    /// 칸 차지 표(줄 × 칸, 그 칸에 조각이 있나)
    private static func occupancy<C: Collection>(_ rows: C, _ cols: [ClosedRange<CGFloat>]) -> [[Bool]] where C.Element == Row {
        rows.map { row in
            let used = usedColumns(row, cols)
            return cols.indices.map { used.contains($0) }
        }
    }

    /// 나란한 두 칸을 어느 줄도 함께 쓰지 않으면 한 칸이다(가운데 맞춘 머리칸 + 왼쪽 맞춘 데이터 칸 같은 경우).
    /// 돌려주는 값: 칸 번호 → 합친 칸 번호
    private static func mergeMap(_ occupied: [[Bool]], count: Int) -> [Int] {
        var map = Array(0..<count)
        guard count > 1 else { return map }
        var group = 0
        var groupUse = occupied.map { $0[0] }
        for c in 1..<count {
            let use = occupied.map { $0[c] }
            if !zip(groupUse, use).contains(where: { $0 && $1 }) {
                groupUse = zip(groupUse, use).map { $0 || $1 }
            } else {
                group += 1
                groupUse = use
            }
            map[c] = group
        }
        return map
    }

    private static func mergedCount<C: Collection>(_ rows: C, _ cols: [ClosedRange<CGFloat>]) -> Int where C.Element == Row {
        (mergeMap(occupancy(rows, cols), count: cols.count).last ?? 0) + 1
    }

    static func cells(_ run: TableRun, rows: [Row]) -> [[String]] {
        let map = mergeMap(occupancy(rows[run.rows], run.columns), count: run.columns.count)
        let count = (map.last ?? 0) + 1
        return rows[run.rows].map { row in
            var cells = Array(repeating: "", count: count)
            for piece in row.pieces where !piece.text.isEmpty {
                let c = map[column(of: piece, in: run.columns)]
                cells[c] = cells[c].isEmpty ? piece.text : cells[c] + " " + piece.text
            }
            return cells
        }
    }

    // MARK: 그래프·도표

    private static let chartCharacters = CharacterSet(charactersIn: "0123456789.,%‰+-–—−~·:/()×①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳")

    /// 그래프 눈금·값 같은 글자: 숫자·기호가 절반 이상
    static func isNumeric(_ text: String) -> Bool {
        let scalars = text.unicodeScalars.filter { !CharacterSet.whitespaces.contains($0) }
        guard !scalars.isEmpty else { return false }
        return Double(scalars.filter { chartCharacters.contains($0) }.count) / Double(scalars.count) >= 0.5
    }

    /// 그래프 라벨 후보: 본문보다 작은 글자의 짧은 줄(또는 넓게 벌어진 짧은 조각들로만 된 줄, 가로축 라벨처럼), 문장이 아님
    private static func isLabel(_ line: PDFLine, body: CGFloat) -> Bool {
        guard line.fontSize < body * 0.88, !PDFTextExtractor.endsSentence(line.text) else { return false }
        let count = letters(line.text)
        if count >= 1 && count <= 14 { return true }
        return line.segments.count >= 2 && line.segments.allSatisfy { (1...14).contains(letters($0.text)) }
    }

    struct Figure {
        var members: Set<Int>
        var box: CGRect
    }

    /// 작은 글자의 짧은 숫자·라벨 줄이 몰려 있고, 그것들이 표처럼 칸·줄로 딱 맞지 않으면(값이 여러 높이에 흩어짐) 그래프.
    /// 애매하면 그래프로 보지 않는다(글로 남긴다).
    static func figures(in lines: [PDFLine], body: CGFloat) -> [Figure] {
        let labels = lines.indices.filter { isLabel(lines[$0], body: body) }
        guard labels.count >= 6 else { return [] }
        func rect(_ i: Int) -> CGRect { CGRect(x: lines[i].minX, y: lines[i].top, width: lines[i].width, height: lines[i].bottom - lines[i].top) }

        // 가까운(글자 4개 크기 안) 라벨끼리 묶기
        var parent = Dictionary(uniqueKeysWithValues: labels.map { ($0, $0) })
        func root(_ i: Int) -> Int { var i = i; while parent[i]! != i { i = parent[i]! }; return i }
        for (n, a) in labels.enumerated() {
            for b in labels[(n + 1)...] {
                let ra = rect(a), rb = rect(b)
                let dx = max(0, max(ra.minX - rb.maxX, rb.minX - ra.maxX))
                let dy = max(0, max(ra.minY - rb.maxY, rb.minY - ra.maxY))
                if max(dx, dy) <= body * 4 { parent[root(a)] = root(b) }
            }
        }
        var clusters = Dictionary(grouping: labels, by: root).values.map { $0.sorted() }.sorted { $0[0] < $1[0] }

        // 같은 높이 범위에 놓였고 그 사이에 다른 글이 없는 무리는 한 그래프(왼쪽 눈금 ↔ 오른쪽 범례처럼 멀리 떨어져도)
        let labelSet = Set(labels)
        func box(_ members: [Int]) -> CGRect { members.map(rect).reduce(CGRect.null) { $0.union($1) } }
        var merged = true
        while merged {
            merged = false
            search: for a in clusters.indices {
                for b in clusters.indices where b > a {
                    let ra = box(clusters[a]), rb = box(clusters[b])
                    let overlap = min(ra.maxY, rb.maxY) - max(ra.minY, rb.minY)
                    guard overlap >= min(ra.height, rb.height) * 0.5 else { continue }
                    let between = CGRect(x: min(ra.minX, rb.minX), y: max(ra.minY, rb.minY),
                                         width: max(ra.maxX, rb.maxX) - min(ra.minX, rb.minX), height: overlap)
                    let blocked = lines.indices.contains { j in
                        !labelSet.contains(j) && between.contains(CGPoint(x: rect(j).midX, y: rect(j).midY))
                    }
                    guard !blocked else { continue }
                    clusters[a] = (clusters[a] + clusters[b]).sorted()
                    clusters.remove(at: b)
                    merged = true
                    break search
                }
            }
        }

        var found: [Figure] = []
        for cluster in clusters where cluster.count >= 6 {
            let numeric = cluster.filter { isNumeric(lines[$0].text) }.count
            guard Double(numeric) / Double(cluster.count) >= 0.5 else { continue }
            let clusterRows = rows(cluster, in: lines)
            guard clusterRows.count >= 3 else { continue }
            // 바로 위 제목 줄이 "표 N."이면 표, "그림 N."이면 그림(지은이가 정해 둔 것을 따른다)
            let caption = captionAbove(box(cluster), excluding: Set(cluster), in: lines, body: body)
            if caption == .table { continue }
            if caption != .figure {
                // 제목 단서가 없으면: 표처럼 줄·칸이 딱 맞을 때는 표 쪽에 맡긴다
                let tabled = tables(in: clusterRows, body: body).reduce(0) { sum, run in
                    sum + clusterRows[run.rows].reduce(0) { $0 + $1.members.count }
                }
                guard cluster.count - tabled >= max(3, cluster.count / 10) else { continue }
            }

            var members = Set(cluster)
            var extent = cluster.map(rect).reduce(CGRect.null) { $0.union($1) }
            guard extent.height >= body * 4 else { continue }
            // 영역 안에 든 다른 줄: 작고 짧으면 그래프의 일부, 본문 문장이면 그래프로 보지 않는다
            var clean = true
            for j in lines.indices where !members.contains(j) {
                let r = rect(j)
                guard extent.contains(CGPoint(x: r.midX, y: r.midY)) else { continue }
                if lines[j].fontSize < body * 0.95 && letters(lines[j].text) <= 30 {
                    members.insert(j)
                    extent = extent.union(r)
                } else {
                    clean = false
                    break
                }
            }
            guard clean else { continue }
            found.append(Figure(members: members, box: extent))
        }
        return found
    }

    enum CaptionKind { case figure, table }

    private static let figureCaption = try! NSRegularExpression(pattern: #"^\s*(그림|도표|차트|Figure|Fig\.|Chart)\s*\d+"#, options: [.caseInsensitive])
    private static let tableCaption = try! NSRegularExpression(pattern: #"^\s*(표|Table)\s*\d+"#, options: [.caseInsensitive])

    /// 영역 바로 위(글자 4개 높이 안)에 가로로 겹쳐 놓인 가장 가까운 줄이 표·그림 제목인가
    static func captionAbove(_ box: CGRect, excluding members: Set<Int>, in lines: [PDFLine], body: CGFloat) -> CaptionKind? {
        let above = lines.indices.filter { j in
            let line = lines[j]
            return !members.contains(j) && line.bottom <= box.minY + body * 0.2 && box.minY - line.bottom <= body * 4
                && line.minX < box.maxX && line.minX + line.width > box.minX
        }
        guard let nearest = above.max(by: { lines[$0].bottom < lines[$1].bottom }) else { return nil }
        let text = lines[nearest].text
        let range = NSRange(text.startIndex..., in: text)
        if figureCaption.firstMatch(in: text, range: range) != nil { return .figure }
        if tableCaption.firstMatch(in: text, range: range) != nil { return .table }
        return nil
    }

    /// 라벨을 감싼 사각형을 그림이 이어지는 데까지 넓힌다(다른 글 줄에 닿으면 멈춤)
    static func region(around box: CGRect, avoiding avoid: [CGRect], raster: PageRaster, pageSize: CGSize, body: CGFloat) -> CGRect {
        let page = CGRect(origin: .zero, size: pageSize)
        let margin = body * 0.5, cap = body * 3, look = body * 0.6, step = max(0.5, body * 0.1)
        var region = box
        for side in 0..<4 {
            func band(_ thickness: CGFloat) -> CGRect {
                switch side {
                case 0: CGRect(x: region.minX, y: region.minY - thickness, width: region.width, height: thickness)
                case 1: CGRect(x: region.minX, y: region.maxY, width: region.width, height: thickness)
                case 2: CGRect(x: region.minX - thickness, y: region.minY, width: thickness, height: region.height)
                default: CGRect(x: region.maxX, y: region.minY, width: thickness, height: region.height)
                }
            }
            var moved: CGFloat = 0
            while moved < cap {
                let next = band(step)
                guard page.contains(next), !avoid.contains(where: { $0.intersects(next) }) else { break }
                if moved >= margin && !raster.hasInk(in: band(look).intersection(page)) { break }
                region = region.union(next)
                moved += step
            }
        }
        return region.intersection(page)
    }

    // MARK: 쪽 하나 → 차례

    /// 쪽마다 그래프(그림으로)·표를 찾아 덩어리로 만들고, 남은 글 줄과 함께 읽는 순서로 늘어놓는다.
    /// `raster`가 없으면(OCR 쪽·테스트) 그래프는 찾지 않는다.
    static func flow(_ lines: [PDFLine], body: CGFloat, raster: ((Int) -> PageRaster?)?) -> [Item] {
        var byPage: [Int: [PDFLine]] = [:]
        for line in lines { byPage[line.page, default: []].append(line) }
        var items: [Item] = []
        for page in byPage.keys.sorted() {
            items += flowPage(byPage[page]!, page: page, body: body, raster: raster)
        }
        return items
    }

    private struct Placed {
        var item: Item
        var first: Int
        var top: CGFloat
        var bottom: CGFloat
        var minX: CGFloat
    }

    private static func flowPage(_ lines: [PDFLine], page: Int, body: CGFloat, raster: ((Int) -> PageRaster?)?) -> [Item] {
        var used = Set<Int>()
        var placed: [Placed] = []

        // 1. 그래프 → 그림
        if let raster {
            let found = figures(in: lines, body: body)
            var picture: PageRaster?
            if !found.isEmpty { picture = raster(page) }
            if let picture {
                let size = CGSize(width: CGFloat(picture.width) / picture.scale, height: CGFloat(picture.height) / picture.scale)
                var taken: [CGRect] = []   // 이미 잘라 낸 그림 영역(한 쪽에 그래프가 둘일 때 겹치지 않게)
                for figure in found {
                    let avoid = lines.indices.filter { !figure.members.contains($0) && !used.contains($0) }.map {
                        CGRect(x: lines[$0].minX, y: lines[$0].top, width: lines[$0].width, height: lines[$0].bottom - lines[$0].top)
                    } + taken
                    let area = region(around: figure.box, avoiding: avoid, raster: picture, pageSize: size, body: body)
                    guard let png = picture.png(of: area) else { continue }
                    taken.append(area)
                    used.formUnion(figure.members)
                    let block = DocumentParagraph(runs: [], image: DocumentImage(png: png, size: area.size))
                    placed.append(Placed(item: .block(block, page: page), first: figure.members.min()!,
                                         top: area.minY, bottom: area.maxY, minX: area.minX))
                }
            }
        }

        // 2. 표
        let remaining = lines.indices.filter { !used.contains($0) }
        let pageRows = rows(remaining, in: lines)
        for run in tables(in: pageRows, body: body) {
            let members = pageRows[run.rows].flatMap(\.members)
            used.formUnion(members)
            let block = DocumentParagraph(runs: [], table: cells(run, rows: pageRows))
            placed.append(Placed(item: .block(block, page: page), first: members.min()!,
                                 top: pageRows[run.rows.lowerBound].top, bottom: pageRows[run.rows.upperBound - 1].bottom,
                                 minX: run.columns.first!.lowerBound))
        }

        // 3. 남은 글 줄
        for i in lines.indices where !used.contains(i) {
            placed.append(Placed(item: .line(lines[i]), first: i, top: lines[i].top, bottom: lines[i].bottom, minX: lines[i].minX))
        }

        // 4. 읽는 순서: 여러 단으로 짠 쪽은 PDF의 글 순서를 믿고, 한 단이면 위→아래, 같은 높이는 왼쪽→오른쪽
        let textLines = lines.indices.filter { !used.contains($0) }
        if placed.count == textLines.count && placed.allSatisfy({ if case .line = $0.item { true } else { false } }) && isTopSorted(lines) {
            return placed.map(\.item)
        }
        if isMultiColumn(textLines, in: lines, body: body) {
            return placed.sorted { $0.first < $1.first }.map(\.item)
        }
        let sorted = placed.sorted { ($0.top, $0.minX) < ($1.top, $1.minX) }
        var ordered: [[Placed]] = []
        for item in sorted {
            if let anchor = ordered.last?.first, sameRow(anchor.top, anchor.bottom, item.top, item.bottom) {
                ordered[ordered.count - 1].append(item)
            } else {
                ordered.append([item])
            }
        }
        return ordered.flatMap { $0.sorted { $0.minX < $1.minX } }.map(\.item)
    }

    /// PDF의 줄 순서가 이미 위→아래면 손대지 않는다
    private static func isTopSorted(_ lines: [PDFLine]) -> Bool {
        zip(lines, lines.dropFirst()).allSatisfy { a, b in b.top >= a.top - 1 || sameRow(a.top, a.bottom, b.top, b.bottom) }
    }

    /// 같은 높이에 긴 글 줄이 나란히 놓인 곳이 세 번 이상이면 여러 단
    static func isMultiColumn(_ indices: [Int], in lines: [PDFLine], body: CGFloat) -> Bool {
        var count = 0
        for row in rows(indices, in: lines) where row.members.count >= 2 {
            let long = row.members.map { lines[$0] }.filter { letters($0.text) >= 12 && $0.width >= body * 6 }
                .sorted { $0.minX < $1.minX }
            if zip(long, long.dropFirst()).contains(where: { $0.minX + $0.width < $1.minX - body }) { count += 1 }
        }
        return count >= 3
    }
}
