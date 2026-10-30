import AppCore
import AppKit
import SkillEngine
import SwiftUI

/// 내보내기 창(라이트룸 "내보내기"를 참고): 위치 · 파일 이름 · 파일 설정 · 크기 · 출력 선명하게 · 메타데이터 · 워터마크 · 내보낸 뒤
struct ExportSheet: View {
    @ObservedObject var session: DevelopSession
    let close: () -> Void

    private var s: Binding<PhotoExportSettings> { $session.exportSettings }
    private var value: PhotoExportSettings { session.exportSettings }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "square.and.arrow.up").font(.system(size: 18))
                Text(L("내보내기", "Export")).font(.system(size: 17, weight: .bold))
                Spacer()
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding([.horizontal, .top], 20).padding(.bottom, 8)

            Form {
                Section(L("위치", "Location")) {
                    Picker(L("저장할 곳", "Export to"), selection: s.destination) {
                        Text(L("원본 옆", "Beside the original")).tag(PhotoExportSettings.Destination.beside)
                        Text(L("원본 옆 새 폴더", "Subfolder beside the original")).tag(PhotoExportSettings.Destination.subfolder)
                        Text(L("고른 폴더", "Chosen folder")).tag(PhotoExportSettings.Destination.folder)
                    }
                    if value.destination == .subfolder {
                        TextField(L("폴더 이름", "Folder name"), text: s.subfolderName)
                    }
                    if value.destination == .folder {
                        HStack {
                            Text(value.folderPath.isEmpty ? L("아직 안 골랐어요", "Not chosen yet") : (value.folderPath as NSString).abbreviatingWithTildeInPath)
                                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button(L("고르기…", "Choose…")) { chooseFolder() }
                        }
                    }
                }

                Section(L("파일 이름", "File naming")) {
                    Picker(L("이름", "Name"), selection: s.naming) {
                        Text(L("원본 이름 + 붙일 글자", "Original name + suffix")).tag(PhotoExportSettings.Naming.suffix)
                        Text(L("새 이름 + 번호", "Custom name + number")).tag(PhotoExportSettings.Naming.custom)
                    }
                    if value.naming == .suffix {
                        TextField(L("붙일 글자", "Suffix"), text: s.suffix)
                    } else {
                        TextField(L("새 이름", "Custom name"), text: s.customName)
                    }
                    Text(example).font(.caption).foregroundStyle(.secondary)
                }

                Section(L("파일 설정", "File settings")) {
                    Picker(L("형식", "Format"), selection: s.format) {
                        ForEach([OutputFormat.jpg, .heic, .png, .tiff], id: \.self) { Text($0.title).tag($0) }
                    }
                    if value.format.isLossy {
                        HStack {
                            Text(L("품질", "Quality"))
                            ResettableSlider(value: s.quality, range: 1...100, defaultValue: 90)
                            Text("\(Int(value.quality))").monospacedDigit().frame(width: 30, alignment: .trailing)
                        }
                        Toggle(L("파일 크기 제한", "Limit file size"), isOn: s.limitFileSize)
                        if value.limitFileSize {
                            Stepper(value: s.maxKilobytes, in: 50...50_000, step: 50) {
                                Text(L("최대 \(value.maxKilobytes) KB", "Up to \(value.maxKilobytes) KB"))
                            }
                        }
                    }
                    Picker(L("색 공간", "Color space"), selection: s.colorSpace) {
                        Text("sRGB").tag(ColorSpaceTarget.sRGB)
                        Text("Display P3").tag(ColorSpaceTarget.displayP3)
                        Text(L("원본 그대로", "Same as original")).tag(ColorSpaceTarget.keep)
                    }
                }

                Section(L("이미지 크기", "Image sizing")) {
                    Picker(L("크기", "Resize"), selection: s.sizing) {
                        Text(L("원래 크기", "Original")).tag(PhotoExportSettings.Sizing.original)
                        Text(L("긴 변", "Long edge")).tag(PhotoExportSettings.Sizing.longEdge)
                        Text(L("짧은 변", "Short edge")).tag(PhotoExportSettings.Sizing.shortEdge)
                        Text(L("가로 × 세로 안에", "Width × height")).tag(PhotoExportSettings.Sizing.fit)
                        Text(L("화소 수", "Megapixels")).tag(PhotoExportSettings.Sizing.megapixels)
                        Text(L("비율(%)", "Percentage")).tag(PhotoExportSettings.Sizing.percent)
                    }
                    switch value.sizing {
                    case .longEdge, .shortEdge:
                        TextField(L("픽셀", "Pixels"), value: s.size, format: .number)
                    case .fit:
                        HStack {
                            TextField(L("가로", "W"), value: s.fitWidth, format: .number)
                            Text("×")
                            TextField(L("세로", "H"), value: s.fitHeight, format: .number)
                        }
                    case .megapixels:
                        TextField(L("백만 화소", "Megapixels"), value: s.megapixels, format: .number)
                    case .percent:
                        TextField("%", value: s.percent, format: .number)
                    case .original:
                        EmptyView()
                    }
                    if value.sizing != .original {
                        Toggle(L("키우지 않기", "Don't enlarge"), isOn: s.dontEnlarge)
                    }
                    Stepper(value: s.ppi, in: 72...1200, step: 1) {
                        HStack {
                            Text(L("해상도", "Resolution"))
                            TextField("", value: s.ppi, format: .number).frame(width: 60)
                            Text("ppi").foregroundStyle(.secondary)
                        }
                    }
                }

                Section(L("출력 선명하게", "Output sharpening")) {
                    Toggle(L("선명하게", "Sharpen for"), isOn: s.sharpen)
                    if value.sharpen {
                        Picker(L("어디에", "For"), selection: s.sharpenMedium) {
                            Text(L("화면", "Screen")).tag(OutputSharpening.Medium.screen)
                            Text(L("무광 인화지", "Matte paper")).tag(OutputSharpening.Medium.matte)
                            Text(L("유광 인화지", "Glossy paper")).tag(OutputSharpening.Medium.glossy)
                        }
                        Picker(L("양", "Amount"), selection: s.sharpenAmount) {
                            Text(L("낮게", "Low")).tag(OutputSharpening.Amount.low)
                            Text(L("보통", "Standard")).tag(OutputSharpening.Amount.standard)
                            Text(L("높게", "High")).tag(OutputSharpening.Amount.high)
                        }
                        .pickerStyle(.segmented)
                    }
                }

                Section(L("메타데이터", "Metadata")) {
                    Picker(L("남길 정보", "Include"), selection: s.metadata) {
                        Text(L("전부", "All")).tag(PhotoExportSettings.Metadata.all)
                        Text(L("위치만 빼고 전부", "All except location")).tag(PhotoExportSettings.Metadata.noLocation)
                        Text(L("카메라 정보만", "Camera info only")).tag(PhotoExportSettings.Metadata.cameraOnly)
                        Text(L("저작권만", "Copyright only")).tag(PhotoExportSettings.Metadata.copyrightOnly)
                        Text(L("아무것도 안 남기기", "None")).tag(PhotoExportSettings.Metadata.none)
                    }
                    if value.metadata != .none {
                        TextField(L("작가", "Creator"), text: s.artist)
                        TextField(L("저작권", "Copyright"), text: s.copyright)
                    }
                }

                Section(L("워터마크", "Watermark")) {
                    Toggle(L("글자 워터마크", "Text watermark"), isOn: s.watermark)
                    if value.watermark {
                        TextField(L("글자", "Text"), text: s.watermarkText)
                        Picker(L("위치", "Position"), selection: s.watermarkPosition) {
                            Text(L("오른쪽 아래", "Bottom right")).tag(WatermarkPosition.bottomRight)
                            Text(L("왼쪽 아래", "Bottom left")).tag(WatermarkPosition.bottomLeft)
                            Text(L("가운데 아래", "Bottom")).tag(WatermarkPosition.bottom)
                            Text(L("가운데", "Center")).tag(WatermarkPosition.center)
                            Text(L("오른쪽 위", "Top right")).tag(WatermarkPosition.topRight)
                            Text(L("왼쪽 위", "Top left")).tag(WatermarkPosition.topLeft)
                        }
                        HStack {
                            Text(L("진하기", "Opacity"))
                            ResettableSlider(value: s.watermarkOpacity, range: 0.1...1, defaultValue: 0.6)
                        }
                        HStack {
                            Text(L("크기", "Size"))
                            ResettableSlider(value: s.watermarkSize, range: 5...60, defaultValue: 20)
                        }
                    }
                }

                Section(L("내보낸 뒤", "After export")) {
                    Toggle(L("Finder에서 보여주기", "Show in Finder"), isOn: s.revealInFinder)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button(L("기본값", "Defaults")) { session.exportSettings = PhotoExportSettings() }
                Spacer()
                Button(L("취소", "Cancel"), action: close).keyboardShortcut(.cancelAction)
                if session.photos.count > 1 {
                    Button(L("\(session.photos.count)장 모두 내보내기", "Export all \(session.photos.count)")) { session.export(all: true); close() }
                }
                Button(L("내보내기", "Export")) { session.export(all: false); close() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(value.destination == .folder && value.folderPath.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 560, height: 720)
    }

    private var summary: String {
        var parts = [value.format.title]
        if value.format.isLossy { parts.append(L("품질 \(Int(value.quality))", "Q\(Int(value.quality))")) }
        if value.sizing != .original { parts.append(L("크기 바꿈", "resized")) }
        if value.limitFileSize, value.format.isLossy { parts.append("≤\(value.maxKilobytes)KB") }
        return parts.joined(separator: " · ")
    }

    private var example: String {
        let original = session.photoURL?.deletingPathExtension().lastPathComponent ?? "DSCF0001"
        let name = value.naming == .suffix ? original + value.suffix : (value.customName.isEmpty ? "photo" : value.customName) + "-1"
        return L("예: \(name).\(value.format.fileExtension)", "e.g. \(name).\(value.format.fileExtension)")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { session.exportSettings.folderPath = url.path }
    }
}
