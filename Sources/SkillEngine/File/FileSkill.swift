import Foundation

// 파일 스킬 = 파일 블록을 순서대로 늘어놓은 목록. 글자 스킬(Skill)과 같은 생각이다:
// "AI가 만든 코드를 실행하는 게 아니라, 앱이 미리 가진 블록만 조합한다".
// 규칙: 원본을 쓰는 블록은 없다(모든 출력은 새 파일). 삭제하는 블록도 없다.

/// 입력 파일의 종류. 스킬의 `input`에 적어서 "이 스킬은 어떤 파일에 쓰는지"를 나타낸다.
public enum FileKind: String, Codable, CaseIterable, Sendable {
    case image, raw, pdf, text, video
    /// Word·RTF·OpenDocument·EPUB 같은 서식 있는 문서
    case document
}

/// 영상 결과 형식. MP4·MOV는 맥 기본 엔진, 나머지는 설치된 ffmpeg로 만든다.
public enum VideoFormat: String, Codable, CaseIterable, Sendable {
    case mp4, mov, mkv, webm, avi, wmv, gif, mp3, m4a

    public var fileExtension: String { rawValue }
    public var title: String { rawValue.uppercased() }
    public var isAudio: Bool { self == .mp3 || self == .m4a }
    /// 맥 기본 영상 엔진(AVFoundation)으로 만들 수 있는지
    public var isNative: Bool { self == .mp4 || self == .mov || self == .m4a }
}

/// 영상 변환 품질(맥에 들어 있는 AVFoundation 내보내기 설정)
public enum VideoPreset: String, Codable, CaseIterable, Sendable {
    /// 다시 인코딩하지 않고 그대로(자르기만 할 때 빠르고 화질 손실 없음)
    case passthrough
    case p1080, hevc1080, p720, p480
    /// 소리만(.m4a)
    case audioOnly

    public var title: String {
        switch self {
        case .passthrough: return L("원본 그대로", "Original")
        case .p1080: return "1080p"
        case .hevc1080: return L("1080p · HEVC(용량 절반)", "1080p · HEVC (half the size)")
        case .p720: return "720p"
        case .p480: return L("480p · 아주 작게", "480p · very small")
        case .audioOnly: return L("소리만(.m4a)", "Audio only (.m4a)")
        }
    }
}

public struct VideoSpec: Equatable, Sendable {
    public var preset: VideoPreset
    /// 자를 구간(초). 없으면 처음/끝까지.
    public var trimStart: Double?
    public var trimEnd: Double?
    public var muted: Bool
    /// 결과 형식. nil이면 예전처럼(소리만이면 M4A, 아니면 MP4·원본이 MOV면 MOV)
    public var format: VideoFormat?

    public init(preset: VideoPreset, trimStart: Double? = nil, trimEnd: Double? = nil, muted: Bool = false, format: VideoFormat? = nil) {
        self.preset = preset
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.muted = muted
        self.format = format
    }

    /// 실제로 만들 형식
    public func resolvedFormat(input: URL) -> VideoFormat {
        if let format { return format }
        if preset == .audioOnly { return .m4a }
        return preset == .passthrough && input.pathExtension.lowercased() == "mov" ? .mov : .mp4
    }
}

public enum OutputFormat: String, Codable, Sendable {
    case jpg, heic, png, tiff, webp, avif, gif, bmp, psd

    public var fileExtension: String { rawValue }
    /// 품질 값으로 크기를 조절할 수 있는 형식
    public var isLossy: Bool { self == .jpg || self == .heic || self == .webp || self == .avif }
    /// 투명을 담을 수 없는 형식(투명한 곳은 흰 배경 위에 올린다)
    public var flattensAlpha: Bool { self == .jpg || self == .bmp }
    /// 16비트까지 그대로 담는 무손실 형식
    public var keepsHighPrecision: Bool { self == .png || self == .tiff || self == .psd }
    public var title: String { self == .jpg ? "JPG" : rawValue.uppercased() }
}

public enum ColorSpaceTarget: String, Codable, Sendable {
    /// 원본의 색 프로필을 그대로(RAW처럼 프로필이 없으면 sRGB)
    case keep
    case sRGB
    case displayP3
}

