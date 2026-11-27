import AppCore
import AppKit
import CryptoKit
import PDFKit
import SkillEngine

/// 읽기 쪽 기능: 책처럼/한 장씩, 두 쪽 기준, 쪽 이동, 파트로 건너뛰기·되돌아가기, 문제 ↔ 답지, AI로 책 나누기.
/// 파트 목록과 두 쪽 기준은 파일마다 이 맥에 기억해 둔다(다시 열면 바로).
extension PDFSession {
    // MARK: 보기 방식

    /// 책처럼 = 두 쪽씩(이어서 내리기), 한 장씩 = 한 쪽씩(이어서 내리기).
    /// 두 쪽 볼 때 "1쪽 혼자"면 2·3, 4·5…가 짝이고, 아니면 1·2, 3·4…가 짝이다.
    func applyLayout() {
        guard let view else { return }
        let mode: PDFDisplayMode = bookLayout ? .twoUpContinuous : .singlePageContinuous
        if view.displayMode != mode { view.displayMode = mode }
        view.displaysAsBook = bookLayout && coverAlone
        if fitsPage { DispatchQueue.main.async { self.fitPage() } } else { view.autoScales = true }
    }

    /// 지금 보는 쪽이 왼쪽에 오게 두 쪽 기준을 맞춘다
    func alignCurrentPageLeft() {
        // 1쪽 혼자일 때 왼쪽 쪽은 2·4·6…(0부터 1·3·5), 아니면 1·3·5…(0부터 0·2·4)
        coverAlone = currentPage % 2 == 1
        bookLayout = true
        message = L("\(currentPage + 1)쪽이 왼쪽에 오게 맞췄어요", "Page \(currentPage + 1) is now on the left")
    }

    // MARK: 쪽 이동

    func pageChanged() {
        guard let view, let document, let page = view.currentPage else { return }
        currentPage = document.index(for: page)
        if let index = bookIndex, let here = index.section(at: currentPage) {
            for s in [here] + index.ancestors(of: here) { lastPageInPart[s.id] = currentPage }
        }
    }

    func go(toPage index: Int, remember: Bool) {
        guard let document, let page = document.page(at: min(max(index, 0), document.pageCount - 1)) else { return }
        if remember, history.last != currentPage { history.append(currentPage); if history.count > 50 { history.removeFirst() } }
        view?.go(to: page)
        currentPage = document.index(for: page)
    }

    /// 파트로 건너뛰기(되돌아가기 목록에 지금 자리를 남긴다)
    func jump(to section: BookSection) {
        let last = lastPageInPart[section.id].flatMap { (section.start...section.end).contains($0) ? $0 : nil }
        go(toPage: last ?? section.start, remember: true)
    }

    /// 목차(책갈피)로 건너뛰기: 되돌아가기 목록에 지금 자리를 남기고 간다
    func rememberAndGo(to destination: PDFDestination?) {
        guard let destination, let document, let page = destination.page else { return }
        if history.last != currentPage { history.append(currentPage) }
        view?.go(to: destination)
        currentPage = document.index(for: page)
    }

    func goBack() {
        guard let back = history.popLast() else { return }
        go(toPage: back, remember: false)
    }

    var currentSection: BookSection? { bookIndex?.section(at: currentPage) }

    /// 지금 쪽에서 건너갈 곳들(단추로 보인다). 이름은 AI가 정한 그 파트의 역할("해설", "기본 문제"…)
    struct JumpTarget: Identifiable {
        var id: String
        var label: String
        var hint: String
        var page: Int?
        var section: BookSection?
    }

    var jumpTargets: [JumpTarget] {
        guard let index = bookIndex else { return [] }
        var out: [JumpTarget] = []
        // 1. 쪽끼리 바로 이은 곳(책에 찍힌 "정답과 해설 n쪽"·"본문 n쪽")
        if let page = index.linkedPage(from: currentPage) {
            let target = index.section(at: page)
            let name = target.map { $0.role.isEmpty ? $0.title : $0.role } ?? L("짝 쪽", "Linked page")
            out.append(JumpTarget(id: "page", label: name, hint: L("\(page + 1)쪽 · \(target?.title ?? "")", "p.\(page + 1) · \(target?.title ?? "")"), page: page))
        }
        // 2. AI가 이어 둔 파트들(같은 역할 이름이 이미 있으면 빼고)
        if let here = index.section(at: currentPage) {
            for target in index.destinations(from: here) where out.count < 3 {
                let name = target.role.isEmpty ? target.title : target.role
                guard !out.contains(where: { $0.label == name }) else { continue }
                out.append(JumpTarget(id: target.id, label: name, hint: "\(target.title) · \(target.start + 1)–\(target.end + 1)쪽", section: target))
            }
        }
        return out
    }

