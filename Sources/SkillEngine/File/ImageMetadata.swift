import Foundation
import ImageIO

/// 결과 파일에 쓸 메타데이터(EXIF·GPS·IPTC 등)를 고른다.
/// 색 프로필(ICC)은 여기서 다루지 않는다 — 색이 틀어지지 않게 항상 이미지와 함께 간다.
enum ImageMetadata {
    private static let exif = kCGImagePropertyExifDictionary as String
    private static let tiff = kCGImagePropertyTIFFDictionary as String
    private static let gps = kCGImagePropertyGPSDictionary as String
    private static let iptc = kCGImagePropertyIPTCDictionary as String
    private static let orientation = kCGImagePropertyOrientation as String

    /// 이미지 컨테이너에 종속되지 않아서 결과에 옮겨도 되는 최상위 항목들 (JFIF·PNG·Raw 같은 건 새로 만들어진다)
    private static let carriedTopLevel: [String] = [
        exif, tiff, gps, iptc,
        kCGImagePropertyExifAuxDictionary as String,
        "{MakerFuji}", "{MakerCanon}", "{MakerNikon}", "{MakerMinolta}", "{MakerOlympus}", "{MakerPentax}", "{MakerApple}",
        kCGImagePropertyDPIWidth as String, kCGImagePropertyDPIHeight as String,
    ]

    /// 카메라 정보만 남기는 모드에서 살려두는 항목
    private static let cameraTIFF: Set<String> = [
        kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel,
    ].map { $0 as String }.reduce(into: Set<String>()) { $0.insert($1) }

    private static let cameraExif: Set<String> = Set([
        kCGImagePropertyExifExposureTime, kCGImagePropertyExifFNumber, kCGImagePropertyExifExposureProgram,
        kCGImagePropertyExifISOSpeedRatings, kCGImagePropertyExifISOSpeed, kCGImagePropertyExifSensitivityType,
        kCGImagePropertyExifExposureBiasValue, kCGImagePropertyExifMaxApertureValue, kCGImagePropertyExifMeteringMode,
        kCGImagePropertyExifLightSource, kCGImagePropertyExifFlash, kCGImagePropertyExifFocalLength,
        kCGImagePropertyExifExposureMode, kCGImagePropertyExifWhiteBalance, kCGImagePropertyExifFocalLenIn35mmFilm,
        kCGImagePropertyExifSceneCaptureType, kCGImagePropertyExifLensMake, kCGImagePropertyExifLensModel,
        kCGImagePropertyExifLensSpecification, kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifDateTimeDigitized,
        kCGImagePropertyExifSubsecTimeOriginal, kCGImagePropertyExifSubsecTimeDigitized,
        kCGImagePropertyExifVersion,
    ].map { $0 as String })

    /// 위치 정보를 지울 때 IPTC에서 같이 지우는 장소 항목
    private static let iptcLocation: [String] = [
        kCGImagePropertyIPTCCity, kCGImagePropertyIPTCProvinceState, kCGImagePropertyIPTCSubLocation,
        kCGImagePropertyIPTCCountryPrimaryLocationCode, kCGImagePropertyIPTCCountryPrimaryLocationName,
    ].map { $0 as String }

    /// - Parameters:
    ///   - source: ImageIO가 원본에서 읽은 속성
    ///   - width/height: 결과 이미지의 픽셀 크기(EXIF 크기 항목을 맞춘다)
    ///   - outputIsSRGB: 결과가 sRGB인지(EXIF의 색 공간 표시: sRGB는 1, 그 밖에는 "보정 안 됨" 65535)
    static func outputProperties(source: [String: Any], spec: MetadataSpec, width: Int, height: Int, outputIsSRGB: Bool) -> [String: Any] {
        var out: [String: Any] = [:]

        if spec.mode != .removeAll {
            for key in carriedTopLevel { if let value = source[key] { out[key] = value } }
        }

        switch spec.mode {
        case .keepAll, .removeAll:
            break
        case .removeGPS:
            out[gps] = nil
            if var iptcDict = out[iptc] as? [String: Any] {
                for key in iptcLocation { iptcDict[key] = nil }
                out[iptc] = iptcDict
            }
        case .keepCameraOnly:
            out[gps] = nil
            out[iptc] = nil
            for key in out.keys where key.hasPrefix("{Maker") || key == kCGImagePropertyExifAuxDictionary as String { out[key] = nil }
            if let t = out[tiff] as? [String: Any] { out[tiff] = t.filter { cameraTIFF.contains($0.key) } }
            if let e = out[exif] as? [String: Any] { out[exif] = e.filter { cameraExif.contains($0.key) } }
        }

        // 방향은 픽셀에 이미 적용했으니 "회전 없음"으로 적는다(안 그러면 보는 앱에서 한 번 더 돌아간다)
        out[orientation] = 1
        if var t = out[tiff] as? [String: Any] {
            t[kCGImagePropertyTIFFOrientation as String] = 1
            out[tiff] = t
        }
        if var e = out[exif] as? [String: Any] {
            e[kCGImagePropertyExifPixelXDimension as String] = width
            e[kCGImagePropertyExifPixelYDimension as String] = height
            e[kCGImagePropertyExifColorSpace as String] = outputIsSRGB ? 1 : 65535
            out[exif] = e
        }

        // 작가·저작권은 모드와 상관없이 기입
        if let artist = spec.artist, !artist.isEmpty {
            var t = out[tiff] as? [String: Any] ?? [:]
            t[kCGImagePropertyTIFFArtist as String] = artist
            out[tiff] = t
            var i = out[iptc] as? [String: Any] ?? [:]
            i[kCGImagePropertyIPTCByline as String] = [artist]
            out[iptc] = i
        }
        if let copyright = spec.copyright, !copyright.isEmpty {
            var t = out[tiff] as? [String: Any] ?? [:]
            t[kCGImagePropertyTIFFCopyright as String] = copyright
            out[tiff] = t
            var i = out[iptc] as? [String: Any] ?? [:]
            i[kCGImagePropertyIPTCCopyrightNotice as String] = copyright
            out[iptc] = i
        }

        return out.filter { key, value in
            if let dict = value as? [String: Any] { return !dict.isEmpty }
            return true
        }
    }
}