public enum MetadataMode: String, Codable, Sendable {
    /// 전부 유지
    case keepAll
    /// 위치(GPS) 정보만 삭제
    case removeGPS
    /// 카메라·렌즈·촬영 설정·촬영 시각만 남기고 나머지 삭제
    case keepCameraOnly
    /// 전부 삭제 (색 프로필은 색이 틀어지지 않게 남긴다)
    case removeAll
}

public struct MetadataSpec: Equatable, Sendable {
    public var mode: MetadataMode
    /// 적어두면 작가·저작권 칸에 기입한다(모드와 상관없이)
    public var artist: String?
    public var copyright: String?

    public init(mode: MetadataMode = .keepAll, artist: String? = nil, copyright: String? = nil) {
        self.mode = mode
        self.artist = artist
        self.copyright = copyright
    }
}

public enum ResizeSpec: Equatable, Sendable {
    case longEdge(Int)
    case shortEdge(Int)
    case percent(Double)
}

/// 자르기. `rect`가 있으면 그 영역(0~1 비율, 왼쪽 위가 원점), 없으면 `aspect`("3:2")로 가운데를 자른다.
public struct CropSpec: Equatable, Sendable {
    public struct Rect: Equatable, Sendable {
        public var x: Double, y: Double, width: Double, height: Double
        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }
    }

    public var rect: Rect?
    public var aspect: String?

    public init(rect: Rect? = nil, aspect: String? = nil) {
        self.rect = rect
        self.aspect = aspect
    }
}

public enum WatermarkPosition: String, Codable, CaseIterable, Sendable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight
}

public struct WatermarkSpec: Equatable, Sendable {
    public var text: String?
    /// 이미지 워터마크 파일 경로(알파가 있는 PNG 권장). text와 둘 중 하나.
    public var imagePath: String?
    public var position: WatermarkPosition
    /// 0(투명)~1(불투명)
    public var opacity: Double
    /// 워터마크 가로 길이: 사진 가로의 몇 %인지
    public var sizePercent: Double
    /// 가장자리 여백: 사진 짧은 변의 몇 %인지
    public var marginPercent: Double

    public init(text: String? = nil, imagePath: String? = nil, position: WatermarkPosition = .bottomRight,
                opacity: Double = 0.6, sizePercent: Double = 20, marginPercent: Double = 2.5) {
        self.text = text
        self.imagePath = imagePath
        self.position = position
        self.opacity = opacity
        self.sizePercent = sizePercent
        self.marginPercent = marginPercent
    }
}

public struct EncodeSpec: Equatable, Sendable {
    public var format: OutputFormat
    /// 0~1. 없으면 형식별 기본값. 손실 압축(jpg·heic)에서만 의미가 있다.
    public var quality: Double?
    /// 결과 파일 크기 상한(바이트). 품질을 이분탐색으로 낮추고, 그래도 크면 크기를 줄여서 다시 시도한다.
    public var maxBytes: Int?
    /// 원본과 같은 형식으로 저장(회전·반전처럼 형식을 바꿀 일이 없는 도구). `format`은 원본 형식을 못 쓸 때(RAW 등) 대신 쓴다.
    public var sameAsInput: Bool

    public init(format: OutputFormat, quality: Double? = nil, maxBytes: Int? = nil, sameAsInput: Bool = false) {
        self.format = format
        self.quality = quality
        self.maxBytes = maxBytes
        self.sameAsInput = sameAsInput
    }
}

extension OutputFormat {
    /// 원본 확장자에 맞는 저장 형식(저장할 수 없는 형식이면 nil)
    public static func matching(extension ext: String) -> OutputFormat? {
        switch ext.lowercased() {
        case "jpg", "jpeg": return .jpg
        case "png": return .png
        case "heic", "heif": return .heic
        case "tif", "tiff": return .tiff
        case "avif": return .avif
        case "gif": return .gif
        case "bmp": return .bmp
        case "psd": return .psd
        default: return nil
        }
    }
}

