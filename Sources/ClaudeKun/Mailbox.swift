import Foundation

// 훅 ↔ 앱 파일 핸드셰이크.
// ponytail: 300ms 폴링 + 파일. 지연이 거슬리면 NWListener 로컬 HTTP로 교체.
let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".token-watch")
let inbox = root.appendingPathComponent("inbox")
let outbox = root.appendingPathComponent("outbox")

struct Inbound: Decodable {
    let event: String        // "prompt" | "turn"
    let id: String
    let sessionId: String?
    let prompt: String?
    let contextTokens: Int?
    let model: String?
    let turn: Turn?
}

struct Pending: Identifiable {
    let id: String
    let prompt: String
    let tips: [Tip]
    let receivedAt: Date
}

@Observable @MainActor
final class Store {
    var pending: Pending?
    var turns: [Turn] = []
    var lastNotify: [Tip] = []
    var contextTokens = 0
    var model = ""

    private let fm = FileManager.default
    private var timer: Timer?

    init() {
        for d in [inbox, outbox] {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
            // 이전 실행이 남긴 응답/요청 찌꺼기 정리
            for f in (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? [] { try? fm.removeItem(at: f) }
        }
        loadTurns()
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    var contextPercent: Int { contextTokens * 100 / Thresholds.contextWindow }
    var todayCost: Double {
        let start = Calendar.current.startOfDay(for: .now).timeIntervalSince1970
        return turns.filter { $0.ts >= start }.reduce(0) { $0 + $1.cost }
    }
    var sessionOutput: Int {
        guard let s = turns.last?.sessionId else { return 0 }
        return turns.filter { $0.sessionId == s }.reduce(0) { $0 + $1.output + $1.thinking }
    }

    private func tick() {
        touchAlive()
        if let p = pending, Date().timeIntervalSince(p.receivedAt) > 85 { respond(.pass) }
        guard let files = try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "json" {
            defer { try? fm.removeItem(at: f) }
            guard let data = try? Data(contentsOf: f),
                  let msg = try? JSONDecoder().decode(Inbound.self, from: data) else { continue }
            handle(msg)
        }
    }

    private func handle(_ m: Inbound) {
        if let model = m.model, !model.isEmpty { self.model = model }
        if let c = m.contextTokens { contextTokens = c }
        switch m.event {
        case "turn":
            guard let t = m.turn else { return }
            turns.append(t)
            contextTokens = t.contextTokens
            model = t.model
            appendTurnLog(t)
        case "prompt":
            let tips = analyze(prompt: m.prompt ?? "", contextTokens: contextTokens, model: model)
            lastNotify = tips.filter { $0.level == .notify }
            if tips.contains(where: { $0.level == .block }) {
                pending = Pending(id: m.id, prompt: m.prompt ?? "", tips: tips, receivedAt: .now)
                TipPanel.shared.show()
            } else {
                write(id: m.id, decision: .pass, reason: "")
            }
        default: break
        }
    }

    enum Decision: String { case pass, block }

    func respond(_ d: Decision) {
        guard let p = pending else { return }
        let reason = p.tips.map { "• " + $0.text }.joined(separator: "\n")
        write(id: p.id, decision: d, reason: reason)
        pending = nil
        TipPanel.shared.hide()
    }

    private func write(id: String, decision: Decision, reason: String) {
        let obj: [String: String] = ["decision": decision.rawValue, "reason": reason]
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        let tmp = outbox.appendingPathComponent(id + ".tmp")
        try? data.write(to: tmp)
        try? fm.moveItem(at: tmp, to: outbox.appendingPathComponent(id + ".json"))
    }

    private func touchAlive() {
        let f = root.appendingPathComponent("alive")
        if !fm.fileExists(atPath: f.path) { fm.createFile(atPath: f.path, contents: nil) }
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: f.path)
    }

    private var turnLog: URL { root.appendingPathComponent("turns.jsonl") }

    // ponytail: 일별 리포트는 이 파일을 jq로 보면 됨. UI 추가는 나중에.
    private func appendTurnLog(_ t: Turn) {
        guard var data = try? JSONEncoder().encode(t) else { return }
        data.append(0x0A)
        if let h = try? FileHandle(forWritingTo: turnLog) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: turnLog)
        }
    }

    private func loadTurns() {
        guard let s = try? String(contentsOf: turnLog, encoding: .utf8) else { return }
        turns = s.split(separator: "\n").compactMap { try? JSONDecoder().decode(Turn.self, from: Data($0.utf8)) }
        if let last = turns.last { contextTokens = last.contextTokens; model = last.model }
    }
}
