import Foundation
import AppKit

// 지금 돌아가는 Claude Code 세션 목록 + 클릭하면 그 터미널 탭으로 이동.
// 데이터: `claude agents --json --all` (대화형 + 백그라운드)
// 위치:   cmux top (pid → surface), ps (pid → 부모 앱), orca terminal list (제목 → 탭)

enum AgentStatus: Int, CaseIterable {
    case needsInput, working, idle, done
    var label: String {
        switch self {
        case .needsInput: L("입력 필요", "入力待ち")
        case .working: L("작업 중", "作業中")
        case .idle: L("대기", "待機")
        case .done: L("완료", "完了")
        }
    }
}

enum Host: Equatable {
    case cmux(workspace: String, surface: String)
    case orca(tabId: String, leafId: String?)
    case background(id: String)
    case unknown
    var rank: Int {
        switch self { case .cmux: 0; case .orca: 1; case .background: 2; case .unknown: 3 }
    }
    var label: String {
        switch self {
        case .cmux: "cmux"
        case .orca: "Orca"
        case .background: L("백그라운드", "バックグラウンド")
        case .unknown: L("터미널", "ターミナル")
        }
    }
}

struct Agent: Identifiable, Equatable {
    let id: String
    let name: String        // claude 세션 이름 (Orca 탭 제목과 같음)
    var title: String       // 보여줄 제목 (이름 바꾸기 낙관적 반영 때문에 var)
    let subtitle: String
    let cwd: String
    let status: AgentStatus
    let host: Host
    let lastActive: Date?
    let contextTokens: Int
    let pid: Int?
    let bgId: String?       // 백그라운드 세션 id (attach 된 탭으로 잡혀도 종료는 claude stop 으로)
}

// ───────── 언어 ─────────

enum Lang: String, CaseIterable { case ko, ja }
var lang: Lang { Lang(rawValue: UserDefaults.standard.string(forKey: "lang") ?? "") ?? .ko }
func L(_ ko: String, _ ja: String) -> String { lang == .ja ? ja : ko }

// ───────── cmux 비밀번호 (키체인) ─────────
// cmux 기본값(cmuxOnly)은 cmux 안에서 띄운 프로세스만 받아줌. 메뉴바 앱은 밖이라 Password 모드 + 비밀번호가 필요

// ponytail: 키체인은 재빌드마다 서명이 바뀌어 허용 창이 떠서, cmux 와 같은 방식(본인만 읽는 600 파일)으로 저장
enum CmuxPass {
    private static let path = "\(home)/.token-watch/cmux-password"
    static func get() -> String? {
        (try? String(contentsOfFile: path, encoding: .utf8))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
    }
    static func set(_ p: String) {
        FileManager.default.createFile(atPath: path, contents: Data(p.trimmingCharacters(in: .whitespacesAndNewlines).utf8),
                                       attributes: [.posixPermissions: 0o600])
    }
}

/// cmux 가 받아주는지. 막히면 출력 없이 Broken pipe 로 끝남
func cmuxReachable() -> Bool { sh(cmuxBin, ["list-workspaces"]).contains("workspace:") }

// ───────── 셸 실행 ─────────

let home = FileManager.default.homeDirectoryForCurrentUser.path
let cmuxBin = "/Applications/cmux.app/Contents/Resources/bin/cmux"
let orcaBin = "/Applications/Orca.app/Contents/Resources/bin/orca"

/// 앱은 로그인 셸 밖에서 돌아서 PATH가 비어 있음. claude(node 스크립트)가 돌 수 있게 직접 찾음.
let claudeBin: String? = {
    let fm = FileManager.default
    var c = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    if let vs = try? fm.contentsOfDirectory(atPath: "\(home)/.nvm/versions/node") {
        c += vs.sorted().reversed().map { "\(home)/.nvm/versions/node/\($0)/bin/claude" }
    }
    return c.first { fm.isExecutableFile(atPath: $0) }
}()