/// 파일 블록. JSON에서는 `"block"` 값으로 종류를 구분한다.
public enum FileStep: Equatable, Sendable {
    /// 이미지·RAW 읽기 (생략해도 맨 앞에서 자동으로 한다)
    case decode
    case colorspace(ColorSpaceTarget)
    /// 작은 사진은 키우지 않는다(`allowUpscale`을 켜면 키움)
    case resize(ResizeSpec, allowUpscale: Bool = false)
    case crop(CropSpec)
    case metadata(MetadataSpec)
    case watermark(WatermarkSpec)
    case encode(EncodeSpec)
    /// PDF → Word(.docx): 글자·문단·제목·굵게/기울임을 옮긴다
    case pdfToDocx
    /// PDF → 텍스트(.txt): 문단마다 빈 줄. `keepLineBreaks`면 PDF 줄바꿈 그대로
    case pdfToText(keepLineBreaks: Bool = false)
    /// 사진 → 글자 인식(OCR, 한국어·영어) → 텍스트(.txt)
    case ocrText
    /// 90도 단위 회전(시계 방향: 90·180·270)
    case rotate(degrees: Int)
    case flip(horizontal: Bool, vertical: Bool)
    /// 밝기(-1~1, 0=그대로)·대비(0.25~4, 1=그대로)·채도(0~2, 1=그대로)
    case adjust(brightness: Double, contrast: Double, saturation: Double)
    /// 영상 변환·자르기·소리 끄기·소리만 뽑기
    case video(VideoSpec)
    /// 사진·스캔 PDF → 보이지 않는 글자 층을 얹은 PDF(검색·복사 가능, 보이는 모양은 그대로)
    case ocrPDF
    /// 사진 → PDF 한 쪽(글자 인식 없이)
    case imageToPDF
    /// 문서끼리 바꾸기(Word·RTF·ODT·HTML·Markdown·텍스트·EPUB·PDF 아무거나 → 아무거나)
    case document(DocumentFormat)
    /// PDF → 쪽마다 사진(JPG·PNG, 기본 300DPI). 여러 쪽이면 폴더 하나에 담는다
    case pdfToImages(OutputFormat, dpi: Int)
    /// PDF → PowerPoint(쪽마다 슬라이드 한 장)
    case pdfToSlides
    /// PDF → Excel(줄은 행, 넓은 빈칸은 칸)
    case pdfToSheet
    /// 스캔한 로고·선화 → 벡터(SVG·PDF)
    case vectorize(VectorFormat)

    /// 결과 파일을 만드는 마지막 블록인지
    public var isOutput: Bool {
        switch self {
        case .encode, .pdfToDocx, .pdfToText, .ocrText, .ocrPDF, .imageToPDF, .video, .document, .pdfToImages, .pdfToSlides, .pdfToSheet, .vectorize: return true
        default: return false
        }
    }

    /// 문서를 만드는 블록인지(사진 블록과 섞을 수 없다)
    public var isDocumentOutput: Bool {
        switch self {
        case .pdfToDocx, .pdfToText, .ocrText, .ocrPDF, .imageToPDF, .video, .document, .pdfToImages, .pdfToSlides, .pdfToSheet, .vectorize: return true
        default: return false
        }
    }
}

public struct FileOutput: Codable, Equatable, Sendable {
    /// 원본 이름 뒤에 붙는 글자. 예: `_web` → DSCF0001_web.jpg
    public var suffix: String

    public init(suffix: String) { self.suffix = suffix }
}

public struct FileSkill: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// SF Symbols 이름(휠 칸 아이콘)
    public var symbol: String?
    public var input: [FileKind]
    public var steps: [FileStep]
    public var output: FileOutput

    public init(id: String, name: String, symbol: String? = nil, input: [FileKind], steps: [FileStep], output: FileOutput) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.input = input
        self.steps = steps
        self.output = output
    }
}

// MARK: - 오류

