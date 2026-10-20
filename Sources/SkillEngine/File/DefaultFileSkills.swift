import Foundation

/// 기본 사진 프리셋 3개. 휠의 칸 하나 = 스킬 하나이고, 사진 프리셋도 스킬이다.
/// (설정에서 편집하는 기능은 8단계에서 붙는다. 그때까지는 여기 값이 기본값이다.)
public enum DefaultFileSkills {
    /// 클라이언트 샘플에 찍는 글자. 작가·저작권은 기본으로 비워 둔다(설정 › 사진 프리셋에서 자기 이름을 넣는다).
    static let sampleMark = "SAMPLE"

    /// 웹용: 낮은 해상도, sRGB, 위치 정보 삭제, 2MB 이하 (작가·저작권은 설정에서 넣으면 기입)
    public static let web = FileSkill(
        id: "photo-web", name: L("웹용", "Web"), symbol: "globe",
        input: [.image, .raw],
        steps: [
            .decode,
            .colorspace(.sRGB),
            .resize(.longEdge(2048)),
            .metadata(MetadataSpec(mode: .removeGPS)),
            .encode(EncodeSpec(format: .jpg, quality: 0.88, maxBytes: 2_000_000)),
        ],
        output: FileOutput(suffix: "_web")
    )

    /// 클라이언트 샘플용: 고화질, "SAMPLE" 워터마크, 위치 정보 삭제
    public static let clientSample = FileSkill(
        id: "photo-client-sample", name: L("클라이언트 샘플", "Client sample"), symbol: "person.crop.rectangle",
        input: [.image, .raw],
        steps: [
            .decode,
            .colorspace(.sRGB),
            .resize(.longEdge(4096)),
            .watermark(WatermarkSpec(text: sampleMark, position: .bottomRight, opacity: 0.55, sizePercent: 20, marginPercent: 2.5)),
            .metadata(MetadataSpec(mode: .removeGPS)),
            .encode(EncodeSpec(format: .jpg, quality: 0.93)),
        ],
        output: FileOutput(suffix: "_sample")
    )

    /// 미리보기용: 화면 크기에 맞는 픽셀 수, 색과 메타데이터는 전부 유지
    public static let preview = FileSkill(
        id: "photo-preview", name: L("미리보기", "Preview"), symbol: "eye",
        input: [.image, .raw],
        steps: [
            .decode,
            .colorspace(.keep),
            .resize(.longEdge(2560)),
            .metadata(MetadataSpec(mode: .keepAll)),
            .encode(EncodeSpec(format: .jpg, quality: 0.85)),
        ],
        output: FileOutput(suffix: "_preview")
    )

    public static let photoPresets: [FileSkill] = [web, clientSample, preview]

    /// PDF → Word: 같은 이름의 .docx로 원본 옆에 (예: 보고서.pdf → 보고서.docx)
    public static let pdfToWord = FileSkill(
        id: "pdf-word", name: "Word", symbol: "doc.text",
        input: [.pdf], steps: [.pdfToDocx], output: FileOutput(suffix: "")
    )

    /// PDF → 텍스트: 같은 이름의 .txt로 원본 옆에
    public static let pdfToPlainText = FileSkill(
        id: "pdf-text", name: L("텍스트", "Text"), symbol: "text.alignleft",
        input: [.pdf], steps: [.pdfToText()], output: FileOutput(suffix: "")
    )

    /// 사진 → PDF 한 쪽 (사진.jpg → 사진.pdf). 글자 인식 없이 그대로.
    public static let imageToPlainPDF = FileSkill(
        id: "image-pdf", name: L("그냥 PDF", "Plain PDF"), symbol: "doc",
        input: [.image, .raw], steps: [.imageToPDF], output: FileOutput(suffix: "")
    )

    /// 사진·스캔 → 글자를 검색·복사할 수 있는 PDF (보이는 모양은 그대로)
    public static let imageToSearchablePDF = FileSkill(
        id: "image-ocr-pdf", name: L("글자 넣은 PDF", "Searchable PDF"), symbol: "doc.text.magnifyingglass",
        input: [.image, .raw], steps: [.ocrPDF], output: FileOutput(suffix: "")
    )

    /// 사진 → 글자 인식 → 텍스트 (사진.jpg → 사진.txt)
    public static let imageToText = FileSkill(
        id: "image-ocr-text", name: L("OCR 텍스트", "OCR text"), symbol: "text.viewfinder",
        input: [.image, .raw], steps: [.ocrText], output: FileOutput(suffix: "")
    )

    /// 스캔 PDF → 같은 모양 + 글자를 검색·복사할 수 있는 PDF (스캔.pdf → 스캔_ocr.pdf)
    public static let pdfAddText = FileSkill(
        id: "pdf-ocr", name: L("글자 넣기", "Add text layer"), symbol: "text.viewfinder",
        input: [.pdf], steps: [.ocrPDF], output: FileOutput(suffix: "_ocr")
    )

