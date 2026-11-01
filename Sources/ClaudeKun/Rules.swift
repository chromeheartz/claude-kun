import Foundation

enum TipLevel { case block, notify }

struct Tip: Equatable {
    let level: TipLevel
    var icon = "💡"
    let text: String
}

// 임계값. 바꿀 일이 있으면 여기만.
enum Thresholds {
    static let pasteLines = 150
    static let pasteChars = 6_000
    static let contextWindow = 200_000
    static let contextWarnRatio = 0.6
    static let shortPromptChars = 80
}

// ponytail: 규칙 하드코딩. 10개 넘으면 ~/.token-watch/rules.json으로 뺀다.
func analyze(prompt: String, contextTokens: Int, model: String) -> [Tip] {
    var tips: [Tip] = []
    let lines = prompt.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
    let chars = prompt.count

    if lines >= Thresholds.pasteLines || chars >= Thresholds.pasteChars {
        tips.append(Tip(level: .block, icon: "📜",
            text: L("붙여넣은 텍스트가 \(lines)줄 / \(chars)자. 로그는 tail -50이나 에러 줄만, 큰 파일은 경로만 주면 필요한 부분만 읽음.", "貼り付けが\(lines)行 / \(chars)文字。ログは tail -50 かエラー行だけ、大きいファイルはパスだけ渡せば必要な所だけ読むよ。")))
    }

    if Double(contextTokens) >= Double(Thresholds.contextWindow) * Thresholds.contextWarnRatio {
        let pct = Int(Double(contextTokens) / Double(Thresholds.contextWindow) * 100)
        tips.append(Tip(level: .block, icon: "🧠",
            text: L("컨텍스트 \(pct)%. 새 작업이면 /clear, 이어가는 작업이면 /compact.", "コンテキスト\(pct)%。新しい作業なら /clear、続きなら /compact。")))
    }

    let hasPath = prompt.range(of: #"[\w./-]+\.(ts|tsx|js|jsx|swift|py|md|json|css|html|go|rs|java|kt|sql|yml|yaml)\b|/[\w-]+/"#,
                               options: .regularExpression) != nil
    let vague = ["전체", "전부", "다 ", "찾아봐", "어디", "훑어", "뭐가 문제"]
    if !hasPath && vague.contains(where: { prompt.contains($0) }) {
        tips.append(Tip(level: .notify, icon: "🗺️",
            text: L("파일 경로나 함수명 하나 주면 탐색(Explore) 비용이 빠짐.", "ファイルパスか関数名をひとつ渡せば探索コストが減るよ。")))
    }

    let verbose = ["자세히", "설명해줘", "왜 ", "상세하게"]
    if chars < 60 && verbose.contains(where: { prompt.contains($0) }) {
        tips.append(Tip(level: .notify, icon: "💬",
            text: L("출력은 입력의 5배 단가. '결론만' 또는 '3줄로' 붙이면 절약.", "出力は入力の5倍の単価。「結論だけ」「3行で」を付けると節約。")))
    }

    if (model.contains("opus") || model.contains("fable"))
        && chars < Thresholds.shortPromptChars && !prompt.contains("```") {
        tips.append(Tip(level: .notify, icon: "🐢",
            text: L("짧은 질문은 /model sonnet으로 충분 (단가 1/2~1/5).", "短い質問なら /model sonnet で十分(単価1/2〜1/5)。")))
    }

    return tips
}

// $/MTok. 2026-10 Anthropic API 기준. 바뀌면 여기만.
struct Price { let input: Double; let output: Double; let cacheRead: Double }
func price(for model: String) -> Price {
    if model.contains("fable") || model.contains("mythos") { return Price(input: 10, output: 50, cacheRead: 0.25) }
    if model.contains("opus") { return Price(input: 4, output: 20, cacheRead: 0.20) }
    if model.contains("haiku") { return Price(input: 0.10, output: 0.50, cacheRead: 0.01) }
    return Price(input: 2, output: 10, cacheRead: 0.20) // sonnet
}

struct Turn: Codable, Identifiable {
    var id: String { "\(ts)-\(sessionId)-\(output)-\(newContext)" }
    let ts: Double
    let sessionId: String
    let model: String
    let output: Int
    let thinking: Int
    let newContext: Int   // cache_creation_input_tokens 합
    let contextTokens: Int

    var cost: Double {
        let p = price(for: model)
        return (Double(output) * p.output + Double(newContext) * p.input * 1.25
                + Double(contextTokens - newContext) * p.cacheRead) / 1_000_000
    }
}

// swift run ClaudeKun --check
func runChecks() {
    let big = String(repeating: "x\n", count: 200)
    assert(analyze(prompt: big, contextTokens: 0, model: "sonnet").contains { $0.level == .block })
    assert(analyze(prompt: "hi", contextTokens: 130_000, model: "sonnet").contains { $0.text.contains("컨텍스트") })
    assert(analyze(prompt: "전체 코드에서 버그 찾아봐", contextTokens: 0, model: "sonnet").contains { $0.text.contains("경로") })
    assert(!analyze(prompt: "src/app.ts 전체 봐줘", contextTokens: 0, model: "sonnet").contains { $0.text.contains("경로") })
    assert(analyze(prompt: "이거 왜 이래? 자세히", contextTokens: 0, model: "sonnet").contains { $0.text.contains("출력") })
    assert(analyze(prompt: "뭐야", contextTokens: 0, model: "claude-opus-5-5").contains { $0.text.contains("sonnet") })
    assert(analyze(prompt: "src/a.ts 의 foo() 반환 타입을 string으로 바꿔. 테스트 돌려서 통과 확인까지.", contextTokens: 1000, model: "claude-sonnet-5-5").isEmpty)
    let t = Turn(ts: 0, sessionId: "s", model: "claude-opus-5-5", output: 1_000_000, thinking: 0, newContext: 0, contextTokens: 0)
    assert(abs(t.cost - 20) < 0.001)
    print("checks ok")
}
