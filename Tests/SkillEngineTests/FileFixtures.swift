import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 파일 블록 테스트용 이미지는 전부 코드로 만든다(테스트 파일을 따로 들고 다니지 않는다).
enum Fixtures {
    static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dragedit-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!
    static let adobeRGB = CGColorSpace(name: CGColorSpace.adobeRGB1998)!
    static let gray = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!

    /// 8비트 RGBA 이미지. `pixel(x, y)`는 y=0이 맨 위 줄.
    static func rgb(width: Int, height: Int, space: CGColorSpace = sRGB, alpha: Bool = false,
                    pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b, a) = pixel(x, y)
                let i = (y * width + x) * 4
                // premultipliedLast: 알파를 곱해서 저장
                bytes[i] = UInt8(Int(r) * Int(a) / 255); bytes[i + 1] = UInt8(Int(g) * Int(a) / 255)
                bytes[i + 2] = UInt8(Int(b) * Int(a) / 255); bytes[i + 3] = a
            }
        }
        let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        return bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: space, bitmapInfo: info)!
            return context.makeImage()!
        }
    }

    /// 16비트 흑백 이미지. `value(x, y)`는 0~65535.
    static func gray16(width: Int, height: Int, value: (Int, Int) -> UInt16) -> CGImage {
        var samples = [UInt16](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width { samples[y * width + x] = value(x, y) } }
        return samples.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 16,
                                    bytesPerRow: width * 2, space: gray,
                                    bitmapInfo: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
            return context.makeImage()!
        }
    }

    /// 압축이 잘 안 되는 잡음 이미지(파일 크기 상한 테스트용). 같은 값이 항상 나온다.
    static func noise(width: Int, height: Int) -> CGImage {
        var state: UInt64 = 0x9E3779B97F4A7C15
        return rgb(width: width, height: height) { _, _ in
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return (UInt8(truncatingIfNeeded: state), UInt8(truncatingIfNeeded: state >> 8), UInt8(truncatingIfNeeded: state >> 16), 255)
        }
    }

    @discardableResult
    static func write(_ image: CGImage, to url: URL, type: UTType, properties: [String: Any] = [:]) throws -> URL {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        precondition(CGImageDestinationFinalize(destination), "테스트 이미지를 쓰지 못했어요")
        return url
    }

    // MARK: - 읽어보기

    static func properties(of data: Data) -> [String: Any] {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
    }

    static func cgImage(of data: Data) -> CGImage {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }!
    }

    /// 이미지를 `space` 기준 8비트 RGBA 값으로 읽는다(y=0이 맨 위 줄).
    static func rgba(_ image: CGImage, in space: CGColorSpace) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    static func pixel(_ rgba: [UInt8], width: Int, x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let i = (y * width + x) * 4
        return (Int(rgba[i]), Int(rgba[i + 1]), Int(rgba[i + 2]), Int(rgba[i + 3]))
    }

    /// 16비트 흑백 값들을 그림의 흑백 프로필 기준으로 읽는다.
    static func gray16Samples(_ image: CGImage) -> [UInt16] {
        var samples = [UInt16](repeating: 0, count: image.width * image.height)
        samples.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 16,
                                    bytesPerRow: image.width * 2, space: image.colorSpace ?? gray,
                                    bitmapInfo: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return samples
    }

    static func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
}
