import AppCore
import AppKit
import SkillEngine
import SwiftUI

// 문서 영역 3단계: 내 정보로 빈칸 채우기.
// PDF 영역(PDFSessionFill.swift)과 같은 흐름: 빈칸 찾기 → 내 정보와 칸 이름으로 짝짓기 → 못 채운 칸은 AI → 타자 효과로 채우기.
// 다른 점: PDF는 "입력칸"을 만들어 쓰지만, 문서는 종이(NSTextView) 글을 바로 바꾼다. 그래서 칸 자리는 글자 위치(NSRange)로 들고 있다.

// MARK: - 빈칸 하나

struct DocumentBlank: Identifiable, Equatable {
    /// 빈칸이 놓인 모양
    enum Site: Equatable {
        /// 표에서 이름표 칸 옆(오른쪽, 없으면 아래)의 빈 칸
        case tableCell
        /// 표 칸 하나가 이름표 글만 들어 있고 답 자리는 그 칸 안(PDF를 변환한 신청서에 흔한 "성명:" 칸): 글 끝에 이어 쓴다
        case inCell
        /// "성명: ____" · "성명 :      " · "성명 ______" 처럼 이름표 뒤 빈 자리
        case afterLabel
        /// "주소(            )" 괄호 안
        case parentheses
        /// "2026년  월  일" 의 비어 있는 월·일(년) 자리
        case date
        /// "(인)" · "(서명)"
        case seal
    }

    var id: String
    var kind: FormField.Kind
    /// 칸 이름("성명", "주소", "월" …)
    var label: String
    /// AI가 무슨 칸인지 알아보라고 주는 둘레 글
    var context: String
    var site: Site
    /// 바꿀 자리(글자 위치). 칸이 비어 있으면 길이 0이거나 공백·밑줄 몇 칸
    var range: NSRange
    /// 바꾸기 전 글(그 사이 사용자가 고쳤는지 확인용)
    var original: String
    /// 값 뒤에 도로 붙일 글(한 줄에 칸이 여러 개일 때 칸 사이 틈)
    var suffix = ""
    /// 서명을 그림으로 넣을 자리(글자 위치): 표 칸이면 표 바로 뒤, 아니면 그 문단 바로 뒤
    var anchor: Int

    /// 엔진(FormFiller)이 알아듣는 칸. 문서에는 쪽·좌표가 없어서 page 0, rect .zero 더미를 쓴다
    var field: FormField { FormField(id: id, page: 0, rect: .zero, label: label, context: context, kind: kind) }
}

// MARK: - 빈칸 찾기

/// 문서 글(화면의 텍스트 저장소)에서 빈칸을 찾는다. 화면 없이도 돈다(테스트가 그대로 쓴다).
/// 규칙
/// - 표: 이름표처럼 보이는 칸(짧은 글: 성명·학번·주소·서명·신청인…, 끝이 ':'인 글, 첫 열의 짧은 글) 바로 오른쪽 칸이 비어 있으면 그 칸.
///   오른쪽이 없거나(맨 끝 열) 오른쪽도 이름표(머리줄 모양)면 바로 아래 칸이 비어 있을 때 그 칸
/// - 글: "성명: ____" / "성명 :      " / "성명 ______"(밑줄 3개 이상) / "주소(            )" / "(인)"·"(서명)"
/// - 날짜: "2026년  월  일" 에서 앞이 비어 있는 년·월·일 글자(두 개 이상 나올 때, 또는 앞 빈 자리가 3칸 이상일 때)
/// - 서명 종류는 FormFieldFinder.kindFor(이름표)로 구분. 이미 서명 그림이 바로 뒤에 들어 있는 칸은 뺀다
enum DocumentBlankFinder {
    static let labelWords: [String] = [
        "성명", "이름", "주소", "연락처", "전화", "휴대폰", "핸드폰", "휴대전화", "전화번호", "생년월일", "주민등록번호", "주민번호",
        "학번", "학과", "전공", "학년", "소속", "학교", "대학", "이메일", "email", "날짜", "일자", "작성일", "신청일", "제출일", "접수일",
        "서명", "대표자", "직위", "직급", "부서", "금액", "은행", "계좌", "예금주", "성별", "국적", "영문", "기간", "회사", "상호", "사업자",
        "신청인", "보호자", "학부모", "작성자", "확인자", "직업", "근무처", "사유", "name", "address", "phone", "date", "signature", "tel", "mobile",
    ]

    // MARK: 글자 판별(UTF-16 한 칸 단위)

    private static func isUnderscore(_ c: unichar) -> Bool { c == 0x5F || c == 0xFF3F }
    /// 빈 자리를 이루는 글자: 공백·탭·전각 공백·밑줄
    private static func isBlankUnit(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 || c == 0xA0 || c == 0x3000 || isUnderscore(c) }
    private static func isSpaceUnit(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 || c == 0xA0 || c == 0x3000 }
    private static func isDigit(_ c: unichar) -> Bool { c >= 0x30 && c <= 0x39 }
    private static func isColon(_ c: unichar) -> Bool { c == 0x3A || c == 0xFF1A }
    private static func isOpenParen(_ c: unichar) -> Bool { c == 0x28 || c == 0xFF08 }
    private static func isCloseParen(_ c: unichar) -> Bool { c == 0x29 || c == 0xFF09 }

