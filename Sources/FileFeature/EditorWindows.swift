import AppCore
import AppKit
import AVFoundation
import AVKit
import SkillEngine
import SwiftUI

/// 편집 창 공통: 테두리 없는 유리 패널(검토 창·요약 창과 같은 질감). "저장"을 누르면 스킬을 만들어 작업으로 돌린다.
@MainActor
final class EditorController: NSObject, NSWindowDelegate {
    private var panel: ReviewPanel?
    private let presence = PanelPresence()
    private let size: NSSize
    private let makeView: (@escaping () -> Void) -> AnyView
    var anchor: NSPoint?
    var onClose: (() -> Void)?

    init(contentSize: CGSize, margin: CGFloat, makeView: @escaping (_ close: @escaping () -> Void) -> AnyView) {
        size = NSSize(width: contentSize.width + margin * 2, height: contentSize.height + margin * 2)
        self.makeView = makeView
    }

    func show() {
        let panel = ReviewPanel(size: size)
        panel.contentView = NSHostingView(rootView: PresenceWrap(presence: presence, content: makeView { [weak self] in
            guard let self else { return }
            self.panel?.dismiss(self.presence)
        }))
        panel.delegate = self
        let point = anchor ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
        self.panel = panel
        panel.present(presence)
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
}

// MARK: - 사진 편집

@MainActor
final class ImageEditorModel: ObservableObject {
    @Published var draft: ImageEditDraft
    @Published var preview: CGImage
    private let base: CGImage

    init(base: CGImage, sourceExtension: String) {
        self.base = base
        preview = base
        draft = ImageEditDraft(sourceSize: CGSize(width: base.width, height: base.height), sourceExtension: sourceExtension)
    }

    func refreshPreview() {
        preview = ImageEditPreview.render(base, rotation: draft.rotation, flipHorizontal: draft.flipHorizontal, flipVertical: draft.flipVertical,
                                          brightness: draft.brightness, contrast: draft.contrast, saturation: draft.saturation)
    }
}

struct ImageEditorView: View {
    static let cardSize = CGSize(width: 980, height: 700)
    static let margin: CGFloat = 30

    @ObservedObject var model: ImageEditorModel
    let fileName: String
    let save: (FileSkill) -> Void
    let close: () -> Void

    private static let aspects: [CropGeometry.Aspect] = [.free, .original, .ratio(1, 1), .ratio(4, 3), .ratio(3, 2), .ratio(16, 9), .ratio(4, 5), .ratio(9, 16)]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "crop").font(.system(size: 20, weight: .medium))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("사진 편집", "Edit photo")).font(.system(size: 18, weight: .bold))
                    Text(fileName).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 12, weight: .bold)) }
                    .buttonStyle(.glass).buttonBorderShape(.circle)
            }

            CropCanvas(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.black.opacity(0.25)))

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(Self.aspects, id: \.self) { aspect in
                        Button(aspect.title) { model.draft.crop.setAspect(aspect) }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                            .opacity(model.draft.crop.aspect == aspect ? 1 : 0.6)
                    }
                    Divider().frame(height: 16)
                    Button { model.draft.rotate(clockwise: false); model.refreshPreview() } label: { Image(systemName: "rotate.left") }
                    Button { model.draft.rotate(clockwise: true); model.refreshPreview() } label: { Image(systemName: "rotate.right") }
                    Button { model.draft.flipH(); model.refreshPreview() } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                    Button { model.draft.flipV(); model.refreshPreview() } label: { Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down") }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }

            HStack(spacing: 18) {
                slider(L("밝기", "Brightness"), $model.draft.brightness, -0.5...0.5)
                slider(L("대비", "Contrast"), $model.draft.contrast, 0.5...1.5)
                slider(L("채도", "Saturation"), $model.draft.saturation, 0...2)
                Button(L("보정 초기화", "Reset adjustments")) { model.draft.resetAdjustments(); model.refreshPreview() }
                    .buttonStyle(.glass).controlSize(.small)
            }

            HStack {
                Text(L("원본은 그대로 두고 옆에 \"\(fileNameBase)_edit.\(model.draft.outputFormat.fileExtension)\"로 저장돼요", "The original stays as is; saved next to it as \"\(fileNameBase)_edit.\(model.draft.outputFormat.fileExtension)\""))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("취소", "Cancel"), action: close).buttonStyle(.glass).keyboardShortcut(.cancelAction)
                Button(L("저장", "Save")) { save(model.draft.skill); close() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.draft.hasChanges)
            }
            .controlSize(.large)
        }
        .padding(22)
        .frame(width: Self.cardSize.width, height: Self.cardSize.height)
        .background(WindowDragArea())
        .modifier(GlassFinish(shape: shape, surface: .panel))
        .environment(\.controlActiveState, .key)
        .shadow(color: .black.opacity(0.28), radius: 22, y: 10)
        .padding(Self.margin)
    }

    private var fileNameBase: String { (fileName as NSString).deletingPathExtension }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption).frame(width: 28, alignment: .leading)
            Slider(value: value, in: range) { editing in if !editing { model.refreshPreview() } }
                .frame(width: 140)
        }
    }
}

