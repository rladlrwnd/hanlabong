import AppCore
import AppKit
import CoreImage
import SkillEngine
import SwiftUI

/// 열어 둔 사진들과 사진마다의 현상 값. 미리보기는 작은 그림(긴 변 2000px)에 같은 현상 코드를 입혀 그린다.
@MainActor
final class DevelopSession: ObservableObject {
    @Published private(set) var photos: [URL] = []
    @Published var current = 0 { didSet { if oldValue != current { loadCurrent() } } }
    @Published var settings = DevelopSettings() { didSet { if oldValue != settings { edits[photoURL ?? URL(fileURLWithPath: "/")] = settings; render() } } }
    @Published private(set) var preview: CGImage?
    @Published private(set) var original: CGImage?
    @Published var showBefore = false
    @Published var presets = DevelopPresetStore.load()
    @Published var message: String?
    @Published var saving = false
    /// 지금 미리보기의 밝기 분포(64칸). 커브 뒤에 깐다
    @Published private(set) var histogram: [Double] = []
    /// 내보내기 설정(마지막에 쓴 값을 기억)
    @Published var exportSettings: PhotoExportSettings = DevelopSession.loadExportSettings() {
        didSet { if let data = try? JSONEncoder().encode(exportSettings) { UserDefaults.standard.set(data, forKey: Self.exportKey) } }
    }
    private static let exportKey = "photoExportSettings"
    private static func loadExportSettings() -> PhotoExportSettings {
        UserDefaults.standard.data(forKey: exportKey).flatMap { try? JSONDecoder().decode(PhotoExportSettings.self, from: $0) } ?? PhotoExportSettings()
    }

    private var edits: [URL: DevelopSettings] = [:]
    private var bases: [URL: CGImage] = [:]
    private var generation = 0
    private let queue = DispatchQueue(label: "app.dragedit.developing.render", qos: .userInteractive)
    private static let context = CIContext(options: [.cacheIntermediates: false])

    var photoURL: URL? { photos.indices.contains(current) ? photos[current] : nil }

    func open(_ urls: [URL]) {
        let fresh = urls.filter { !photos.contains($0) && FileKindDetector.kind(of: $0).map { [.image, .raw].contains($0) } == true }
        guard !fresh.isEmpty else {
            if urls.contains(where: { !photos.contains($0) }) { message = L("사진만 열 수 있어요", "Only photos can be opened") }
            return
        }
        let first = photos.count
        photos += fresh
        current = first
        loadCurrent()
    }

    func thumbnail(_ url: URL) -> CGImage? { bases[url] }

    private func loadCurrent() {
        guard let url = photoURL else { return }
        settings = edits[url] ?? DevelopSettings()
        if let base = bases[url] {
            original = base
            render()
            return
        }
        original = nil
        preview = nil
        Task.detached(priority: .userInitiated) {
            let base = try? ImageEditPreview.load(url, maxPixels: 2000)
            await MainActor.run {
                guard let base else { self.message = L("“\(url.lastPathComponent)”을(를) 열지 못했어요", "Couldn't open “\(url.lastPathComponent)”"); return }
                self.bases[url] = base
                if self.photoURL == url { self.original = base; self.render() }
            }
        }
    }