    /// 이름표처럼 보이는가: 짧고(글자 14자 이하) 글자가 들어 있고, 끝이 ':'이거나 칸 이름 말이 들어 있다. weak면 짧은 글이면 그냥 이름표로(첫 열)
    static func isLabel(_ text: String, weak: Bool = false) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        let compact = t.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !compact.isEmpty, compact.count <= 14, compact.contains(where: { $0.isLetter }) else { return false }
        if t.hasSuffix(":") || t.hasSuffix("：") { return true }
        if labelWords.contains(where: { compact == $0 || ($0.count >= 2 && compact.count <= 10 && compact.contains($0)) }) { return true }
        return weak && compact.count <= 8
    }

    /// 칸 이름 다듬기: 앞 번호("1.", "※")·끝 ':'·괄호 떼기
    static func cleanLabel(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t:：*·•-()[]<>（）※□■").union(.whitespacesAndNewlines))
        if let r = s.range(of: #"^[\d①-⑩]+[.)]\s*"#, options: .regularExpression) { s.removeSubrange(r) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 칸 종류: 서명이면 .signature (단 "서명일"처럼 날짜면 글 칸)
    static func kind(of label: String) -> FormField.Kind {
        let kind = FormFieldFinder.kindFor(label)
        if kind == .signature {
            let l = label.replacingOccurrences(of: " ", with: "").lowercased()
            if l.contains("서명일") || l.contains("서명날짜") || l.contains("서명일자") { return .text }
        }
        return kind
    }

    // MARK: 한 번에 찾기

    private struct Para {
        var content: NSRange
        var enclosing: NSRange
        var text: String
        var cell: CellKey?
        var isBand: Bool
    }

    private struct CellKey: Hashable {
        var table: ObjectIdentifier
        var row: Int
        var col: Int
    }

    private struct Cell {
        var key: CellKey
        var paraIndex: Int
        var content: NSRange
        var enclosing: NSRange
        var text: String
        var isBlank: Bool { text.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) || $0 == "_" || $0 == "＿" } }
    }

    static func find(in text: NSAttributedString) -> [DocumentBlank] {
        let ns = text.string as NSString
        guard ns.length > 0 else { return [] }

        // 1. 문단·표 칸 모으기
        var paras: [Para] = []
        var tables: [ObjectIdentifier: NSTextTable] = [:]
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs, .substringNotRequired]) { _, range, enclosing, _ in
            let probe = enclosing.location
            var key: CellKey?
            if let style = text.attribute(.paragraphStyle, at: probe, effectiveRange: nil) as? NSParagraphStyle,
               let block = style.textBlocks.first(where: { $0 is NSTextTableBlock }) as? NSTextTableBlock {
                let id = ObjectIdentifier(block.table)
                tables[id] = block.table
                key = CellKey(table: id, row: block.startingRow, col: block.startingColumn)
            }
            let band = text.attribute(.hanlabongPageBreak, at: probe, effectiveRange: nil) != nil
            paras.append(Para(content: range, enclosing: enclosing, text: range.length > 0 ? ns.substring(with: range) : "", cell: key, isBand: band))
        }
        var cells: [CellKey: Cell] = [:]
        for (i, p) in paras.enumerated() {
            guard let key = p.cell else { continue }
            if var cell = cells[key] {
                if !p.text.isEmpty { cell.text += (cell.text.isEmpty ? "" : "\n") + p.text }
                cells[key] = cell
            } else {
                cells[key] = Cell(key: key, paraIndex: i, content: p.content, enclosing: p.enclosing, text: p.text)
            }
        }

        var found: [DocumentBlank] = []
        func overlaps(_ range: NSRange) -> Bool {
            found.contains { NSIntersectionRange($0.range, range).length > 0 || $0.range == range }
        }
        func tableEnd(_ key: CellKey, at location: Int) -> Int {
            guard let table = tables[key.table] else { return location }
            return NSMaxRange(text.range(of: table, at: location))
        }

        // 2. 표: 이름표 칸 옆의 빈 칸
        var labelParas: Set<Int> = []
        let byTable = Dictionary(grouping: cells.keys, by: \.table)
        for (_, keys) in byTable {
            let ordered = keys.sorted { ($0.row, $0.col) < ($1.row, $1.col) }
            let maxCol = (ordered.map(\.col).max() ?? 0)
            func rowSummary(_ row: Int, blankKey: CellKey) -> String {
                var parts: [String] = []
                for c in 0...maxCol {
                    let k = CellKey(table: blankKey.table, row: row, col: c)
                    guard let cell = cells[k] else { continue }
                    parts.append(k == blankKey ? L("(빈칸)", "(blank)") : (cell.isBlank ? "" : String(cell.text.prefix(24))))
                }
                return parts.filter { !$0.isEmpty }.joined(separator: " | ")
            }
            var claimed: Set<CellKey> = []
            for key in ordered {
                guard let labelCell = cells[key], !labelCell.isBlank, isLabel(labelCell.text, weak: key.col == 0) else { continue }
                let right = cells[CellKey(table: key.table, row: key.row, col: key.col + 1)]
                var target: Cell?
                if let right, right.isBlank {
                    target = right
                } else if right == nil || (right.map { !$0.isBlank && isLabel($0.text) } ?? false) {
                    if let below = cells[CellKey(table: key.table, row: key.row + 1, col: key.col)], below.isBlank { target = below }
                }
                if target == nil {
                    // 옆·아래에 빈 칸이 없고 이름표 칸뿐인 표(변환한 신청서): 답 자리는 그 칸 안이라고 보고 글 끝에 이어 쓴다.
                    // 오른쪽·아래에 이미 쓴 값이 있으면(머리줄 + 값 줄) 빈칸이 아니다
                    let below = cells[CellKey(table: key.table, row: key.row + 1, col: key.col)]
                    let rightOpen = right == nil || (right.map { isLabel($0.text) } ?? false)
                    let belowFilled = below.map { !$0.isBlank && !isLabel($0.text) } ?? false
                    if isLabel(labelCell.text), rightOpen, !belowFilled {
                        labelParas.insert(labelCell.paraIndex)
                        let label = cleanLabel(labelCell.text)
                        let end = labelCell.content.location + labelCell.content.length
                        found.append(DocumentBlank(
                            id: "", kind: kind(of: label), label: label,
                            context: L("표 칸: ", "Table cell: ") + String(labelCell.text.prefix(30)),
                            site: .inCell, range: NSRange(location: end, length: 0), original: "",
                            anchor: tableEnd(key, at: labelCell.enclosing.location)))
                    }
                    continue
                }
                guard let blankCell = target, !claimed.contains(blankCell.key) else { continue }
                claimed.insert(blankCell.key)
                labelParas.insert(labelCell.paraIndex)
                let label = cleanLabel(labelCell.text)
                found.append(DocumentBlank(
                    id: "", kind: kind(of: label), label: label,
                    context: L("표 줄: ", "Table row: ") + rowSummary(blankCell.key.row, blankKey: blankCell.key),
                    site: .tableCell, range: blankCell.content, original: blankCell.content.length > 0 ? ns.substring(with: blankCell.content) : "",
                    anchor: tableEnd(blankCell.key, at: blankCell.enclosing.location)))
            }
        }

        // 3. 글: 문단마다 날짜 → 괄호 → (인) → 콜론 → 밑줄 차례로(앞에서 찾은 자리와 겹치면 건너뛴다)
        for (index, para) in paras.enumerated() where !para.isBand && para.content.length > 0 {
            let s = para.text as NSString
            let base = para.content.location
            let anchor = NSMaxRange(para.enclosing)
            let context = String(para.text.replacingOccurrences(of: #"[_＿]{3,}"#, with: "___", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
            func add(_ kind: FormField.Kind, _ label: String, _ site: DocumentBlank.Site, _ local: NSRange, suffix: String = "") {
                let range = NSRange(location: base + local.location, length: local.length)
                guard !overlaps(range) else { return }
                found.append(DocumentBlank(id: "", kind: kind, label: label, context: context, site: site, range: range,
                                           original: ns.substring(with: range), suffix: suffix, anchor: anchor))
            }
            /// 어느 자리 앞에 쓰인 이름표(같은 줄 안: 탭·공백 두 칸 이상·콜론·닫는 괄호에서 끊는다, 14자까지)
            func label(before end: Int) -> String {
                var e = end
                while e > 0, isBlankUnit(s.character(at: e - 1)) || isColon(s.character(at: e - 1)) { e -= 1 }
                var st = e
                while st > 0, e - st < 14 {
                    let c = s.character(at: st - 1)
                    if c == 0x09 || isColon(c) || isCloseParen(c) || c == 0x2C || c == 0xFF0C || c == 0x2F { break }
                    if isSpaceUnit(c), st >= 2, isSpaceUnit(s.character(at: st - 2)) { break }
                    st -= 1
                }
                return cleanLabel(s.substring(with: NSRange(location: st, length: e - st)))
            }

            // 날짜: "2026년  월  일"
            var dateTokens: [(run: NSRange, char: unichar)] = []
            for i in 0..<s.length {
                let c = s.character(at: i)
                guard c == 0xB144 || c == 0xC6D4 || c == 0xC77C else { continue }          // 년 월 일
                var rs = i
                while rs > 0, isBlankUnit(s.character(at: rs - 1)) { rs -= 1 }
                guard rs < i else { continue }
                if rs > 0, isDigit(s.character(at: rs - 1)) { continue }
                if i + 1 < s.length {
                    let next = s.substring(with: NSRange(location: i + 1, length: 1))
                    if next.first.map({ $0.isLetter || $0.isNumber }) == true { continue }
                }
                dateTokens.append((NSRange(location: rs, length: i - rs), c))
            }
            if dateTokens.count >= 2 || dateTokens.contains(where: { $0.run.length >= 3 }) {
                for token in dateTokens {
                    let kind: FormField.Kind = token.char == 0xB144 ? .year : token.char == 0xC6D4 ? .month : .day
                    add(kind, String(utf16CodeUnits: [token.char], count: 1), .date, token.run)
                }
            }

            // 괄호 빈칸: "주소(            )"
            var i = 0
            while i < s.length {
                if isOpenParen(s.character(at: i)) {
                    var j = i + 1
                    while j < s.length, isBlankUnit(s.character(at: j)) { j += 1 }
                    if j < s.length, isCloseParen(s.character(at: j)), j - (i + 1) >= 3 {
                        let name = label(before: i)
                        if !name.isEmpty, name.contains(where: { $0.isLetter }) {
                            add(kind(of: name), name, .parentheses, NSRange(location: i + 1, length: j - (i + 1)))
                        }
                        i = j
                    }
                }
                i += 1
            }

            // (인)·(서명)  — 이름표 칸이 이미 서명 칸을 차지한 표 안에서는 건너뛴다
            if !labelParas.contains(index),
               let regex = try? NSRegularExpression(pattern: #"[(（]\s*(?:서명\s*또는\s*인|서명|날인|도장|인)\s*[)）]"#) {
                for m in regex.matches(in: para.text, range: NSRange(location: 0, length: s.length)) {
                    add(.signature, L("서명", "Signature"), .seal, m.range)
                }
            }

            // 콜론 뒤: "성명: ____" · "성명 :      "
            i = 0
            while i < s.length {
                let c = s.character(at: i)
                guard isColon(c) else { i += 1; continue }
                if i > 0, i + 1 < s.length, isDigit(s.character(at: i - 1)), isDigit(s.character(at: i + 1)) { i += 1; continue }     // 10:30
                if i + 1 < s.length, s.character(at: i + 1) == 0x2F { i += 1; continue }                                                // http://
                let name = label(before: i)
                guard !name.isEmpty, name.contains(where: { $0.isLetter }) else { i += 1; continue }
                var e = i + 1
                while e < s.length, isBlankUnit(s.character(at: e)) { e += 1 }
                let runLength = e - (i + 1)
                var underscores = 0
                for k in (i + 1)..<e where isUnderscore(s.character(at: k)) { underscores += 1 }
                let atEnd = e == s.length
                var range = NSRange(location: i + 1, length: runLength)
                var suffix = ""
                var accept = false
                if underscores >= 2 {
                    accept = true
                    if !atEnd {
                        // 밑줄 뒤 틈은 칸 밖으로 둔다(다음 칸과 안 붙게)
                        var re = e
                        while re > i + 1, !isUnderscore(s.character(at: re - 1)) { re -= 1 }
                        range = NSRange(location: i + 1, length: re - (i + 1))
                    }
                } else if atEnd {
                    // 줄 끝: 콜론 뒤가 비어 있다. 표 칸 안에서는 표 규칙이 맡는다
                    accept = para.cell == nil && (runLength >= 2 || isLabel(name))
                } else if runLength >= 3 {
                    // 공백만 있고 뒤에 또 이름표가 이어지는 줄: "성명 :        학번 :     "
                    let lookahead = min(s.length, e + 16)
                    var follows = false
                    for k in e..<lookahead where isColon(s.character(at: k)) { follows = true; break }
                    if follows { accept = true; suffix = "   " }
                }
                if accept { add(kind(of: name), name, .afterLabel, range, suffix: suffix) }
                i = max(e, i + 1)
            }

            // 밑줄만: "성명 ________"
            i = 0
            while i < s.length {
                guard isUnderscore(s.character(at: i)) else { i += 1; continue }
                var e = i
                while e < s.length, isUnderscore(s.character(at: e)) { e += 1 }
                if e - i >= 3 {
                    let name = label(before: i)
                    if !name.isEmpty, name.contains(where: { $0.isLetter }) {
                        add(kind(of: name), name, .afterLabel, NSRange(location: i, length: e - i))
                    }
                }
                i = e
            }
        }

        // 4. 서명이 이미 들어 있는 칸은 뺀다: 칸 자리(anchor) 바로 뒤에 그림 문단이 이어지는 만큼, 그 자리를 쓰는 서명 칸부터
        var signedPerAnchor: [Int: Int] = [:]
        func pictures(at anchor: Int) -> Int {
            var count = 0
            var pos = anchor
            // 표 뒤 틈 문단(빈 줄)은 건너뛴다: 저장했다 다시 열면 표와 그림 사이에 틈 문단이 끼기 때문
            var skipped = 0
            while skipped < 2, pos < ns.length, ns.character(at: pos) != 0xFFFC {
                let paragraph = ns.paragraphRange(for: NSRange(location: pos, length: 0))
                guard ns.substring(with: paragraph).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { break }
                pos = NSMaxRange(paragraph)
                skipped += 1
            }
            while pos < ns.length, ns.character(at: pos) == 0xFFFC {
                count += 1
                pos = NSMaxRange(ns.paragraphRange(for: NSRange(location: pos, length: 0)))
            }
            return count
        }
        found.sort { $0.range.location < $1.range.location }
        found = found.filter { blank in
            guard blank.kind == .signature else { return true }
            let already = signedPerAnchor[blank.anchor] ?? 0
            let total = pictures(at: blank.anchor)
            if already < total { signedPerAnchor[blank.anchor] = already + 1; return false }
            return true
        }
        for i in found.indices { found[i].id = "d\(i)" }
        return found
    }
}

