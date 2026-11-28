import AppCore
import AppKit
import SkillEngine

/// 바탕화면에 새로 생긴 결과 파일을 휠이 있던 자리(커서 아래 동심원 근처)에 놓는다.
/// 그냥 두면 Finder가 새 파일을 바탕화면 오른쪽 위 빈칸에 놓는다.
/// Finder에게 아이콘 자리를 정해 달라고 부탁하는 방식이라, 처음 한 번 "Finder 제어" 허용을 묻는다.
/// (바탕화면 "정렬 기준"이나 "스택"을 켜 두면 Finder가 자리를 다시 정해서 효과가 없다)
@MainActor
enum DesktopPlacement {
    static let enabledKey = "placeOnDesktopAtWheel"

    /// 결과 여러 개를 휠 가운데부터 차례로 놓을 자리(포인트). 아이콘 하나 칸은 대략 가로 100 · 세로 110.
    nonisolated static func offsets(count: Int) -> [CGPoint] {
        let ring: [CGPoint] = [.zero, CGPoint(x: 100, y: 0), CGPoint(x: -100, y: 0), CGPoint(x: 0, y: 110), CGPoint(x: 100, y: 110),
                               CGPoint(x: -100, y: 110), CGPoint(x: 0, y: -110), CGPoint(x: 100, y: -110), CGPoint(x: -100, y: -110)]
        return (0..<count).map { i in
            if i < ring.count { return ring[i] }
            let extra = i - ring.count               // 9개가 넘으면 오른쪽 아래로 줄지어
            return CGPoint(x: 200 + Double(extra % 4) * 100, y: Double(extra / 4) * 110)
        }
    }

    /// 화면 좌표(왼쪽 아래 원점) → Finder 바탕화면 좌표(주 화면 왼쪽 위 원점)
    nonisolated static func finderPoint(_ point: NSPoint, mainScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: mainScreenHeight - point.y)
    }

    nonisolated static func isOnDesktop(_ url: URL) -> Bool {
        guard let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else { return false }
        return url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
            == desktop.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func place(_ urls: [URL], near point: NSPoint?) {
        UserDefaults.standard.register(defaults: [enabledKey: true])
        guard UserDefaults.standard.bool(forKey: enabledKey), let point,
              let mainHeight = NSScreen.screens.first?.frame.height else { return }
        let onDesktop = urls.filter(isOnDesktop)
        guard !onDesktop.isEmpty else { return }
        let center = finderPoint(point, mainScreenHeight: mainHeight)
        let lines = zip(onDesktop, offsets(count: onDesktop.count)).map { url, offset -> String in
            let name = url.lastPathComponent.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "try\n set desktop position of item \"\(name)\" of desktop to {\(Int(center.x + offset.x)), \(Int(center.y + offset.y))}\nend try"
        }
        let script = "tell application \"Finder\"\n" + lines.joined(separator: "\n") + "\nend tell"
        // Finder가 새 파일을 알아챌 시간을 조금 주고, 한 번 더 시도한다.
        // 메인 스레드에서 돌리지 않는다: "Finder 제어" 허락 창이 처음 뜨거나 Finder가 바쁘면
        // Apple Event가 답을 기다리는 동안(최대 약 2분) 앱 전체가 멈췄다
        for delay in [0.6, 1.8] {
            queue.asyncAfter(deadline: .now() + delay) { runOsascript(script) }
        }
        log.info("desktop placement: files=\(onDesktop.count, privacy: .public)")
    }

    private nonisolated static let queue = DispatchQueue(label: "app.dragedit.desktop-placement", qos: .utility)

    /// osascript로 실행(셸을 거치지 않고 인자로 넘김). 20초 넘게 걸리면 끊는다
    private nonisolated static func runOsascript(_ script: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        do { try process.run() } catch {
            log.info("desktop placement failed to start")
            return
        }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20, execute: timer)     // 기다리는 큐와 다른 큐에서
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        if process.terminationStatus != 0 {
            log.info("desktop placement failed: status=\(process.terminationStatus, privacy: .public) bytes=\(message.count, privacy: .public)")
        }
    }
}
