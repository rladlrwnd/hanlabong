import Foundation

/// 파일 스킬 JSON 형식. 기본값인 옵션은 저장할 때 생략해서 사람이 읽기 쉽게 한다.
///
/// ```json
/// { "block": "colorspace", "to": "sRGB" }
/// { "block": "resize", "longEdge": 2048 }
/// { "block": "metadata", "mode": "removeGPS", "artist": "Jane Doe", "copyright": "© Jane Doe" }
/// { "block": "watermark", "text": "SAMPLE", "position": "bottomRight", "opacity": 0.6 }
/// { "block": "encode", "format": "jpg", "quality": 0.9, "maxBytes": 2000000 }
/// ```
extension FileStep: Codable {
    private enum Keys: String, CodingKey {
        case block, to, longEdge, shortEdge, percent, allowUpscale
        case aspect, x, y, width, height
        case mode, artist, copyright
        case text, imagePath, position, opacity, sizePercent, marginPercent
        case format, quality, maxBytes, sameAsInput
        case keepLineBreaks
        case degrees, horizontal, vertical, brightness, contrast, saturation
        case preset, trimStart, trimEnd, muted, videoFormat, documentFormat, imageFormat, dpi, vectorFormat
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let block = try c.decode(String.self, forKey: .block)
        switch block {
        case "decode":
            self = .decode
        case "colorspace":
            self = .colorspace(try c.decode(ColorSpaceTarget.self, forKey: .to))
        case "resize":
            let upscale = try c.decodeIfPresent(Bool.self, forKey: .allowUpscale) ?? false
            if let n = try c.decodeIfPresent(Int.self, forKey: .longEdge) {
                self = .resize(.longEdge(n), allowUpscale: upscale)
            } else if let n = try c.decodeIfPresent(Int.self, forKey: .shortEdge) {
                self = .resize(.shortEdge(n), allowUpscale: upscale)
            } else if let p = try c.decodeIfPresent(Double.self, forKey: .percent) {
                self = .resize(.percent(p), allowUpscale: upscale)
            } else {
                throw DecodingError.dataCorruptedError(forKey: .block, in: c, debugDescription: L("resize에는 longEdge, shortEdge, percent 중 하나가 필요해요", "resize needs one of longEdge, shortEdge, percent"))
            }
        case "crop":
            if let x = try c.decodeIfPresent(Double.self, forKey: .x),
               let y = try c.decodeIfPresent(Double.self, forKey: .y),
               let w = try c.decodeIfPresent(Double.self, forKey: .width),
               let h = try c.decodeIfPresent(Double.self, forKey: .height) {
                self = .crop(CropSpec(rect: .init(x: x, y: y, width: w, height: h)))
            } else {
                self = .crop(CropSpec(aspect: try c.decodeIfPresent(String.self, forKey: .aspect)))
            }
        case "metadata":
            self = .metadata(MetadataSpec(
                mode: try c.decodeIfPresent(MetadataMode.self, forKey: .mode) ?? .keepAll,
                artist: try c.decodeIfPresent(String.self, forKey: .artist),
                copyright: try c.decodeIfPresent(String.self, forKey: .copyright)
            ))
        case "watermark":
            self = .watermark(WatermarkSpec(
                text: try c.decodeIfPresent(String.self, forKey: .text),
                imagePath: try c.decodeIfPresent(String.self, forKey: .imagePath),
                position: try c.decodeIfPresent(WatermarkPosition.self, forKey: .position) ?? .bottomRight,
                opacity: try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 0.6,
                sizePercent: try c.decodeIfPresent(Double.self, forKey: .sizePercent) ?? 20,
                marginPercent: try c.decodeIfPresent(Double.self, forKey: .marginPercent) ?? 2.5
            ))
        case "encode":
            self = .encode(EncodeSpec(
                format: try c.decode(OutputFormat.self, forKey: .format),
                quality: try c.decodeIfPresent(Double.self, forKey: .quality),
                maxBytes: try c.decodeIfPresent(Int.self, forKey: .maxBytes),
                sameAsInput: try c.decodeIfPresent(Bool.self, forKey: .sameAsInput) ?? false
            ))
        case "pdfToDocx":
            self = .pdfToDocx
        case "pdfToText":
            self = .pdfToText(keepLineBreaks: try c.decodeIfPresent(Bool.self, forKey: .keepLineBreaks) ?? false)
        case "rotate":
            self = .rotate(degrees: try c.decode(Int.self, forKey: .degrees))
        case "flip":
            self = .flip(horizontal: try c.decodeIfPresent(Bool.self, forKey: .horizontal) ?? false,
                         vertical: try c.decodeIfPresent(Bool.self, forKey: .vertical) ?? false)
        case "adjust":
            self = .adjust(brightness: try c.decodeIfPresent(Double.self, forKey: .brightness) ?? 0,
                           contrast: try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 1,
                           saturation: try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 1)
        case "video":
            self = .video(VideoSpec(
                preset: try c.decode(VideoPreset.self, forKey: .preset),
                trimStart: try c.decodeIfPresent(Double.self, forKey: .trimStart),
                trimEnd: try c.decodeIfPresent(Double.self, forKey: .trimEnd),
                muted: try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false,
                format: try c.decodeIfPresent(VideoFormat.self, forKey: .videoFormat)))
        case "ocrText":
            self = .ocrText
        case "ocrPDF":
            self = .ocrPDF
        case "imageToPDF":
            self = .imageToPDF
        case "document":
            self = .document(try c.decode(DocumentFormat.self, forKey: .documentFormat))
        case "pdfToImages":
            self = .pdfToImages(try c.decodeIfPresent(OutputFormat.self, forKey: .imageFormat) ?? .png, dpi: try c.decodeIfPresent(Int.self, forKey: .dpi) ?? 300)
        case "pdfToSlides":
            self = .pdfToSlides
        case "pdfToSheet":
            self = .pdfToSheet
        case "vectorize":
            self = .vectorize(try c.decodeIfPresent(VectorFormat.self, forKey: .vectorFormat) ?? .svg)
        default:
            throw DecodingError.dataCorruptedError(forKey: .block, in: c, debugDescription: L("알 수 없는 블록 “\(block)”", "Unknown block “\(block)”"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .decode:
            try c.encode("decode", forKey: .block)
        case .colorspace(let target):
            try c.encode("colorspace", forKey: .block)
            try c.encode(target, forKey: .to)
        case .resize(let spec, let allowUpscale):
            try c.encode("resize", forKey: .block)
            switch spec {
            case .longEdge(let n): try c.encode(n, forKey: .longEdge)
            case .shortEdge(let n): try c.encode(n, forKey: .shortEdge)
            case .percent(let p): try c.encode(p, forKey: .percent)
            }
            if allowUpscale { try c.encode(true, forKey: .allowUpscale) }
        case .crop(let spec):
            try c.encode("crop", forKey: .block)
            if let rect = spec.rect {
                try c.encode(rect.x, forKey: .x)
                try c.encode(rect.y, forKey: .y)
                try c.encode(rect.width, forKey: .width)
                try c.encode(rect.height, forKey: .height)
            } else if let aspect = spec.aspect {
                try c.encode(aspect, forKey: .aspect)
            }
        case .metadata(let spec):
            try c.encode("metadata", forKey: .block)
            try c.encode(spec.mode, forKey: .mode)
            if let artist = spec.artist { try c.encode(artist, forKey: .artist) }
            if let copyright = spec.copyright { try c.encode(copyright, forKey: .copyright) }
        case .watermark(let spec):
            try c.encode("watermark", forKey: .block)
            if let text = spec.text { try c.encode(text, forKey: .text) }
            if let path = spec.imagePath { try c.encode(path, forKey: .imagePath) }
            try c.encode(spec.position, forKey: .position)
            try c.encode(spec.opacity, forKey: .opacity)
            try c.encode(spec.sizePercent, forKey: .sizePercent)
            try c.encode(spec.marginPercent, forKey: .marginPercent)
        case .pdfToDocx:
            try c.encode("pdfToDocx", forKey: .block)
        case .pdfToText(let keepLineBreaks):
            try c.encode("pdfToText", forKey: .block)
            if keepLineBreaks { try c.encode(true, forKey: .keepLineBreaks) }
        case .rotate(let degrees):
            try c.encode("rotate", forKey: .block)
            try c.encode(degrees, forKey: .degrees)
        case .flip(let horizontal, let vertical):
            try c.encode("flip", forKey: .block)
            if horizontal { try c.encode(true, forKey: .horizontal) }
            if vertical { try c.encode(true, forKey: .vertical) }
        case .adjust(let brightness, let contrast, let saturation):
            try c.encode("adjust", forKey: .block)
            try c.encode(brightness, forKey: .brightness)
            try c.encode(contrast, forKey: .contrast)
            try c.encode(saturation, forKey: .saturation)
        case .video(let spec):
            try c.encode("video", forKey: .block)
            try c.encode(spec.preset, forKey: .preset)
            if let s = spec.trimStart { try c.encode(s, forKey: .trimStart) }
            if let e = spec.trimEnd { try c.encode(e, forKey: .trimEnd) }
            if spec.muted { try c.encode(true, forKey: .muted) }
            if let f = spec.format { try c.encode(f, forKey: .videoFormat) }
        case .ocrText:
            try c.encode("ocrText", forKey: .block)
        case .ocrPDF:
            try c.encode("ocrPDF", forKey: .block)
        case .imageToPDF:
            try c.encode("imageToPDF", forKey: .block)
        case .document(let format):
            try c.encode("document", forKey: .block)
            try c.encode(format, forKey: .documentFormat)
        case .pdfToImages(let format, let dpi):
            try c.encode("pdfToImages", forKey: .block)
            try c.encode(format, forKey: .imageFormat)
            try c.encode(dpi, forKey: .dpi)
        case .pdfToSlides:
            try c.encode("pdfToSlides", forKey: .block)
        case .pdfToSheet:
            try c.encode("pdfToSheet", forKey: .block)
        case .vectorize(let format):
            try c.encode("vectorize", forKey: .block)
            try c.encode(format, forKey: .vectorFormat)
        case .encode(let spec):
            try c.encode("encode", forKey: .block)
            try c.encode(spec.format, forKey: .format)
            if let quality = spec.quality { try c.encode(quality, forKey: .quality) }
            if let max = spec.maxBytes { try c.encode(max, forKey: .maxBytes) }
            if spec.sameAsInput { try c.encode(true, forKey: .sameAsInput) }
        }
    }
}
