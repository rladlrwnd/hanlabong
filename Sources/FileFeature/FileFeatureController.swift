import AppCore
import AppKit
import SkillEngine
import SwiftUI

/// 파일 기능의 입구. 설정의 "파일 기능 켜기/끄기"에 따라 드래그 감시를 켜고 끈다.
/// 꺼져 있으면 아무것도 감시하지 않는다(전역 이벤트 감시도 해제).
@MainActor
package final class FileFeatureController {
    package static let enabledKey = "fileFeatureEnabled"

    /// 작업 기록(설정 탭·되돌리기의 근거)
    package let history = JobHistory()
    /// 휠 구성·사진 프리셋(설정 탭에서 고친다)
    let wheelConfig = WheelConfigStore()
    private let jobs = JobCenter()
    private lazy var progressCard = ProgressCardController(center: jobs)
    private let notifier = JobNotifier()
    private let watcher = DragWatcher()
    private let wheel = WheelController()
    private let runner = FileJobRunner()
    private let actions = FileActionPerformer()
    /// 지금 휠에 끌고 온 것(휠 종류를 바꿀 때 다시 쓴다)
    private var dragged: (extensions: [String], folders: Bool) = ([], false)
    private var observer: NSObjectProtocol?
    /// 휠 가운데에 진행을 보여주고 있는 작업. 새 휠이 뜨면 지난 작업은 휠에 그리지 않는다.
    private var wheelJob: UUID?
    /// AI(글 팝업과 같은 에이전트 선택·키체인·로컬/클라우드 설정을 쓴다)
    let agents: AgentStore
    /// 열려 있는 검토 창들(작업 번호별)
    private var reviews: [UUID: ReviewWindowController] = [:]
    /// AI에게 한 번에 보내는 불확실한 곳 수
    private static let aiBatch = 15

    package init(agents: AgentStore) {
        self.agents = agents
        UserDefaults.standard.register(defaults: [Self.enabledKey: true])
        watcher.onShowWheel = { [weak self] mouse, mode in self?.showWheel(at: mouse, mode: mode) }
        watcher.onSwitchMode = { [weak self] mode in self?.switchWheel(to: mode) }
        actions.onReport = { [weak self] title, body in self?.notifier.notify(title: title, body: body) }
        actions.onCopied = { [weak self] outputs, count, duration in
            self?.history.add(JobRecord(date: Date(), skillID: "action-copy", skillName: L("복사", "Copy"), symbol: "doc.on.doc",
                                        inputCount: count, outputs: outputs.map(\.path), duration: duration))
        }
        watcher.onCloseWheel = { [weak self] in self?.wheel.close() }
        wheel.onDrop = { [weak self] item, urls in self?.handleDrop(item: item, urls: urls) }
    }

    private var wakeObserver: NSObjectProtocol?

    package func start() {
        notifier.setUp()
        _ = progressCard
        apply()
        // 유리 준비: 앱이 자리 잡은 뒤(1초) 한 번, 잠자기에서 깬 뒤(3초) 한 번
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.prewarmGlass() }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.wheel.markCold()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.prewarmGlass() }
            }
        }
        // 설정에서 스위치를 바꾸면 바로 반영 (값이 바뀔 때만 깨어난다)
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
    }

    private func prewarmGlass() {
        guard watcher.isWatching else { return }   // 파일 기능을 꺼 뒀으면 할 필요 없다
        wheel.prewarm()
        progressCard.prewarm()
    }

    private func apply() {
        let enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        if enabled && !watcher.isWatching {
            watcher.start()
        } else if !enabled && watcher.isWatching {
            watcher.stop()
            wheel.close()
        }
    }

    // MARK: 휠

    private func showWheel(at mouse: NSPoint, mode: WheelMode) {
        // 끌고 있는 파일의 확장자만 본다(드롭 전에는 파일을 열지 않는다). 폴더인지는 경로 모양으로만 안다.
        let urls = (NSPasteboard(name: .drag).readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        dragged = (urls.prefix(20).map(\.pathExtension), urls.contains { $0.hasDirectoryPath })
        let ai = currentAI()
        wheelJob = nil
        wheel.show(at: mouse, layout: layout(for: mode, ai: ai))
        // Ollama를 나중에 켰을 수도 있으니 AI 목록을 새로 확인하고, 바뀌었으면 떠 있는 휠에 바로 반영한다
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.agents.refreshIfStale()
            let fresh = self.currentAI()
            if fresh != ai { self.wheel.updateLayout(self.layout(for: self.wheel.mode, ai: fresh)) }
        }
    }

    private func currentAI() -> AIDestination? {
        agents.agent(for: .ocrTypoFix).map { AIDestination(name: $0.name, isCloud: !$0.isLocal) }
    }

    private func layout(for mode: WheelMode, ai: AIDestination?) -> WheelLayout {
        let whatIs = agents.agent(for: .whatIs).map { AIDestination(name: $0.name, isCloud: !$0.isLocal) }
        return WheelLayout.layout(mode: mode, extensions: dragged.extensions, containsFolders: dragged.folders, ai: ai,
                                  whatIsAI: whatIs, config: wheelConfig.config, recentFolders: RecentFolders.all)
    }

    /// 휠이 떠 있는 동안 ⇧/⌘/⌃를 누르면 그 휠로 바꾼다
    private func switchWheel(to mode: WheelMode) {
        wheel.switchLayout(layout(for: mode, ai: currentAI()))
    }

    // MARK: 작업

    private func handleDrop(item: WheelItem, urls: [URL]) {
        if let task = item.aiTask {
            startAIJob(task, urls: urls)
            return
        }
        if let edit = item.edit {
            openEditor(edit, url: urls[0])
            return
        }
        if let action = item.fileAction {
            let point = wheel.lastCenter
            wheel.beginWork(total: 1)
            wheel.finish(succeeded: 1, failed: 0)
            actions.perform(action, urls: urls, near: point)
            return
        }
        guard let skill = item.skill else { return }
        runSkill(skill, urls: urls, fromWheel: true)
    }

    // MARK: 편집 창 (사진 자르기·보정, 영상 구간 자르기)

    private var editors: [UUID: EditorController] = [:]

    private func openEditor(_ kind: EditKind, url: URL) {
        let id = UUID()
        let anchor = wheel.lastCenter
        wheel.beginWork(total: 1)
        wheel.handOff()                                // 휠은 바로 닫고, 그 자리에 편집 창이 뜬다
        let controller: EditorController
        switch kind {
        case .image:
            guard let base = try? ImageEditPreview.load(url) else {
                showAlert(L("사진을 열지 못했어요", "Couldn't open the photo"), L("“\(url.lastPathComponent)”을(를) 읽을 수 없어요.", "Can't read “\(url.lastPathComponent)”."))
                return
            }
            let model = ImageEditorModel(base: base, sourceExtension: url.pathExtension)
            controller = EditorController(contentSize: ImageEditorView.cardSize, margin: ImageEditorView.margin) { [weak self] close in
                AnyView(ImageEditorView(model: model, fileName: url.lastPathComponent,
                                        save: { skill in self?.runSkill(skill, urls: [url], fromWheel: false, anchor: anchor) }, close: close))
            }
        case .video:
            let model = VideoEditorModel(url: url)
            controller = EditorController(contentSize: VideoEditorView.cardSize, margin: VideoEditorView.margin) { [weak self] close in
                AnyView(VideoEditorView(model: model,
                                        save: { skill in self?.runSkill(skill, urls: [url], fromWheel: false, anchor: anchor) }, close: close))
            }
        }
        controller.anchor = anchor
        controller.onClose = { [weak self] in self?.editors[id] = nil }
        editors[id] = controller
        controller.show()
    }

    /// 스킬 하나를 파일들에 돌린다. 휠에서 놓은 거면 휠 가운데에 진행을 보여주고, 편집 창에서 저장한 거면 진행 카드만 쓴다.
    private func runSkill(_ skill: FileSkill, urls: [URL], fromWheel: Bool, anchor: NSPoint? = nil) {
        let id = UUID()
        let started = Date()
        if fromWheel {
            wheelJob = id
            progressCard.anchor = wheel.lastCenter        // 카드는 휠이 있던 자리에(빨리 끝나 5초 전에 카드가 떠도)
            wheel.beginWork(total: urls.count)
        } else {
            progressCard.anchor = anchor
        }
        log.info("job start: skill=\(skill.id, privacy: .public) files=\(urls.count, privacy: .public)")

        let task = Task { @MainActor [weak self, runner] in
            let report = await runner.run(
                skill: skill, urls: urls,
                onStarted: { name in
                    Task { @MainActor in self?.jobs.update(id, current: name) }
                },
                onProgress: { done, total in
                    Task { @MainActor in
                        guard let self else { return }
                        self.jobs.update(id, done: done)
                        if self.wheelJob == id { self.wheel.progress(done: done, total: total) }
                    }
                }
            )
            self?.finish(id, skill: skill, inputCount: urls.count, started: started, report: report)
        }
        jobs.begin(JobCenter.Job(id: id, title: skill.name, symbol: skill.symbol ?? "photo", total: urls.count, started: started)) {
            task.cancel()
        }

        // 5초가 지나도 안 끝나면 휠은 닫고 진행 카드로 넘긴다(취소는 카드에서)
        DispatchQueue.main.asyncAfter(deadline: .now() + JobCenter.longJobThreshold) { [weak self] in
            guard let self else { return }
            self.progressCard.anchor = self.wheel.lastCenter      // 카드는 휠이 있던 자리에
            guard self.jobs.markLongIfRunning(id) else { return }
            log.info("job is long → progress card")
            if self.wheelJob == id {
                self.wheelJob = nil
                self.wheel.handOff()
            }
        }
    }

    private func finish(_ id: UUID, skill: FileSkill, inputCount: Int, started: Date, report: FileJobRunner.Report) {
        let wasLong = jobs.finish(id)
        let record = JobRecord(
            date: started, skillID: skill.id, skillName: skill.name, symbol: skill.symbol,
            inputCount: inputCount, outputs: report.outputs.map(\.path), failures: report.failures,
            skipped: report.skipped, canceledCount: report.canceled, duration: Date().timeIntervalSince(started)
        )
        history.add(record)
        log.info("job done: ok=\(report.outputs.count, privacy: .public) failed=\(report.failures.count, privacy: .public) skipped=\(report.skipped, privacy: .public) canceled=\(report.canceled, privacy: .public) long=\(wasLong, privacy: .public)")

        if wheelJob == id {
            wheelJob = nil
            wheel.finish(succeeded: report.outputs.count, failed: report.failures.count)
        }
        if wasLong { notifier.notifyFinished(record) }
        if !report.failures.isEmpty { showFailures(report.failures) }
    }

    // MARK: AI 작업 (글자 인식 → 불확실한 곳만 AI → 검토 → 적용해야 저장)

    /// 열려 있는 What is it? 창들
    private var whatIsWindows: [UUID: WhatIsController] = [:]

    private func startWhatIs(urls: [URL]) {
        guard let agent = agents.agent(for: .whatIs), let url = urls.first else {
            wheel.close()
            showAlert(L("쓸 수 있는 AI가 없어요", "No AI available"), L("Ollama나 LM Studio를 켜거나, 설정 › API 키에서 클라우드 AI를 켜줘.", "Start Ollama or LM Studio, or turn on cloud AI in Settings › API Keys."))
            return
        }
        let id = UUID()
        let controller = WhatIsController(url: url, agent: agent, agents: agents)
        controller.anchor = wheel.lastCenter
        controller.onClose = { [weak self] in self?.whatIsWindows[id] = nil }
        whatIsWindows[id] = controller
        wheel.beginWork(total: 1, ai: true)
        wheel.handOff()                              // 휠은 바로 닫고, 그 자리에 요약 창이 뜬다
        controller.show()
    }

    private func startAIJob(_ task: AITask, urls: [URL]) {
        if task == .whatIs { startWhatIs(urls: urls); return }
        guard case .ocrTypoFix = task, let agent = agents.agent(for: .ocrTypoFix) else {
            wheel.close()
            showAlert(L("쓸 수 있는 AI가 없어요", "No AI available"), L("Ollama나 LM Studio를 켜거나, 설정 › API 키에서 클라우드 AI를 켜줘.", "Start Ollama or LM Studio, or turn on cloud AI in Settings › API Keys."))
            return
        }
        let id = UUID()
        let started = Date()
        let title = L("AI 오타수정", "AI typo fix")
        wheelJob = id
        progressCard.anchor = wheel.lastCenter        // 검토 대기 카드도 휠이 있던 자리에
        wheel.beginWork(total: urls.count, ai: true)
        // 파일 이름·내용은 남기지 않는다
        log.info("ai job start: files=\(urls.count, privacy: .public) cloud=\(!agent.isLocal, privacy: .public)")
        let apiKey = agent.isLocal ? nil : KeychainStore.key(for: agent.provider)
        let cloudEnabled = agents.cloudEnabled

        let work = Task { @MainActor [weak self] in
            var documents: [OCRReview.Document] = []
            var failures: [JobRecord.Failure] = []
            do {
                for url in urls {
                    self?.jobs.update(id, current: L("글자 인식 중 · \(url.lastPathComponent)", "Recognizing text · \(url.lastPathComponent)"))
                    do {
                        documents.append(try await FileJobRunner.onWorkQueue { try OCRReview.prepare(url, cancellation: $0) })
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        failures.append(JobRecord.Failure(name: url.lastPathComponent, message: error.localizedDescription))
                    }
                }
                let total = documents.reduce(0) { $0 + $1.spotCount }
                self?.jobs.update(id, done: 0, total: total, current: total == 0 ? L("확인할 곳이 없어요", "Nothing to check") : L("AI가 확인하는 중", "AI is checking"))
                var checked = 0
                for index in documents.indices {
                    var outputs: [String] = []
                    for (batch, prompt) in documents[index].prompts(batchSize: Self.aiBatch).enumerated() {
                        try Task.checkCancellation()
                        outputs.append(try await AIClient.complete(
                            system: OCRReview.systemPrompt, messages: [.user(prompt)], agent: agent,
                            apiKey: apiKey, cloudEnabled: cloudEnabled, json: true, temperature: 0
                        ))
                        checked += min(Self.aiBatch, documents[index].spotCount - batch * Self.aiBatch)
                        self?.jobs.update(id, done: checked)
                    }
                    documents[index].apply(aiOutputs: outputs)
                }
                self?.aiFinished(id, title: title, documents: documents, failures: failures, agent: agent, started: started)
            } catch is CancellationError {
                self?.endAIJob(id, succeeded: 0, failed: 0)
            } catch {
                log.error("ai job failed: \(error.localizedDescription, privacy: .public)")
                self?.endAIJob(id, succeeded: 0, failed: 1)
                self?.showAlert(L("AI 오타수정을 하지 못했어요", "AI typo fix failed"), error.localizedDescription + L("\n\n아무것도 저장하지 않았어요.", "\n\nNothing was saved."))
            }
        }
        jobs.begin(JobCenter.Job(id: id, title: title, symbol: "sparkles", total: 0, started: started, agent: agent, unit: L("곳", " spot(s)"))) { [weak self] in
            work.cancel()
            self?.discardReview(id)                 // 검토를 기다리던 중이면 "버리기"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + JobCenter.longJobThreshold) { [weak self] in
            guard let self else { return }
            self.progressCard.anchor = self.wheel.lastCenter
            guard self.jobs.markLongIfRunning(id) else { return }
            if self.wheelJob == id {
                self.wheelJob = nil
                self.wheel.handOff()
            }
        }
    }

    private func aiFinished(_ id: UUID, title: String, documents: [OCRReview.Document], failures: [JobRecord.Failure],
                            agent: Agent, started: Date) {
        if !failures.isEmpty { showFailures(failures) }
        guard !documents.isEmpty else {
            endAIJob(id, succeeded: 0, failed: failures.count)
            return
        }
        let spots = documents.reduce(0) { $0 + $1.spotCount }
        let changes = documents.reduce(0) { $0 + $1.changes.count }
        log.info("ai job ready: spots=\(spots, privacy: .public) changes=\(changes, privacy: .public)")
        if spots == 0 {
            // 불확실한 곳이 없으면 AI는 끼지 않았다 → 검토 없이 인식한 글 그대로 저장
            let outputs = save(documents)
            record(id, title: title, documents: documents, outputs: outputs, failures: failures, started: started)
            endAIJob(id, succeeded: outputs.count, failed: failures.count)
            return
        }
        let wasLong = jobs.longJobs.contains { $0.id == id }
        jobs.awaitReview(id) { [weak self] in
            self?.openReview(id, title: title, documents: documents, agent: agent, failures: failures, started: started)
        }
        if wheelJob == id {
            wheelJob = nil
            wheel.handOff()
        }
        if wasLong { notifier.notifyReviewReady(title: title, changes: changes) }
    }

    private func openReview(_ id: UUID, title: String, documents: [OCRReview.Document], agent: Agent,
                            failures: [JobRecord.Failure], started: Date) {
        if let open = reviews[id] { open.show(); return }
        let controller = ReviewWindowController(documents: documents, agent: agent, onApply: { [weak self] reviewed in
            guard let self else { return }
            let outputs = self.save(reviewed)
            self.record(id, title: title, documents: reviewed, outputs: outputs, failures: failures, started: started)
            self.reviews[id] = nil
            self.jobs.finish(id)
            log.info("ai review applied: files=\(outputs.count, privacy: .public)")
        }, onDiscard: { [weak self] in
            self?.discardReview(id)
        }, onClose: { [weak self] in
            // 창만 닫았으면 카드의 "검토하기"로 다시 열 수 있게 둔다
            self?.reviews[id] = nil
        })
        controller.anchor = progressCard.anchor
        reviews[id] = controller
        controller.show()
    }

    /// "버리기": 아무것도 저장하지 않고 끝낸다
    private func discardReview(_ id: UUID) {
        guard jobs.jobs.first(where: { $0.id == id })?.awaitingReview == true else { return }
        reviews[id] = nil
        jobs.finish(id)
        log.info("ai review discarded")
    }

    private func endAIJob(_ id: UUID, succeeded: Int, failed: Int) {
        jobs.finish(id)
        if wheelJob == id {
            wheelJob = nil
            wheel.finish(succeeded: succeeded, failed: failed)
        }
    }

    /// 고친 글을 원본 옆에 같은 이름의 .txt로
    private func save(_ documents: [OCRReview.Document]) -> [URL] {
        documents.compactMap { document in
            try? FileOutputWriter.save(Data(document.finalText.utf8), fileExtension: "txt", suffix: "", besideOriginal: document.source)
        }
    }

    private func record(_ id: UUID, title: String, documents: [OCRReview.Document], outputs: [URL],
                        failures: [JobRecord.Failure], started: Date) {
        history.add(JobRecord(
            date: started, skillID: "image-ocr-ai", skillName: title, symbol: "sparkles",
            inputCount: documents.count + failures.count, outputs: outputs.map(\.path), failures: failures,
            duration: Date().timeIntervalSince(started)
        ))
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate()
        alert.runModal()
    }

    private func showFailures(_ failures: [JobRecord.Failure]) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = failures.count == 1 ? L("변환하지 못한 파일이 있어요", "Some files couldn't be converted") : L("변환하지 못한 파일이 \(failures.count)개 있어요", "\(failures.count) file(s) couldn't be converted")
        let shown = failures.prefix(3).map { "• \($0.name): \($0.message)" }.joined(separator: "\n")
        alert.informativeText = shown + (failures.count > 3 ? L("\n… 외 \(failures.count - 3)개", "\n… and \(failures.count - 3) more") : "") + L("\n\n나머지 파일은 정상적으로 저장됐어요. 원본은 그대로예요.", "\n\nThe other files were saved. Originals are untouched.")
        NSApp.activate()
        alert.runModal()
    }

    // MARK: 되돌리기

    /// 메뉴의 "마지막 파일 변환 되돌리기"가 휴지통으로 옮길 파일 수 (없으면 0)
    package var undoableCount: Int { history.latestUndoable?.outputs.count ?? 0 }

    /// 마지막 작업이 만든 결과 파일을 휴지통으로 옮긴다(원본은 건드린 적이 없으니 이걸로 충분하다).
    package func undoLastConversion() {
        guard let record = history.latestUndoable else { return }
        let outcome = history.undo(record.id)
        log.info("undo: trashed=\(outcome.trashed, privacy: .public) missing=\(outcome.missing, privacy: .public) failed=\(outcome.failed, privacy: .public)")
        if outcome.failed > 0 {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L("일부 파일을 휴지통으로 옮기지 못했어요", "Some files couldn't be moved to the Trash")
            alert.informativeText = L("\(outcome.trashed)개는 옮겼고 \(outcome.failed)개는 못 옮겼어요.", "Moved \(outcome.trashed), couldn't move \(outcome.failed).")
            NSApp.activate()
            alert.runModal()
        }
    }

    /// 설정 창에 끼워 넣는 "작업 기록" 탭
    package func historyTab() -> SettingsTab {
        SettingsTab(id: FileFeatureSettings.historyTabID, title: L("작업 기록", "History"), systemImage: "clock.arrow.circlepath") { [history] in
            AnyView(HistoryTab(history: history))
        }
    }
}