    /// 마지막 요청만 그린다(슬라이더를 빨리 끌어도 밀리지 않게)
    private func render() {
        guard let base = original else { return }
        generation += 1
        let mine = generation, settings = settings
        queue.async {
            let input = CIImage(cgImage: base)
            let output = Developer.apply(settings, to: input)
            let image = Self.context.createCGImage(output, from: output.extent, format: .RGBA8, colorSpace: base.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB))
            let bins = image.map(Self.histogram) ?? []
            DispatchQueue.main.async {
                guard mine == self.generation else { return }
                self.preview = image
                self.histogram = bins
            }
        }
    }

    /// 밝기 분포: 작게 줄여서(256px) 64칸으로 센다
    nonisolated private static func histogram(_ image: CGImage) -> [Double] {
        let w = 256, h = max(1, image.height * 256 / max(image.width, 1))
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var bins = [Double](repeating: 0, count: 64)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let y = 0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])
            bins[min(63, Int(y / 4))] += 1
        }
        return bins
    }

    // MARK: 프리셋

    func apply(_ preset: DevelopPreset) { settings = preset.settings }

    func storeIntoSlot(_ slot: Int, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        do {
            try DevelopPresetStore.replace(slot: slot, with: DevelopPreset(id: "", name: trimmed.isEmpty ? presets[slot].name : trimmed, settings: settings))
            presets = DevelopPresetStore.load()
            message = L("휠의 \(slot + 1)번 칸에 저장했어요", "Saved to wheel slot \(slot + 1)")
        } catch {
            message = L("프리셋을 저장하지 못했어요", "Couldn't save the preset")
        }
    }

    func copyToAll() {
        for url in photos { edits[url] = settings }
        message = L("사진 \(photos.count)장에 같은 값을 넣었어요", "Applied to \(photos.count) photos")
    }

    // MARK: 내보내기(위치·이름·형식·크기 등을 정해서)

    func export(all: Bool) {
        let targets: [(URL, DevelopSettings)] = all ? photos.map { ($0, edits[$0] ?? DevelopSettings()) } : photoURL.map { [($0, settings)] } ?? []
        guard !targets.isEmpty else { return }
        let options = exportSettings
        saving = true
        Task.detached(priority: .userInitiated) {
            var done: [URL] = [], problems: [String] = []
            for (index, job) in targets.enumerated() {
                do { done.append(try options.export(job.0, develop: job.1, index: index + 1)) } catch {
                    problems.append((error as? LocalizedError)?.errorDescription ?? job.0.lastPathComponent)
                }
            }
            let (saved, failed) = (done, problems)
            await MainActor.run {
                self.saving = false
                if failed.isEmpty {
                    self.message = saved.count == 1 ? L("내보냈어요: \(saved[0].lastPathComponent)", "Exported: \(saved[0].lastPathComponent)")
                                                    : L("\(saved.count)장 내보냈어요", "Exported \(saved.count) photos")
                } else {
                    self.message = L("\(saved.count)장 내보냄, \(failed.count)장 실패: \(failed[0])", "Exported \(saved.count), \(failed.count) failed: \(failed[0])")
                }
                if options.revealInFinder, !saved.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(saved) }
            }
        }
    }

    // MARK: 저장(원본 옆에 _dev)

    func save(all: Bool) {
        let targets: [(URL, DevelopSettings)] = all ? photos.map { ($0, edits[$0] ?? DevelopSettings()) } : photoURL.map { [($0, settings)] } ?? []
        let jobs = targets.filter { !$0.1.isNeutral }
        guard !jobs.isEmpty else { message = L("바꾼 값이 없어요", "Nothing changed yet"); return }
        saving = true
        Task.detached(priority: .userInitiated) {
            var savedSoFar: [URL] = [], failedSoFar = 0
            for (url, settings) in jobs {
                let skill = DevelopPresetStore.skill(for: DevelopPreset(id: "develop", name: "Develop", settings: settings))
                if let out = try? FileJob.run(skill, input: url) { savedSoFar.append(out) } else { failedSoFar += 1 }
            }
            let (saved, failed) = (savedSoFar, failedSoFar)
            await MainActor.run {
                self.saving = false
                if saved.count == 1, failed == 0 {
                    self.message = L("저장했어요: \(saved[0].lastPathComponent)", "Saved: \(saved[0].lastPathComponent)")
                } else {
                    self.message = failed == 0 ? L("\(saved.count)장 저장했어요", "Saved \(saved.count) photos")
                                               : L("\(saved.count)장 저장, \(failed)장 실패", "Saved \(saved.count), \(failed) failed")
                }
            }
        }
    }
}