@discardableResult
func sh(_ bin: String, _ args: [String]) -> String {
    guard FileManager.default.isExecutableFile(atPath: bin) else { return "" }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: bin)
    p.arguments = args
    // 앱을 cmux/Orca 터미널에서 띄우면 그 탭의 ID를 물려받는데, cmux CLI가 이걸 "호출한 탭"으로 보고
    // 다른 워크스페이스로 안 넘어감. 그래서 지움
    var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CMUX_") && !$0.key.hasPrefix("ORCA_") }
    let extra = [claudeBin.map { ($0 as NSString).deletingLastPathComponent }, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
    // 비밀번호는 ps 에 보이는 인자 대신 환경변수로
    if bin == cmuxBin, let p = CmuxPass.get() { env["CMUX_SOCKET_PASSWORD"] = p }
    env["PATH"] = (extra.compactMap { $0 } + [env["PATH"] ?? ""]).joined(separator: ":")
    p.environment = env
    let out = Pipe()
    p.standardOutput = out
    // cmux 는 실패 이유를 stderr 로만 줘서 같이 받음 (성공 판정은 "OK" 접두로 하니까 안전)
    p.standardError = bin == cmuxBin ? out : FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

// ───────── 수집 ─────────

private struct RawAgent: Decodable {
    let pid: Int?
    let id: String?
    let cwd: String
    let kind: String
    let sessionId: String
    let name: String?
    let status: String?
    let state: String?
}

/// claude 프로세스의 환경변수. 터미널이 심어둔 탭 ID가 여기 있음.
/// (cmux top 은 죽은 탭이 tty 번호를 재사용하면 한 pid 를 여러 탭에 붙여서 못 믿음)
private func procEnv(_ pid: Int) -> [String: String] {
    let line = sh("/bin/ps", ["eww", "-o", "command=", "-p", "\(pid)"])
    var env: [String: String] = [:]
    for tok in line.split(separator: " ") where tok.hasPrefix("CMUX_") || tok.hasPrefix("ORCA_") {
        let kv = tok.split(separator: "=", maxSplits: 1)
        if kv.count == 2 { env[String(kv[0])] = String(kv[1]) }
    }
    return env
}

private func orcaTerminals() -> [[String: Any]] {
    let json = sh(orcaBin, ["terminal", "list", "--json"])
    let o = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    return (o?["result"] as? [String: Any])?["terminals"] as? [[String: Any]] ?? []
}

/// cmux tree 에서 surface UUID → 탭 제목
private func cmuxTitles() -> [String: String] {
    let tree = sh(cmuxBin, ["tree", "--all", "--id-format", "both"])
    var out: [String: String] = [:]
    let re = try! NSRegularExpression(pattern: #"surface surface:\d+ ([0-9A-F-]{36}) \[terminal\] "(.*?)""#)
    for m in re.matches(in: tree, range: NSRange(tree.startIndex..., in: tree)) {
        if let u = Range(m.range(at: 1), in: tree), let t = Range(m.range(at: 2), in: tree) {
            out[String(tree[u]).uppercased()] = String(tree[t])
        }
    }
    return out
}

/// "✳ 일본어 책 단어장 PWA" → "일본어 책 단어장 PWA" (앞의 스피너/상태 글리프 제거)
func cleanTitle(_ t: String) -> String {
    var s = Substring(t)
    while let f = s.first, !(f.isLetter || f.isNumber) { s = s.dropFirst() }
    return String(s).trimmingCharacters(in: .whitespaces)
}

// ───────── transcript에서 마지막 프롬프트와 컨텍스트 크기 ─────────

private func transcriptURL(_ sessionId: String) -> URL? {
    let projects = URL(fileURLWithPath: "\(home)/.claude/projects")
    guard let dirs = try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { return nil }
    return dirs.lazy.map { $0.appendingPathComponent("\(sessionId).jsonl") }
        .first { FileManager.default.fileExists(atPath: $0.path) }
}

private func tail(_ url: URL, bytes: Int = 131_072) -> [Substring] {
    guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
    defer { try? h.close() }
    let size = (try? h.seekToEnd()) ?? 0
    try? h.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
    let s = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
    var lines = s.split(separator: "\n")
    if size > UInt64(bytes), !lines.isEmpty { lines.removeFirst() }
    return lines
}

private func parsePromptAndContext(_ lines: [Substring]) -> (String, Int) {
    var prompt = "", ctx = 0
    for line in lines.reversed() {
        guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let msg = o["message"] as? [String: Any] else { continue }
        if ctx == 0, o["type"] as? String == "assistant", let u = msg["usage"] as? [String: Any] {
            ctx = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"].reduce(0) { $0 + ((u[$1] as? Int) ?? 0) }
        }
        if prompt.isEmpty, o["type"] as? String == "user", o["isMeta"] as? Bool != true {
            var texts: [String] = []
            if let s = msg["content"] as? String { texts = [s] }
            else if let arr = msg["content"] as? [[String: Any]], !arr.contains(where: { $0["type"] as? String == "tool_result" }) {
                texts = arr.compactMap { $0["text"] as? String }
            }
            // 슬래시 명령·시스템 태그 블록은 건너뜀
            prompt = texts.filter { !$0.hasPrefix("<") }.joined(separator: " ")
        }
        if !prompt.isEmpty && ctx > 0 { break }
    }
    return (prompt.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces), ctx)
}

// 파일이 안 바뀌었으면 다시 안 읽음
private var transcriptCache: [String: (Date, String, Int)] = [:]
private let cacheLock = NSLock()

private func lastPromptAndContext(_ url: URL) -> (String, Int) {
    let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
    cacheLock.lock(); let hit = transcriptCache[url.path]; cacheLock.unlock()
    if let hit, hit.0 == mtime { return (hit.1, hit.2) }
    // 스크린샷 붙은 줄은 한 줄이 수백 KB라, 못 찾으면 범위를 늘려 다시 읽음
    var result = ("", 0)
    for bytes in [131_072, 1_048_576, 4_194_304] {
        result = parsePromptAndContext(tail(url, bytes: bytes))
        if !result.0.isEmpty && result.1 > 0 { break }
    }
    cacheLock.lock(); transcriptCache[url.path] = (mtime, result.0, result.1); cacheLock.unlock()
    return result
}

private func jobDetail(_ id: String) -> String {
    let f = URL(fileURLWithPath: "\(home)/.claude/jobs/\(id)/state.json")
    guard let d = try? Data(contentsOf: f),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return "" }
    return (o["needs"] as? String) ?? (o["detail"] as? String) ?? ""
}

