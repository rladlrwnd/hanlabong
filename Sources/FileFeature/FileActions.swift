import AppCore
import AppKit
import SkillEngine

/// 동작 휠(⌃)의 일을 실제로 한다. 파일 내용은 바꾸지 않는다.
/// 복사는 고른 폴더에 새로 만들고(같은 이름이 있으면 " (1)"), 이동은 원본을 그 폴더로 옮긴다(덮어쓰지 않는다).
@MainActor
final class FileActionPerformer {
    let float = FloatShelfController()
    /// 끝났을 때 알림(제목, 내용)
    var onReport: ((String, String) -> Void)?
    /// 복사한 결과(되돌리기 기록용)
    var onCopied: ((_ outputs: [URL], _ inputCount: Int, _ duration: TimeInterval) -> Void)?

    func perform(_ action: FileAction, urls: [URL], near point: NSPoint?) {
        switch action {
        case .airDrop:
            guard let service = NSSharingService(named: .sendViaAirDrop) else { return }
            NSApp.activate(ignoringOtherApps: true)
            if service.canPerform(withItems: urls) { service.perform(withItems: urls) }
            else { onReport?(L("AirDrop을 쓸 수 없어요", "AirDrop isn't available"), L("제어 센터에서 AirDrop과 Wi‑Fi·블루투스를 켜줘", "Turn on AirDrop, Wi‑Fi and Bluetooth in Control Center")) }
        case .float:
            float.add(urls, near: point)
        case .copyPath:
            let text = urls.map(\.path).joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            onReport?(L("경로를 복사했어요", "Path copied"), urls.count == 1 ? (urls[0].path as NSString).abbreviatingWithTildeInPath : L("\(urls.count)개", "\(urls.count) items"))
        case .terminal:
            let folders = Set(urls.map { $0.hasDirectoryPath ? $0 : $0.deletingLastPathComponent() })
            let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
                ?? URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.open(Array(folders), withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        case .copy(let folder):
            withDestination(folder, verb: L("복사", "Copy")) { [weak self] destination in self?.transfer(urls, to: destination, move: false) }
        case .move(let folder):
            withDestination(folder, verb: L("이동", "Move")) { [weak self] destination in self?.transfer(urls, to: destination, move: true) }
        }
    }

    private func withDestination(_ folder: URL?, verb: String, then run: @escaping (URL) -> Void) {
        if let folder { run(folder); return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("여기로 \(verb)", "\(verb) here")
        panel.message = L("어느 폴더로 \(verb)할까요?", "Where should the files go?")
        if let recent = RecentFolders.all.first { panel.directoryURL = recent }
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            run(url)
        }
    }

    /// 파일 옮기기·복사는 오래 걸릴 수 있어(큰 폴더) 작업 큐에서 한다
    private func transfer(_ urls: [URL], to folder: URL, move: Bool) {
        RecentFolders.remember(folder)
        let started = Date()
        let report = onReport, copied = onCopied
        DispatchQueue.global(qos: .userInitiated).async {
            var done: [URL] = []
            var failed: [String] = []
            for url in urls {
                // 자기 자신 안으로 옮기거나 같은 폴더로 옮기는 건 건너뛴다
                if move, url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL { continue }
                if folder.standardizedFileURL.path.hasPrefix(url.standardizedFileURL.path + "/") { failed.append(url.lastPathComponent); continue }
                let target = Self.uniqueURL(folder.appendingPathComponent(url.lastPathComponent))
                do {
                    if move { try FileManager.default.moveItem(at: url, to: target) } else { try FileManager.default.copyItem(at: url, to: target) }
                    done.append(target)
                } catch { failed.append(url.lastPathComponent) }
            }
            DispatchQueue.main.async {
                let verb = move ? L("옮겼어요", "Moved") : L("복사했어요", "Copied")
                let title = L("\(done.count)개를 \(folder.lastPathComponent)(으)로 \(verb)", "\(verb) \(done.count) to \(folder.lastPathComponent)")
                let body = failed.isEmpty ? "" : L("못 한 것: ", "Failed: ") + failed.prefix(3).joined(separator: ", ")
                report?(title, body)
                if !move, !done.isEmpty { copied?(done, urls.count, Date().timeIntervalSince(started)) }
                if !done.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(done) }
            }
        }
    }

    /// 같은 이름이 있으면 " (1)", " (2)"… (폴더도 같은 규칙)
    nonisolated static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let folder = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        for n in 1... {
            let name = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            let candidate = folder.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }
}