    func go(to target: JumpTarget) {
        if let page = target.page { go(toPage: page, remember: true) } else if let section = target.section { jump(to: section) }
    }

    // MARK: 책 나누기(AI → 짐작) + "본문 n쪽" 표시로 자세히·쪽 잇기

    func buildIndex(force: Bool = false) {
        guard let document, let url, !indexing else { return }
        if !force, let cached = loadIndex(), cached.pageCount == document.pageCount { bookIndex = cached; return }
        indexing = true
        indexProgress = IndexProgress(stage: .preparing)
        let digest = BookIndexer.pageDigest(document)
        let outline = BookIndexer.outlineEntries(document).prefix(120).map { "\($0.title) → p\($0.page + 1)" }
        let pageCount = document.pageCount
        let started = Date()
        indexTask = Task { @MainActor in
            defer { self.indexing = false; self.indexProgress = nil; self.indexTask = nil }
            var index: BookIndex?
            var failure: String?
            AddonBootstrap.syncAISettings()       // 본체에서 고른 AI(로컬/클라우드)를 지금 값으로
            let agents = AgentStore()
            await agents.refresh()
            if let agent = agents.agent(for: .bookParts) {
                let key = agent.isLocal ? nil : KeychainStore.key(for: agent.provider)
                self.indexProgress?.stage = .reading
                self.indexProgress?.model = agent.model
                do {
                    // 답을 조금씩 받으면서 진행률을 센다: AI는 목차를 쪽 순서대로 쓰니까 마지막으로 쓴 "end" 쪽 / 전체 쪽
                    var answer = ""
                    for try await piece in AIClient.stream(
                        system: BookIndexer.system,
                        messages: [.user(BookIndexer.prompt(digest: digest, outline: Array(outline), pageCount: pageCount))],
                        agent: agent, apiKey: key, cloudEnabled: agents.cloudEnabled, json: true, temperature: 0.1) {
                        answer += piece
                        let page = Self.lastWrittenPage(in: answer)
                        self.indexProgress?.wrote(page: page, of: pageCount, characters: answer.count)
                    }
                    index = BookIndexer.parse(answer, pageCount: pageCount)
                    if index == nil { log.error("book index: unreadable AI answer") }
                } catch is CancellationError {
                    log.info("book index AI cancelled")
                } catch let error as URLError where error.code == .cancelled {
                    log.info("book index AI cancelled")
                } catch {
                    log.error("book index AI failed: \(error.localizedDescription, privacy: .public)")
                    if !Task.isCancelled { failure = Self.explain(error, agent: agent) }
                }
            }
            self.indexProgress?.stage = .refining
            // 짐작·다듬기·쪽 잇기는 쪽마다 글을 다 읽어야 해서 따로 연 사본으로 뒤에서
            let base = index
            let result = await Task.detached(priority: .userInitiated) { () -> BookIndex? in
                guard let copy = PDFDocument(url: url) else { return base }
                guard var built = base ?? BookIndexer.guess(copy) else { return nil }
                BookIndexer.enrich(copy, into: &built)
                return built
            }.value
            guard self.url == url else { return }      // 그사이 다른 파일을 열었으면 버린다
            if let failure { self.aiError = failure }
            if let result, !result.sections.isEmpty {
                self.bookIndex = result
                self.saveIndex(result)
                let n = result.sections.count
                let took = IndexProgress.clock(Date().timeIntervalSince(started))
                self.message = (result.source == .ai ? L("AI가 책 구조를 \(n)개 파트로 읽었어요", "AI read \(n) sections")
                    : L("AI 없이 책갈피·쪽 표시로 \(n)개 파트를 찾았어요", "Found \(n) sections without AI")) + " · " + took
            } else {
                self.message = L("파트를 못 찾았어요. 한라봉 설정에서 AI를 켜면 더 잘 나눠요", "Couldn't find parts. Turn on AI in Hanlabong settings for better results")
            }
        }
    }

    /// AI 부르기만 그만두기: 그때까지 받은 건 버리고 쪽 표시·책갈피로만 나눈다
    func stopAIIndexing() { indexTask?.cancel() }

