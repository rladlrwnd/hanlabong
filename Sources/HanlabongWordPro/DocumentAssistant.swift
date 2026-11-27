import AppCore
import AppKit
import Foundation
import SkillEngine

/// 문서 영역의 AI 요청칸. PDF 쪽(PDFSessionFill.swift)과 같은 방식: 에이전트 고르기 → AIClient.stream → 받는 대로 보여 주기.
/// 3단계: 묻는 말엔 답하고, 고쳐 달라는 말엔 문서를 직접 고친다(행동 계획·적용은 DocumentAIEdit.swift).
extension DocumentSession {
    // MARK: AI 고르기

    /// 요청칸에서 직접 고른 게 있고 지금 쓸 수 있으면 그걸, 아니면 한라봉 설정(자동)
    func assistantAgent() async -> (Agent, AgentStore)? {
        AddonBootstrap.syncAISettings()
        let agents = AgentStore()
        await agents.refresh()
        agentChoices = agents.allAgents
        let picked = assistantAgentID.flatMap { id in agents.allAgents.first { $0.id == id } }
        guard let agent = picked ?? agents.agent(for: .pdfAssistant) else { currentAgent = nil; return nil }
        currentAgent = agent
        return (agent, agents)
    }

    /// 요청칸이 보일 때·고를 때 목록과 지금 AI를 새로
    func refreshAgents() async { _ = await assistantAgent() }

    /// nil = 자동(한라봉 설정을 따름)
    func pickAgent(_ agent: Agent?) {
        assistantAgentID = agent?.id
        Task { await refreshAgents() }
    }

    func stopAssistant() { assistantTask?.cancel() }

    // MARK: 묻기 · 고치기

