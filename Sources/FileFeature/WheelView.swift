import AppCore
import SkillEngine
import SwiftUI
import ThinkingOrbsKit

/// 휠 화면 상태: 어느 칸이 눌려 있고 어느 칸이 펼쳐졌는지(`navigator`), 놓은 뒤 처리 진행 상황(`phase`).
@MainActor
package final class WheelModel: ObservableObject {
    package enum Phase: Equatable {
        case choosing
        case working(done: Int, total: Int)
        case finished(succeeded: Int, failed: Int)
    }

    @Published var navigator: WheelNavigator
    @Published var isShown = false
    @Published var phase: Phase = .choosing
    /// 파일을 놓은 칸(처리하는 동안 계속 강조한다)
    @Published var committed: WheelGeometry.Hit?
    /// AI가 끼는 작업이면 가운데에 생각 구슬을 띄운다(움직이는 효과는 AI가 일할 때만)
    @Published var aiWorking = false

    package init(layout: WheelLayout) {
        navigator = WheelNavigator(layout: layout)
    }

    var geometry: WheelGeometry { navigator.geometry }

    func setLayout(_ layout: WheelLayout) {
        navigator = WheelNavigator(layout: layout)
        phase = .choosing
        committed = nil
        aiWorking = false
    }

    /// 드래그 중인 커서가 움직일 때. 값이 바뀔 때만 화면을 다시 그리게 한다.
    @discardableResult
    func pointerMoved(to offset: CGPoint) -> WheelItem? {
        var next = navigator
        next.move(to: offset)
        if next != navigator {
            if next.hoveredItem?.id != navigator.hoveredItem?.id {
                // 칸을 옮길 때마다 트랙패드에 짧은 진동(포스 터치 트랙패드에서만 느껴진다)
                if next.hoveredItem != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
                log.info("wheel hover: \(next.hoveredItem?.id ?? "-", privacy: .public) droppable=\(next.droppable != nil, privacy: .public)")
            }
            navigator = next
        }
        return navigator.droppable
    }

    func pointerLeft() {
        var next = navigator
        next.leave()
        if next != navigator { navigator = next }
    }
}

/// 꽃잎 한 장: 안쪽 반지름~바깥 반지름, 시작~끝 각도(12시 기준, 시계 방향)로 이루어진 부채꼴 조각. 네 모서리는 둥글게 깎는다.
/// 호는 점을 촘촘히 찍어서 그린다(SwiftUI의 addArc는 방향이 뒤집혀 헷갈리기 쉽다).
struct PetalShape: Shape {
    let inner: CGFloat
    let outer: CGFloat
    let startDegrees: Double
    let endDegrees: Double
    var cornerRadius: CGFloat = 11

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        func point(_ radius: CGFloat, _ degrees: Double) -> CGPoint {
            let radians = degrees * .pi / 180
            return CGPoint(x: center.x + radius * CGFloat(sin(radians)), y: center.y - radius * CGFloat(cos(radians)))
        }
        func arc(_ path: inout Path, radius: CGFloat, from: Double, to: Double) {
            let steps = max(2, Int(abs(to - from) / 1.5))
            for i in 1...steps { path.addLine(to: point(radius, from + (to - from) * Double(i) / Double(steps))) }
        }
        // 모서리 반지름이 꽃잎보다 커지지 않게 (안쪽 호가 가장 짧다)
        let sweep = (endDegrees - startDegrees) * .pi / 180
        let r = max(0, min(cornerRadius, (outer - inner) / 2 - 1, inner * CGFloat(sweep) / 2 - 1))
        let degreesOuter = Double(r / outer) * 180 / .pi   // 모서리 반지름만큼의 호 각도
        let degreesInner = Double(r / inner) * 180 / .pi
        let s = startDegrees, e = endDegrees

        var path = Path()
        path.move(to: point(outer, s + degreesOuter))
        arc(&path, radius: outer, from: s + degreesOuter, to: e - degreesOuter)
        path.addQuadCurve(to: point(outer - r, e), control: point(outer, e))
        path.addLine(to: point(inner + r, e))
        path.addQuadCurve(to: point(inner, e - degreesInner), control: point(inner, e))
        arc(&path, radius: inner, from: e - degreesInner, to: s + degreesInner)
        path.addQuadCurve(to: point(inner + r, s), control: point(inner, s))
        path.addLine(to: point(outer - r, s))
        path.addQuadCurve(to: point(outer, s + degreesOuter), control: point(outer, s))
        path.closeSubpath()
        return path
    }
}