// MARK: - 채우기 모델

/// 채운 결과(상태 안내와 테스트가 읽는다)
struct DocumentFillReport: Equatable {
    var found = 0
    var filled = 0
    var signed = 0
    /// 서명 칸인데 저장해 둔 서명이 없어서 그대로 둔 칸
    var needSignature = 0
    /// 어떤 값을 넣을지 못 정해서 비워 둔 칸
    var left = 0
    /// 비워 둔 칸의 이름표(안내에 보여 준다)
    var leftLabels: [String] = []
    var cancelled = false

    var summary: String {
        var text = L("빈칸 \(found)개 중 \(filled + signed)개를 채웠어요", "Filled \(filled + signed) of \(found) blanks")
        if signed > 0 { text += L(" (서명 \(signed)칸)", " (\(signed) signed)") }
        if needSignature > 0 { text += L(" · 서명 \(needSignature)칸은 ‘서명 넣기’로", " · \(needSignature) signature blank(s): use Add signature") }
        if left > 0 {
            let names = leftLabels.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " :：")) }.filter { !$0.isEmpty }
            if names.isEmpty {
                text += L(" · \(left)칸은 비워 뒀어요", " · left \(left) empty")
            } else {
                let list = names.prefix(4).joined(separator: "·") + (names.count > 4 ? L(" 등", " etc.") : "")
                text += L(" · \(list)은(는) 내 정보에 없어서 비워 뒀어요. ‘\(names[0])에 ○○ 써 줘’라고 하면 채울게요",
                          " · \(list) left empty (not in My info). Say “write ○○ in \(names[0])” to fill")
            }
        }
        if cancelled { text += L(" · 멈췄어요", " · stopped") }
        return text
    }
}

