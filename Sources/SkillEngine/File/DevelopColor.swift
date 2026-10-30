import Foundation

/// 커브의 점 하나(0~1)
public struct CurvePoint: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}

/// 톤 커브: 전체(RGB)와 빨강·초록·파랑 따로. 점 사이는 넘치지 않는 부드러운 곡선(단조 3차)으로 잇는다.
public struct ToneCurve: Codable, Equatable, Hashable, Sendable {
    public static let identity = [CurvePoint(0, 0), CurvePoint(1, 1)]
    public var rgb = ToneCurve.identity
    public var red = ToneCurve.identity
    public var green = ToneCurve.identity
    public var blue = ToneCurve.identity

    public init() {}

    public var isIdentity: Bool { [rgb, red, green, blue].allSatisfy { Self.isStraight($0) } }

    static func isStraight(_ points: [CurvePoint]) -> Bool { points.allSatisfy { abs($0.x - $0.y) < 0.0001 } }

    /// 단조 3차 보간(Fritsch–Carlson): 점을 지나면서 곡선이 점보다 튀어 오르거나 꺼지지 않는다
    public static func evaluate(_ points: [CurvePoint], at x: Double) -> Double {
        let p = points.sorted { $0.x < $1.x }
        guard p.count >= 2 else { return x }
        if x <= p[0].x { return p[0].y }
        if x >= p[p.count - 1].x { return p[p.count - 1].y }
        let n = p.count
        var d = [Double](repeating: 0, count: n - 1), m = [Double](repeating: 0, count: n)
        for i in 0..<(n - 1) { d[i] = (p[i + 1].y - p[i].y) / max(p[i + 1].x - p[i].x, 1e-9) }
        m[0] = d[0]; m[n - 1] = d[n - 2]
        for i in 1..<(n - 1) { m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2 }
        for i in 0..<(n - 1) where d[i] == 0 { m[i] = 0; m[i + 1] = 0 }
        for i in 0..<(n - 1) where d[i] != 0 {
            let a = m[i] / d[i], b = m[i + 1] / d[i], h = a * a + b * b
            if h > 9 { let t = 3 / h.squareRoot(); m[i] = t * a * d[i]; m[i + 1] = t * b * d[i] }
        }
        var k = 0
        while k < n - 2 && x > p[k + 1].x { k += 1 }
        let h = p[k + 1].x - p[k].x, t = (x - p[k].x) / h
        let t2 = t * t, t3 = t2 * t
        let y = (2 * t3 - 3 * t2 + 1) * p[k].y + (t3 - 2 * t2 + t) * h * m[k] + (-2 * t3 + 3 * t2) * p[k + 1].y + (t3 - t2) * h * m[k + 1]
        return min(max(y, 0), 1)
    }
}

/// 색조 편집(라이트룸의 색상 혼합): 8색마다 색조·채도·밝기를 -100~100
public struct ColorMixer: Codable, Equatable, Hashable, Sendable {
    public enum Band: Int, CaseIterable, Sendable {
        case red, orange, yellow, green, aqua, blue, purple, magenta
        /// 색상환에서 이 색의 가운데(도)
        public var hue: Double { [0, 30, 60, 120, 180, 225, 270, 315][rawValue] }
        public var title: String {
            [L("빨강", "Red"), L("주황", "Orange"), L("노랑", "Yellow"), L("초록", "Green"),
             L("청록", "Aqua"), L("파랑", "Blue"), L("보라", "Purple"), L("자주", "Magenta")][rawValue]
        }
    }

    public var hue = [Double](repeating: 0, count: 8)
    public var saturation = [Double](repeating: 0, count: 8)
    public var luminance = [Double](repeating: 0, count: 8)

    public init() {}
    public var isNeutral: Bool { (hue + saturation + luminance).allSatisfy { $0 == 0 } }

    /// 이 색(도)이 각 띠에 얼마나 속하는지: 가운데 1, 이웃 띠 가운데로 갈수록 0
    static func weights(hue h: Double) -> [Double] {
        let centers = Band.allCases.map(\.hue)
        return centers.indices.map { i in
            let c = centers[i]
            let prev = centers[(i + 7) % 8], next = centers[(i + 1) % 8]
            var diff = h - c
            if diff > 180 { diff -= 360 } else if diff < -180 { diff += 360 }
            var span = diff >= 0 ? next - c : c - prev
            if span <= 0 { span += 360 }
            return max(0, 1 - abs(diff) / span)
        }
    }
}