/// 꽃잎형 링 + 가운데 원. Prism과 같은 유리 질감이고, 설정의 흐림·틴트·밝기 슬라이더가 그대로 적용된다.
/// 1단계 칸 위에 커서가 오면 그 칸의 2단계 링이 바깥쪽으로 펼쳐진다.
struct WheelView: View {
    @ObservedObject var model: WheelModel
    /// 화면에 그리고 있는 2단계 링(접힐 때 사라지는 모션이 끝날 때까지 남겨 둔다)
    @State private var shownParent: Int?
    @State private var ringVisible = false

    var body: some View {
        let g = model.geometry
        let navigator = model.navigator
        ZStack {
        WheelDisk(radius: g.outerRadius + 14)
        GlassEffectContainer(spacing: 0) {
            ZStack {
                ForEach(0..<g.slotCount, id: \.self) { slot in
                    firstRingPetal(slot, geometry: g, navigator: navigator)
                }
                center(geometry: g, navigator: navigator)
            }
            .frame(width: g.side, height: g.side)
        }
        // 2단계 링은 따로 된 유리 묶음. 유리 조각 하나하나를 움직이면 유리가 엉뚱한 곳(우측 하단)에서 자라 나오니,
        // 묶음 전체를 휠 가운데 기준으로 키우고 흐리게 한다(휠 전체가 뜰 때와 같은 방식).
        GlassEffectContainer(spacing: 0) {
            ZStack {
                if let parent = shownParent, let item = navigator.layout.slots[parent] {
                    ForEach(Array(item.children.enumerated()), id: \.element.id) { index, child in
                        childPetal(parent: parent, index: index, count: item.children.count, item: child, geometry: g)
                    }
                }
            }
            .frame(width: g.side, height: g.side)
        }
        .scaleEffect(ringVisible ? 1 : 0.84, anchor: .center)
        .opacity(ringVisible ? 1 : 0)
        .allowsHitTesting(false)
        }
        .onChange(of: navigator.expandedParent) { _, parent in showRing(parent) }
        .onChange(of: model.isShown) { _, shown in
            if !shown { shownParent = nil; ringVisible = false }
        }
        .frame(width: g.side, height: g.side)
        // 키 창이 아니어도 활성 창처럼 그린다(비활성 창이면 유리가 흐린 배경으로 바뀐다)
        .environment(\.controlActiveState, .key)
        .scaleEffect(model.isShown ? 1 : 0.94)
        .opacity(model.isShown ? 1 : 0)
        .animation(model.isShown ? .spring(response: 0.4, dampingFraction: 0.86) : .easeInOut(duration: 0.2), value: model.isShown)
    }