/// 사진 위에 자르기 상자: 안쪽을 끌면 이동, 모서리·변을 끌면 크기 조절. 바깥은 어둡게, 안쪽엔 삼분할선.
struct CropCanvas: View {
    @ObservedObject var model: ImageEditorModel
    @State private var activeHandle: CropGeometry.Handle?
    @State private var moving = false
    @State private var lastPoint: CGPoint?

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let imageSize = CGSize(width: model.preview.width, height: model.preview.height)
            let scale = min((size.width - 24) / imageSize.width, (size.height - 24) / imageSize.height)
            let fit = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            let origin = CGPoint(x: (size.width - fit.width) / 2, y: (size.height - fit.height) / 2)
            let rect = model.draft.crop.rect
            let box = CGRect(x: origin.x + rect.minX * fit.width, y: origin.y + rect.minY * fit.height,
                             width: rect.width * fit.width, height: rect.height * fit.height)
            ZStack(alignment: .topLeading) {
                Image(decorative: model.preview, scale: 1)
                    .resizable()
                    .frame(width: fit.width, height: fit.height)
                    .position(x: size.width / 2, y: size.height / 2)
                // 바깥 어둡게
                Path { path in
                    path.addRect(CGRect(origin: origin, size: fit))
                    path.addRect(box)
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                Rectangle().strokeBorder(.white, lineWidth: 1.5).frame(width: box.width, height: box.height).position(x: box.midX, y: box.midY)
                // 삼분할선
                Path { path in
                    for i in 1...2 {
                        let x = box.minX + box.width * CGFloat(i) / 3, y = box.minY + box.height * CGFloat(i) / 3
                        path.move(to: CGPoint(x: x, y: box.minY)); path.addLine(to: CGPoint(x: x, y: box.maxY))
                        path.move(to: CGPoint(x: box.minX, y: y)); path.addLine(to: CGPoint(x: box.maxX, y: y))
                    }
                }
                .stroke(.white.opacity(0.35), lineWidth: 0.5)
                ForEach(Array(Self.handles(box).enumerated()), id: \.offset) { _, item in
                    Circle().fill(.white).frame(width: 10, height: 10).position(item.1).shadow(radius: 2)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let point = CGPoint(x: (value.location.x - origin.x) / fit.width, y: (value.location.y - origin.y) / fit.height)
                    if lastPoint == nil {
                        let start = CGPoint(x: (value.startLocation.x - origin.x) / fit.width, y: (value.startLocation.y - origin.y) / fit.height)
                        activeHandle = Self.handle(at: value.startLocation, box: box)
                        moving = activeHandle == nil && model.draft.crop.rect.contains(start)
                        lastPoint = start
                    }
                    if let handle = activeHandle {
                        model.draft.crop.drag(handle, to: point)
                    } else if moving, let last = lastPoint {
                        model.draft.crop.move(by: CGSize(width: point.x - last.x, height: point.y - last.y))
                    }
                    lastPoint = point
                }
                .onEnded { _ in activeHandle = nil; moving = false; lastPoint = nil })
        }
    }

    private static func handles(_ box: CGRect) -> [(CropGeometry.Handle, CGPoint)] {
        [(.topLeft, CGPoint(x: box.minX, y: box.minY)), (.top, CGPoint(x: box.midX, y: box.minY)), (.topRight, CGPoint(x: box.maxX, y: box.minY)),
         (.left, CGPoint(x: box.minX, y: box.midY)), (.right, CGPoint(x: box.maxX, y: box.midY)),
         (.bottomLeft, CGPoint(x: box.minX, y: box.maxY)), (.bottom, CGPoint(x: box.midX, y: box.maxY)), (.bottomRight, CGPoint(x: box.maxX, y: box.maxY))]
    }

    private static func handle(at point: CGPoint, box: CGRect) -> CropGeometry.Handle? {
        handles(box).min { hypot($0.1.x - point.x, $0.1.y - point.y) < hypot($1.1.x - point.x, $1.1.y - point.y) }
            .flatMap { hypot($0.1.x - point.x, $0.1.y - point.y) < 18 ? $0.0 : nil }
    }
}

// MARK: - 영상 편집

@MainActor
final class VideoEditorModel: ObservableObject {
    let url: URL
    let player: AVPlayer
    @Published var duration = 0.0
    @Published var start = 0.0
    @Published var end = 0.0
    @Published var muted = false
    @Published var preset: VideoPreset = .passthrough
    @Published var loadFailed = false
    /// AVI·MKV처럼 맥 기본 재생기가 못 트는 영상(시간만 정하고 ffmpeg로 바꾼다)
    let noPreview: Bool

    init(url: URL) {
        self.url = url
        noPreview = FFmpeg.needsFFmpeg(url)
        player = noPreview ? AVPlayer() : AVPlayer(url: url)
        Task { @MainActor [noPreview] in
            do {
                let seconds: Double
                if noPreview {
                    // 앞부분이 진짜 영상인지 먼저 본다(이름만 .avi인 재생목록 같은 건 열지 않는다)
                    seconds = try await Task.detached { try FFmpeg.probe(url).duration }.value
                } else {
                    seconds = try await AVURLAsset(url: url).load(.duration).seconds
                }
                guard seconds > 0 else { loadFailed = true; return }
                duration = seconds
                end = seconds
            } catch { loadFailed = true }
        }
    }

