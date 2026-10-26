import Foundation
import SkillEngine
import Testing
@testable import FileFeature

/// PDF 편집 창의 쪽 다루기(화면 없이)
struct PDFPageDraftTests {
    private func indexes(_ draft: PDFPageDraft) -> [String] { draft.items.map { "\($0.file):\($0.index)" } }

    @Test func untouchedHasNoChanges() {
        #expect(!PDFPageDraft(pageCount: 3).hasChanges)
    }

    @Test func moveSelectionBeforeAPage() {
        var draft = PDFPageDraft(pageCount: 5)
        let ids = draft.items.map(\.id)
        draft.move([ids[3], ids[4]], before: ids[1])
        #expect(indexes(draft) == ["0:0", "0:3", "0:4", "0:1", "0:2"])
        draft.move([ids[0]], before: nil)
        #expect(indexes(draft) == ["0:3", "0:4", "0:1", "0:2", "0:0"])
        #expect(draft.hasChanges)
    }

    @Test func movingOntoItselfDoesNothing() {
        var draft = PDFPageDraft(pageCount: 3)
        let ids = draft.items.map(\.id)
        draft.move([ids[1]], before: ids[1])
        #expect(!draft.hasChanges)
    }

    @Test func rotateDeleteInsertAndSave() {
        var draft = PDFPageDraft(pageCount: 3)
        let ids = draft.items.map(\.id)
        draft.rotate([ids[0]], clockwise: false)
        draft.delete([ids[2]])
        let added = draft.insert(path: "/x/extra.pdf", pageCount: 2, after: ids[0])
        #expect(indexes(draft) == ["0:0", "1:0", "1:1", "0:1"])
        #expect(draft.items[0].rotation == 270)
        guard case .pdfPages(let edit) = draft.skill().steps.last else { Issue.record("no pdfPages"); return }
        #expect(edit.extraFiles == ["/x/extra.pdf"])
        #expect(edit.pages.map(\.rotation) == [270, 0, 0, 0])
        #expect(draft.skill().output.suffix == "_merged")   // 다른 파일을 끼우면 합친 결과
        // 고른 쪽만 저장: 지금 순서대로
        guard case .pdfPages(let only) = draft.skill(only: Set(added)).steps.last else { Issue.record("no pdfPages"); return }
        #expect(only.pages.map(\.file) == [1, 1])
        #expect(draft.skill(only: Set(added)).output.suffix == "_pages")
        #expect((try? draft.skill().validate()) != nil)
    }
}

/// 사진 편집 창: 수평 맞추기와 저장 크기가 스킬에 제 순서로 들어가는지
struct ImageEditExtrasTests {
    @Test func straightenAndSizeGoIntoTheSkill() {
        var draft = ImageEditDraft(sourceSize: CGSize(width: 400, height: 300), sourceExtension: "jpg")
        #expect(!draft.hasChanges)
        draft.rotate(clockwise: true)
        draft.straighten = 2.5
        draft.longEdge = 1080
        #expect(draft.hasChanges)
        let steps = draft.skill.steps
        let names = steps.map { step -> String in
            switch step {
            case .rotate: return "rotate"
            case .straighten: return "straighten"
            case .resize: return "resize"
            case .encode: return "encode"
            default: return "-"
            }
        }.filter { $0 != "-" }
        #expect(names == ["rotate", "straighten", "resize", "encode"])
        #expect(steps.contains(.straighten(degrees: 2.5)) && steps.contains(.resize(.longEdge(1080))))
    }
}

/// 여러 개를 끌면 도구 휠 맨 앞에 "합치기"
struct MergeSlotTests {
    private func ids(_ layout: WheelLayout) -> [String] { layout.slots.compactMap { $0?.id } }

    @Test func severalPDFsOrPhotosOfferMerge() {
        #expect(ids(WheelLayout.tools(forDraggedFileExtensions: ["pdf", "pdf"])).first == "pmerge")
        #expect(ids(WheelLayout.tools(forDraggedFileExtensions: ["pdf", "jpg"])).first == "pmerge")
        #expect(ids(WheelLayout.tools(forDraggedFileExtensions: ["jpg", "png", "heic"])).first == "pmerge")
    }

    @Test func singleFileOrOtherKindsDoNot() {
        #expect(ids(WheelLayout.tools(forDraggedFileExtensions: ["pdf"])).first == "pedit")
        #expect(ids(WheelLayout.tools(forDraggedFileExtensions: ["jpg"])).first == "crop")
        #expect(!ids(WheelLayout.tools(forDraggedFileExtensions: ["pdf", "mov"])).contains("pmerge"))
        #expect(!ids(WheelLayout.tools(forDraggedFileExtensions: ["raf", "raf"])).contains("pmerge"))
    }
}