public enum FileSkillError: LocalizedError, Equatable {
    case invalidSkill(String)
    case unreadable(String)
    case wrongKind(file: String)
    case unsupportedFormat(String)
    case cannotReachTargetSize(Int)
    case encodeFailed(String)
    case outputFolderNotWritable(String)
    case unsafeOutputPath
    case encryptedPDF(String)
    case noTextInPDF(String)
    case noTextFound(String)
    case notText(String)
    case tooLarge(String)
    case noAudio(String)
    case noVideoTrack(String)
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSkill(let why): return L("스킬이 올바르지 않아요: \(why)", "Invalid skill: \(why)")
        case .unreadable(let name): return L("“\(name)”을(를) 읽지 못했어요", "Couldn't read “\(name)”")
        case .wrongKind(let file): return L("“\(file)”은(는) 이 스킬로 바꿀 수 없는 파일이에요", "“\(file)” can't be converted with this skill")
        case .unsupportedFormat(let name): return L("이 맥에서는 \(name) 저장을 지원하지 않아요", "This Mac can't save \(name)")
        case .cannotReachTargetSize(let bytes): return L("크기를 줄여도 \(bytes / 1000)KB 이하로 만들지 못했어요", "Couldn't get it under \(bytes / 1000) KB even after shrinking")
        case .encodeFailed(let why): return L("저장 형식으로 바꾸지 못했어요: \(why)", "Couldn't encode the output: \(why)")
        case .outputFolderNotWritable(let folder): return L("“\(folder)” 폴더에 쓸 수 없어요 (읽기 전용이거나 권한이 없을 수 있어요)", "Can't write to the “\(folder)” folder (it may be read-only or need permission)")
        case .unsafeOutputPath: return L("결과 파일을 원본이 있는 폴더 밖에 저장하려고 해서 막았어요", "Blocked: the result would be saved outside the original's folder")
        case .encryptedPDF(let name): return L("“\(name)”은(는) 암호가 걸린 PDF라 열 수 없어요", "“\(name)” is a password-protected PDF")
        case .noTextInPDF(let name): return L("“\(name)”에서 글자를 찾지 못했어요(빈 쪽이거나 글자가 너무 흐릴 수 있어요)", "No text found in “\(name)” (pages may be blank or too blurry)")
        case .noAudio(let name): return L("“\(name)”에는 소리가 없어요", "“\(name)” has no audio")
        case .noVideoTrack(let name): return L("“\(name)”에서 영상을 찾지 못했어요", "No video track in “\(name)”")
        case .exportFailed(let why): return L("영상을 내보내지 못했어요: \(why)", "Couldn't export the video: \(why)")
        case .tooLarge(let name): return L("“\(name)”이(가) 너무 커서 열지 않았어요", "“\(name)” is too large to open")
        case .notText(let name): return L("“\(name)”은(는) 글로 된 파일이 아니라서 읽을 글이 없어요", "“\(name)” isn't a text document, so there's nothing to read")
        case .noTextFound(let name): return L("“\(name)”에서 글자를 찾지 못했어요(글자가 너무 작거나 흐릴 수 있어요)", "No text found in “\(name)” (text may be too small or blurry)")
        }
    }
}

// MARK: - 검사와 사람이 읽는 이름

extension FileSkill {
    /// 스킬이 실행 가능한 모양인지: decode는 있다면 맨 앞, encode는 정확히 하나이고 맨 끝.
    public func validate() throws {
        guard !input.isEmpty else { throw FileSkillError.invalidSkill(L("입력 파일 종류(input)가 비어 있어요", "The input file kinds (input) are empty")) }
        guard let last = steps.last, last.isOutput else {
            throw FileSkillError.invalidSkill(L("마지막 블록은 결과를 만드는 블록(encode·pdfToDocx·pdfToText·ocrText·ocrPDF·imageToPDF)이어야 해요", "The last block must produce output (encode, pdfToDocx, pdfToText, ocrText, ocrPDF, imageToPDF)"))
        }
        guard steps.filter(\.isOutput).count == 1 else { throw FileSkillError.invalidSkill(L("결과를 만드는 블록은 하나만 둘 수 있어요", "Only one output block is allowed")) }
        if last.isDocumentOutput, steps.dropLast().contains(where: { $0 != .decode }) {
            throw FileSkillError.invalidSkill(L("문서를 만드는 스킬에는 사진 블록(크기·색·워터마크 등)을 넣을 수 없어요", "Document skills can't contain photo blocks (size, color, watermark…)"))
        }
        if let index = steps.firstIndex(of: .decode), index != 0 {
            throw FileSkillError.invalidSkill(L("decode는 맨 앞에 와야 해요", "decode must come first"))
        }
        guard !output.suffix.contains("/"), !output.suffix.contains("..") else {
            throw FileSkillError.invalidSkill(L("output.suffix에는 / 나 .. 를 쓸 수 없어요", "output.suffix can't contain / or .."))
        }
    }

