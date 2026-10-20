import SkillEngine
import AppCore
import AppKit
import BorderBeamKit
import BotAvatarsKit
import Combine
import SwiftUI

/// 5초를 넘긴 파일 변환을 작은 카드로 보여준다(진행 바·남은 개수·취소). 휠이 닫힌 그 자리에 이어서 뜬다.
/// AI가 끼지 않는 일반 변환이라 움직이는 효과 없이 조용하게 둔다.
@MainActor
package final class ProgressCardController {
    private let panel = PopupPanel()
    private let hosting: CardHostingView<PresenceWrap<ProgressCardView>>
    private let presence = PanelPresence()
    private var subscription: AnyCancellable?
    /// 카드 가운데를 둘 자리(휠이 있던 곳). 없으면 화면 오른쪽 위.
    package var anchor: NSPoint?

    package init(center: JobCenter) {
        hosting = CardHostingView(rootView: PresenceWrap(presence: presence, content: ProgressCardView(center: center)))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        hosting.onSizeChange = { [weak self] in self?.place() }
        subscription = center.$jobs
            .map { jobs in jobs.contains(where: \.isLong) }
            .removeDuplicates()
            .sink { [weak self] visible in
                // 값이 실제로 바뀌고 카드 내용이 그려진 다음에 띄운다(바뀌는 순간에 재면 빈 카드 크기가 나온다)
                DispatchQueue.main.async { self?.setVisible(visible) }
            }
    }

    private func setVisible(_ visible: Bool) {
        warmWork?.cancel()
        warmWork = nil
        if visible {
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) { presence.shown = false }
            panel.alphaValue = 1
            panel.ignoresMouseEvents = false
            place()
            panel.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [presence] in presence.shown = true }
        } else {
            presence.shown = false
            let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
            warmWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
        }
    }

    private var warmWork: DispatchWorkItem?

    /// 휠과 같은 이유로, 앱을 켤 때 빈 카드를 화면 구석에 거의 투명하게 잠깐 그려서 유리를 준비시킨다
    package func prewarm(duration: TimeInterval = 1.5) {
        guard !panel.isVisible else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(NSRect(origin: NSPoint(x: visible.minX, y: visible.minY), size: size), display: true)
        panel.alphaValue = 0.02
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
            self.panel.ignoresMouseEvents = false
            self.warmWork = nil
        }
        warmWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// 휠이 있던 자리 가운데에(화면 밖으로 안 나가게). 자리를 모르면 오른쪽 위(메뉴 막대 아래).
    private func place() {
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let point = anchor ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = anchor.map { NSPoint(x: $0.x - size.width / 2, y: $0.y - size.height / 2) }
            ?? NSPoint(x: visible.maxX - size.width, y: visible.maxY - size.height)
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

/// 비활성 패널에서도 첫 클릭에 취소 버튼이 눌리게 하고, 내용 크기가 바뀌면 알려주는 호스팅 뷰
final class CardHostingView<Content: View>: NSHostingView<Content> {
    var onSizeChange: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in self?.onSizeChange?() }
    }
}

struct ProgressCardView: View {
    @ObservedObject var center: JobCenter

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        // AI가 끼는 작업일 때만 테두리에 빛이 돈다. 검토를 기다리는 동안엔 천천히 깜빡인다.
        BorderBeam(
            size: center.isAwaitingReview ? .pulseOutside : .md,
            colorVariant: .colorful,
            theme: .auto,
            active: center.hasAIJobs,
            borderRadius: 16,
            strength: 0.8
        ) {
            VStack(spacing: 12) {
                ForEach(center.longJobs) { job in
                    JobRow(job: job,
                           onCancel: { center.cancel(job.id) },
                           onReview: { center.openReview(job.id) })
                }
            }
            .padding(14)
            .frame(width: 340)
            .modifier(GlassFinish(shape: shape, surface: .panel))
        }
        // 카드는 키 창이 되지 않으니, 활성 창처럼 그리게 한다
        .environment(\.controlActiveState, .key)
        .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
        .padding(24)   // 그림자·빛줄기가 잘리지 않을 여백
    }
}

private struct JobRow: View {
    let job: JobCenter.Job
    let onCancel: () -> Void
    let onReview: () -> Void

    private var title: String {
        if job.awaitingReview { return L("\(job.title) · 검토할 준비가 됐어요", "\(job.title) · ready for review") }
        if job.isCanceling { return L("\(job.title) 취소하는 중…", "Canceling \(job.title)…") }
        return L("\(job.title) 진행 중", "\(job.title) in progress")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let agent = job.agent {
                BotAvatar(type: agent.avatar, state: job.awaitingReview ? .default : .working, size: 22,
                          paused: false, shading: .smooth, interactive: false)
                    .frame(width: 24, height: 24)
            } else {
                Image(systemName: job.symbol)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 22, height: 22)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 8)
                    if !job.awaitingReview, job.total > 0 {
                        Text("\(job.done)/\(job.total)\(job.unit)")
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                if let agent = job.agent {
                    DestinationBadge(agent: agent)
                }
                if job.awaitingReview {
                    HStack {
                        Button(L("검토하기", "Review"), action: onReview)
                            .buttonStyle(.glassProminent)
                            .controlSize(.small)
                        Button(L("버리기", "Discard"), action: onCancel)
                            .buttonStyle(.glass)
                            .controlSize(.small)
                            .help(L("아무것도 저장하지 않아요", "Nothing will be saved"))
                    }
                } else {
                    if job.total > 1 {
                        ProgressView(value: Double(job.done), total: Double(job.total))
                    } else {
                        ProgressView().progressViewStyle(.linear)    // 얼마나 남았는지 알 수 없을 때
                    }
                    TimelineView(.periodic(from: job.started, by: 1)) { context in
                        let seconds = max(0, Int(context.date.timeIntervalSince(job.started)))
                        Text([job.current, L("\(seconds)초", "\(seconds) s")].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            if !job.awaitingReview {
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L("취소 (이미 저장된 파일은 남고, 나머지는 만들지 않아요)", "Cancel (files already saved stay; the rest won't be made)"))
                .disabled(job.isCanceling)
            }
        }
    }
}

/// 파일 내용이 어디로 가는지: 이 컴퓨터(초록) / 클라우드(주황, 더 눈에 띄게)
struct DestinationBadge: View {
    let agent: Agent

    var body: some View {
        let cloud = !agent.isLocal
        HStack(spacing: 5) {
            Image(systemName: cloud ? "icloud.and.arrow.up.fill" : "desktopcomputer")
                .font(.system(size: cloud ? 12 : 11, weight: .semibold))
            Text(cloud ? L("클라우드(\(agent.name))로 보내는 중 · 불확실한 곳만", "Sending to cloud (\(agent.name)) · uncertain spots only") : L("이 컴퓨터에서 · \(agent.name)", "On this computer · \(agent.name)"))
                .font(.system(size: 11, weight: cloud ? .semibold : .medium))
                .lineLimit(1)
        }
        .foregroundStyle(cloud ? Color.orange : Color.green)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        // 유리 알약: 클라우드는 주황빛을 더 진하게 물들여 눈에 띄게
        .glassEffect(.regular.tint((cloud ? Color.orange : Color.green).opacity(cloud ? 0.28 : 0.12)), in: Capsule())
    }
}