    // MARK: 영상

    private static func video(_ id: String, _ name: String, _ symbol: String, _ preset: VideoPreset, suffix: String) -> FileSkill {
        FileSkill(id: id, name: name, symbol: symbol, input: [.video], steps: [.video(VideoSpec(preset: preset))], output: FileOutput(suffix: suffix))
    }

    public static let video1080 = video("video-1080", "1080p", "play.rectangle", .p1080, suffix: "_1080p")
    public static let videoHEVC = video("video-hevc", "1080p HEVC", "arrow.down.right.and.arrow.up.left", .hevc1080, suffix: "_hevc")
    public static let video720 = video("video-720", "720p", "play.rectangle", .p720, suffix: "_720p")
    public static let video480 = video("video-480", L("480p 작게", "480p small"), "play.rectangle", .p480, suffix: "_480p")
    public static let videoAudio = video("video-audio", L("소리만", "Audio only"), "waveform", .audioOnly, suffix: "")

    /// 영상 휠 2단계(MP4) 기본 프리셋
    public static let videoPresets: [FileSkill] = [video1080, videoHEVC, video720, video480]

    // MARK: 사진 형식 바꾸기 (크기·색·메타데이터는 그대로, 형식만)

    private static func convert(_ format: OutputFormat, symbol: String) -> FileSkill {
        FileSkill(id: "convert-\(format.rawValue)", name: format.title, symbol: symbol, input: [.image, .raw],
                  steps: [.decode, .colorspace(.keep), .metadata(MetadataSpec(mode: .keepAll)),
                          .encode(EncodeSpec(format: format, quality: format.isLossy ? 0.92 : nil))],
                  output: FileOutput(suffix: ""))
    }

    public static let toPNG = convert(.png, symbol: "photo")
    public static let toHEIC = convert(.heic, symbol: "photo.stack")
    public static let toAVIF = convert(.avif, symbol: "sparkles.rectangle.stack")
    public static let toTIFF = convert(.tiff, symbol: "doc.richtext")
    public static let toPSD = convert(.psd, symbol: "square.3.layers.3d")
    public static let toGIF = convert(.gif, symbol: "square.grid.3x3")
    public static let toBMP = convert(.bmp, symbol: "square.dashed")
    public static let toJPG = convert(.jpg, symbol: "photo.fill")

    /// 사진 휠 "형식" 칸의 기본 2단계(6칸까지)
    public static let formatPresets: [FileSkill] = [toJPG, toPNG, toHEIC, toAVIF, toTIFF, toPSD]
    public static let allFormatConversions: [FileSkill] = [toJPG, toPNG, toHEIC, toAVIF, toTIFF, toPSD, toGIF, toBMP]

    // MARK: 도구 휠(⌘)

    private static func photoTool(_ id: String, _ name: String, _ symbol: String, _ step: FileStep, suffix: String) -> FileSkill {
        FileSkill(id: id, name: name, symbol: symbol, input: [.image, .raw],
                  steps: [.decode, step, .colorspace(.keep), .metadata(MetadataSpec(mode: .keepAll)),
                          .encode(EncodeSpec(format: .jpg, quality: 0.95, sameAsInput: true))],
                  output: FileOutput(suffix: suffix))
    }

    public static let rotateRight = photoTool("tool-rotate-90", L("시계 방향 90°", "Rotate right 90°"), "rotate.right", .rotate(degrees: 90), suffix: "_rotated")
    public static let rotateLeft = photoTool("tool-rotate-270", L("반시계 방향 90°", "Rotate left 90°"), "rotate.left", .rotate(degrees: 270), suffix: "_rotated")
    public static let rotateHalf = photoTool("tool-rotate-180", "180°", "arrow.uturn.down", .rotate(degrees: 180), suffix: "_rotated")
    public static let flipHorizontal = photoTool("tool-flip-h", L("좌우 반전", "Flip horizontal"), "arrow.left.and.right.righttriangle.left.righttriangle.right", .flip(horizontal: true, vertical: false), suffix: "_flipped")
    public static let flipVertical = photoTool("tool-flip-v", L("상하 반전", "Flip vertical"), "arrow.up.and.down.righttriangle.up.righttriangle.down", .flip(horizontal: false, vertical: true), suffix: "_flipped")

    private static func shrink(_ id: String, _ name: String, quality: Double, maxBytes: Int?) -> FileSkill {
        FileSkill(id: id, name: name, symbol: "arrow.down.right.and.arrow.up.left", input: [.image, .raw],
                  steps: [.decode, .colorspace(.keep), .metadata(MetadataSpec(mode: .keepAll)),
                          .encode(EncodeSpec(format: .jpg, quality: quality, maxBytes: maxBytes))],
                  output: FileOutput(suffix: "_small"))
    }