    /// 휠 가운데 등에 보여줄 한 줄 설명 (decode는 뺀다)
    public var summary: String {
        steps.filter { $0 != .decode }.map(\.displayName).joined(separator: " · ")
    }
}

extension FileStep {
    public var displayName: String {
        switch self {
        case .decode: return L("읽기", "Read")
        case .colorspace(let target):
            switch target {
            case .keep: return L("색 유지", "Keep color")
            case .sRGB: return "sRGB"
            case .displayP3: return "Display P3"
            }
        case .resize(let spec, _):
            switch spec {
            case .longEdge(let n): return L("긴 변 \(n)px", "Long edge \(n)px")
            case .shortEdge(let n): return L("짧은 변 \(n)px", "Short edge \(n)px")
            case .percent(let p): return L("\(Int(p))%로", "To \(Int(p))%")
            }
        case .crop(let spec):
            return spec.aspect.map { L("\($0)로 자르기", "Crop to \($0)") } ?? L("자르기", "Crop")
        case .metadata(let spec):
            switch spec.mode {
            case .keepAll: return L("메타데이터 유지", "Keep metadata")
            case .removeGPS: return L("위치 삭제", "Remove location")
            case .keepCameraOnly: return L("카메라 정보만", "Camera info only")
            case .removeAll: return L("메타데이터 삭제", "Remove metadata")
            }
        case .watermark(let spec):
            return spec.text.map { L("워터마크 “\($0)”", "Watermark “\($0)”") } ?? L("워터마크", "Watermark")
        case .pdfToDocx:
            return L("Word(.docx)로", "To Word (.docx)")
        case .pdfToText(let keepLineBreaks):
            return keepLineBreaks ? L("텍스트(.txt)로 · 줄바꿈 유지", "To text (.txt) · keep line breaks") : L("텍스트(.txt)로", "To text (.txt)")
        case .rotate(let degrees):
            return L("\(degrees)° 회전", "Rotate \(degrees)°")
        case .flip(let horizontal, let vertical):
            return [horizontal ? L("좌우 반전", "Flip horizontal") : nil, vertical ? L("상하 반전", "Flip vertical") : nil].compactMap { $0 }.joined(separator: "·")
        case .adjust:
            return L("밝기·대비·채도 조정", "Brightness · contrast · saturation")
        case .video(let spec):
            var parts = [spec.preset.title]
            if spec.trimStart != nil || spec.trimEnd != nil { parts.append(L("구간 자르기", "Trim")) }
            if spec.muted { parts.append(L("소리 끄기", "Mute")) }
            return parts.joined(separator: " · ")
        case .ocrText:
            return L("글자 인식 → 텍스트(.txt)", "Recognize text → .txt")
        case .ocrPDF:
            return L("글자 인식 → 검색되는 PDF", "Recognize text → searchable PDF")
        case .document(let format):
            return L("\(format.title)(.\(format.fileExtension))로", "To \(format.title) (.\(format.fileExtension))")
        case .pdfToImages(let format, let dpi):
            return L("쪽마다 \(format.title) · \(dpi)DPI", "\(format.title) per page · \(dpi) DPI")
        case .pdfToSlides:
            return L("PowerPoint(.pptx) · 쪽마다 슬라이드", "PowerPoint (.pptx) · a slide per page")
        case .pdfToSheet:
            return L("Excel(.xlsx) · 줄은 행, 빈칸은 칸", "Excel (.xlsx) · lines to rows")
        case .vectorize(let format):
            return L("선을 따라 다시 그리기 → \(format.rawValue.uppercased()) · 로고·선화용", "Trace to \(format.rawValue.uppercased()) · logos & line art")
        case .imageToPDF:
            return L("PDF로", "To PDF")
        case .encode(let spec):
            var text = spec.format.rawValue.uppercased()
            if let max = spec.maxBytes { let size = max >= 1_000_000 ? "\(max / 1_000_000)MB" : "\(max / 1000)KB"; text += L(" \(size) 이하", " ≤ \(size)") }
            return text
        }
    }
}