/// 커브·색조를 합친 3D 색 표. 같은 값이면 다시 만들지 않는다.
enum ColorLUT {
    static let size = 33
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [Int: Data] = [:]

    static func cube(curve: ToneCurve, mixer: ColorMixer) -> Data {
        var hasher = Hasher(); hasher.combine(curve); hasher.combine(mixer)
        let key = hasher.finalize()
        lock.lock(); if let hit = cache[key] { lock.unlock(); return hit }; lock.unlock()
        let data = build(curve: curve, mixer: mixer)
        lock.lock(); if cache.count > 16 { cache.removeAll() }; cache[key] = data; lock.unlock()
        return data
    }

    /// 표의 한 칸 = (r, g, b)가 바뀔 색. Core Image 순서: 빨강이 가장 빨리 바뀌고 다음 초록, 파랑
    private static func build(curve: ToneCurve, mixer: ColorMixer) -> Data {
        let n = size
        // 커브는 256칸으로 미리 계산(같은 점을 수만 번 다시 계산하지 않게)
        func table(_ points: [CurvePoint]) -> [Double] {
            ToneCurve.isStraight(points) ? (0..<256).map { Double($0) / 255 } : (0..<256).map { ToneCurve.evaluate(points, at: Double($0) / 255) }
        }
        let master = table(curve.rgb), reds = table(curve.red), greens = table(curve.green), blues = table(curve.blue)
        func look(_ t: [Double], _ v: Double) -> Double {
            let f = min(max(v, 0), 1) * 255, i = Int(f), frac = f - Double(i)
            return i >= 255 ? t[255] : t[i] * (1 - frac) + t[i + 1] * frac
        }
        var values = [Float](repeating: 0, count: n * n * n * 4)
        var index = 0
        for bi in 0..<n {
            for gi in 0..<n {
                for ri in 0..<n {
                    var r = Double(ri) / Double(n - 1), g = Double(gi) / Double(n - 1), b = Double(bi) / Double(n - 1)
                    r = look(reds, look(master, r)); g = look(greens, look(master, g)); b = look(blues, look(master, b))
                    if !mixer.isNeutral { (r, g, b) = mix(r, g, b, mixer) }
                    values[index] = Float(r); values[index + 1] = Float(g); values[index + 2] = Float(b); values[index + 3] = 1
                    index += 4
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// HSL로 바꿔서 띠마다 색조를 옆 색 쪽으로 밀고(최대 30도), 채도·밝기를 바꾼다. 회색(채도 0)은 건드리지 않는다
    private static func mix(_ r: Double, _ g: Double, _ b: Double, _ mixer: ColorMixer) -> (Double, Double, Double) {
        let maxC = max(r, g, b), minC = min(r, g, b), l = (maxC + minC) / 2, delta = maxC - minC
        guard delta > 1e-6 else { return (r, g, b) }
        var s = l > 0.5 ? delta / (2 - maxC - minC) : delta / (maxC + minC)
        var h: Double
        if maxC == r { h = (g - b) / delta + (g < b ? 6 : 0) } else if maxC == g { h = (b - r) / delta + 2 } else { h = (r - g) / delta + 4 }
        h *= 60
        let w = ColorMixer.weights(hue: h)
        var hueShift = 0.0, satScale = 0.0, lumShift = 0.0
        for i in 0..<8 where w[i] > 0 {
            hueShift += w[i] * mixer.hue[i] / 100 * 30
            satScale += w[i] * mixer.saturation[i] / 100
            lumShift += w[i] * mixer.luminance[i] / 100
        }
        h = (h + hueShift).truncatingRemainder(dividingBy: 360); if h < 0 { h += 360 }
        s = min(max(s * (1 + satScale), 0), 1)
        // 밝기는 채도가 있는 만큼만(회색에 가까울수록 덜 바뀐다)
        var newL = l + lumShift * 0.3 * s
        newL = min(max(newL, 0), 1)
        return hslToRGB(h, s, newL)
    }

    private static func hslToRGB(_ h: Double, _ s: Double, _ l: Double) -> (Double, Double, Double) {
        let c = (1 - abs(2 * l - 1)) * s, hp = h / 60, x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1)), m = l - c / 2
        let (r, g, b): (Double, Double, Double)
        switch hp {
        case ..<1: (r, g, b) = (c, x, 0)
        case ..<2: (r, g, b) = (x, c, 0)
        case ..<3: (r, g, b) = (0, c, x)
        case ..<4: (r, g, b) = (0, x, c)
        case ..<5: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return (r + m, g + m, b + m)
    }
}
