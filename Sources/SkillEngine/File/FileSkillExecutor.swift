import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import Foundation
import ImageIO
import AVFoundation
import PDFKit
import UniformTypeIdentifiers

/// 스킬 실행 결과(아직 저장 전). 사진이면 픽셀 크기, 문서면 0.
public struct FileResult: Sendable {
    public let data: Data
    public let fileExtension: String
    public let width: Int
    public let height: Int
    /// 영상처럼 큰 결과는 메모리에 안 올리고 임시 파일로 준다(저장할 때 원본 옆으로 옮긴다)
    public var fileURL: URL?
}

/// 이미지 파일 스킬을 실행한다. 원본은 읽기만 하고, 결과는 메모리의 데이터로 돌려준다(저장은 `FileOutputWriter`).
///
/// 원칙:
/// - 색 프로필(ICC)과 EXIF는 사용자가 지우라고 한 경우가 아니면 보존한다.
/// - 16비트 이미지는 16비트로 처리하다가 저장할 때만 필요하면 바꾼다.
/// - 그림은 Core Image(색 관리되는 그래프)로 이어 붙이고, 마지막에 한 번만 그려서 인코딩한다.
public final class FileSkillExecutor: @unchecked Sendable {
    // 8비트로 저장할 때는 기본(half float)으로, 16비트로 저장할 때는 32비트 float로 처리해서 값이 뭉개지지 않게 한다.
    // 컨텍스트는 작업마다 새로 만들고 버린다: 재사용하면 큰 사진 한 장(약 1GB)씩 메모리가 안 돌아온다.
    private func makeContext(precise: Bool) -> CIContext {
        if precise {
            return CIContext(options: [.cacheIntermediates: false, .workingFormat: NSNumber(value: CIFormat.RGBAf.rawValue)])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }

    public init() {}

    // MARK: - 실행

    public func run(_ skill: FileSkill, input: URL, cancellation: FileCancellation = .never) throws -> FileResult {
        // 큰 사진은 한 장에 2GB 가까이 쓰니, 끝나면 바로 돌려준다(안 그러면 장마다 메모리가 쌓인다)
        try autoreleasepool { try runUnpooled(skill, input: input, cancellation: cancellation) }
    }

    private func runUnpooled(_ skill: FileSkill, input: URL, cancellation: FileCancellation) throws -> FileResult {
        try skill.validate()
        // 확장자가 아니라 내용으로 판별한다. 알아볼 수 없으면 손상됐거나 사진이 아닌 파일이다.
        guard let kind = FileKindDetector.kind(of: input) else { throw FileSkillError.unreadable(input.lastPathComponent) }
        guard skill.input.contains(kind) else { throw FileSkillError.wrongKind(file: input.lastPathComponent) }

        switch skill.steps.last {
        case .video(let spec)?:
            let result = try runVideo(spec, input: input, cancellation: cancellation)
            return result
        case .pdfToDocx?:
            let document = try readPDF(input, cancellation: cancellation)
            let title = document.title ?? input.deletingPathExtension().lastPathComponent
            return FileResult(data: DocxWriter.make(document, title: title), fileExtension: "docx", width: 0, height: 0)
        case .pdfToText(let keepLineBreaks)?:
            let document = try readPDF(input, cancellation: cancellation)
            return FileResult(data: PlainTextWriter.make(document, keepLineBreaks: keepLineBreaks), fileExtension: "txt", width: 0, height: 0)
        case .ocrText?:
            let page = try TextRecognizer.recognize(try OCRSource.uprightImage(input))
            let paragraphs = PDFTextExtractor.assemble(TextRecognizer.pdfLines(from: page, pageIndex: 0))
            let text = paragraphs.map(\.text).joined(separator: "\n\n")
            guard PDFTextExtractor.letterCount(text) > 0 else { throw FileSkillError.noTextFound(input.lastPathComponent) }
            return FileResult(data: Data((text + "\n").utf8), fileExtension: "txt", width: 0, height: 0)
        case .ocrPDF?:
            if kind == .pdf {
                guard let document = PDFDocument(url: input) else { throw FileSkillError.unreadable(input.lastPathComponent) }
                if document.isLocked { throw FileSkillError.encryptedPDF(input.lastPathComponent) }
                return FileResult(data: try SearchablePDF.fromPDF(document, title: input.deletingPathExtension().lastPathComponent, cancellation: cancellation),
                                  fileExtension: "pdf", width: 0, height: 0)
            }
            return FileResult(data: try SearchablePDF.fromImage(input, ocr: true, cancellation: cancellation), fileExtension: "pdf", width: 0, height: 0)
        case .imageToPDF?:
            return FileResult(data: try SearchablePDF.fromImage(input, ocr: false), fileExtension: "pdf", width: 0, height: 0)
        case .document(let format)?:
            let source: RichDocument
            if kind == .pdf {
                let extracted = try readPDF(input, cancellation: cancellation)
                source = RichDocument(title: extracted.title ?? input.deletingPathExtension().lastPathComponent, paragraphs: extracted.paragraphs)
            } else {
                source = try RichDocumentReader.read(input)
            }
            return FileResult(data: try RichDocumentWriter.write(source, as: format), fileExtension: format.fileExtension, width: 0, height: 0)
        case .pdfToImages(let format, let dpi)?:
            return try PDFExports.images(try openPDF(input), name: input.deletingPathExtension().lastPathComponent, format: format, dpi: dpi, cancellation: cancellation)
        case .pdfToSlides?:
            return FileResult(data: try PDFExports.slides(try openPDF(input), title: input.deletingPathExtension().lastPathComponent, cancellation: cancellation),
                              fileExtension: "pptx", width: 0, height: 0)
        case .vectorize(let format)?:
            return try Vectorizer.run(input, format: format, cancellation: cancellation)
        case .pdfToSheet?:
            return FileResult(data: try PDFExports.sheet(try openPDF(input), title: input.lastPathComponent, cancellation: cancellation),
                              fileExtension: "xlsx", width: 0, height: 0)
        default:
            break
        }

        var loaded = try load(input)
        var target = ColorSpaceTarget.keep
        var metadata = MetadataSpec()
        var encodeSpec: EncodeSpec?

        for step in skill.steps {
            switch step {
            case .decode:
                break
            case .colorspace(let value):
                target = value
            case .resize(let spec, let allowUpscale):
                loaded.image = resized(loaded.image, spec, allowUpscale: allowUpscale)
            case .crop(let spec):
                loaded.image = cropped(loaded.image, spec)
            case .metadata(let spec):
                metadata = spec
            case .watermark(let spec):
                loaded.image = try watermarked(loaded.image, spec)
            case .encode(let spec):
                encodeSpec = spec
            case .rotate(let degrees):
                loaded.image = Self.rotated(loaded.image, degrees: degrees)
            case .flip(let horizontal, let vertical):
                loaded.image = Self.flipped(loaded.image, horizontal: horizontal, vertical: vertical)
            case .adjust(let brightness, let contrast, let saturation):
                loaded.image = Self.adjusted(loaded.image, brightness: brightness, contrast: contrast, saturation: saturation)
            case .video, .pdfToDocx, .pdfToText, .ocrText, .ocrPDF, .imageToPDF, .document, .pdfToImages, .pdfToSlides, .pdfToSheet, .vectorize:
                break   // 위에서 문서로 이미 처리했다(검사에서 사진 블록과 섞이지 않게 막는다)
            }
        }
        guard var encodeSpec else { throw FileSkillError.invalidSkill(L("encode 블록이 없어요", "No encode block")) }
        if encodeSpec.sameAsInput, let same = OutputFormat.matching(extension: input.pathExtension), Self.canWrite(same) {
            encodeSpec.format = same
            if encodeSpec.quality == nil, same.isLossy { encodeSpec.quality = 0.95 }
        }
        return try encode(loaded, target: target, metadata: metadata, spec: encodeSpec)
    }

    // MARK: - 회전·반전·보정

    private static func normalizedOrigin(_ image: CIImage) -> CIImage {
        let e = image.extent
        return image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
    }

    public static func rotated(_ image: CIImage, degrees: Int) -> CIImage {
        switch ((degrees % 360) + 360) % 360 {
        case 90: return normalizedOrigin(image.oriented(.right))      // 시계 방향 90도
        case 180: return normalizedOrigin(image.oriented(.down))
        case 270: return normalizedOrigin(image.oriented(.left))
        default: return image
        }
    }

    public static func flipped(_ image: CIImage, horizontal: Bool, vertical: Bool) -> CIImage {
        var result = image
        if horizontal { result = normalizedOrigin(result.oriented(.upMirrored)) }
        if vertical { result = normalizedOrigin(result.oriented(.downMirrored)) }
        return result
    }

    public static func adjusted(_ image: CIImage, brightness: Double, contrast: Double, saturation: Double) -> CIImage {
        guard brightness != 0 || contrast != 1 || saturation != 1 else { return image }
        let filter = CIFilter.colorControls()
        filter.inputImage = image
        filter.brightness = Float(min(max(brightness, -1), 1))
        filter.contrast = Float(min(max(contrast, 0.25), 4))
        filter.saturation = Float(min(max(saturation, 0), 2))
        return filter.outputImage ?? image
    }

    // MARK: - 영상 (AVFoundation)

    private final class ExportBox: @unchecked Sendable { var failure: Error? }

    private func runVideo(_ spec: VideoSpec, input: URL, cancellation: FileCancellation) throws -> FileResult {
        try cancellation.check()
        let name = input.lastPathComponent
        let format = spec.resolvedFormat(input: input)
        let ext = format.fileExtension
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("dragedit-\(UUID().uuidString).\(ext)")
        if FFmpeg.needsFFmpeg(input) || !format.isNative {
            try FFmpeg.convert(spec, input: input, to: out, cancellation: cancellation)
            if cancellation.isCancelled { try? FileManager.default.removeItem(at: out); throw CancellationError() }
            return FileResult(data: Data(), fileExtension: ext, width: 0, height: 0, fileURL: out)
        }
        let box = ExportBox()
        let done = DispatchSemaphore(value: 0)
        // 내보내기는 async라서 별도 Task로 돌리고, 이 스레드(전용 작업 큐)는 기다리면서 취소 깃발을 본다
        let task = Task {
            do { try await Self.export(spec, input: input, to: out, ext: ext, name: name) } catch { box.failure = error }
            done.signal()
        }
        while done.wait(timeout: .now() + 0.2) == .timedOut {
            if cancellation.isCancelled { task.cancel() }
        }
        if let failure = box.failure {
            try? FileManager.default.removeItem(at: out)
            if failure is CancellationError || cancellation.isCancelled { throw CancellationError() }
            throw failure
        }
        if cancellation.isCancelled {                      // 끝나기 직전에 취소했으면 결과를 버린다
            try? FileManager.default.removeItem(at: out)
            throw CancellationError()
        }
        return FileResult(data: Data(), fileExtension: ext, width: 0, height: 0, fileURL: out)
    }

    private static func export(_ spec: VideoSpec, input: URL, to out: URL, ext: String, name: String) async throws {
        let asset = AVURLAsset(url: input)
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audioOnly = spec.preset == .audioOnly
        if audioOnly { guard !audioTracks.isEmpty else { throw FileSkillError.noAudio(name) } }
        else { guard !videoTracks.isEmpty else { throw FileSkillError.noVideoTrack(name) } }

        // 자를 구간
        let total = duration.seconds
        let start = min(max(spec.trimStart ?? 0, 0), max(total - 0.1, 0))
        let end = min(max(spec.trimEnd ?? total, start + 0.1), total)
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))

