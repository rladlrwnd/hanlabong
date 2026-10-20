import CoreGraphics
import SkillEngine
import Testing
@testable import FileFeature

/// 2단계 휠: 1단계 칸 위에 커서가 오면 자식 링이 펼쳐지고, 자식 칸에 놓았을 때만 스킬이 실행된다.
struct WheelNavigationTests {
    private let geometry = WheelGeometry()
    private func offset(_ degrees: Double, _ radius: CGFloat) -> CGPoint {
        let r = degrees * .pi / 180
        return CGPoint(x: radius * CGFloat(sin(r)), y: radius * CGFloat(cos(r)))
    }

    // MARK: 2단계 기하

    @Test func childrenFanOutAroundTheirParent() {
        // 부모가 12시(0번 칸)면 자식 3개는 12시를 가운데로 좌우 대칭
        let a0 = geometry.childAngles(parentSlot: 0, index: 0, count: 3)
        let a1 = geometry.childAngles(parentSlot: 0, index: 1, count: 3)
        let a2 = geometry.childAngles(parentSlot: 0, index: 2, count: 3)
        #expect(abs((a1.start + a1.end) / 2) < 1e-9)
        #expect(abs((a0.start + a0.end) / 2 + (a2.start + a2.end) / 2) < 1e-9)
        #expect(a0.end < a1.start && a1.end < a2.start)                       // 서로 안 겹치고 빈틈이 있다
        // 부모가 3시(2번 칸)면 가운데 자식이 3시
        let right = geometry.childAngles(parentSlot: 2, index: 1, count: 3)
        #expect(abs((right.start + right.end) / 2 - 90) < 1e-9)
    }

    @Test func hitPrefersChildRingWhenExpanded() {
        #expect(geometry.hit(at: offset(0, 100), expandedParent: nil, childCount: 0) == .slot(0))
        #expect(geometry.hit(at: offset(0, 190), expandedParent: 0, childCount: 3) == .child(parent: 0, index: 1))
        #expect(geometry.hit(at: offset(-43, 190), expandedParent: 0, childCount: 3) == .child(parent: 0, index: 0))
        #expect(geometry.hit(at: offset(43, 190), expandedParent: 0, childCount: 3) == .child(parent: 0, index: 2))
        #expect(geometry.hit(at: offset(0, 190), expandedParent: nil, childCount: 0) == nil)   // 안 펼쳐졌으면 바깥은 빈 곳
        #expect(geometry.hit(at: offset(90, 190), expandedParent: 0, childCount: 3) == nil)     // 자식 링 밖의 방향
        #expect(geometry.hit(at: offset(0, 145), expandedParent: 0, childCount: 3) == nil)      // 두 링 사이의 틈
        #expect(geometry.hit(at: offset(0, 230), expandedParent: 0, childCount: 3) == nil)      // 바깥
    }

    @Test func childRingWrapsAroundTwelveOClock() {
        // 11시 방향 칸(7번)의 자식도 12시를 넘어가는 각도에서 제대로 찾아진다
        #expect(geometry.hit(at: offset(-45, 190), expandedParent: 7, childCount: 3) == .child(parent: 7, index: 1))
        #expect(geometry.hit(at: offset(-2, 190), expandedParent: 7, childCount: 3) == .child(parent: 7, index: 2))
    }

    // MARK: 따라가기

    private func navigator() -> WheelNavigator { WheelNavigator(layout: .image()) }

    @Test func hoveringJpgOpensPresetsAndOnlyAPresetIsDroppable() {
        var nav = navigator()
        nav.move(to: offset(0, 100))                                   // JPG 칸
        #expect(nav.expandedParent == 0)
        #expect(nav.hoveredItem?.id == "jpg")
        #expect(nav.droppable == nil)                                  // 부모 칸에는 놓을 수 없다
        nav.move(to: offset(0, 190))                                   // 가운데 프리셋
        #expect(nav.droppable?.skill == DefaultFileSkills.clientSample)
        nav.move(to: offset(-43, 190))
        #expect(nav.droppable?.skill == DefaultFileSkills.web)
        nav.move(to: offset(43, 190))
        #expect(nav.droppable?.skill == DefaultFileSkills.preview)
    }

    @Test func expansionSticksThroughGapsAndFoldsWhenMovingToAnotherSlot() {
        var nav = navigator()
        nav.move(to: offset(0, 100))
        nav.move(to: offset(22.5, 100))                                // 칸 사이 빈틈을 지나가도
        #expect(nav.expandedParent == 0)
        nav.move(to: offset(0, 145))                                   // 두 링 사이를 지나가도
        #expect(nav.expandedParent == 0)
        nav.move(to: .zero)                                            // 가운데 원으로 돌아오면 접힌다
        #expect(nav.expandedParent == nil)
        nav.move(to: offset(0, 100))
        #expect(nav.expandedParent == 0)
        nav.move(to: offset(45, 100))                                  // 1번 칸(PDF)으로 옮기면 그 칸이 펼쳐진다
        #expect(nav.expandedParent == 1)
        nav.move(to: offset(225, 100))                                 // 빈 칸 위로 가면 접힌다
        #expect(nav.expandedParent == nil)
        #expect(nav.droppable == nil)                                  // 준비 안 된 칸에는 놓을 수 없다
    }

    @Test func comingSoonAndEmptySlotsNeverAcceptFiles() {
        var nav = navigator()
        for degrees in [45.0, 90, 180, 225, 270, 315] {                // PDF·TXT 묶음(부모 칸)과 빈 칸들
            nav.move(to: offset(degrees, 100))
            #expect(nav.droppable == nil, "\(degrees)도 칸에 놓을 수 있게 됐어요")
        }
    }

