import Foundation
import SkillEngine

/// PDF 편집 창이 만드는 스킬의 재료(화면과 분리해서 테스트한다).
/// 쪽마다 고유 번호를 붙여 두고, 순서 바꾸기·돌리기·지우기·끼워 넣기를 번호로 한다.
package struct PDFPageDraft: Equatable {
    package struct Item: Identifiable, Equatable, Hashable {
        package let id: UUID
        /// 0 = 원본, 1부터 = 끼워 넣은 파일 순번
        package let file: Int
        package let index: Int
        package var rotation: Int

        package init(file: Int, index: Int, rotation: Int = 0) {
            id = UUID(); self.file = file; self.index = index; self.rotation = rotation
        }
    }

    package private(set) var items: [Item]
    package private(set) var extraFiles: [String] = []
    private let originalCount: Int

    package init(pageCount: Int) {
        originalCount = pageCount
        items = (0..<pageCount).map { Item(file: 0, index: $0) }
    }

    package var hasChanges: Bool {
        !extraFiles.isEmpty || items.count != originalCount
            || items.enumerated().contains { $0.element.file != 0 || $0.element.index != $0.offset || $0.element.rotation != 0 }
    }

    /// 고른 쪽들을 `target` 쪽 앞으로(target이 nil이면 맨 뒤로). 고른 쪽끼리의 순서는 그대로.
    package mutating func move(_ ids: Set<UUID>, before target: UUID?) {
        guard !ids.isEmpty, target.map({ !ids.contains($0) }) ?? true else { return }
        let moving = items.filter { ids.contains($0.id) }
        items.removeAll { ids.contains($0.id) }
        let position = target.flatMap { t in items.firstIndex { $0.id == t } } ?? items.count
        items.insert(contentsOf: moving, at: position)
    }

    package mutating func rotate(_ ids: Set<UUID>, clockwise: Bool) {
        for i in items.indices where ids.contains(items[i].id) {
            items[i].rotation = (items[i].rotation + (clockwise ? 90 : 270)) % 360
        }
    }

    package mutating func delete(_ ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) }
    }

    /// 다른 파일의 쪽을 `after` 쪽 뒤에(nil이면 맨 뒤에) 끼워 넣는다. 새로 들어간 쪽 번호를 돌려준다.
    @discardableResult
    package mutating func insert(path: String, pageCount: Int, after: UUID?) -> [UUID] {
        extraFiles.append(path)
        let file = extraFiles.count
        let new = (0..<pageCount).map { Item(file: file, index: $0) }
        let position = after.flatMap { a in items.firstIndex { $0.id == a }.map { $0 + 1 } } ?? items.count
        items.insert(contentsOf: new, at: position)
        return new.map(\.id)
    }

    /// 저장할 스킬. `only`가 있으면 그 쪽들만(지금 순서대로) 새 PDF로.
    package func skill(only: Set<UUID>? = nil) -> FileSkill {
        let chosen = only.map { ids in items.filter { ids.contains($0.id) } } ?? items
        let edit = PDFPageEdit(pages: chosen.map { PDFPageEdit.Page(file: $0.file, index: $0.index, rotation: $0.rotation) }, extraFiles: extraFiles)
        // 원본은 PDF가 아니어도 된다(사진 여러 장을 PDF 하나로 합칠 때 첫 사진이 원본)
        let suffix = only != nil ? "_pages" : (extraFiles.isEmpty ? "_edit" : "_merged")
        return FileSkill(id: "pdf-edit", name: L("PDF 편집", "Edit PDF"), symbol: "doc.on.doc", input: [.pdf, .image], steps: [.pdfPages(edit)],
                         output: FileOutput(suffix: suffix))
    }
}