/// 문서 창 하나의 채우기 상태: 내 정보·서명 시트, 빈칸 목록, 채우는 일. 세션(DocumentSession)은 고치지 않고 이 모델이 편집기(DocumentEditor)의 공개 함수만 쓴다.
@MainActor
final class DocumentFillModel: ObservableObject {
    weak var session: DocumentSession?
    /// 내 정보(PDF 영역과 같은 ProfileStore)
    @Published var profile: UserProfile
    @Published var editingProfile = false
    /// 빈칸 목록 시트
    @Published var listing = false
    @Published var blanks: [DocumentBlank] = []
    /// 서명 시트(PDF 영역과 같은 SignaturePad)
    @Published var signing = false
    @Published var signatures: [Signature]
    /// 서명 시트에서 고른 서명을 넣을 칸(없으면 커서 자리)
    var signTarget: DocumentBlank?
    @Published private(set) var busy = false
    /// 마지막 결과 글
    @Published private(set) var lastSummary: String?

    /// false면 디스크(내 정보·서명 파일)를 읽고 쓰지 않는다(테스트가 진짜 파일을 안 건드리게)
    let usesDisk: Bool
    private var flashTask: Task<Void, Never>?

    init(session: DocumentSession? = nil, profile: UserProfile? = nil, signatures: [Signature]? = nil) {
        self.session = session
        self.usesDisk = profile == nil && signatures == nil
        self.profile = profile ?? ProfileStore.load()
        self.signatures = signatures ?? SignatureStore.load()
    }