private func status(_ r: RawAgent) -> AgentStatus {
    let s = (r.status ?? r.state ?? "").lowercased()
    if ["blocked", "waiting", "needs_input", "awaiting", "permission"].contains(where: s.contains) { return .needsInput }
    if ["busy", "working", "running", "starting"].contains(where: s.contains) { return .working }
    if ["done", "failed", "error", "stopped", "exited"].contains(where: s.contains) { return .done }
    return .idle
}

/// 백그라운드 id → 그 세션에 `claude ... attach <id>` 로 붙어 있는 터미널 프로세스 pid
private func attachPids() -> [String: Int] {
    var m: [String: Int] = [:]
    for line in sh("/bin/ps", ["-axo", "pid=,command="]).split(separator: "\n") {
        let parts = line.split(separator: " ")
        guard parts.count > 2, parts[parts.count - 2] == "attach", parts.contains(where: { $0.hasSuffix("/claude") || $0 == "claude" }),
              let pid = Int(parts[0]) else { continue }
        m[String(parts[parts.count - 1])] = pid
    }
    return m
}

func collectAgents() -> [Agent] {
    guard let bin = claudeBin,
          let raws = try? JSONDecoder().decode([RawAgent].self, from: Data(sh(bin, ["agents", "--json", "--all"]).utf8))
    else { return [] }
    let titles = cmuxTitles()
    let orca = orcaTerminals()
    let attached = attachPids()

    return raws.map { r in
        let t = transcriptURL(r.sessionId)
        let (prompt, ctx) = t.map(lastPromptAndContext) ?? ("", 0)
        let mtime = t.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date }
        let name = r.name ?? String(r.sessionId.prefix(8))
        var host = Host.unknown
        var title = name
        // 백그라운드도 이미 어느 탭에서 `claude attach <id>` 중이면 그 탭으로 감 (새 워크스페이스 안 엶)
        let termPid = r.kind == "background" ? r.id.flatMap { attached[$0] } : r.pid
        if let pid = termPid {
            let env = procEnv(pid)
            if let s = env["CMUX_SURFACE_ID"], let w = env["CMUX_WORKSPACE_ID"] {
                host = .cmux(workspace: w, surface: s)
                let t = cleanTitle(titles[s.uppercased()] ?? "")
                if !t.isEmpty { title = t }
            } else if let tab = env["ORCA_TAB_ID"] {
                // ORCA_AGENT_PANE = "<tabId>:<leafId>"
                let leaf = env["ORCA_AGENT_PANE"]?.split(separator: ":").last.map(String.init)
                host = .orca(tabId: tab, leafId: leaf)
                let term = orca.first { $0["tabId"] as? String == tab && (leaf == nil || $0["leafId"] as? String == leaf) }
                    ?? orca.first { $0["tabId"] as? String == tab }
                if let t = term?["title"] as? String, !t.isEmpty { title = cleanTitle(t) }
            }
        }
        if case .unknown = host, r.kind == "background", let id = r.id { host = .background(id: id) }
        let sub = r.kind == "background" ? jobDetail(r.id ?? "") : prompt
        return Agent(id: r.id ?? "\(r.pid ?? 0)", name: name, title: title,
                     subtitle: sub.isEmpty ? (r.cwd as NSString).abbreviatingWithTildeInPath : sub,
                     cwd: r.cwd, status: status(r), host: host, lastActive: mtime, contextTokens: ctx, pid: r.pid, bgId: r.kind == "background" ? r.id : nil)
    }
    // 상태 → 앱(cmux, Orca, 백그라운드, 터미널) → 최근 순
    .sorted { ($0.status.rawValue, $0.host.rank, -($0.lastActive?.timeIntervalSince1970 ?? 0)) < ($1.status.rawValue, $1.host.rank, -($1.lastActive?.timeIntervalSince1970 ?? 0)) }
}