    /// 묻는 말엔 답하고, 고쳐 달라는 말엔 문서를 직접 고친다(3단계).
    /// 차례: 목차 이동 → 로컬 빠른 길("A를 B로 바꿔 줘", "주소에 ~ 써 줘") → AI에게 JSON 행동 목록(DocumentAIEdit.system)
    /// 빈칸 채우기 요청인가: "채워/작성해/기입해" + (빈칸·칸·서식·양식·신청서·내 정보·전부·다) 또는 대상 없이 "채워 줘"
    static func wantsFill(_ text: String) -> Bool {
        let verb = text.range(of: #"(채워|채우|작성해|작성\s*해|기입해|입력해)"#, options: .regularExpression) != nil
        guard verb else { return false }
        let target = text.range(of: #"(빈\s*칸|칸들|서식|양식|신청서|지원서|내\s*정보|정보로|전부|다\s*채|모두|알아서|자동)"#, options: .regularExpression) != nil
        // "주소에 ~ 써 줘"처럼 칸 하나를 짚은 요청은 아니다(그건 앞에서 따로 처리)
        let single = text.range(of: #"\S+(에|란에|칸에)\s"#, options: .regularExpression) != nil && !target
        return !single && (target || text.trimmingCharacters(in: .whitespaces).count <= 8)
    }

    /// AI에게 줄 내 정보(채우기·쓰기 요청에서 값을 지어내지 않고 이걸 쓰게)
    static func profileContext() -> String {
        let filled = ProfileStore.load().filled
        guard !filled.isEmpty else { return "\n\n[내 정보] 비어 있음 — 사용자 정보가 필요하면 지어내지 말고 물어볼 것" }
        return "\n\n[내 정보] 사용자가 자기 정보를 채우거나 쓰라고 하면 이 값을 그대로 쓴다(없는 항목은 지어내지 말고 비워 두고 알려 줄 것)\n"
            + filled.map { "- \($0.key): \($0.value)" }.joined(separator: "\n")
    }

    func ask(_ request: String) {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let document, !assistantPhase.busy else { return }
        assistantReply = nil

        // "~로 가줘"는 AI를 부르지 않고 목차에서 바로 간다
        let wantsToGo = text.range(of: #"(가\s*줘|가자|갈래|이동|넘겨|펼쳐|열어|보여\s*줘)"#, options: .regularExpression) != nil
        let matched = document.outlineItem(matching: text)
        if wantsToGo, let matched, matched.location != nil {
            scroll(to: matched)
            assistantReply = L("“\(matched.title)”(으)로 왔어요", "Went to “\(matched.title)”")
            return
        }

        // 지금 종이 위 글(고친 것까지). 화면이 아직 없으면 읽어 온 글
        let live: NSAttributedString = editor.textView?.textStorage ?? document.attributed
        let local = DocumentAIEdit.local(text, in: live)
        if let plan = local.plan {
            assistantTask = Task { @MainActor [weak self] in
                guard let self else { return }
                self.assistantReply = await self.applyEdits(plan, reply: "")
                self.assistantTask = nil
            }
            return
        }

        // "빈칸 채워 줘", "내 정보로 작성해 줘", "신청서 채워 줘" → 내 정보로 빈칸 채우기(채우기 단추와 같은 일)
        if Self.wantsFill(text), let fill {
            assistantTask = Task { @MainActor [weak self] in
                _ = await fill.autoFill()
                self?.assistantTask = nil
            }
            return
        }

        assistantPhase = .waiting
        let visible = editor.visibleCharacterRange()
        let selection = editor.textView?.selectedRange()
        let context = DocumentAIEdit.context(text: live, fileName: title, kind: area.title, outline: document.outline,
                                             visible: visible, selection: selection, focus: matched)
        let hint = (selection?.length ?? 0) > 0 ? (selection?.location ?? 0) : (visible?.location ?? 0)
        assistantTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let (agent, agents) = await self.assistantAgent() else {
                self.assistantPhase = .idle
                self.assistantTask = nil
                self.assistantReply = local.note
                    ?? L("AI가 꺼져 있어요. 한라봉 설정에서 AI를 켜면 문서에 대해 묻거나 고쳐 달라고 할 수 있어요",
                         "AI is off. Turn it on in Hanlabong settings to ask about or edit the document")
                return
            }
            var answer = ""
            do {
                for try await piece in AIClient.stream(system: DocumentAIEdit.system,
                                                       messages: [.user(context + Self.profileContext() + "\n\n사용자 요청: " + text)],
                                                       agent: agent, apiKey: agent.isLocal ? nil : KeychainStore.key(for: agent.provider),
                                                       cloudEnabled: agents.cloudEnabled, json: true, temperature: 0.2) {
                    answer += piece
                    self.assistantPhase = .writing
                    // 답 글("reply")은 받는 대로 바로 보여 준다
                    if let partial = PDFSession.partialReply(in: Self.cleaned(answer)), partial != self.assistantReply { self.assistantReply = partial }
                }
            } catch is CancellationError {
                self.assistantPhase = .idle; self.assistantTask = nil; return
            } catch let error as URLError where error.code == .cancelled {
                self.assistantPhase = .idle; self.assistantTask = nil; return
            } catch {
                self.assistantPhase = .idle; self.assistantTask = nil
                if !Task.isCancelled { self.aiError = Self.explain(error, agent: agent) }
                return
            }
            await self.finish(answer: answer, hint: hint)
            self.assistantTask = nil
        }
    }

    /// AI 답을 행동으로: 이동 → 고치기(타자 효과) → 결과 한 줄. JSON이 아니면 답 글만
    private func finish(answer: String, hint: Int) async {
        guard let parsed = DocumentAIEdit.parse(answer) else {
            // JSON이 아니면: reply만 건지고, 그것도 없으면 앞부분만(날것을 다 쏟지 않게)
            let shown = PDFSession.partialReply(in: Self.cleaned(answer)) ?? String(Self.cleaned(answer).prefix(600))
            assistantPhase = .idle
            assistantReply = shown.isEmpty ? L("답을 받지 못했어요. 다시 물어봐 줘요", "No answer came back. Try again") : shown
            log.info("doc assistant: not json chars=\(answer.count, privacy: .public)")
            return
        }
        let live: NSAttributedString = editor.textView?.textStorage ?? document?.attributed ?? NSAttributedString()
        let plan = DocumentAIEdit.plan(parsed.actions, in: live, near: hint)
        log.info("doc assistant: actions=\(parsed.actions.count, privacy: .public) edits=\(plan.edits.count, privacy: .public) failed=\(plan.failures.count, privacy: .public)")
        assistantPhase = .idle
        // 이동(고침이 없을 때만: 고치면 그 자리로 간다)
        if plan.edits.isEmpty, let heading = plan.gotos.first {
            if let item = document?.outlineItem(matching: heading), item.location != nil {
                scroll(to: item)
                assistantReply = parsed.reply.isEmpty ? L("“\(item.title)”(으)로 왔어요", "Went to “\(item.title)”") : parsed.reply
            } else {
                let name = DocumentAIEdit.short(heading)
                assistantReply = L("목차에서 ‘\(name)’\(DocumentAIEdit.josa(name, "을", "를")) 못 찾았어요", "Couldn't find ‘\(name)’ in the contents")
            }
            return
        }
        if plan.edits.isEmpty {
            let wantedEdit = parsed.actions.contains {
                switch $0 { case .answer, .goto: return false; default: return true }
            }
            // 고치려다 못 찾았으면 AI 말("바꿨어요") 대신 정직하게
            if wantedEdit { assistantReply = Self.failureMessage(plan, reply: "") }
            else { assistantReply = parsed.reply.isEmpty ? L("답을 받지 못했어요. 다시 물어봐 줘요", "No answer came back. Try again") : parsed.reply }
            return
        }
        assistantReply = await applyEdits(plan, reply: parsed.reply)
    }

    // MARK: 말 다듬기

    /// 어떤 모델은 생각 과정을 <think>…</think>로 같이 보낸다. 답에는 안 보이게(아직 안 닫혔어도 그 뒤는 가린다)
    static func cleaned(_ answer: String) -> String {
        var s = answer.replacingOccurrences(of: #"(?s)<think>.*?</think>"#, with: "", options: .regularExpression)
        if let open = s.range(of: "<think>") { s = String(s[..<open.lowerBound]) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 오류창에 띄울 말: 키 만료·잘못된 키(401·403)는 따로 알려준다
    static func explain(_ error: Error, agent: Agent) -> String {
        if case AIError.http(let code, _) = error, code == 401 || code == 403 {
            return L("\(agent.provider.displayName) API 키가 만료됐거나 맞지 않아서 AI가 요청을 처리하지 못했어요(\(code)). 한라봉 설정 › API 키에서 새 키를 넣거나, 로컬 AI로 바꿔줘.",
                     "\(agent.provider.displayName) rejected the API key (\(code)): it has expired or is wrong. Add a new key in Hanlabong Settings › API Keys, or switch to a local AI.")
        }
        return L("AI가 요청을 처리하지 못했어요: \(error.localizedDescription)", "The AI couldn't handle the request: \(error.localizedDescription)")
    }
}