    var editor: DocumentEditor? { session?.editor }
    var storage: NSTextStorage? { session?.editor.textView?.textStorage }
    private var accent: NSColor { AppAccent.nsColor(UserDefaults.standard.string(forKey: AppAccent.key) ?? AppAccent.defaultHex) ?? .systemOrange }

    // MARK: 찾기 · 안내

    /// 지금 종이에서 빈칸을 찾는다
    func scan() -> [DocumentBlank] {
        guard let storage else { return [] }
        return DocumentBlankFinder.find(in: storage)
    }

    /// 아래 요청칸 위(답 자리)와 상태 막대에 한 줄 안내
    func announce(_ text: String) {
        lastSummary = text
        session?.assistantReply = text
        session?.message = text
    }

    static var noBlanksText: String { L("이 문서에서 빈칸을 못 찾았어요", "No blanks found in this document") }

    /// 빈칸 목록 시트 열기. 없으면 안내만
    func openList() {
        let found = scan()
        guard !found.isEmpty else { announce(Self.noBlanksText); return }
        blanks = found
        listing = true
    }

    func beginEditingProfile() {
        if usesDisk { profile = ProfileStore.load() }
        editingProfile = true
    }

    func saveProfile(_ new: UserProfile) {
        profile = new
        if usesDisk { ProfileStore.save(new) }
    }