// ───────── 이동 ─────────

/// 백그라운드(accessory) 앱의 NSRunningApplication.activate() 는 macOS 14+에서 무시되기도 해서 open -a
private func bringToFront(_ app: String) { sh("/usr/bin/open", ["-a", app]) }

/// handle 은 Orca 재시작 때 바뀌니까 쓸 때마다 tabId 로 다시 찾음
private func orcaHandle(_ tab: String, _ leaf: String?) -> String? {
    let terms = orcaTerminals()
    let hit = terms.first { $0["tabId"] as? String == tab && (leaf == nil || $0["leafId"] as? String == leaf) }
        ?? terms.first { $0["tabId"] as? String == tab }
    return hit?["handle"] as? String
}

/// 그 세션 터미널에 `/rename 이름` 을 대신 입력해서 Claude Code 가 직접 이름을 바꾸게 함.
/// 입력창에 쓰던 글이 있으면 뒤에 붙고, 권한 질문 중이면 답으로 들어가니까 대기(idle) 세션만 허용 (canRename)
func rename(_ a: Agent, to raw: String) {
    // 줄바꿈은 전송, 역슬래시는 cmux 이스케이프라 제거
    let name = raw.components(separatedBy: .newlines).joined(separator: " ")
        .replacingOccurrences(of: "\\", with: "").trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty else { return }
    jumpLog("rename \(a.title) → \(name)")
    MainActor.assumeIsolated { agentStore.setOptimistic(a.id, name) }   // 버튼에서 불리니 메인
    let fail = { DispatchQueue.main.async { agentStore.dropOptimistic(a.id) } }
    DispatchQueue.global(qos: .userInitiated).async {
        switch a.host {
        case .cmux(let ws, let surface):
            let r = sh(cmuxBin, ["send", "--workspace", ws, "--surface", surface, "/rename \(name)\\r"])
            if r.contains("Error") { fail(); return cmuxBlocked(r) }
        case .orca(let tab, let leaf):
            guard let h = orcaHandle(tab, leaf) else { return fail() }
            sh(orcaBin, ["terminal", "send", "--terminal", h, "--text", "/rename \(name)", "--enter"])
        default: return fail()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { agentStore.refresh() }
    }
}

/// 클릭했는데 cmux 가 거절 → 패널에 비밀번호 안내 띄움
private func cmuxBlocked(_ err: String) {
    jumpLog("cmux 거절: \(err.trimmingCharacters(in: .whitespacesAndNewlines))")
    DispatchQueue.main.async { agentStore.cmuxNeedsAuth = true }
}

private func jumpLog(_ line: String) {
    let log = "\(Date()) \(line)\n"
    if let h = FileHandle(forWritingAtPath: "\(home)/.token-watch/jump.log") { h.seekToEndOfFile(); h.write(Data(log.utf8)); h.closeFile() }
    else { try? log.write(toFile: "\(home)/.token-watch/jump.log", atomically: true, encoding: .utf8) }
}

func jump(to a: Agent) {
    // ponytail: 클릭이 들어왔는지 확인용 한 줄 로그
    jumpLog("jump \(a.title) \(a.host)")
    DispatchQueue.global(qos: .userInitiated).async {
        switch a.host {
        case .cmux(let ws, let surface):
            // focus-panel 은 워크스페이스·칸까지만 옮기고 칸 안의 탭은 원래 선택된 걸로 둠.
            // 그래서 그 칸에서 탭 위치를 찾아 제자리 reorder + focus 로 탭을 선택 (move-surface 는 순서를 바꿔서 X)
            let r = sh(cmuxBin, ["focus-panel", "--panel", surface, "--workspace", ws])
            guard r.hasPrefix("OK") else { return cmuxBlocked(r) }
            let tabs = sh(cmuxBin, ["list-pane-surfaces", "--workspace", ws, "--id-format", "uuids"])
                .split(separator: "\n")
            if let i = tabs.firstIndex(where: { $0.uppercased().contains(surface.uppercased()) }) {
                sh(cmuxBin, ["reorder-surface", "--surface", surface, "--workspace", ws, "--index", "\(i)", "--focus", "true"])
            }
            bringToFront("/Applications/cmux.app")
        case .orca(let tab, let leaf):
            bringToFront("/Applications/Orca.app")
            if let h = orcaHandle(tab, leaf) { sh(orcaBin, ["terminal", "switch", "--terminal", h]) }
        case .background(let id):
            // cmux 새 워크스페이스에서 attach
            let r = sh(cmuxBin, ["new-workspace", "--name", a.title, "--cwd", a.cwd, "--command", "claude attach \(id)", "--focus", "true"])
            guard r.hasPrefix("OK") else { return cmuxBlocked(r) }
            bringToFront("/Applications/cmux.app")
        case .unknown:
            break
        }
    }
}

/// 백그라운드는 `claude stop` (대화는 남아서 attach 로 재개), 터미널 세션은 SIGTERM (claude --resume 으로 재개)
/// 이미 끝난 백그라운드는 끌 프로세스가 없고 목록에만 남아 있어서 `claude rm` (worktree 는 안전할 때만 지움)
func stop(_ a: Agent) {
    DispatchQueue.global(qos: .userInitiated).async {
        if let id = a.bgId, let bin = claudeBin {
            sh(bin, [a.status == .done ? "rm" : "stop", id])
        } else if let pid = a.pid {
            kill(pid_t(pid), SIGTERM)
        }
        DispatchQueue.main.async { agentStore.refresh() }
    }
}

// ───────── 상태 저장소 ─────────

@Observable @MainActor
final class AgentStore {
    var agents: [Agent] = []
    var cmuxNeedsAuth = false
    /// 방향키로 고른 세션 (agents 인덱스). 명령줄이 비어 있을 때 ↑↓ 로 움직이고 Enter 로 이동
    var cursor: Int?
    /// 이름 바꾸기 낙관적 반영: id → (새 이름, 기한). 실제 제목이 따라오면 지우고, 기한 넘기면 원래대로 돌아감
    private var optimistic: [String: (title: String, until: Date)] = [:]

    func setOptimistic(_ id: String, _ title: String) {
        optimistic[id] = (title, Date() + 10)
        agents = applyOptimistic(agents)
    }

    func dropOptimistic(_ id: String) {
        optimistic[id] = nil
        refresh()
    }

    private func applyOptimistic(_ list: [Agent]) -> [Agent] {
        list.map { a in
            guard let o = optimistic[a.id] else { return a }
            if a.title == o.title || Date() > o.until { optimistic[a.id] = nil; return a }
            var a = a
            a.title = o.title
            return a
        }
    }
    private var timer: Timer?
    private var loading = false

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        DispatchQueue.global(qos: .utility).async {
            let list = collectAgents()
            DispatchQueue.main.async {
                let list = self.applyOptimistic(list)
                if list != self.agents { self.agents = list }
                self.loading = false
            }
        }
    }

    func count(_ s: AgentStatus) -> Int { agents.filter { $0.status == s }.count }
}

func ago(_ d: Date?) -> String {
    guard let d else { return "" }
    let s = Int(Date().timeIntervalSince(d))
    switch s {
    case ..<60: return "\(max(s, 0))" + L("초", "秒")
    case ..<3600: return "\(s / 60)" + L("분", "分")
    case ..<86400: return "\(s / 3600)" + L("시간", "時間")
    default: return "\(s / 86400)" + L("일", "日")
    }
}

// swift run ClaudeKun --agents : 수집 결과를 터미널에 출력 (디버그)
func printAgents() {
    for a in collectAgents() {
        print("[\(a.status.label)] \(a.title) | \(a.host.label) \(a.host) | \(ago(a.lastActive)) | ctx \(a.contextTokens) | \(a.subtitle.prefix(50))")
    }
    assert(cleanTitle("✳ 일본어 책 단어장 PWA") == "일본어 책 단어장 PWA")
    assert(cleanTitle("⠐ Fly.io 배포") == "Fly.io 배포")
}
