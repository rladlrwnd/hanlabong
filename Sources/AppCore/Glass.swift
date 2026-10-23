import AppKit
import Foundation
import SwiftUI

// 팝업(그리고 나중에 휠)이 함께 쓰는 유리 모양 설정값.

/// 팝업 유리 모양. 설정 › 일반 › 모양의 슬라이더로 조절한다.
///
/// 층 구조(아래→위): clear 유리 → 흐림(가장 얇은 흐림 재질을 반투명하게) → 밝기 색(흰↔검) 덧칠 → 글자.
/// - 흐림: 흐림 재질은 세기를 직접 못 바꿔서, 흐린 층을 얼마나 보이게 할지로 조절한다.
/// - 밝기/틴트: 흰색~검은색 중 어떤 색을(밝기) 얼마나 진하게(틴트) 덧칠할지.
/// - 글자색: 밝기가 밝으면 어두운 글자, 어두우면 흰 글자(팝업 전체를 라이트/다크로 맞춘다).
package enum PopupGlass {
    package static let blurKey = "popupBlur"
    package static let tintKey = "popupTint"
    package static let brightnessKey = "popupBrightness"
    package static let followSystemKey = "popupBrightnessFollowsSystem"

    package static let defaultBlur = 0.55
    package static let defaultTint = 0.12
    package static let defaultBrightness = 0.85
    package static let defaultFollowSystem = true

    package static func resetToDefaults() {
        let defaults = UserDefaults.standard
        defaults.set(defaultBlur, forKey: blurKey)
        defaults.set(defaultTint, forKey: tintKey)
        defaults.set(defaultBrightness, forKey: brightnessKey)
        defaults.set(defaultFollowSystem, forKey: followSystemKey)
    }
}

/// 강조색: 휠에서 칸 위에 올렸을 때 칠하는 색. 기본은 한라봉 주황, 설정 › 일반 › 모양에서 바꾼다.
/// 맥 시스템 강조색과 따로 간다(사용자가 고른 색을 hex 글자로 저장).
package enum AppAccent {
    package static let key = "accentColorHex"
    package static let defaultHex = "#FFB347"

    package static func color(_ hex: String) -> Color {
        Color(nsColor: nsColor(hex) ?? nsColor(defaultHex)!)
    }

    package static func nsColor(_ hex: String) -> NSColor? {
        let digits = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    package static func hex(_ color: Color) -> String {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return defaultHex }
        let to255 = { (v: CGFloat) in Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", to255(c.redComponent), to255(c.greenComponent), to255(c.blueComponent))
    }
}

/// 유리 두께.
/// - element: 꽃잎·팝업·버튼처럼 작은 조각(설정의 흐림 슬라이더를 그대로 따른다)
/// - panel: 창(요약·편집·검토·진행 카드)과 휠 아래 판. 크기가 커서 뒤가 너무 비치면 글이 안 읽히니
///   흐림을 한 단계 고정으로 깔고, 잔 결(질감)을 얹는다. 모든 창이 같은 두께가 되게 이걸 같이 쓴다.
package enum GlassSurface: Sendable {
    case element, panel
}

/// 유리 + 흐림 + 밝기 덧칠 + 글자색을 한 번에 입힌다.
package struct GlassFinish<S: Shape>: ViewModifier {
    let shape: S
    let surface: GlassSurface

    package init(shape: S, surface: GlassSurface = .element) {
        self.shape = shape
        self.surface = surface
    }

    @AppStorage(PopupGlass.blurKey) private var blur = PopupGlass.defaultBlur
    @AppStorage(PopupGlass.tintKey) private var tint = PopupGlass.defaultTint
    @AppStorage(PopupGlass.brightnessKey) private var brightness = PopupGlass.defaultBrightness
    @AppStorage(PopupGlass.followSystemKey) private var followSystem = PopupGlass.defaultFollowSystem
    @Environment(\.colorScheme) private var systemScheme

    private var scheme: ColorScheme {
        followSystem ? systemScheme : (brightness >= 0.5 ? .light : .dark)
    }

    private var overlay: Color {
        followSystem ? (systemScheme == .dark ? .black : .white) : Color(white: brightness)
    }

    package func body(content: Content) -> some View {
        content
            .background {
                switch surface {
                case .element:
                    ZStack {
                        shape.fill(.ultraThinMaterial).opacity(blur)
                        shape.fill(overlay.opacity(tint))
                    }
                case .panel:
                    // 뒤에 뭐가 있는지 대충 보일 정도: 얇은 흐림 재질을 꽉 + 밝기 덧칠 조금 더 + 잔 결
                    ZStack {
                        shape.fill(.thinMaterial)
                        shape.fill(overlay.opacity(min(tint + 0.10, 0.6)))
                        GrainTexture().clipShape(shape).opacity(scheme == .dark ? 0.09 : 0.06)
                        shape.stroke(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.06), .black.opacity(0.10)],
                                                    startPoint: .top, endPoint: .bottom), lineWidth: 1.2)
                    }
                    .allowsHitTesting(false)
                }
            }
            .glassEffect(.clear, in: shape)
            // 유리 조각이 생기거나 사라질 때 모서리에서 "솟아오르며 합쳐지는" 전환을 끈다(칸 위에 올릴 때마다 보이던 현상)
            .glassEffectTransition(.identity)
            .environment(\.colorScheme, scheme)
    }
}

/// 고정된 잔 무늬. 256×256 타일을 앱 실행 중 한 번만 만들어 두고 깔아서 쓴다
/// (예전엔 Canvas로 점 수만 개를 그려서, 요약 글이 한 글자씩 나올 때마다 다시 그리느라 버벅였다).
package struct GrainTexture: View {
    package init() {}

    @MainActor private static let tile: NSImage = {
        let side = 256
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var state: UInt64 = 0x2545F4914F6CDD1D
        func next() -> Double {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Double(state % 10_000) / 10_000
        }
        for _ in 0..<(side * side / 14) {
            let x = Int(next() * Double(side)), y = Int(next() * Double(side))
            ctx.setFillColor(next() > 0.5 ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
        return NSImage(cgImage: ctx.makeImage()!, size: NSSize(width: side, height: side))
    }()

    package var body: some View {
        Image(nsImage: Self.tile)
            .resizable(resizingMode: .tile)
            .allowsHitTesting(false)
    }
}