    public static let shrinkGentle = shrink("tool-shrink", L("크기 그대로 · 용량만", "Same size · smaller file"), quality: 0.78, maxBytes: nil)
    public static let shrink2MB = shrink("tool-shrink-2mb", L("2MB 이하", "Under 2 MB"), quality: 0.9, maxBytes: 2_000_000)
    public static let shrink500KB = shrink("tool-shrink-500kb", L("500KB 이하", "Under 500 KB"), quality: 0.85, maxBytes: 500_000)

    public static let videoMute = FileSkill(id: "tool-video-mute", name: L("소리 끄기", "Mute"), symbol: "speaker.slash",
                                            input: [.video], steps: [.video(VideoSpec(preset: .passthrough, muted: true))], output: FileOutput(suffix: "_muted"))
    public static let videoShrink = FileSkill(id: "tool-video-shrink", name: L("용량 줄이기", "Shrink"), symbol: "arrow.down.right.and.arrow.up.left",
                                              input: [.video], steps: [.video(VideoSpec(preset: .hevc1080))], output: FileOutput(suffix: "_small"))

    public static let photoTools: [FileSkill] = [rotateRight, rotateLeft, rotateHalf, flipHorizontal, flipVertical, shrinkGentle, shrink2MB, shrink500KB]

    // MARK: 문서끼리(양방향)

    private static func docSymbol(_ f: DocumentFormat) -> String {
        switch f {
        case .pdf: return "doc.richtext"
        case .docx: return "doc.text"
        case .rtf, .odt: return "doc"
        case .html: return "chevron.left.forwardslash.chevron.right"
        case .md: return "number"
        case .txt: return "text.alignleft"
        case .epub: return "book"
        case .hwpx: return "character.book.closed"
        }
    }

    public static func toDocument(_ format: DocumentFormat) -> FileSkill {
        FileSkill(id: "doc-\(format.rawValue)", name: format.title, symbol: docSymbol(format), input: [.document, .text, .pdf],
                  steps: [.document(format)], output: FileOutput(suffix: ""))
    }

    public static let documentConversions: [FileSkill] = DocumentFormat.allCases.map(toDocument)

    // MARK: PDF → 그림·슬라이드·표

    public static let pdfToJPG = FileSkill(id: "pdf-jpg", name: "JPG", symbol: "photo", input: [.pdf], steps: [.pdfToImages(.jpg, dpi: 300)], output: FileOutput(suffix: ""))
    public static let pdfToPNG = FileSkill(id: "pdf-png", name: "PNG", symbol: "photo.on.rectangle", input: [.pdf], steps: [.pdfToImages(.png, dpi: 300)], output: FileOutput(suffix: ""))
    public static let pdfToPPTX = FileSkill(id: "pdf-pptx", name: "PowerPoint", symbol: "rectangle.on.rectangle", input: [.pdf], steps: [.pdfToSlides], output: FileOutput(suffix: ""))
    public static let pdfToXLSX = FileSkill(id: "pdf-xlsx", name: "Excel", symbol: "tablecells", input: [.pdf], steps: [.pdfToSheet], output: FileOutput(suffix: ""))

    // MARK: 영상 형식(원본 크기 그대로, 형식만)

    public static func toVideo(_ format: VideoFormat) -> FileSkill {
        let symbol: String = {
            switch format {
            case .gif: return "square.stack.3d.forward.dottedline"
            case .mp3, .m4a: return "music.note"
            default: return "film"
            }
        }()
        return FileSkill(id: "video-\(format.rawValue)", name: format.title, symbol: symbol, input: [.video],
                         steps: [.video(VideoSpec(preset: format.isAudio ? .audioOnly : .passthrough, format: format))], output: FileOutput(suffix: ""))
    }

    public static let videoFormats: [FileSkill] = [VideoFormat.mov, .mkv, .webm, .avi, .wmv, .gif].map(toVideo)
    public static let videoToMP3 = toVideo(.mp3)

    /// 움직이는 GIF → MP4(같은 크기, 훨씬 작은 용량)
    public static let gifToMP4 = FileSkill(id: "gif-mp4", name: "MP4", symbol: "film", input: [.image],
                                           steps: [.video(VideoSpec(preset: .passthrough, format: .mp4))], output: FileOutput(suffix: ""))

    // MARK: 벡터 재구성(로고·도장·선화 스캔)

    public static let vectorSVG = FileSkill(id: "vector-svg", name: L("벡터 SVG", "Vector SVG"), symbol: "scribble.variable", input: [.image, .raw],
                                            steps: [.vectorize(.svg)], output: FileOutput(suffix: "_vector"))
    public static let vectorPDF = FileSkill(id: "vector-pdf", name: L("벡터 PDF", "Vector PDF"), symbol: "scribble", input: [.image, .raw],
                                            steps: [.vectorize(.pdf)], output: FileOutput(suffix: "_vector"))
}