        let composition = AVMutableComposition()
        if !audioOnly, let source = videoTracks.first, let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try track.insertTimeRange(range, of: source, at: .zero)
            track.preferredTransform = try await source.load(.preferredTransform)      // 세로 영상 방향 유지
        }
        if !spec.muted || audioOnly, let source = audioTracks.first, let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try track.insertTimeRange(range, of: source, at: .zero)
        }

        let preset: String
        switch spec.preset {
        case .passthrough: preset = AVAssetExportPresetPassthrough
        case .p1080: preset = AVAssetExportPreset1920x1080
        case .hevc1080: preset = AVAssetExportPresetHEVC1920x1080
        case .p720: preset = AVAssetExportPreset1280x720
        case .p480: preset = AVAssetExportPreset640x480
        case .audioOnly: preset = AVAssetExportPresetAppleM4A
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw FileSkillError.exportFailed(L("이 영상에는 이 설정을 쓸 수 없어요", "This setting can't be used for this video"))
        }
        let type: AVFileType = ext == "m4a" ? .m4a : (ext == "mov" ? .mov : .mp4)
        do {
            try await session.export(to: out, as: type)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FileSkillError.exportFailed(error.localizedDescription)
        }
    }

    // MARK: - PDF

    private func openPDF(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else { throw FileSkillError.unreadable(url.lastPathComponent) }
        if document.isLocked { throw FileSkillError.encryptedPDF(url.lastPathComponent) }
        return document
    }

    private func readPDF(_ url: URL, cancellation: FileCancellation) throws -> ExtractedDocument {
        guard let document = PDFDocument(url: url) else { throw FileSkillError.unreadable(url.lastPathComponent) }
        if document.isLocked { throw FileSkillError.encryptedPDF(url.lastPathComponent) }
        // 글자가 없는 쪽(스캔한 쪽)은 그 쪽만 글자 인식(OCR)해서 쓴다
        let extracted = try PDFTextExtractor.extract(document) { page, index in
            try PDFPageOCR.lines(of: page, index: index, cancellation: cancellation)
        }
        // 그래도 글자가 거의 없으면 빈 쪽이거나 너무 흐린 스캔이다
        let letters = extracted.paragraphs.reduce(0) { $0 + $1.text.filter { !$0.isWhitespace }.count }
        guard letters >= 3 else { throw FileSkillError.noTextInPDF(url.lastPathComponent) }
        return extracted
    }

    // MARK: - 읽기

    struct Loaded {
        var image: CIImage
        var properties: [String: Any]
        var colorSpace: CGColorSpace?
        var depth: Int
        var hasAlpha: Bool
        var isRAW: Bool
        var isHighPrecision: Bool { depth > 8 || isRAW }
    }

    private func load(_ url: URL) throws -> Loaded {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options), CGImageSourceGetCount(source) > 0 else {
            throw FileSkillError.unreadable(url.lastPathComponent)
        }
        let properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [String: Any]) ?? [:]
        let type = CGImageSourceGetType(source).flatMap { UTType($0 as String) }
        let isRAW = type?.conforms(to: .rawImage) ?? false

        let image: CIImage
        if isRAW {
            guard let filter = CIRAWFilter(imageURL: url), let output = filter.outputImage else {
                throw FileSkillError.unreadable(url.lastPathComponent)
            }
            image = output
        } else {
            // 같은 소스를 캐시 없이 쓴다: ImageIO가 풀린 픽셀(큰 사진은 1GB)을 붙잡고 있지 않게
            image = CIImage(cgImageSource: source, index: 0, options: [.applyOrientationProperty: true])
        }

        return Loaded(
            image: image,
            properties: properties,
            colorSpace: image.colorSpace,
            depth: properties[kCGImagePropertyDepth as String] as? Int ?? 8,
            hasAlpha: properties[kCGImagePropertyHasAlpha as String] as? Bool ?? false,
            isRAW: isRAW
        )
    }

    // MARK: - 크기·자르기

    private func resized(_ image: CIImage, _ spec: ResizeSpec, allowUpscale: Bool) -> CIImage {
        let extent = image.extent
        let longEdge = Double(max(extent.width, extent.height))
        let shortEdge = Double(min(extent.width, extent.height))
        let scale: Double
        switch spec {
        case .longEdge(let n): scale = Double(n) / longEdge
        case .shortEdge(let n): scale = Double(n) / shortEdge
        case .percent(let p): scale = p / 100
        }
        guard scale > 0, scale != 1, scale < 1 || allowUpscale else { return image }
        return scaled(image, toWidth: max(1, Int((Double(extent.width) * scale).rounded())),
                      height: max(1, Int((Double(extent.height) * scale).rounded())))
    }

    /// Lanczos로 정확히 `width`×`height` 픽셀이 되게 줄이거나 키운다. 가장자리가 흐려지지 않게 가장자리 픽셀을 늘려서 계산한다.
    private func scaled(_ image: CIImage, toWidth width: Int, height: Int) -> CIImage {
        let extent = image.extent
        let origin = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let scaleY = CGFloat(height) / extent.height
        let scaleX = CGFloat(width) / extent.width
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = origin.clampedToExtent()
        filter.scale = Float(scaleY)
        filter.aspectRatio = Float(scaleX / scaleY)
        guard let output = filter.outputImage else { return image }
        return output.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    private func cropped(_ image: CIImage, _ spec: CropSpec) -> CIImage {
        let extent = image.extent
        var rect = extent
        if let r = spec.rect {
            // 비율 좌표(왼쪽 위 원점) → Core Image 좌표(왼쪽 아래 원점)
            rect = CGRect(
                x: extent.minX + r.x * extent.width,
                y: extent.maxY - (r.y + r.height) * extent.height,
                width: r.width * extent.width,
                height: r.height * extent.height
            )
        } else if let aspect = spec.aspect, let ratio = Self.parseAspect(aspect) {
            if extent.width / extent.height > ratio {
                let width = extent.height * ratio
                rect = CGRect(x: extent.minX + (extent.width - width) / 2, y: extent.minY, width: width, height: extent.height)
            } else {
                let height = extent.width / ratio
                rect = CGRect(x: extent.minX, y: extent.minY + (extent.height - height) / 2, width: extent.width, height: height)
            }
        }
        rect = rect.integral.intersection(extent)
        guard !rect.isEmpty else { return image }
        let result = image.cropped(to: rect)
        return result.transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    }

    static func parseAspect(_ text: String) -> Double? {
        let parts = text.split(whereSeparator: { $0 == ":" || $0 == "x" || $0 == "/" }).compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return parts[0] / parts[1]
    }

    // MARK: - 워터마크

    private func watermarked(_ base: CIImage, _ spec: WatermarkSpec) throws -> CIImage {
        let extent = base.extent
        let mark: CIImage
        if let path = spec.imagePath, !path.isEmpty {
            guard let loaded = CIImage(contentsOf: URL(fileURLWithPath: path), options: [.applyOrientationProperty: true]) else {
                throw FileSkillError.unreadable(URL(fileURLWithPath: path).lastPathComponent)
            }
            mark = loaded.transformed(by: CGAffineTransform(translationX: -loaded.extent.minX, y: -loaded.extent.minY))
        } else if let text = spec.text, !text.isEmpty, let rendered = Self.renderText(text) {
            mark = CIImage(cgImage: rendered)
        } else {
            return base
        }

        let targetWidth = max(1, Int((extent.width * spec.sizePercent / 100).rounded()))
        let targetHeight = max(1, Int((CGFloat(targetWidth) * mark.extent.height / mark.extent.width).rounded()))
        var placed = scaled(mark, toWidth: targetWidth, height: targetHeight)

        if spec.opacity < 1 {
            placed = placed.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: max(0, spec.opacity)),
            ])
        }

        let margin = min(extent.width, extent.height) * spec.marginPercent / 100
        let w = CGFloat(targetWidth), h = CGFloat(targetHeight)
        let x: CGFloat, y: CGFloat
        switch spec.position {
        case .topLeft, .left, .bottomLeft: x = margin
        case .top, .center, .bottom: x = (extent.width - w) / 2
        case .topRight, .right, .bottomRight: x = extent.width - w - margin
        }
        switch spec.position {
        case .bottomLeft, .bottom, .bottomRight: y = margin
        case .left, .center, .right: y = (extent.height - h) / 2
        case .topLeft, .top, .topRight: y = extent.height - h - margin
        }
        let moved = placed.transformed(by: CGAffineTransform(translationX: extent.minX + x, y: extent.minY + y))
        return moved.composited(over: base)
    }

    /// 흰 글자 + 부드러운 그림자로 그린 글자 이미지(sRGB, 알파 있음). 어떤 배경 위에서도 읽히게 한다.
    static func renderText(_ text: String) -> CGImage? {
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, 160, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font,
            NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
        let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let pad: CGFloat = 28
        let width = Int(ceil(bounds.width + pad * 2)), height = Int(ceil(bounds.height + pad * 2))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setShadow(offset: CGSize(width: 0, height: -3), blur: 9, color: CGColor(gray: 0, alpha: 0.55))
        context.textPosition = CGPoint(x: pad - bounds.minX, y: pad - bounds.minY)
        CTLineDraw(line, context)
        return context.makeImage()
    }

    // MARK: - 인코딩

    private func outputColorSpace(_ target: ColorSpaceTarget, _ loaded: Loaded) -> CGColorSpace {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        switch target {
        case .sRGB: return srgb
        case .displayP3: return CGColorSpace(name: CGColorSpace.displayP3) ?? srgb
        case .keep:
            // RAW는 프로필이 없어서 sRGB. 그 밖에는 원본 프로필 그대로(RGB·흑백만, CMYK 등은 sRGB로).
            if !loaded.isRAW, let space = loaded.colorSpace, space.model == .rgb || space.model == .monochrome { return space }
            return srgb
        }
    }

    private func encode(_ loaded: Loaded, target: ColorSpaceTarget, metadata: MetadataSpec, spec: EncodeSpec) throws -> FileResult {
        if spec.format == .webp, !Self.canWrite(.webp) { throw FileSkillError.unsupportedFormat("WebP") }

        let outSpace = outputColorSpace(target, loaded)
        let isGray = outSpace.model == .monochrome
        if !Self.canWrite(spec.format) { throw FileSkillError.unsupportedFormat(spec.format.title) }
        let isLosslessContainer = spec.format.keepsHighPrecision
        let bits16 = isLosslessContainer && loaded.isHighPrecision
        // 결과가 16비트일 때만 32비트 float로 처리한다. 8비트로 저장할 거면 half float로 충분하고 메모리도 절반이다.
        let context = makeContext(precise: bits16)

        var image = loaded.image
        var keepsAlpha = loaded.hasAlpha && !isGray && !spec.format.flattensAlpha
        if loaded.hasAlpha && spec.format.flattensAlpha {
            // JPEG에는 투명이 없으니 흰 배경 위에 올린다
            image = image.composited(over: CIImage(color: .white).cropped(to: image.extent))
            keepsAlpha = false
        }
        let extent = image.extent
        let width = Int(extent.width), height = Int(extent.height)

        func properties(for size: (Int, Int)) -> [String: Any] {
            var props = ImageMetadata.outputProperties(
                source: loaded.properties, spec: metadata, width: size.0, height: size.1,
                outputIsSRGB: outSpace.name == CGColorSpace.sRGB
            )
            if spec.format == .tiff {
                var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
                tiff[kCGImagePropertyTIFFCompression as String] = 5  // LZW (무손실)
                props[kCGImagePropertyTIFFDictionary as String] = tiff
            }
            return props
        }

        func render(_ source: CIImage) throws -> CGImage {
            try Self.renderBitmap(source, context: context, colorSpace: outSpace, bits16: bits16, gray: isGray, alpha: keepsAlpha)
        }

        let startQuality = spec.quality ?? (spec.format == .heic ? 0.8 : 0.9)
        func data(from cgImage: CGImage, quality: Double?) throws -> Data {
            try Self.write(cgImage, format: spec.format, quality: quality, properties: properties(for: (cgImage.width, cgImage.height)))
        }

        let first = try render(image)
        guard let maxBytes = spec.maxBytes else {
            return FileResult(data: try data(from: first, quality: startQuality), fileExtension: spec.format.fileExtension, width: width, height: height)
        }

        // 목표 크기: 품질을 이분탐색으로 낮추고, 그래도 크면 크기를 줄여서 다시 시도한다.
        let minQuality = 0.4
        var scale = 1.0
        var current = first
        for attempt in 0..<10 {
            if attempt > 0 {
                let w = max(1, Int((Double(width) * scale).rounded())), h = max(1, Int((Double(height) * scale).rounded()))
                current = try render(scaled(image, toWidth: w, height: h))
            }
            var lastSize: Int
            if spec.format.isLossy {
                let best = try data(from: current, quality: startQuality)
                if best.count <= maxBytes { return result(best, current) }
                let floor = try data(from: current, quality: minQuality)
                if floor.count <= maxBytes {
                    var low = minQuality, high = startQuality, found = floor
                    for _ in 0..<7 {
                        let mid = (low + high) / 2
                        let candidate = try data(from: current, quality: mid)
                        if candidate.count <= maxBytes { found = candidate; low = mid } else { high = mid }
                    }
                    return result(found, current)
                }
                lastSize = floor.count
            } else {
                let d = try data(from: current, quality: nil)
                if d.count <= maxBytes { return result(d, current) }
                lastSize = d.count
            }
            // 파일 크기는 대략 픽셀 수에 비례한다
            let ratio = (Double(maxBytes) / Double(lastSize)).squareRoot() * 0.95
            scale *= min(0.9, max(0.3, ratio))
        }
        throw FileSkillError.cannotReachTargetSize(maxBytes)

        func result(_ data: Data, _ cgImage: CGImage) -> FileResult {
            FileResult(data: data, fileExtension: spec.format.fileExtension, width: cgImage.width, height: cgImage.height)
        }
    }

    /// Core Image로 한 번만 그려서 `CGImage`로 만든다. 프로필이 붙은 채로 나온다.
    static func renderBitmap(_ image: CIImage, context: CIContext, colorSpace: CGColorSpace, bits16: Bool, gray: Bool, alpha: Bool) throws -> CGImage {
        let bounds = image.extent.integral
        let width = Int(bounds.width), height = Int(bounds.height)
        let channels = gray ? 1 : 4
        let bytesPerComponent = bits16 ? 2 : 1
        let rowBytes = width * channels * bytesPerComponent
        var buffer = Data(count: rowBytes * height)
        let format: CIFormat = gray ? (bits16 ? .L16 : .L8) : (bits16 ? .RGBA16 : .RGBA8)
        buffer.withUnsafeMutableBytes { pointer in
            context.render(image, toBitmap: pointer.baseAddress!, rowBytes: rowBytes, bounds: bounds, format: format, colorSpace: colorSpace)
        }

        var info: UInt32 = gray ? CGImageAlphaInfo.none.rawValue
            : (alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)
        if bits16 { info |= CGBitmapInfo.byteOrder16Little.rawValue }
        guard let provider = CGDataProvider(data: buffer as CFData),
              let cgImage = CGImage(
                width: width, height: height,
                bitsPerComponent: bits16 ? 16 : 8, bitsPerPixel: channels * bytesPerComponent * 8,
                bytesPerRow: rowBytes, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: info),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              ) else {
            throw FileSkillError.encodeFailed(L("이미지를 그리지 못했어요", "Couldn't render the image"))
        }
        return cgImage
    }

    static func canWrite(_ format: OutputFormat) -> Bool {
        guard let identifier = uti(for: format) else { return false }
        return ((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []).contains(identifier)
    }

    private static func uti(for format: OutputFormat) -> String? {
        switch format {
        case .jpg: return UTType.jpeg.identifier
        case .heic: return UTType.heic.identifier
        case .png: return UTType.png.identifier
        case .tiff: return UTType.tiff.identifier
        case .webp: return "org.webmproject.webp"
        case .avif: return "public.avif"
        case .gif: return UTType.gif.identifier
        case .bmp: return UTType.bmp.identifier
        case .psd: return "com.adobe.photoshop-image"
        }
    }

    static func write(_ image: CGImage, format: OutputFormat, quality: Double?, properties: [String: Any]) throws -> Data {
        guard let identifier = uti(for: format) else { throw FileSkillError.unsupportedFormat(format.rawValue) }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, identifier as CFString, 1, nil) else {
            throw FileSkillError.unsupportedFormat(format.rawValue.uppercased())
        }
        var options = properties
        if let quality, format.isLossy { options[kCGImageDestinationLossyCompressionQuality as String] = quality }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw FileSkillError.encodeFailed(L("파일로 쓰지 못했어요", "Couldn't write the file")) }
        return output as Data
    }
}
