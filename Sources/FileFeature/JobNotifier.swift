import SkillEngine
import AppCore
import AppKit
@preconcurrency import UserNotifications

/// 오래 걸린 변환이 끝나면 macOS 알림을 보낸다. 알림을 누르면 결과 파일을 Finder에서 보여준다.
/// 알림 권한은 처음 오래 걸린 작업이 끝날 때 한 번 물어본다(앱을 켤 때 묻지 않는다).
@MainActor
final class JobNotifier: NSObject, UNUserNotificationCenterDelegate {
    func setUp() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// 짧은 알림(동작 휠 결과 등)
    func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in if granted { center.add(request) } }
    }

    func notifyFinished(_ record: JobRecord) {
        let content = UNMutableNotificationContent()
        content.title = record.wasCanceled ? L("\(record.skillName) 취소됨", "\(record.skillName) canceled") : L("\(record.skillName) 완료", "\(record.skillName) done")
        var parts = [L("\(record.outputs.count)개 저장", "\(record.outputs.count) saved")]
        if !record.failures.isEmpty { parts.append(L("실패 \(record.failures.count)개", "\(record.failures.count) failed")) }
        if record.wasCanceled { parts.append(L("취소 \(record.canceledCount)개", "\(record.canceledCount) canceled")) }
        // 파일 이름은 알림에 넣지 않는다
        content.body = parts.joined(separator: " · ") + (record.outputs.isEmpty ? "" : L(" — 원본 옆에 있어요", " — next to the original"))
        content.userInfo = ["outputs": record.outputs]
        let request = UNNotificationRequest(identifier: record.id.uuidString, content: content, trigger: nil)

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else {
                log.info("notifications not allowed")
                return
            }
            center.add(request)
        }
    }

    /// AI가 끝나서 검토를 기다릴 때(오래 걸린 작업만)
    func notifyReviewReady(title: String, changes: Int) {
        let content = UNMutableNotificationContent()
        content.title = L("\(title) · 검토할 준비가 됐어요", "\(title) · ready for review")
        content.body = changes == 0 ? L("AI가 고칠 곳이 없다고 했어요", "The AI found nothing to fix") : L("AI가 \(changes)곳을 고쳤어요. 확인하고 적용해줘", "The AI fixed \(changes) spot(s). Review and apply")
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            if granted { center.add(request) }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let paths = response.notification.request.content.userInfo["outputs"] as? [String] ?? []
        let urls = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        DispatchQueue.main.async {
            if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