    var isTrimmed: Bool { start > 0.05 || end < duration - 0.05 }

    var skill: FileSkill {
        var spec = VideoSpec(preset: preset, trimStart: start > 0.05 ? start : nil, trimEnd: end < duration - 0.05 ? end : nil, muted: muted)
        if spec.preset == .audioOnly { spec.muted = false }
        return FileSkill(id: "video-edit", name: L("영상 편집", "Edit video"), symbol: "scissors", input: [.video], steps: [.video(spec)],
                         output: FileOutput(suffix: "_edit"))
    }

    func seek(_ seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func playSelection() {
        seek(start)
        player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: end, preferredTimescale: 600)
        player.play()
    }
}

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {}
}

struct VideoEditorView: View {
    static let cardSize = CGSize(width: 860, height: 660)
    static let margin: CGFloat = 30

    @ObservedObject var model: VideoEditorModel
    let save: (FileSkill) -> Void
    let close: () -> Void

    private func time(_ seconds: Double) -> String {
        let total = Int(seconds.rounded()), h = total / 3600, m = total % 3600 / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "scissors").font(.system(size: 20, weight: .medium))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("영상 편집", "Edit video")).font(.system(size: 18, weight: .bold))
                    Text(model.url.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 12, weight: .bold)) }
                    .buttonStyle(.glass).buttonBorderShape(.circle)
            }

            Group {
                if model.noPreview {
                    VStack(spacing: 8) {
                        Image(systemName: "film").font(.system(size: 34, weight: .light))
                        Text(L("이 형식은 미리보기를 못 해요 · 시간으로 구간을 정하면 ffmpeg로 바꿔요", "No preview for this format · set the range by time and ffmpeg converts it"))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.black.opacity(0.2)))
                } else {
                    PlayerSurface(player: model.player)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if model.loadFailed {
                Label(L("이 영상을 읽지 못했어요", "Couldn't read this video"), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(L("시작 \(time(model.start))", "Start \(time(model.start))")).monospacedDigit().frame(width: 90, alignment: .leading)
                        Slider(value: $model.start, in: 0...max(model.duration, 0.1)) { editing in
                            if !editing { model.start = min(model.start, model.end - 0.1); model.seek(model.start) }
                        }
                    }
                    HStack {
                        Text(L("끝 \(time(model.end))", "End \(time(model.end))")).monospacedDigit().frame(width: 90, alignment: .leading)
                        Slider(value: $model.end, in: 0...max(model.duration, 0.1)) { editing in
                            if !editing { model.end = max(model.end, model.start + 0.1); model.seek(model.end) }
                        }
                    }
                    Text(L("선택한 길이 \(time(max(0, model.end - model.start))) / 전체 \(time(model.duration))", "Selected \(time(max(0, model.end - model.start))) / total \(time(model.duration))"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 14) {
                Button { model.playSelection() } label: { Label(L("선택 구간 재생", "Play selection"), systemImage: "play.fill") }
                    .buttonStyle(.glass).controlSize(.small)
                    .disabled(model.noPreview)
                Toggle(L("소리 끄기", "Mute"), isOn: $model.muted).toggleStyle(.switch).controlSize(.small)
                    .disabled(model.preset == .audioOnly)
                Picker(L("품질", "Quality"), selection: $model.preset) {
                    ForEach(VideoPreset.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .frame(width: 260)
                .controlSize(.small)
            }
            if model.preset == .passthrough, model.isTrimmed, !model.noPreview {
                Text(L("원본 그대로 + 자르기: 다시 인코딩하지 않아서 빠르고 화질 손실이 없어요(자르는 지점은 가장 가까운 키프레임이라 조금 어긋날 수 있어요)", "Original + trim: no re-encoding, so it's fast and lossless (cuts snap to the nearest keyframe, so they may be slightly off)"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Text(L("원본은 그대로 두고 옆에 \"_edit\"을 붙여 저장해요. 오래 걸리면 진행 카드에 보여요.", "The original stays as is; saved next to it with \"_edit\". Long jobs show a progress card."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("취소", "Cancel"), action: close).buttonStyle(.glass).keyboardShortcut(.cancelAction)
                Button(L("저장", "Save")) { model.player.pause(); save(model.skill); close() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.loadFailed || (!model.isTrimmed && !model.muted && model.preset == .passthrough && !model.noPreview))
            }
            .controlSize(.large)
        }
        .padding(22)
        .frame(width: Self.cardSize.width, height: Self.cardSize.height)
        .background(WindowDragArea())
        .modifier(GlassFinish(shape: shape, surface: .panel))
        .environment(\.controlActiveState, .key)
        .shadow(color: .black.opacity(0.28), radius: 22, y: 10)
        .padding(Self.margin)
    }
}