    private func showRing(_ parent: Int?) {
        if let parent {
            if shownParent != nil, shownParent != parent {
                // 다른 묶음으로 옮겨가면: 내용을 바로 바꾸고 다시 키운다
                var quiet = Transaction()
                quiet.disablesAnimations = true
                withTransaction(quiet) { ringVisible = false }
            }
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) { shownParent = parent }
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { ringVisible = true }
            }
        } else {
            withAnimation(.easeOut(duration: 0.18)) { ringVisible = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if model.navigator.expandedParent == nil { shownParent = nil }
            }
        }
    }

    // MARK: 칸

    private func firstRingPetal(_ slot: Int, geometry g: WheelGeometry, navigator: WheelNavigator) -> some View {
        let angles = g.angles(of: slot)
        let petal = PetalShape(inner: g.innerRadius, outer: g.outerRadius, startDegrees: angles.start, endDegrees: angles.end)
        let item = navigator.layout.slots[slot]
        let hovered = navigator.hover == .slot(slot)
        let highlight: Double = {
            guard let item else { return 0 }
            if model.committed == .slot(slot) { return 0.38 }
            if item.isDroppable { return hovered ? 0.38 : 0 }
            return (hovered && !item.children.isEmpty) || navigator.expandedParent == slot ? 0.22 : 0
        }()
        return petalContent(petal, highlight: highlight, size: g.side) {
            if let item {
                label(item, angle: Double(slot) * g.slotWidthDegrees, radius: (g.innerRadius + g.outerRadius) / 2, iconSize: 18, titleSize: 13)
            }
        }
    }

    private func childPetal(parent: Int, index: Int, count: Int, item: WheelItem, geometry g: WheelGeometry) -> some View {
        let angles = g.childAngles(parentSlot: parent, index: index, count: count)
        let petal = PetalShape(inner: g.childInnerRadius, outer: g.childOuterRadius, startDegrees: angles.start, endDegrees: angles.end)
        let hovered = model.navigator.hover == .child(parent: parent, index: index) || model.committed == .child(parent: parent, index: index)
        return petalContent(petal, highlight: hovered ? 0.38 : 0, size: g.side) {
            label(item, angle: (angles.start + angles.end) / 2, radius: (g.childInnerRadius + g.childOuterRadius) / 2, iconSize: 16, titleSize: 12)
        }
    }

    /// 꽃잎 한 장 = 유리 + 그 위의 내용(강조색, 아이콘, 이름). 팝업 카드와 같은 구조라 글씨가 유리 위에 또렷하게 얹힌다.
    private func petalContent<Label: View>(_ petal: PetalShape, highlight: Double, size: CGFloat, @ViewBuilder label: () -> Label) -> some View {
        ZStack {
            petal.fill(Color.accentColor.opacity(highlight)).animation(.easeOut(duration: 0.08), value: highlight)
            label()
        }
        .frame(width: size, height: size)
        .modifier(GlassFinish(shape: petal))
    }

    /// 칸 위의 아이콘 + 이름. 준비 안 된 칸은 흐리게.
    private func label(_ item: WheelItem, angle: Double, radius: CGFloat, iconSize: CGFloat, titleSize: CGFloat) -> some View {
        let radians = angle * .pi / 180
        return VStack(spacing: 2) {
            Image(systemName: item.symbol).font(.system(size: iconSize, weight: .medium))
            Text(item.title).font(.system(size: titleSize, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(item.isComingSoon ? .secondary : .primary)
        .offset(x: radius * CGFloat(sin(radians)), y: -radius * CGFloat(cos(radians)))
        .allowsHitTesting(false)
    }

    // MARK: 가운데 원

    private func center(geometry g: WheelGeometry, navigator: WheelNavigator) -> some View {
        let circle = Circle()
        return Group {
            switch model.phase {
            case .working where model.aiWorking:
                VStack(spacing: 0) {
                    ThinkingOrb(state: .composing, size: .px64, displaySize: 54)
                    Text(L("AI 확인 중", "AI checking")).font(.system(size: 9, weight: .medium)).opacity(0.85)
                }
            case .working(let done, let total):
                VStack(spacing: 3) {
                    ProgressView().controlSize(.small)
                    Text("\(done)/\(total)").font(.system(size: 11, weight: .medium)).monospacedDigit()
                }
            case .finished(let succeeded, let failed):
                VStack(spacing: 2) {
                    Image(systemName: failed == 0 ? "checkmark" : "exclamationmark.triangle").font(.system(size: 17, weight: .bold))
                    Text(failed == 0 ? L("\(succeeded)개", "\(succeeded) done") : L("\(succeeded)개 · 실패 \(failed)", "\(succeeded) · \(failed) failed")).font(.system(size: 10, weight: .medium)).lineLimit(1)
                }
            case .choosing:
                if let item = navigator.hoveredItem {
                    VStack(spacing: 2) {
                        Text(item.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        if let subtitle = item.subtitle {
                            Text(subtitle).font(.system(size: 9)).opacity(0.8).multilineTextAlignment(.center).lineLimit(3)
                        }
                    }
                    .padding(.horizontal, 6)
                } else if let message = navigator.layout.emptyMessage {
                    Text(message).font(.system(size: 10)).opacity(0.85).multilineTextAlignment(.center).padding(.horizontal, 8)
                } else {
                    VStack(spacing: 4) {
                        Text(navigator.layout.mode.title).font(.system(size: 13, weight: .bold))
                        HStack(spacing: 5) {
                            ForEach(WheelMode.allCases, id: \.self) { mode in
                                Text(mode.keySymbol)
                                    .font(.system(size: 11, weight: mode == navigator.layout.mode ? .bold : .regular))
                                    .opacity(mode == navigator.layout.mode ? 1 : 0.45)
                            }
                        }
                        Text(L("칸에 놓기", "Drop on a slot")).font(.system(size: 9, weight: .medium)).opacity(0.7)
                    }
                    .help(L("⇧ 변환 · ⌘ 도구 · ⌃ 동작", "⇧ Convert · ⌘ Tools · ⌃ Actions"))
                }
            }
        }
        .frame(width: (g.innerRadius - 6) * 2, height: (g.innerRadius - 6) * 2)
        .modifier(GlassFinish(shape: circle))
    }
}


/// 꽃잎들 아래에 깔리는 둥근 판. 창들과 같은 panel 유리(뒤가 대충 보일 정도로 흐림 + 잔 결).
struct WheelDisk: View {
    let radius: CGFloat

    var body: some View {
        Color.clear
            .frame(width: radius * 2, height: radius * 2)
            .modifier(GlassFinish(shape: Circle(), surface: .panel))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            .allowsHitTesting(false)
    }
}
