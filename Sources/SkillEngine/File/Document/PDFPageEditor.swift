import AppKit
import Foundation
import PDFKit

/// PDF 쪽 편집(미리보기 앱의 쪽 다루기와 같은 수준): 쪽을 골라 순서대로 새 PDF에 담는다.
/// 쪽은 그림으로 바꾸지 않고 그대로 옮겨서 글자 선택·검색·링크가 살아 있다.
public enum PDFPageEditor {
    /// 끼워 넣을 수 있는 파일: PDF 또는 사진(사진은 한 쪽짜리 PDF로)
    public static func openExtra(_ url: URL) throws -> PDFDocument {
        if let document = PDFDocument(url: url), document.pageCount > 0 {
            if document.isLocked { throw FileSkillError.encryptedPDF(url.lastPathComponent) }
            return document
        }
        guard let image = NSImage(contentsOf: url), let page = PDFPage(image: image) else { throw FileSkillError.unreadable(url.lastPathComponent) }
        let document = PDFDocument()
        document.insert(page, at: 0)
        return document
    }

    public static func make(_ source: PDFDocument, edit: PDFPageEdit) throws -> Data {
        let extras = try edit.extraFiles.map { try openExtra(URL(fileURLWithPath: $0)) }
        let files = [source] + extras
        guard !edit.pages.isEmpty else { throw FileSkillError.invalidSkill(L("남은 쪽이 없어요", "No pages left")) }
        let output = PDFDocument()
        for (position, ref) in edit.pages.enumerated() {
            guard files.indices.contains(ref.file), let original = files[ref.file].page(at: ref.index),
                  let page = original.copy() as? PDFPage else {
                throw FileSkillError.invalidSkill(L("없는 쪽이에요", "Page not found"))
            }
            page.rotation = ((original.rotation + ref.rotation) % 360 + 360) % 360
            output.insert(page, at: position)
        }
        if let attributes = source.documentAttributes { output.documentAttributes = attributes }
        guard let data = output.dataRepresentation() else { throw FileSkillError.encodeFailed("PDF") }
        return data
    }
}
