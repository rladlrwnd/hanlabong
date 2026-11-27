import CoreGraphics
import Foundation

/// 한글 파일(.hwpx·옛 .hwp)을 읽은 결과. 문단 말고도 쪽 크기·여백·머리글·꼬리글·본문 글꼴을 같이 돌려준다.
struct HangulDocument {
    var paragraphs: [DocumentParagraph] = []
    var pageSize: CGSize?
    var margins: DocumentMargins?
    var header: [DocumentParagraph] = []
    var footer: [DocumentParagraph] = []
    var showPageNumber = false
    var bodyFontSize: CGFloat?
    var bodyFontName: String?

    /// 읽은 문서에 쪽 크기 말고 나머지(여백·머리글·꼬리글·본문 글꼴)를 옮긴다
    func apply(to document: inout RichDocument) {
        if document.pageSize == nil { document.pageSize = pageSize }
        document.margins = margins
        document.header = header
        document.footer = footer
        document.showPageNumber = showPageNumber
        document.bodyFontSize = bodyFontSize
        document.bodyFontName = bodyFontName
    }

    /// 본문에서 가장 많이 쓰인 글자 크기·글꼴과 같은 글자는 "기본"(nil)으로 돌린다
    mutating func normalizeBodyFont() {
        func fix(_ list: inout [DocumentParagraph]) {
            for i in list.indices {
                for j in list[i].runs.indices {
                    if let size = bodyFontSize, list[i].runs[j].fontSize == size { list[i].runs[j].fontSize = nil }
                    if let name = bodyFontName, list[i].runs[j].fontName == name { list[i].runs[j].fontName = nil }
                }
            }
        }
        fix(&paragraphs); fix(&header); fix(&footer)
    }
}

extension ReaderBlocks {
    /// 모양(밑줄·색 등)을 건드리지 않고 문단을 그대로 놓는다. 쪽 나눔 보류를 붙인다
    mutating func addKeepingStyle(_ paragraph: DocumentParagraph) {
        var p = paragraph
        if pendingBreak {
            p.pageBreakBefore = !paragraphs.isEmpty
            pendingBreak = false
        }
        paragraphs.append(p)
    }
}

enum HangulRuns {
    /// 같은 모양(굵게·밑줄·색 …)끼리 이어 붙이고 빈 조각은 뺀다
    static func merge(_ runs: [DocumentRun]) -> [DocumentRun] {
        var out: [DocumentRun] = []
        for run in runs where !run.text.isEmpty {
            if let last = out.last, last.sameStyle(as: run) { out[out.count - 1].text += run.text }
            else { out.append(run) }
        }
        return out
    }

    static func hasVisibleText(_ runs: [DocumentRun]) -> Bool {
        runs.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// 줄 간격이 고정값(pt)일 때 배수로 어림한다
    static func multiple(fixedPoints: CGFloat, fontPoints: CGFloat) -> CGFloat {
        let base = max(fontPoints, 6) * 1.2
        return min(max(fixedPoints / base, 0.8), 4)
    }

    /// "RRGGBB"(검정·없음이면 nil)
    static func hex(_ r: Int, _ g: Int, _ b: Int) -> String? {
        if r == 0 && g == 0 && b == 0 { return nil }
        return String(format: "%02X%02X%02X", r & 255, g & 255, b & 255)
    }
}
