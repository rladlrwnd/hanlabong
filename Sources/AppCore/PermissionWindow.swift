import SkillEngine
import AppKit
import ApplicationServices
import SwiftUI

@MainActor
package final class PermissionState: ObservableObject {
    @Published package var trusted = AXIsProcessTrusted()
}

/// 처음 실행했을 때(또는 권한이 꺼져 있을 때) "손쉬운 사용" 권한을 켜는 방법을 안내하는 창.
/// 권한이 켜지는 순간을 1초마다 확인해서 자동으로 "준비 완료"로 바뀐다.
@MainActor
package final class PermissionWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var timer: Timer?
    private let state = PermissionState()

    package func show() {
        state.trusted = AXIsProcessTrusted()
        if window == nil {
            let view = PermissionView(
                state: state,
                openSettings: { Self.requestAccess() },
                close: { [weak self] in self?.window?.close() }
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 400),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: view)
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        startPolling()
    }

    package func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }

    private func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let trusted = AXIsProcessTrusted()
                if trusted != self.state.trusted {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { self.state.trusted = trusted }
                }
            }
        }
    }

    /// 시스템 권한 요청 알림을 띄우고(이때 목록에 TextPopup이 자동으로 추가된다) 설정 화면도 연다.
    package static func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct PermissionView: View {
    @ObservedObject var state: PermissionState
    let openSettings: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: state.trusted ? "checkmark.circle.fill" : "accessibility")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(state.trusted ? .green : .accentColor)
                .contentTransition(.symbolEffect(.replace))

            if state.trusted {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("준비 완료!", "You're all set!"))
                        .font(.system(size: 22, weight: .bold))
                    Text(LocalizedStringKey(L("아무 앱에서 글자를 드래그하고 **⌥ Option + Space**를 눌러봐.\n메뉴 막대의 프리즘 아이콘에서 설정을 열거나 종료할 수 있어.", "Select text in any app and press **⌥ Option + Space**.\nOpen Settings or quit from the prism icon in the menu bar.")))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button(L("시작하기", "Get started"), action: close)
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("손쉬운 사용 권한을 켜줘", "Turn on Accessibility access"))
                        .font(.system(size: 22, weight: .bold))
                    Text(L("다른 앱에서 드래그한 글자를 읽고, 바꾼 결과를 다시 넣으려면 맥의 ‘손쉬운 사용’ 권한이 필요해. 글자는 이 컴퓨터 밖으로 나가지 않아.", "To read text you select in other apps and put the result back, DragEdit needs macOS Accessibility access. Your text never leaves this computer."))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 10) {
                    step(1, L("아래 **설정 열기**를 눌러", "Click **Open Settings** below"))
                    step(2, L("목록에서 **DragEdit** 스위치를 켜 (비밀번호나 Touch ID를 물어보면 입력)", "Turn on the **DragEdit** switch in the list (enter your password or Touch ID if asked)"))
                    step(3, L("이 창으로 돌아오면 자동으로 확인돼", "Come back to this window and it checks automatically"))
                }
                Spacer(minLength: 0)
                Button(L("설정 열기", "Open Settings"), action: openSettings)
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 36)
        .padding(.bottom, 28)
        .frame(width: 440, height: 400, alignment: .topLeading)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .frame(width: 22, height: 22)
                .glassEffect(.regular, in: Circle())
            Text(LocalizedStringKey(text))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