    /// 시트를 닫고 잠깐 뒤에(시트 두 개가 겹쳐 뜨지 않게) 할 일
    func afterSheetClosed(_ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            work()
        }
    }

    /// 칸 하나에 넣을 만한 값(내 정보·오늘 날짜로 짝지은 것). 없으면 nil
    func suggestion(for blank: DocumentBlank) -> String? {
        guard blank.kind != .signature else { return nil }
        return FormFiller.matchByLabel([blank.field], profile: profile)[blank.id]
    }

    // MARK: 내 정보로 자동 채우기

    /// 단추에서: 일을 시작한다(그만두기 단추가 이 일을 멈추게 세션의 assistantTask에 둔다)
    func fillFromProfile() {
        guard let session, !busy else { return }
        session.assistantTask = Task { @MainActor [weak self] in
            _ = await self?.autoFill()
            self?.session?.assistantTask = nil
        }
    }

    /// 빈칸 찾기 → 칸 이름으로 짝짓기 → 못 채운 칸은 AI → 타자 효과로 한 번에(⌘Z 한 번)
    @discardableResult
    func autoFill(animated: Bool = true, useAI: Bool = true) async -> DocumentFillReport? {
        guard let session, storage != nil else { return nil }
        guard !busy, !session.assistantPhase.busy else {
            announce(L("지금 다른 일을 하는 중이에요. 끝나면 다시 눌러 줘요", "Busy with something else. Try again when it finishes"))
            return nil
        }
        let found = scan()
        guard !found.isEmpty else { announce(Self.noBlanksText); return nil }
        if usesDisk { profile = ProfileStore.load() }
        guard !profile.filled.isEmpty else {
            announce(L("먼저 내 정보를 넣어줘요", "Add your info first"))
            editingProfile = true
            return nil
        }
        busy = true
        session.assistantReply = nil
        session.assistantPhase = .working(L("빈칸 \(found.count)개를 찾았어요 · 내 정보와 맞춰 보는 중…", "Found \(found.count) blanks · matching your info…"))
        defer {
            busy = false
            session.assistantPhase = .idle
        }

        let fields = found.map(\.field)
        var values = FormFiller.matchByLabel(fields, profile: profile)
        // 못 채운 글 칸만 AI에게(서명 칸은 제외)
        let rest = fields.filter { values[$0.id] == nil && $0.kind == .text }
        if useAI, !rest.isEmpty, let (agent, agents) = await session.assistantAgent() {
            session.assistantPhase = .working(L("AI가 남은 \(rest.count)칸에 알맞은 정보를 고르는 중…", "AI is picking values for \(rest.count) more blanks…"))
            do {
                var answer = ""
                for try await piece in AIClient.stream(system: FormFiller.system,
                                                       messages: [.user(FormFiller.prompt(fields: rest, profile: profile))],
                                                       agent: agent, apiKey: agent.isLocal ? nil : KeychainStore.key(for: agent.provider),
                                                       cloudEnabled: agents.cloudEnabled, json: true, temperature: 0.1) {
                    answer += piece
                }
                values.merge(FormFiller.parse(answer, fields: rest)) { _, fromAI in fromAI }
            } catch is CancellationError {
                var report = DocumentFillReport(found: found.count)
                report.cancelled = true
                announce(report.summary)
                return report
            } catch let error as URLError where error.code == .cancelled {
                var report = DocumentFillReport(found: found.count)
                report.cancelled = true
                announce(report.summary)
                return report
            } catch {
                if !Task.isCancelled { session.aiError = DocumentSession.explain(error, agent: agent) }
            }
        }
        if Task.isCancelled {
            var report = DocumentFillReport(found: found.count)
            report.cancelled = true
            announce(report.summary)
            return report
        }

        // 다시 읽어서(AI를 기다리는 동안 글이 바뀌었을 수 있다) 칸이 그대로인지 맞춰 본다
        let current = scan()
        let stillThere = current.filter { now in found.contains { $0.range == now.range && $0.original == now.original && $0.label == now.label } }
        let idByRange = Dictionary(uniqueKeysWithValues: found.map { ("\($0.range.location)-\($0.range.length)", $0.id) })
        var texts: [(DocumentBlank, String)] = []
        var signs: [DocumentBlank] = []
        var report = DocumentFillReport(found: stillThere.count)
        for blank in stillThere {
            let oldID = idByRange["\(blank.range.location)-\(blank.range.length)"] ?? blank.id
            if blank.kind == .signature {
                signs.append(blank)
            } else if let value = values[oldID], !value.isEmpty {
                texts.append((blank, value))
            } else {
                report.left += 1
                report.leftLabels.append(blank.label)
            }
        }
        let signature = signatures.first
        if signature == nil { report.needSignature = signs.count; signs = [] }
        session.assistantPhase = .working(L("빈칸을 채우는 중…", "Filling in…"))
        let result = await perform(texts: texts, signs: signs, signature: signature, animated: animated)
        report.filled = result.filled
        report.signed = result.signed
        report.left += texts.count - result.filled
        report.cancelled = result.cancelled
        announce(report.summary)
        return report
    }

    // MARK: 수동으로 한 칸

    /// 빈칸 목록에서 고른 칸 하나를 값으로 채운다. 채웠으면 true
    @discardableResult
    func fillOne(_ blank: DocumentBlank, with value: String, animated: Bool = true) async -> Bool {
        guard !busy else { return false }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, blank.kind != .signature else { return false }
        busy = true
        defer { busy = false }
        let result = await perform(texts: [(blank, text)], signs: [], signature: nil, animated: animated)
        if result.filled > 0 {
            announce(L("‘\(blank.label)’ 칸을 채웠어요", "Filled “\(blank.label)”"))
            blanks = scan()
            return true
        }
        announce(L("그 사이 글이 바뀌어서 못 채웠어요. 목록을 다시 불러왔어요", "The text changed, so it wasn't filled. Reloaded the list"))
        blanks = scan()
        return false
    }

    // MARK: 채우는 일(한 덩어리 = ⌘Z 한 번)

    /// 글 칸들에 타자 효과로 값을 넣고, 서명 칸에는 서명 그림을 넣는다. 모든 고침은 같은 되돌리기 묶음.
    /// 앞(글 위치가 작은 칸)에서부터 차례로 하면서, 앞 고침이 만든 길이 차이만큼 뒤 칸 자리를 밀어 준다.
    func perform(texts: [(DocumentBlank, String)], signs: [DocumentBlank], signature: Signature?, animated: Bool)
        async -> (filled: Int, signed: Int, cancelled: Bool) {
        guard let editor, let tv = editor.textView, let storage = tv.textStorage else { return (0, 0, false) }
        enum Job { case text(DocumentBlank, String), sign(DocumentBlank) }
        var jobs: [(Int, Job)] = texts.map { ($0.0.range.location, Job.text($0.0, $0.1)) }
        if signature != nil { jobs += signs.map { ($0.range.location, Job.sign($0)) } }
        jobs.sort { $0.0 < $1.0 }
        guard !jobs.isEmpty else { return (0, 0, false) }

        let undo = editor.undo
        let groupsByEvent = undo.groupsByEvent
        undo.groupsByEvent = false             // 시간이 걸리는 채우기가 이벤트마다 끊겨 여러 번의 ⌘Z로 갈라지지 않게
        undo.beginUndoGrouping()
        var edits: [(at: Int, delta: Int)] = []
        func shift(_ location: Int) -> Int { edits.filter { $0.at <= location }.reduce(0) { $0 + $1.delta } }
        var flashRanges: [NSRange] = []
        var filled = 0, signed = 0
        var cancelled = false

        for (_, job) in jobs {
            if Task.isCancelled { cancelled = true; break }
            switch job {
            case .text(let blank, let value):
                let start = blank.range.location + shift(blank.range.location)
                var range = NSRange(location: start, length: blank.range.length)
                guard NSMaxRange(range) <= storage.length, storage.attributedSubstring(from: range).string == blank.original else { continue }
                let ns = storage.string as NSString
                var prefix = ""
                if blank.site != .tableCell, blank.site != .parentheses, range.location > 0 {
                    let previous = ns.character(at: range.location - 1)
                    let space = previous == 0x20 || previous == 0x09 || previous == 0xA0 || previous == 0x3000 || previous == 0x0A
                    if !space { prefix = " " }
                }
                let full = prefix + value + blank.suffix
                let attributes = Self.typingAttributes(in: storage, at: range.location, fallback: tv.typingAttributes)
                let steps = animated ? max(1, min(value.count, 10)) : 1
                var typedLength = 0
                var aborted = false
                for k in 1...steps {
                    let count = Int((Double(value.count) * Double(k) / Double(steps)).rounded(.up))
                    let partial = prefix + String(value.prefix(count)) + (k == steps ? blank.suffix : "")
                    // 사이에 사용자가 고쳤으면 그 칸은 거기서 멈춘다
                    guard NSMaxRange(range) <= storage.length else { aborted = true; break }
                    if k > 1, storage.attributedSubstring(from: range).string != lastPartial(prefix, value, steps, k - 1, blank.suffix) { aborted = true; break }
                    editor.replace(range, with: NSAttributedString(string: partial, attributes: attributes))
                    range = NSRange(location: range.location, length: (partial as NSString).length)
                    typedLength = range.length
                    if animated, k < steps {
                        tv.scrollRangeToVisible(range)
                        try? await Task.sleep(nanoseconds: 24_000_000)
                        if Task.isCancelled {
                            // 멈추는 중이어도 이 칸은 끝까지 쓴다(글이 반쯤 남지 않게)
                            let rest = NSAttributedString(string: full, attributes: attributes)
                            editor.replace(range, with: rest)
                            range = NSRange(location: range.location, length: rest.length)
                            typedLength = range.length
                            cancelled = true
                            break
                        }
                    }
                }
                guard !aborted, typedLength > 0 else { continue }
                edits.append((blank.range.location, range.length - blank.range.length))
                let valueRange = NSRange(location: range.location + (prefix as NSString).length, length: (value as NSString).length)
                flashRanges.append(valueRange)
                filled += 1
                if animated { tv.scrollRangeToVisible(range) }
                if cancelled { break }
            case .sign(let blank):
                guard let signature, let piece = signaturePiece(signature) else { continue }
                let location = blank.anchor + shift(blank.anchor)
                guard location <= storage.length else { continue }
                let ns = storage.string as NSString
                let atLineStart = location == 0 || ns.character(at: location - 1) == 10
                let prefix = atLineStart ? "" : "\n"
                let whole = NSMutableAttributedString(string: prefix, attributes: DocumentEditor.bodyAttributes())
                whole.append(piece)
                editor.replace(NSRange(location: location, length: 0), with: whole)
                edits.append((blank.anchor, whole.length))
                flashRanges.append(NSRange(location: location + (prefix as NSString).length, length: 1))
                signed += 1
                if animated { tv.scrollRangeToVisible(NSRange(location: location, length: 1)) }
            }
        }
        undo.endUndoGrouping()
        undo.groupsByEvent = groupsByEvent
        flash(flashRanges)
        return (filled, signed, cancelled)
    }

    /// k단계까지 썼을 때 칸에 들어 있어야 할 글
    private func lastPartial(_ prefix: String, _ value: String, _ steps: Int, _ k: Int, _ suffix: String) -> String {
        let count = Int((Double(value.count) * Double(k) / Double(steps)).rounded(.up))
        return prefix + String(value.prefix(count)) + (k == steps ? suffix : "")
    }

    /// 새 글이 물려받을 모양: 그 자리 글자 모양에서 그림·쪽 띠 표시만 뺀다
    static func typingAttributes(in storage: NSTextStorage, at location: Int, fallback: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any]
        if storage.length > 0 {
            attributes = storage.attributes(at: min(location, storage.length - 1), effectiveRange: nil)
        } else {
            attributes = fallback
        }
        attributes[.attachment] = nil
        attributes[.hanlabongPageBreak] = nil
        attributes[.link] = nil
        return attributes
    }

    // MARK: 채운 칸 잠깐 강조(저장되는 글이 아니라 화면에만 — 레이아웃 매니저의 임시 속성)

    private func flash(_ ranges: [NSRange]) {
        guard let layout = session?.editor.textView?.layoutManager, !ranges.isEmpty else { return }
        let color = accent.withAlphaComponent(0.42)
        let length = storage?.length ?? 0
        let valid = ranges.compactMap { range -> NSRange? in
            let r = NSIntersectionRange(range, NSRange(location: 0, length: length))
            return r.length > 0 ? r : nil
        }
        for range in valid { layout.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: range) }
        flashTask?.cancel()
        flashTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let layout = self?.session?.editor.textView?.layoutManager else { return }
            let total = self?.storage?.length ?? 0
            for range in valid {
                let r = NSIntersectionRange(range, NSRange(location: 0, length: total))
                if r.length > 0 { layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: r) }
            }
        }
    }

    /// 테스트·화면 정리용: 강조를 바로 거둔다
    func clearFlash() {
        flashTask?.cancel()
        guard let layout = session?.editor.textView?.layoutManager, let total = storage?.length, total > 0 else { return }
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: total))
    }
}