    /// 받은 답에서 마지막으로 나온 "end": N (없으면 "start")
    static func lastWrittenPage(in answer: String) -> Int? {
        let tail = String(answer.suffix(400))
        let re = try! NSRegularExpression(pattern: #""(?:start|end)"\s*:\s*(\d+)"#)
        return re.matches(in: tail, range: NSRange(tail.startIndex..., in: tail))
            .compactMap { Range($0.range(at: 1), in: tail).flatMap { Int(tail[$0]) } }.max()
    }

    /// 오류창에 띄울 말: 키 만료·잘못된 키(401·403)는 따로 알려준다. fallback = AI 대신 어떻게 했는지
    static func explain(_ error: Error, agent: Agent, fallback: String = L("이번엔 AI 없이 책갈피·쪽 표시로만 나눴어요.", "This time the book was split without AI.")) -> String {
        let tail = fallback.isEmpty ? "" : " " + fallback
        if case AIError.http(let code, _) = error, code == 401 || code == 403 {
            return L("\(agent.provider.displayName) API 키가 만료됐거나 맞지 않아서 AI가 요청을 처리하지 못했어요(\(code)). 한라봉 설정 › API 키에서 새 키를 넣거나, 로컬 AI로 바꿔줘.",
                     "\(agent.provider.displayName) rejected the API key (\(code)): it has expired or is wrong. Add a new key in Hanlabong Settings › API Keys, or switch to a local AI.") + tail
        }
        return L("AI가 요청을 처리하지 못했어요: \(error.localizedDescription)", "The AI couldn't handle the request: \(error.localizedDescription)") + tail
    }

    // MARK: 파일마다 기억(이 맥에만): 파트 목록, 두 쪽 기준

    private var storeFolder: URL { AppPaths.supportFolder.appendingPathComponent("books2", isDirectory: true) }

    /// 파일 경로 + 크기 + 고친 시각으로 이름표(내용이 바뀌면 새로 나눈다)
    private var storeKey: String? {
        guard let url, let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
        let raw = "\(url.path)|\(values.fileSize ?? 0)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24).description
    }

    private struct Stored: Codable { var index: BookIndex?; var coverAlone: Bool? }

    private func readStored() -> Stored? {
        guard let key = storeKey, let data = try? Data(contentsOf: storeFolder.appendingPathComponent("\(key).json")) else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    private func writeStored(_ change: (inout Stored) -> Void) {
        guard let key = storeKey else { return }
        var stored = readStored() ?? Stored()
        change(&stored)
        try? FileManager.default.createDirectory(at: storeFolder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(stored).write(to: storeFolder.appendingPathComponent("\(key).json"), options: .atomic)
    }

    func loadIndex() -> BookIndex? { readStored()?.index }
    func saveIndex(_ index: BookIndex) { writeStored { $0.index = index } }

    func loadReaderState() {
        let stored = readStored()
        coverAlone = stored?.coverAlone ?? true
        bookIndex = stored?.index
    }

    func saveReaderState() {
        guard url != nil else { return }
        let value = coverAlone
        writeStored { $0.coverAlone = value }
    }
}

/// 책 나누기 진행 상황: 준비 → AI가 읽는 중(답이 아직 안 옴) → AI가 목차 쓰는 중(몇 %) → 쪽 표시로 다듬는 중
struct IndexProgress: Equatable {
    enum Stage: Equatable { case preparing, reading, writing, refining }
    var stage: Stage
    var model: String?
    var started = Date()
    var writingStarted: Date?
    /// AI가 목차를 몇 쪽까지 썼는지(0~1)
    var fraction: Double?
    var characters = 0

    mutating func wrote(page: Int?, of pageCount: Int, characters: Int) {
        if stage != .writing { stage = .writing; writingStarted = Date() }
        self.characters = characters
        if let page, pageCount > 0 { fraction = max(fraction ?? 0, min(Double(page) / Double(pageCount), 0.99)) }
    }

    var title: String {
        switch stage {
        case .preparing: return L("준비 중", "Preparing")
        case .reading: return L("AI가 책을 읽는 중", "AI is reading the book")
        case .writing: return L("AI가 목차를 쓰는 중", "AI is writing the contents")
        case .refining: return L("쪽 표시로 다듬는 중", "Refining from page marks")
        }
    }

    /// 남은 시간 짐작: 목차 쓰기가 시작된 뒤 속도로(쓰기 전엔 모른다)
    func remaining(now: Date) -> TimeInterval? {
        guard stage == .writing, let fraction, fraction > 0.05, let writingStarted else { return nil }
        let spent = now.timeIntervalSince(writingStarted)
        return spent / fraction * (1 - fraction)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        return s >= 60 ? L("\(s / 60)분 \(s % 60)초", "\(s / 60)m \(s % 60)s") : L("\(s)초", "\(s)s")
    }
}