    @Test func leavingClearsTheHoverButNotTheLayout() {
        var nav = navigator()
        nav.move(to: offset(0, 190))
        nav.leave()
        #expect(nav.hover == nil && nav.droppable == nil)
    }

    // MARK: 입력 종류에 따른 휠

    @Test func layoutDependsOnDraggedFileExtensions() {
        #expect(WheelLayout.layout(forDraggedFileExtensions: ["JPG", "png"]) == .image())
        #expect(WheelLayout.layout(forDraggedFileExtensions: ["RAF"]) == .image())                // RAW
        #expect(WheelLayout.layout(forDraggedFileExtensions: ["pdf"]) == .pdf())
        #expect(WheelLayout.layout(forDraggedFileExtensions: ["PDF", "pdf"]) == .pdf())
        #expect(WheelLayout.layout(forDraggedFileExtensions: ["zip", "mp3"]) == .unsupported)
        #expect(WheelLayout.layout(forDraggedFileExtensions: ["pdf", "jpg"]) == .image())         // 섞이면 사진 휠(PDF는 그 스킬 대상이 아니라 실패로 알린다)
        #expect(WheelLayout.layout(forDraggedFileExtensions: []) == .image())                     // 확장자를 못 읽었을 때 기본 휠
    }

    @Test func unsupportedWheelHasNoDropTargetsAndExplainsWhy() {
        var nav = WheelNavigator(layout: .unsupported)
        for degrees in stride(from: 0.0, to: 360, by: 15) {
            nav.move(to: offset(degrees, 100))
            #expect(nav.droppable == nil)
        }
        #expect(WheelLayout.unsupported.emptyMessage != nil)
    }

    @Test func photoPdfAndTxtSlotsOpenTheirOcrChoices() {
        var nav = navigator()
        nav.move(to: offset(45, 100))                                  // PDF 칸
        nav.move(to: offset(45 - 64.5, 190))
        #expect(nav.droppable?.skill == DefaultFileSkills.imageToPlainPDF)
        nav.move(to: offset(45 - 21.5, 190))
        #expect(nav.droppable?.skill == DefaultFileSkills.imageToSearchablePDF)
        nav.move(to: offset(45 + 21.5, 190))
        #expect(nav.droppable?.skill == DefaultFileSkills.vectorPDF)       // 벡터 재구성(로고·선화)
        nav.move(to: offset(45 + 64.5, 190))
        #expect(nav.droppable?.skill == DefaultFileSkills.vectorSVG)

        nav.move(to: offset(90, 100))                                  // TXT 칸: 자식 2개는 3시를 가운데로 양옆
        #expect(nav.expandedParent == 2)
        nav.move(to: offset(90 - 21.5, 190))
        #expect(nav.droppable?.skill == DefaultFileSkills.imageToText)
        nav.move(to: offset(90 + 21.5, 190))
        #expect(nav.hoveredItem?.id == "ocr-ai" && nav.droppable == nil)   // AI 오타수정은 7단계
    }

    @Test func aiTypoFixIsDroppableOnlyWhenAnAIIsAvailableAndSaysWhereItRuns() {
        var locked = WheelNavigator(layout: .image())
        locked.move(to: offset(90, 100))
        locked.move(to: offset(90 + 21.5, 190))
        #expect(locked.hoveredItem?.id == "ocr-ai" && locked.droppable == nil)
        #expect(locked.hoveredItem?.subtitle?.contains("AI가 없어요") == true)

        var local = WheelNavigator(layout: .image(ai: AIDestination(name: "qwen3.6:27b", isCloud: false)))
        local.move(to: offset(90, 100))
        local.move(to: offset(90 + 21.5, 190))
        #expect(local.droppable?.aiTask == .ocrTypoFix)
        #expect(local.droppable?.subtitle?.contains("이 컴퓨터") == true)

        let cloud = WheelLayout.image(ai: AIDestination(name: "Claude", isCloud: true)).slots[2]?.children[1]
        #expect(cloud?.subtitle?.contains("클라우드로 보냄") == true)          // 파일 내용이 밖으로 나간다는 걸 놓기 전에 보여준다
    }

    @Test func pdfWheelDropsStraightOnWordAndText() {
        var nav = WheelNavigator(layout: .pdf())
        nav.move(to: offset(0, 100))
        #expect(nav.droppable?.skill == DefaultFileSkills.pdfToWord)
        #expect(nav.expandedParent == nil)                                   // 2단계 없이 바로 놓는다
        nav.move(to: offset(45, 100))
        #expect(nav.expandedParent == 1)                                     // 텍스트 묶음(TXT·MD)
        #expect(WheelLayout.pdf().slots[1]?.children.compactMap(\.skill) == [DefaultFileSkills.pdfToPlainText, DefaultFileSkills.toDocument(.md)])
        nav.move(to: offset(135, 100))
        #expect(nav.droppable?.skill == DefaultFileSkills.pdfToPPTX)
        nav.move(to: offset(315, 100))
        #expect(nav.droppable?.skill == DefaultFileSkills.toDocument(.hwpx))  // 한글(.hwpx)
    }

    @Test func everyPresetOnTheWheelIsAValidSkillForPhotos() throws {
        guard let jpg = WheelLayout.image().slots[0] else { Issue.record("JPG 칸이 없어요"); return }
        #expect(jpg.children.count == 3)
        for child in jpg.children {
            let skill = try #require(child.skill)
            try skill.validate()
            #expect(skill.input.contains(.image) && skill.input.contains(.raw))
            #expect(!child.title.isEmpty && !(child.subtitle ?? "").isEmpty)
        }
    }
}
