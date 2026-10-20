import AppCore
import AppKit
import Carbon.HIToolbox
import SkillEngine
import SwiftUI

/// 팝업을 어디에 띄울지, 어떻게 열고 닫을지, 키보드/마우스를 어떻게 받을지 담당한다.
@MainActor
package final class PopupController {
    /// 마지막으로 바꾼 내용. 바꾼 결과를 다시 선택하고 ⌥Space를 누르면 "원래대로"가 나타난다.
    private struct LastChange {
        let original: String
        let result: String
        let appPID: pid_t?
    }

    private let panel = PopupPanel()
    private let model = PopupModel()
    private let hosting: FittingHostingView<PopupView>
    private let store: SkillStore
    private let agents: AgentStore

    private var selection: CapturedSelection?
    /// 팝업을 붙일 기준 영역(선택 영역, 없으면 열 때의 마우스 위치). 크기를 다시 맞출 때도 같은 기준을 쓴다.
    private var placementTarget = CGRect.zero
    private var targetApp: NSRunningApplication?
    private var lastChange: LastChange?
    private var aiTask: Task<Void, Never>?
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    /// 닫는 애니메이션 도중 새로 열리면, 늦게 도착한 "창 숨기기"가 새 팝업을 지우지 않게 구분한다.
    private var generation = 0
    /// 이번에 팝업을 연 동안 모델을 미리 올렸는지
    private var warmedUp = false

    package private(set) var isOpen = false

    package init(store: SkillStore, agents: AgentStore) {
        self.store = store
        self.agents = agents
        hosting = FittingHostingView(rootView: PopupView(model: model))
        // 화면 크기를 잴 때 SwiftUI 내용물의 크기를 알려주게 한다(빈 값으로 두면 fittingSize가 0×0이 되어 창이 안 보였다).
        // 창 크기 자체는 우리가 직접 정하므로 최소/최대 크기 제약은 걸지 않는다.
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        model.onPerform = { [weak self] action in self?.perform(action) }
        model.onSubmitPrompt = { [weak self] in self?.submit() }
        model.onSelectAgent = { [weak self] agent in self?.choose(agent) }
        model.onSaveDraft = { [weak self] apply in self?.saveDraft(apply: apply) }
        model.onDiscardDraft = { [weak self] in self?.discardDraft() }
        // 스킬만 쓸 때는 큰 모델을 메모리에 올리지 않는다 — 입력을 시작해야 미리 올린다.
        model.onStartTyping = { [weak self] in
            guard let self, !self.warmedUp, let agent = self.agents.agent(for: .popup) else { return }
            self.warmedUp = true
            AIClient.warmUp(agent)
        }
        hosting.onIntrinsicSizeInvalidated = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refit() } }
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
    }

    // MARK: - 열기

    package func show(selection: CapturedSelection?, targetApp: NSRunningApplication?) {
        generation += 1
        aiTask?.cancel()
        self.selection = selection
        self.targetApp = targetApp

        store.refresh()
        // 설정에서 켠 스킬만, 위에서부터 ⌘1~⌘9
        var actions = store.visibleSkills.enumerated().map { PopupAction.skill($1, number: $0 + 1) }
        if let selection, canRestore(selection, in: targetApp) {
            actions.insert(.restore, at: 0)
        }

        model.isPresented = true
        model.isShown = false
        model.selectedText = selection?.text
        model.allActions = actions
        model.query = ""
        model.selectedIndex = 0
        model.listNavigated = false
        model.showingAgents = false
        model.aiPhase = .idle
        model.streamed = ""
        model.designingSkill = false
        model.draft = nil
        syncAgents()
        if selection == nil {
            model.message = L("선택된 글자를 찾지 못했어요", "No selected text found")
        } else if let problem = store.problem {
            model.message = problem
        } else {
            model.message = nil
        }

        placementTarget = selection?.bounds ?? {
            let mouse = NSEvent.mouseLocation
            return CGRect(x: mouse.x, y: mouse.y - 14, width: 1, height: 22)
        }()
        // 여기서 잰 크기는 이전 내용 기준일 수 있다 — 아래 refit()에서 실제 크기로 다시 맞춘다.
        let placement = Self.placement(size: hosting.fittingSize, around: placementTarget)
        model.anchor = placement.anchor
        panel.setFrame(placement.frame, display: true)
        panel.orderFrontRegardless()
        isOpen = true

        if selection != nil {
            panel.makeKey()
            installMonitors()
            warmedUp = false
            // 모델을 새로 받았을 수도 있으니 목록을 조용히 새로 고친다(20초에 한 번까지만)
            Task { [weak self] in
                await self?.agents.refreshIfStale()
                self?.syncAgents()
            }
        } else {
            // 안내 문구는 잠깐 보여주고 알아서 사라진다(포커스도 가져가지 않음)
            let current = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                guard let self, self.generation == current else { return }
                self.close(completion: nil)
            }
        }

        // 한 박자 뒤: SwiftUI가 새 내용을 다 그린 다음 실제 크기로 자리를 다시 잡고, 그때 등장 애니메이션을 켠다
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hosting.layoutSubtreeIfNeeded()
            let placement = Self.placement(size: self.hosting.fittingSize, around: self.placementTarget)
            self.model.anchor = placement.anchor
            self.panel.setFrame(placement.frame, display: true)
            self.model.isShown = true
            if selection != nil { self.model.focusToken += 1 }
            let size = self.panel.frame.size
            log.info("show popup size=\(Int(size.width), privacy: .public)x\(Int(size.height), privacy: .public) hasBounds=\(selection?.bounds != nil, privacy: .public) source=\(selection?.source.rawValue ?? "none", privacy: .public)")
        }
    }

    private func syncAgents() {
        model.agents = agents.allAgents
        model.agent = agents.agent(for: .popup)
    }

    /// 열려 있는 동안 내용 크기가 바뀌면(Tab, AI 작업, 미리보기 등) 창 크기를 맞춘다.
    /// - 커질 때: 바로 키운다 → SwiftUI가 그 안에서 부드럽게 늘어난다.
    /// - 작아질 때: 애니메이션이 끝난 뒤에 줄인다 → 줄어드는 모습이 잘리지 않는다.
    /// 선택 영역 쪽 가장자리(아래에 떴으면 윗변)는 그대로 두어 팝업이 들썩이지 않게 한다.
    private func refit() {
        guard isOpen, model.isShown else { return }
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let current = panel.frame.size
        if abs(size.height - current.height) < 0.5, abs(size.width - current.width) < 0.5 { return }

        shrinkWork?.cancel()
        if size.height >= current.height {
            panel.setFrame(resized(panel.frame, to: size), display: true)
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isOpen else { return }
                let latest = self.hosting.fittingSize
                guard latest.height > 0, latest.height < self.panel.frame.height else { return }
                self.panel.setFrame(self.resized(self.panel.frame, to: latest), display: true)
            }
            shrinkWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }
    }

    private var shrinkWork: DispatchWorkItem?

    private func resized(_ frame: NSRect, to size: NSSize) -> NSRect {
        var result = frame
        if model.anchor == .topLeading { result.origin.y = frame.maxY - size.height }
        result.size = size
        // 늘어나다가 화면 밖으로 나가면 안쪽으로 밀어 넣는다(그림자 여백은 밖으로 나가도 괜찮다)
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            let margin = PopupView.outerMargin
            if result.minY < visible.minY - margin { result.origin.y = visible.minY - margin }
            if result.maxY > visible.maxY + margin { result.origin.y = visible.maxY + margin - result.height }
        }
        return result
    }

    // MARK: - 닫기

    package func cancel() {
        guard isOpen else { return }
        aiTask?.cancel()
        aiTask = nil
        close(completion: nil)
    }

    private func close(completion: (() -> Void)?) {
        guard isOpen else { completion?(); return }
        isOpen = false
        shrinkWork?.cancel()
        removeMonitors()
        model.isShown = false
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            guard let self else { return }
            if self.generation == current {
                self.panel.orderOut(nil)
                self.model.isPresented = false
            }
            completion?()
        }
    }

    /// 결과를 원래 글자 자리에 넣고 닫는다.
    private func apply(_ output: String, original: String) {
        lastChange = LastChange(original: original, result: output, appPID: targetApp?.processIdentifier)
        let targetApp = self.targetApp
        close {
            Task { @MainActor in
                await TextReplacer.replaceSelection(with: output, in: targetApp)
            }
        }
    }

    // MARK: - 스킬

    private func perform(_ action: PopupAction) {
        guard isOpen, !model.isBusy, let selection, !selection.text.isEmpty else { return }
        let original = selection.text

        switch action {
        case .restore:
            guard let lastChange else { return }
            let restored = lastChange.original
            self.lastChange = nil
            log.info("restore original")
            let targetApp = self.targetApp
            close {
                Task { @MainActor in await TextReplacer.replaceSelection(with: restored, in: targetApp) }
            }

        case .skill(let skill, _):
            let output: String
            do {
                output = try SkillExecutor.run(skill, on: original)
            } catch {
                // 실패하면 팝업을 열어둔 채 이유를 보여준다(글자는 건드리지 않음)
                showMessage(error.localizedDescription)
                log.error("skill \(skill.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard output != SkillExecutor.normalizedForComparison(original) else {
                showMessage(L("바뀐 내용이 없어요", "Nothing changed"))
                return
            }
            log.info("run skill \(skill.id, privacy: .public)")
            apply(output, original: original)
        }
    }

    // MARK: - AI

    /// ⏎: 입력창에 쓴 요청을 AI에게 보낸다. "…스킬 만들어줘"면 스킬을 설계한다.
    /// (↑↓로 목록을 골랐으면 그 스킬을 실행, 스킬 미리보기 중이면 저장)
    private func submit() {
        guard isOpen, !model.isBusy else { return }
        if model.draft != nil {
            saveDraft(apply: false)
            return
        }
        if model.showingAgents {
            if model.agents.indices.contains(model.agentIndex) { choose(model.agents[model.agentIndex]) }
            return
        }
        let instruction = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if instruction.isEmpty || model.listNavigated {
            let actions = model.actions
            if actions.indices.contains(model.selectedIndex) { perform(actions[model.selectedIndex]) }
            return
        }
        if SkillAuthoring.isCreationRequest(instruction) {
            designSkill(instruction)
        } else {
            runAI(instruction)
        }
    }

    // MARK: - AI가 스킬 만들기

    private func designSkill(_ request: String) {
        guard let selection, !selection.text.isEmpty else { return }
        guard let agent = agents.agent(for: .skillAuthoring) else {
            showMessage(L("쓸 수 있는 AI가 없어요. Ollama를 켜거나 설정 › API 키를 확인해줘", "No AI available. Start Ollama or check Settings › API Keys"))
            return
        }
        let apiKey = agent.provider.isCloud ? KeychainStore.key(for: agent.provider) : nil
        let cloudEnabled = agents.cloudEnabled
        let sample = selection.text

        model.message = nil
        model.designingSkill = true
        model.aiPhase = .waiting
        log.info("skill design request agent=\(agent.id, privacy: .public)")

        aiTask = Task { @MainActor [weak self] in
            do {
                let outcome = try await SkillGenerator.generate(
                    request: request, sample: sample, agent: agent, apiKey: apiKey, cloudEnabled: cloudEnabled
                )
                try Task.checkCancellation()
                guard let self else { return }
                self.model.aiPhase = .idle
                self.model.designingSkill = false
                switch outcome {
                case .ready(let preview):
                    self.model.draft = preview
                case .impossible(let reason):
                    self.showMessage(L("이건 스킬로 못 만들고 AI로만 가능해요. \(reason)", "This can't be a skill — AI only. \(reason)"))
                }
            } catch is CancellationError {
                self?.model.aiPhase = .idle
                self?.model.designingSkill = false
            } catch let error as URLError where error.code == .cancelled {
                self?.model.aiPhase = .idle
                self?.model.designingSkill = false
            } catch {
                log.error("skill design failed: \(error.localizedDescription, privacy: .public)")
                self?.model.aiPhase = .idle
                self?.model.designingSkill = false
                self?.showMessage(L("스킬을 만들지 못했어요: \(error.localizedDescription)", "Couldn't create the skill: \(error.localizedDescription)"))
            }
        }
    }

    private func saveDraft(apply shouldApply: Bool) {
        guard let preview = model.draft, let selection else { return }
        switch store.add(preview.skill) {
        case .failure(let error):
            showMessage(error.localizedDescription)
        case .success(let number):
            log.info("saved new skill, apply=\(shouldApply, privacy: .public)")
            if shouldApply, preview.changesSample {
                apply(preview.result, original: selection.text)
                return
            }
            model.draft = nil
            model.query = ""
            model.allActions = store.visibleSkills.enumerated().map { PopupAction.skill($1, number: $0 + 1) }
            model.selectedIndex = model.actions.firstIndex { $0.id == preview.skill.id } ?? 0
            model.listNavigated = true
            showMessage(L("“\(preview.skill.name)” 스킬을 저장했어요", "Saved the “\(preview.skill.name)” skill") + (number.map { " · ⌘\($0)" } ?? ""))
            model.focusToken += 1
        }
    }

    private func discardDraft() {
        model.draft = nil
        model.focusToken += 1
    }

    private func runAI(_ instruction: String) {
        guard let selection, !selection.text.isEmpty else { return }
        guard let agent = agents.agent(for: .popup) else {
            showMessage(L("쓸 수 있는 AI가 없어요. Ollama를 켜거나 설정 › API 키를 확인해줘", "No AI available. Start Ollama or check Settings › API Keys"))
            return
        }
        let original = selection.text
        let apiKey = agent.provider.isCloud ? KeychainStore.key(for: agent.provider) : nil
        let cloudEnabled = agents.cloudEnabled

        model.message = nil
        model.streamed = ""
        model.aiPhase = .waiting
        log.info("ai request agent=\(agent.id, privacy: .public) length=\(original.count, privacy: .public)")

        aiTask = Task { @MainActor [weak self] in
            var output = ""
            do {
                let stream = AIClient.transform(
                    text: original, instruction: instruction, agent: agent,
                    apiKey: apiKey, cloudEnabled: cloudEnabled
                )
                var lastDraw = Date.distantPast
                for try await piece in stream {
                    output += piece
                    // 글자마다 다시 그리지 않고 0.04초에 한 번(긴 답에서 버벅임 방지)
                    if Date().timeIntervalSince(lastDraw) > 0.04 {
                        lastDraw = Date()
                        self?.model.streamed = output
                        self?.model.aiPhase = .writing
                    }
                }
                self?.model.streamed = output
                try Task.checkCancellation()
                guard let self else { return }
                let result = AIClient.clean(output, original: original)
                guard !result.isEmpty else { throw AIError.emptyResult }
                log.info("ai done length=\(result.count, privacy: .public)")
                self.model.aiPhase = .idle
                self.apply(result, original: original)
            } catch is CancellationError {
                self?.model.aiPhase = .idle
            } catch let error as URLError where error.code == .cancelled {
                self?.model.aiPhase = .idle
            } catch {
                log.error("ai failed: \(error.localizedDescription, privacy: .public)")
                self?.model.aiPhase = .idle
                self?.showMessage(error.localizedDescription)
            }
        }
    }

    private func cancelAI() {
        aiTask?.cancel()
        aiTask = nil
        model.aiPhase = .idle
        model.designingSkill = false
        model.streamed = ""
        model.focusToken += 1
    }

    private func choose(_ agent: Agent) {
        agents.select(agent, for: .popup)
        model.agent = agent
        model.showingAgents = false
        model.focusToken += 1
        // 이미 무언가 입력 중이면 새 에이전트를 바로 준비시킨다
        if !model.query.isEmpty {
            AIClient.warmUp(agent)
            warmedUp = true
        } else {
            warmedUp = false
        }
    }

    /// 팝업을 연 채로 안내 문구를 띄운다. 늘어난 높이는 refit()이 알아서 맞춘다.
    private func showMessage(_ message: String) {
        model.message = message
    }

    /// 지금 선택된 글자가 방금 우리가 바꿔 넣은 결과와 같으면(같은 앱) "원래대로"를 보여준다.
    private func canRestore(_ selection: CapturedSelection, in app: NSRunningApplication?) -> Bool {
        guard let lastChange else { return false }
        if let pid = lastChange.appPID, let app, pid != app.processIdentifier { return false }
        let clean = { (text: String) in
            SkillExecutor.normalizedForComparison(text).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return clean(selection.text) == clean(lastChange.result)
    }

    // MARK: - 키보드 · 마우스

    private func installMonitors() {
        removeMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = Int(event.keyCode)
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let characters = event.charactersIgnoringModifiers
            let handled = MainActor.assumeIsolated {
                guard let self, self.isOpen, self.panel.isKeyWindow else { return false }
                return self.handleKey(keyCode: keyCode, flags: flags, characters: characters)
            }
            return handled ? nil : event
        }
        // 팝업 바깥(다른 앱)을 클릭하면 닫는다
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        keyMonitor = nil
        clickMonitor = nil
    }

    /// 한글처럼 조합 중인 글자가 있으면 ⏎·Esc·화살표는 입력기에 양보해야 한다.
    private var isComposingText: Bool {
        (panel.firstResponder as? NSTextView)?.hasMarkedText() == true
    }

    /// 처리했으면 true(이벤트를 삼킴)
    private func handleKey(keyCode: Int, flags: NSEvent.ModifierFlags, characters: String?) -> Bool {
        if isComposingText { return false }

        switch keyCode {
        case kVK_Escape:
            if model.isBusy {
                cancelAI()
            } else if model.draft != nil {
                discardDraft()
            } else if model.showingAgents {
                model.showingAgents = false
            } else {
                cancel()
            }
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if flags == .command, model.draft != nil {
                saveDraft(apply: true)
            } else {
                submit()
            }
            return true
        case kVK_Tab:
            guard !model.isBusy, model.draft == nil else { return true }
            model.agentIndex = model.agents.firstIndex { $0.id == model.agent?.id } ?? 0
            model.showingAgents.toggle()
            return true
        case kVK_UpArrow:
            model.move(-1)
            return true
        case kVK_DownArrow:
            model.move(1)
            return true
        case kVK_ANSI_Z where flags == .command:
            // 되돌릴 게 있으면 "원래대로", 없으면 입력창의 실행 취소로 넘긴다
            guard model.allActions.contains(where: { if case .restore = $0 { true } else { false } }) else { return false }
            perform(.restore)
            return true
        default:
            break
        }

        // ⌘1~⌘9 → 스킬 번호 (그냥 숫자는 입력창에 글자로 들어간다)
        if flags == .command, model.draft == nil, let digit = characters.flatMap(Int.init), (1...9).contains(digit) {
            let match = model.allActions.first {
                if case .skill(_, let number) = $0 { number == digit } else { false }
            }
            if let match { perform(match) }
            return true
        }
        return false
    }

    // MARK: - 위치 계산

    private struct Placement {
        let frame: NSRect
        let anchor: UnitPoint
    }

    /// 선택 영역 바로 아래에 띄우고(글자를 가리지 않게), 아래 공간이 모자라면 위로 올린다.
    /// 좌우는 화면 밖으로 나가지 않게 안쪽으로 밀어 넣는다.
    private static func placement(size: NSSize, around target: CGRect) -> Placement {
        let margin = PopupView.outerMargin
        let gap: CGFloat = 6
        let edge: CGFloat = 8

        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: target.midX, y: target.midY)) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame

        let cardWidth = size.width - margin * 2
        let cardHeight = size.height - margin * 2

        var anchor = UnitPoint.topLeading
        var cardTop = target.minY - gap  // AppKit 좌표는 위로 갈수록 y가 커진다
        if cardTop - cardHeight < visible.minY + edge {
            cardTop = target.maxY + gap + cardHeight
            anchor = .bottomLeading
        }
        cardTop = min(max(cardTop, visible.minY + edge + cardHeight), visible.maxY - edge)
        let cardX = min(max(target.minX, visible.minX + edge), visible.maxX - edge - cardWidth)

        let origin = NSPoint(x: cardX - margin, y: cardTop - cardHeight - margin)
        return Placement(frame: NSRect(origin: origin, size: size), anchor: anchor)
    }
}