/// 설정 › 일반 탭에 끼워 넣는 "파일 기능" 섹션.
package enum FileFeatureSettings {
    package static let historyTabID = "file-history"
    package static func section() -> AnyView { AnyView(FileFeatureSection()) }
}

private struct FileFeatureSection: View {
    @AppStorage(FileFeatureController.enabledKey) private var enabled = true
    @State private var keysChanged = false

    var body: some View {
        Section(L("파일 기능", "File features")) {
            Toggle(L("파일을 끌어서 변환하기", "Convert files by dragging"), isOn: $enabled)
            ForEach(WheelMode.allCases, id: \.self) { mode in
                Picker(L("\(mode.title) 휠", "\(mode.title) wheel"), selection: Binding(
                    get: { WheelKeys.key(for: mode) },
                    set: { WheelKeys.set($0, for: mode); keysChanged.toggle() }
                )) {
                    ForEach(ModifierKey.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .id("\(mode.rawValue)-\(keysChanged)")
            }
            Text(L("파일을 끌기 시작한 뒤에 키를 눌러요(⌃는 끌기 전에 누르면 오른쪽 클릭이 돼요). 휠이 떠 있는 동안 다른 키를 누르면 그 휠로 바뀌어요. 같은 키를 고르면 두 휠의 키가 서로 바뀌어요.", "Press the key after you start dragging (⌃ before clicking is a right-click). Press another key while the wheel is open to switch. Picking a key that's in use swaps the two."))
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent(L("저장 위치", "Saved to"), value: L("원본 옆에 새 파일 (원본은 그대로)", "A new file next to the original (the original is untouched)"))
        }
    }
}
