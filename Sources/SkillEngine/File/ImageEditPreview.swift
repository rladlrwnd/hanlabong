import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// 편집 창의 미리보기: 사진 편집 블록(회전·반전·보정)과 같은 코드로 작은 그림에 적용해서 보여준다.
public enum ImageEditPreview {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// 파일 → 방향이 바로잡힌 미리보기용 그림(긴 변 `maxPixels`). RAW도 읽는다.
    public static func load(_ url: URL, maxPixels: CGFloat = 1800) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw FileSkillError.unreadable(url.lastPathComponent)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels, kCGImageSourceShouldCacheImmediately: true,
        ]
        if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) { return image }
        throw FileSkillError.unreadable(url.lastPathComponent)
    }

    public static func render(_ image: CGImage, rotation: Int, flipHorizontal: Bool, flipVertical: Bool,
                              brightness: Double, contrast: Double, saturation: Double) -> CGImage {
        var ci = CIImage(cgImage: image)
        ci = FileSkillExecutor.rotated(ci, degrees: rotation)
        ci = FileSkillExecutor.flipped(ci, horizontal: flipHorizontal, vertical: flipVertical)
        ci = FileSkillExecutor.adjusted(ci, brightness: brightness, contrast: contrast, saturation: saturation)
        return context.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)) ?? image
    }
}