// MARK: - 빈칸 목록 시트(수동 채우기)

/// 빈칸 목록: 하나를 고르면 값을 직접 쓰거나 내 정보 항목을 눌러 넣을 수 있다. 서명 칸은 서명 시트로 이어진다.
struct DocumentBlankListSheet: View {
    @ObservedObject var fill: DocumentFillModel
    let close: () -> Void
    @State private var selectedID: String?
    @State private var value = ""

    private var selected: DocumentBlank? { fill.blanks.first { $0.id == selectedID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("빈칸 목록", "Blanks")).font(.title3.bold())
                Spacer()
                Text(L("\(fill.blanks.count)칸", "\(fill.blanks.count) blanks")).font(.caption).foregroundStyle(.secondary)
            }
            Text(L("고르면 값을 직접 쓰거나 내 정보에서 골라 넣을 수 있어요. 채운 칸은 ⌘Z로 되돌려요.", "Pick one to type a value or choose from your info. ⌘Z undoes a fill."))
                .font(.caption).foregroundStyle(.secondary)
            if fill.blanks.isEmpty {
                Text(DocumentFillModel.noBlanksText).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(fill.blanks) { blank in row(blank) }
                    }
                }
                .frame(height: 220)
            }
            if let blank = selected { editor(blank) }
            HStack {
                Button { close(); fill.afterSheetClosed { fill.beginEditingProfile() } } label: { Label(L("내 정보 편집…", "Edit my info…"), systemImage: "person.text.rectangle") }
                Spacer()
                Button(L("닫기", "Close"), action: close).keyboardShortcut(.cancelAction)
                Button(L("내 정보로 모두 채우기", "Fill all")) { close(); fill.fillFromProfile() }
                    .buttonStyle(.borderedProminent).disabled(fill.blanks.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private func symbol(_ blank: DocumentBlank) -> String {
        switch blank.kind {
        case .signature: return "signature"
        case .year, .month, .day: return "calendar"
        case .text: return "character.cursor.ibeam"
        }
    }

    private func row(_ blank: DocumentBlank) -> some View {
        Button { select(blank) } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol(blank)).frame(width: 20).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(blank.label.isEmpty ? L("(이름 없는 칸)", "(unnamed)") : blank.label).font(.callout.weight(.semibold))
                    Text(blank.context).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(blank.id == selectedID ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func select(_ blank: DocumentBlank) {
        selectedID = blank.id
        value = fill.suggestion(for: blank) ?? ""
    }

    @ViewBuilder private func editor(_ blank: DocumentBlank) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            if blank.kind == .signature {
                Text(L("‘\(blank.label)’은 서명 칸이에요. 저장해 둔 서명을 고르거나 새로 써서 넣어요.", "“\(blank.label)” is a signature blank. Pick a saved signature or draw a new one."))
                    .font(.callout)
                Button { close(); fill.afterSheetClosed { fill.beginSigning(target: blank) } } label: { Label(L("서명 넣기…", "Add signature…"), systemImage: "signature") }
            } else {
                Text(L("‘\(blank.label)’에 넣을 값", "Value for “\(blank.label)”")).font(.callout.weight(.semibold))
                TextField(L("값", "Value"), text: $value).textFieldStyle(.roundedBorder).onSubmit { apply(blank) }
                if !fill.profile.filled.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(fill.profile.filled) { entry in
                                Button { value = entry.value } label: { Text("\(entry.key) · \(entry.value)").lineLimit(1) }
                                    .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                } else {
                    Text(L("내 정보가 비어 있어요. 아래 ‘내 정보 편집…’에서 넣어 두면 골라 쓸 수 있어요.", "Your info is empty. Add it with “Edit my info…” below."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button(L("채우기", "Fill")) { apply(blank) }
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                        .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || fill.busy)
                }
            }
        }
    }

    private func apply(_ blank: DocumentBlank) {
        let text = value
        Task { @MainActor in
            if await fill.fillOne(blank, with: text) {
                selectedID = nil
                value = ""
                if fill.blanks.isEmpty { close() }
            }
        }
    }
}
