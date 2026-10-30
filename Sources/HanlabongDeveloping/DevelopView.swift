import AppCore
import AppKit
import SkillEngine
import SwiftUI
import UniformTypeIdentifiers

/// Hanlabong Developing 창: 왼쪽 큰 사진, 오른쪽 유리 패널에 슬라이더, 아래 필름 띠(여러 장일 때).
/// 사진을 제대로 보려고 바탕은 무채색 어두운 회색(라이트룸과 같은 이유).
struct DevelopView: View {
    @ObservedObject var session: DevelopSession
    @AppStorage(AppAccent.key) private var accentHex = AppAccent.defaultHex
    @State private var slotToStore: Int?
    @State private var newPresetName = ""
    @State private var showExport = false
    @State private var mixerMode = 0          // 0 색조, 1 채도, 2 밝기

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 10) {
                photo
                if session.photos.count > 1 { filmstrip }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            panel
                .frame(width: 320)
                .padding([.top, .bottom, .trailing], 12)
        }
        .background(Color(white: 0.11))
        .dropDestination(for: URL.self) { urls, _ in
            session.open(urls.filter(\.isFileURL))
            return true
        }
        .sheet(isPresented: $showExport) { ExportSheet(session: session) { showExport = false } }
        .alert(L("휠 칸에 저장", "Save to wheel slot"), isPresented: Binding(get: { slotToStore != nil }, set: { if !$0 { slotToStore = nil } })) {
            TextField(L("이름", "Name"), text: $newPresetName)
            Button(L("저장", "Save")) { if let slot = slotToStore { session.storeIntoSlot(slot, name: newPresetName) }; slotToStore = nil }
            Button(L("취소", "Cancel"), role: .cancel) { slotToStore = nil }
        } message: {
            Text(L("지금 값이 한라봉 휠 › 현상의 \((slotToStore ?? 0) + 1)번 칸이 돼요", "Current values become slot \((slotToStore ?? 0) + 1) in the Hanlabong wheel › Develop"))
        }
    }

    // MARK: 사진

    private var photo: some View {
        ZStack {
            if let image = session.showBefore ? session.original : (session.preview ?? session.original) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
            } else if session.photos.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "camera.aperture").font(.system(size: 44, weight: .light))
                    Text(L("한라봉 휠 ⌘ › 현상 › …에 사진을 놓거나, 여기로 끌어 놓아요", "Drop a photo on Hanlabong wheel ⌘ › Develop › …, or drag it here"))
                        .foregroundStyle(.secondary)
                    Button(L("사진 열기…", "Open photos…")) { chooseFiles() }.buttonStyle(.glass)
                }
                .foregroundStyle(.white.opacity(0.85))
            } else {
                ProgressView().controlSize(.large)
            }
            if session.showBefore {
                Text(L("원본", "Before")).font(.caption.bold()).padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(.black.opacity(0.55))).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 누르고 있는 동안 원본 보기
        .onLongPressGesture(minimumDuration: 0.15, maximumDistance: 30, perform: {}, onPressingChanged: { session.showBefore = $0 })
    }

    private var filmstrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(session.photos.enumerated()), id: \.element) { index, url in
                    Group {
                        if let thumb = session.thumbnail(url) {
                            Image(decorative: thumb, scale: 1).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Color.white.opacity(0.08)
                        }
                    }
                    .frame(width: 72, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(index == session.current ? AppAccent.color(accentHex) : .clear, lineWidth: 2.5))
                    .onTapGesture { session.current = index }
                    .help(url.lastPathComponent)
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(height: 62)
    }

    // MARK: 오른쪽 패널

    private var panel: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Hanlabong Developing").font(.system(size: 15, weight: .bold))
                Text(session.photoURL?.lastPathComponent ?? L("사진 없음", "No photo")).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .padding(.bottom, 10)

            presetRow
                .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    section(L("빛", "Light")) {
                        row(L("노출", "Exposure"), \.exposure, -5...5, format: "%+.2f")
                        row(L("대비", "Contrast"), \.contrast)
                        row(L("하이라이트", "Highlights"), \.highlights)
                        row(L("섀도", "Shadows"), \.shadows)
                        row(L("화이트", "Whites"), \.whites)
                        row(L("블랙", "Blacks"), \.blacks)
                    }
                    section(L("색", "Color")) {
                        row(L("색온도", "Temp"), \.temperature)
                        row(L("색조", "Tint"), \.tint)
                        row(L("생동감", "Vibrance"), \.vibrance)
                        row(L("채도", "Saturation"), \.saturation)
                        Toggle(L("흑백", "Black & white"), isOn: $session.settings.blackAndWhite).toggleStyle(.switch).controlSize(.small)
                    }
                    section(L("색조 편집", "Color mixer")) { mixer }
                    section(L("톤 커브", "Tone curve")) {
                        CurveEditor(curve: $session.settings.curve, histogram: session.histogram)
                    }
                    section(L("효과", "Effects")) {
                        row(L("선명도", "Clarity"), \.clarity)
                        row(L("비네트", "Vignette"), \.vignette)
                        row(L("그레인", "Grain"), \.grain, 0...100)
                    }
                }
                .padding(.vertical, 4)
            }
            .disabled(session.photoURL == nil)

            Divider().padding(.vertical, 8)
            if let message = session.message {
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2).padding(.bottom, 6)
            }
            HStack(spacing: 8) {
                Button(L("초기화", "Reset")) { session.settings = DevelopSettings() }
                    .disabled(session.settings.isNeutral)
                if session.photos.count > 1 {
                    Button(L("모두에", "To all")) { session.copyToAll() }.help(L("지금 값을 열어 둔 사진 전부에", "Apply current values to every open photo"))
                }
                Spacer()
                Menu(L("저장", "Save")) {
                    Button(L("이 사진 저장 (⌘S)", "Save this photo (⌘S)")) { session.save(all: false) }
                    if session.photos.count > 1 { Button(L("모두 저장", "Save all")) { session.save(all: true) } }
                    Divider()
                    Button(L("내보내기… (⇧⌘E)", "Export… (⇧⌘E)")) { showExport = true }
                } primaryAction: { session.save(all: false) }
                .menuStyle(.button)
                .buttonStyle(.glassProminent)
                .fixedSize()
                .keyboardShortcut("s", modifiers: .command)
                .disabled(session.photoURL == nil || session.saving)
            }
            .buttonStyle(.glass)
            .controlSize(.regular)
            Text(L("원본은 그대로 두고 옆에 _dev로 저장해요 · 크기·형식·위치를 정하려면 내보내기 · 사진을 누르고 있으면 원본", "Originals stay as is; saved beside them as _dev · use Export for size, format and location · press and hold the photo to see the original"))
                .font(.caption2).foregroundStyle(.secondary).padding(.top, 6)
            Button("") { showExport = true }.keyboardShortcut("e", modifiers: [.command, .shift]).hidden().frame(width: 0, height: 0)
        }
        .padding(16)
        .modifier(GlassFinish(shape: shape, surface: .panel))
    }

    /// 휠의 세 칸: 누르면 그 값으로, 길게 눌러(메뉴) 지금 값을 그 칸에 저장
    private var presetRow: some View {
        HStack(spacing: 6) {
            ForEach(Array(session.presets.enumerated()), id: \.element.id) { index, preset in
                Button(preset.name) { session.apply(preset) }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .lineLimit(1)
                    .contextMenu {
                        Button(L("지금 값을 이 칸에 저장…", "Save current values to this slot…")) {
                            newPresetName = preset.name
                            slotToStore = index
                        }
                    }
                    .help(L("휠 \(index + 1)번 칸 · 오른쪽 클릭으로 지금 값 저장", "Wheel slot \(index + 1) · right-click to save current values"))
            }
        }
    }

    /// 8색 × (색조·채도·밝기). 위에서 무엇을 바꿀지 고르고, 색마다 슬라이더 하나
    private var mixer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $mixerMode) {
                Text(L("색조", "Hue")).tag(0)
                Text(L("채도", "Saturation")).tag(1)
                Text(L("밝기", "Luminance")).tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            ForEach(ColorMixer.Band.allCases, id: \.rawValue) { band in
                HStack(spacing: 8) {
                    Circle().fill(Color(hue: band.hue / 360, saturation: 0.8, brightness: 0.95)).frame(width: 9, height: 9)
                    Text(band.title).font(.caption).frame(width: 52, alignment: .leading)
                    ResettableSlider(value: mixerBinding(band), range: -100...100, defaultValue: 0)
                    Text(String(format: "%+.0f", mixerBinding(band).wrappedValue)).font(.caption).monospacedDigit()
                        .frame(width: 34, alignment: .trailing).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func mixerBinding(_ band: ColorMixer.Band) -> Binding<Double> {
        let i = band.rawValue
        switch mixerMode {
        case 0: return Binding(get: { session.settings.mixer.hue[i] }, set: { session.settings.mixer.hue[i] = $0 })
        case 1: return Binding(get: { session.settings.mixer.saturation[i] }, set: { session.settings.mixer.saturation[i] = $0 })
        default: return Binding(get: { session.settings.mixer.luminance[i] }, set: { session.settings.mixer.luminance[i] = $0 })
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            content()
        }
    }

    private func row(_ title: String, _ key: WritableKeyPath<DevelopSettings, Double>, _ range: ClosedRange<Double> = -100...100, format: String = "%+.0f") -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).frame(width: 64, alignment: .leading)
            ResettableSlider(value: Binding(get: { session.settings[keyPath: key] }, set: { session.settings[keyPath: key] = $0 }),
                             range: range, defaultValue: 0)
            Text(String(format: format, session.settings[keyPath: key])).font(.caption).monospacedDigit()
                .frame(width: 40, alignment: .trailing).foregroundStyle(.secondary)
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .rawImage]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { session.open(panel.urls) }
    }
}
