import AppCore
import SkillEngine
import SwiftUI

/// 톤 커브 편집: 빈 곳을 누르면 점이 생기고, 점을 끌면 곡선이 따라 움직인다. 점을 두 번 누르면 지운다(양 끝 점은 못 지움).
/// 뒤에는 지금 사진의 밝기 분포(히스토그램)를 깔아서 어디를 만지는지 보이게 한다.
struct CurveEditor: View {
    enum Channel: String, CaseIterable, Identifiable {
        case rgb, red, green, blue
        var id: String { rawValue }
        var title: String { self == .rgb ? "RGB" : self == .red ? "R" : self == .green ? "G" : "B" }
        var color: Color { self == .rgb ? .white : self == .red ? .red : self == .green ? .green : .blue }
    }

    @Binding var curve: ToneCurve
    let histogram: [Double]
    @State private var channel = Channel.rgb
    @State private var dragging: Int?
    @State private var lastTap: (index: Int, time: Date)?

    private var points: [CurvePoint] {
        get {
            switch channel {
            case .rgb: return curve.rgb
            case .red: return curve.red
            case .green: return curve.green
            case .blue: return curve.blue
            }
        }
    }

    private func setPoints(_ new: [CurvePoint]) {
        let sorted = new.sorted { $0.x < $1.x }
        switch channel {
        case .rgb: curve.rgb = sorted
        case .red: curve.red = sorted
        case .green: curve.green = sorted
        case .blue: curve.blue = sorted
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("", selection: $channel) {
                    ForEach(Channel.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
                Spacer()
                Button(L("직선으로", "Reset")) { setPoints(ToneCurve.identity) }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    .disabled(ToneCurveIsStraight(points))
            }
            GeometryReader { proxy in
                let size = proxy.size
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.35))
                    histogramShape(size).fill(Color.white.opacity(0.10))
                    grid(size).stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                    Path { p in p.move(to: CGPoint(x: 0, y: size.height)); p.addLine(to: CGPoint(x: size.width, y: 0)) }
                        .stroke(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                    curvePath(size).stroke(channel.color.opacity(0.9), lineWidth: 1.6)
                    ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                        Circle()
                            .fill(dragging == index ? channel.color : Color.black)
                            .overlay(Circle().stroke(channel.color, lineWidth: 1.5))
                            .frame(width: 9, height: 9)
                            .position(x: point.x * size.width, y: (1 - point.y) * size.height)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in drag(value, size: size) }
                    .onEnded { value in end(value, size: size) })
            }
            .aspectRatio(1, contentMode: .fit)
            Text(L("빈 곳을 눌러 점 추가 · 끌어서 이동 · 점을 두 번 누르면 지우기", "Click to add a point · drag to move · double-click a point to remove"))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func ToneCurveIsStraight(_ p: [CurvePoint]) -> Bool { p == ToneCurve.identity }

    private func unit(_ location: CGPoint, _ size: CGSize) -> CurvePoint {
        CurvePoint(min(max(location.x / size.width, 0), 1), min(max(1 - location.y / size.height, 0), 1))
    }

    private func drag(_ value: DragGesture.Value, size: CGSize) {
        var p = points
        if dragging == nil {
            let start = unit(value.startLocation, size)
            if let near = p.indices.min(by: { hypot(p[$0].x - start.x, p[$0].y - start.y) < hypot(p[$1].x - start.x, p[$1].y - start.y) }),
               hypot((p[near].x - start.x) * size.width, (p[near].y - start.y) * size.height) < 12 {
                dragging = near
            } else {
                p.append(start)
                p.sort { $0.x < $1.x }
                dragging = p.firstIndex(of: start)
                setPoints(p)
            }
        }
        guard let index = dragging else { return }
        p = points
        var target = unit(value.location, size)
        // 양 끝 점은 위아래로만, 가운데 점은 이웃 점을 넘지 못하게
        if index == 0 { target.x = 0 } else if index == p.count - 1 { target.x = 1 } else {
            target.x = min(max(target.x, p[index - 1].x + 0.01), p[index + 1].x - 0.01)
        }
        p[index] = target
        switch channel {
        case .rgb: curve.rgb = p
        case .red: curve.red = p
        case .green: curve.green = p
        case .blue: curve.blue = p
        }
    }

    private func end(_ value: DragGesture.Value, size: CGSize) {
        defer { dragging = nil }
        guard let index = dragging else { return }
        let moved = hypot(value.translation.width, value.translation.height) > 3
        if !moved, let last = lastTap, last.index == index, Date().timeIntervalSince(last.time) < 0.35, index > 0, index < points.count - 1 {
            var p = points
            p.remove(at: index)
            setPoints(p)
            lastTap = nil
            return
        }
        lastTap = moved ? nil : (index, Date())
    }

    private func curvePath(_ size: CGSize) -> Path {
        Path { path in
            let p = points
            for step in 0...100 {
                let x = Double(step) / 100
                let point = CGPoint(x: x * size.width, y: (1 - ToneCurve.evaluate(p, at: x)) * size.height)
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
    }

    private func grid(_ size: CGSize) -> Path {
        Path { path in
            for i in 1...3 {
                let f = CGFloat(i) / 4
                path.move(to: CGPoint(x: f * size.width, y: 0)); path.addLine(to: CGPoint(x: f * size.width, y: size.height))
                path.move(to: CGPoint(x: 0, y: f * size.height)); path.addLine(to: CGPoint(x: size.width, y: f * size.height))
            }
        }
    }

    private func histogramShape(_ size: CGSize) -> Path {
        Path { path in
            guard histogram.count > 1, let peak = histogram.max(), peak > 0 else { return }
            path.move(to: CGPoint(x: 0, y: size.height))
            for (i, v) in histogram.enumerated() {
                path.addLine(to: CGPoint(x: CGFloat(i) / CGFloat(histogram.count - 1) * size.width, y: size.height * (1 - CGFloat(v / peak) * 0.9)))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
        }
    }
}
