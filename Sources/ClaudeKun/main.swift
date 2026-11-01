import SwiftUI
import AppKit

if CommandLine.arguments.contains("--check") { runChecks(); exit(0) }
if CommandLine.arguments.contains("--agents") { printAgents(); exit(0) }
// 디버그: 저장된 비밀번호로 cmux 에 붙어지는지 (비밀번호 자체는 출력 안 함)
if CommandLine.arguments.contains("--cmux-test") {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: cmuxBin)
    p.arguments = ["list-workspaces"]
    var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CMUX_") }
    let pw = CmuxPass.get()
    if let pw { env["CMUX_SOCKET_PASSWORD"] = pw }
    p.environment = env
    try? p.run(); p.waitUntilExit()
    print("password saved:", pw != nil, "length:", pw?.count ?? 0, "trailing space/newline:", pw.map { $0 != $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? false)
    print("exit:", p.terminationStatus)
    exit(0)
}
// 디버그: --jump <제목 일부>
if let i = CommandLine.arguments.firstIndex(of: "--jump"), i + 1 < CommandLine.arguments.count {
    let q = CommandLine.arguments[i + 1]
    if let a = collectAgents().first(where: { $0.title.contains(q) }) {
        print("jump →", a.title, a.host)
        jump(to: a)
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
    } else { print("없음:", q) }
    exit(0)
}

let store = MainActor.assumeIsolated { Store() }
let agentStore = MainActor.assumeIsolated { AgentStore() }

func fmtK(_ n: Int) -> String { n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)" }

// ───────── 팔레트: kotsukotsu 토큰 그대로 ─────────

extension Color {
    init(_ light: UInt32, _ dark: UInt32) {
        func ns(_ h: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((h >> 16) & 0xff) / 255, green: CGFloat((h >> 8) & 0xff) / 255,
                    blue: CGFloat(h & 0xff) / 255, alpha: 1)
        }
        self.init(nsColor: NSColor(name: nil) { a in
            a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark) : ns(light)
        })
    }
}

enum Pal {
    static let bg     = Color(0xfff5e9, 0x2b211c)
    static let dot    = Color(0xf1dcc3, 0x3e3029)
    static let card   = Color(0xfffdf8, 0x372a23)
    static let ink    = Color(0x4b3428, 0xfbeee0)
    static let shadow = Color(0x4b3428, 0x170f0b)
    static let muted  = Color(0x86695a, 0xb49c8a)
    static let coral  = Color(0xff8a65, 0xff9a78)
    static let peach  = Color(0xffcdb5, 0xf2b59a)
    static let butter = Color(0xffe39a, 0xf3d27c)
    static let sage   = Color(0xcde5bb, 0xb5d29f)
    static let sky    = Color(0xc6e1f5, 0xa9cbe6)
    static let pink   = Color(0xfbcadb, 0xeeafc3)
    static let onPastel = Color(0x4b3428, 0x2b211c)
}

func round(_ size: CGFloat, _ w: Font.Weight = .semibold) -> Font { .system(size: size, weight: w, design: .rounded) }

// ───────── 스티커 부품 ─────────

struct DotBackground: View {
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 18
            var y: CGFloat = 9
            while y < size.height {
                var x: CGFloat = 9
                while x < size.width {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 1.3, y: y - 1.3, width: 2.6, height: 2.6)), with: .color(Pal.dot))
                    x += step
                }
                y += step
            }
        }
        .background(Pal.bg)
    }
}

/// 잉크 테두리 + 아래로 떨어진 딱딱한 그림자. kotsukotsu의 --pop.
struct Sticker: ViewModifier {
    var fill: Color = Pal.card
    var radius: CGFloat = 16
    var lift: CGFloat = 4
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Pal.ink, lineWidth: 2))
            .background(RoundedRectangle(cornerRadius: radius).fill(Pal.shadow).offset(y: lift))
    }
}
extension View {
    func sticker(_ fill: Color = Pal.card, radius: CGFloat = 16, lift: CGFloat = 4) -> some View {
        modifier(Sticker(fill: fill, radius: radius, lift: lift))
    }
}

struct Chip: View {
    let text: String
    var fill: Color = Pal.butter
    var body: some View {
        Text(text).font(round(10.5)).foregroundStyle(Pal.onPastel)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .sticker(fill, radius: 999, lift: 2)
    }
}

/// 누르면 그림자 위로 쏙 내려앉는 버튼
struct PopButton: ButtonStyle {
    var fill: Color = Pal.coral
    var text: Color = Pal.onPastel
    var small = false
    func makeBody(configuration: Configuration) -> some View {
        let down = configuration.isPressed
        return configuration.label
            .font(round(small ? 10.5 : 13, .bold)).foregroundStyle(text)
            .padding(.horizontal, small ? 8 : 14).padding(.vertical, small ? 3 : 8)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(Pal.ink, lineWidth: 2))
            .offset(y: down ? 3 : 0)
            .background(Capsule().fill(Pal.shadow).offset(y: 3))
            .animation(.spring(duration: 0.15), value: down)
            .contentShape(Capsule())
    }
}

// ───────── 마스코트: Claude 픽셀 ─────────

enum Mood {
    case calm, ok, sweat, panic
    init(percent: Int) {
        switch percent {
        case ..<30: self = .calm
        case ..<60: self = .ok
        case ..<80: self = .sweat
        default: self = .panic
        }
    }
    var color: Color {
        switch self {
        case .calm: Pal.sage
        case .ok: Pal.butter
        case .sweat: Pal.peach
        case .panic: Pal.coral
        }
    }
    var line: String {
        switch self {
        case .calm: L("흥, 아직 여유 있거든", "ふん、まだ余裕だし")
        case .ok: L("나쁘지 않네. 계속 아껴", "悪くないね。その調子")
        case .sweat: L("슬슬 무거워. /clear 할 때 됐어", "そろそろ重いよ。/clear しよ")
        case .panic: L("꽉 찼잖아! 당장 /clear 해", "パンパンだよ!今すぐ /clear")
        }
    }
}

/// Claude Code 픽셀 마스코트. 18×10 칸 그리드, 기분은 눈 모양 + 기호로
struct Mascot: View {
    var size: CGFloat = 40
    var mood: Mood = .ok
    var animate = true   // ponytail: 움직임은 뺐음(가만히). 호출부 호환용으로만 남김

    var body: some View {
        Canvas { ctx, sz in draw(ctx, sz) }
            .frame(width: size, height: size)
            .overlay(alignment: .topTrailing) {
                switch mood {
                case .sweat: Text("💦").font(.system(size: size * 0.3)).offset(x: size * 0.1, y: size * 0.04)
                case .panic: Text("💢").font(.system(size: size * 0.32)).offset(x: size * 0.12, y: size * 0.02)
                default: EmptyView()
                }
            }
    }

    private func draw(_ ctx: GraphicsContext, _ sz: CGSize) {
        let u = sz.width / 18                       // 한 칸
        let top = (sz.height - u * 10) / 2           // 세로 가운데
        func px(_ x: Int, _ y: Int, _ w: Int = 1, _ h: Int = 1, _ c: Color) {
            // 0.5px 겹쳐 그려서 칸 사이 틈 안 보이게
            ctx.fill(Path(CGRect(x: CGFloat(x) * u, y: top + CGFloat(y) * u, width: CGFloat(w) * u + 0.5, height: CGFloat(h) * u + 0.5)), with: .color(c))
        }
        let body = Color(0xd97757, 0xd97757)
        let eye = Color(0x1a1a1a, 0x1a1a1a)
        px(2, 0, 14, 8, body)                        // 몸통
        px(0, 4, 2, 2, body); px(16, 4, 2, 2, body)  // 팔
        for x in [3, 5, 12, 14] { px(x, 8, 1, 2, body) } // 다리
        switch mood {
        case .calm:  px(4, 3, 1, 1, eye); px(13, 3, 1, 1, eye)   // 졸린 눈
        case .panic: px(3, 2, 2, 1, eye); px(13, 2, 2, 1, eye); px(4, 3, 1, 1, eye); px(13, 3, 1, 1, eye) // 찡그림
        default:     px(4, 2, 1, 2, eye); px(13, 2, 1, 2, eye)
        }
    }
}

@MainActor func mascotIcon(_ mood: Mood) -> NSImage {
    let r = ImageRenderer(content: Mascot(size: 18, mood: mood, animate: false))
    r.scale = NSScreen.main?.backingScaleFactor ?? 2
    let img = r.nsImage ?? NSImage()
    img.isTemplate = false
    return img
}

/// 말풍선: 꼬리가 왼쪽 마스코트를 가리킴
struct Bubble<C: View>: View {
    @ViewBuilder var content: C
    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sticker(Pal.card, radius: 14, lift: 3)
            .overlay(alignment: .leading) {
                Image(systemName: "triangle.fill").font(.system(size: 11)).foregroundStyle(Pal.card)
                    .rotationEffect(.degrees(-90)).offset(x: -8, y: 0)
                    .overlay(Image(systemName: "triangle").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Pal.ink).rotationEffect(.degrees(-90)).offset(x: -9.5))
                    .mask(Rectangle().offset(x: -10).frame(width: 12))
            }
    }
}

struct TipCard: View {
    let tip: Tip
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(tip.icon).font(.system(size: 18))
                .frame(width: 32, height: 32)
                .sticker(tip.level == .block ? Pal.pink : Pal.sky, radius: 10, lift: 2)
            Text(tip.text).font(round(12.5, .medium)).foregroundStyle(Pal.ink)
                .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .sticker(Pal.card, radius: 14, lift: 3)
    }
}

// ───────── 보내기 전 가로채기 패널 ─────────

struct PendingView: View {
    @Bindable var store: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let p = store.pending {
                HStack(alignment: .center, spacing: 14) {
                    Mascot(size: 54, mood: .panic)
                    Bubble {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L("잠깐! 이거 그냥 보내게?", "ちょっと待って!このまま送る?")).font(round(15, .heavy)).foregroundStyle(Pal.ink)
                            Text(L("토큰 꽤 털릴 거야.", "トークンけっこう減るよ。")).font(round(11.5, .medium)).foregroundStyle(Pal.muted)
                        }
                    }
                }
                Text("“" + p.prompt.prefix(90).replacingOccurrences(of: "\n", with: " ") + (p.prompt.count > 90 ? "…" : "") + "”")
                    .font(round(11, .medium)).foregroundStyle(Pal.muted).lineLimit(2)
                    .padding(.horizontal, 4)
                VStack(spacing: 10) { ForEach(Array(p.tips.enumerated()), id: \.offset) { TipCard(tip: $0.element) } }
                HStack(spacing: 10) {
                    Button(L("✏️ 고칠게", "✏️ 直す")) { store.respond(.block) }
                        .buttonStyle(PopButton(fill: Pal.coral)).keyboardShortcut(.defaultAction)
                    Button(L("그냥 보낼래", "このまま送る")) { store.respond(.pass) }
                        .buttonStyle(PopButton(fill: Pal.card, text: Pal.ink)).keyboardShortcut(.cancelAction)
                    Spacer()
                    Text("⏎ / esc").font(round(10)).foregroundStyle(Pal.muted)
                }
                .padding(.top, 2)
            }
        }
        .padding(18).padding(.bottom, 4)
        .frame(width: 400)
        .background(DotBackground())
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Pal.ink, lineWidth: 2.5))
    }
}

final class TipPanel {
    @MainActor static let shared = TipPanel()
    private var panel: NSPanel?

    @MainActor func show() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .floating
            p.isFloatingPanel = true
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.isMovableByWindowBackground = true
            // 터미널이 전체화면이어도, 다른 Space여도 보이게
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            p.contentView = NSHostingView(rootView: PendingView(store: store))
            panel = p
        }
        guard let p = panel, let v = p.contentView else { return }
        v.layoutSubtreeIfNeeded()
        let fit = v.fittingSize
        p.setContentSize(NSSize(width: 400, height: fit.height > 50 ? fit.height : 320))
        // 마우스가 있는 화면의 오른쪽 위
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let sf = screen?.visibleFrame {
            p.setFrameTopLeftPoint(NSPoint(x: sf.maxX - p.frame.width - 18, y: sf.maxY - 10))
        }
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; p.animator().alphaValue = 1 }
        NSSound(named: "Pop")?.play()
    }

    @MainActor func hide() { panel?.orderOut(nil) }
}

// ───────── 메뉴바 드롭다운 ─────────

struct Gauge: View {
    let percent: Int
    var body: some View {
        let mood = Mood(percent: percent)
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Pal.card)
                Capsule().fill(mood.color)
                    .frame(width: max(14, g.size.width * CGFloat(min(percent, 100)) / 100))
                    .animation(.spring(duration: 0.5), value: percent)
                // 60% 경고선
                Rectangle().fill(Pal.ink.opacity(0.35)).frame(width: 2, height: 8)
                    .offset(x: g.size.width * 0.6 - 1)
            }
            .overlay(Capsule().strokeBorder(Pal.ink, lineWidth: 2))
        }
        .frame(height: 16)
    }
}

struct TurnRow: View {
    let t: Turn
    var body: some View {
        let heavy = t.output > 3000 || t.newContext > 20_000
        HStack(spacing: 6) {
            Text(heavy ? "🔥" : "🫧").font(.system(size: 13))
            mini(L("출력", "出力"), t.output, Pal.peach)
            mini(L("생각", "思考"), t.thinking, Pal.lilacish)
            mini(L("새로", "新規"), t.newContext, Pal.sky)
            Spacer()
            Text(String(format: "$%.3f", t.cost)).font(round(11, heavy ? .heavy : .medium))
                .foregroundStyle(heavy ? Pal.ink : Pal.muted).monospacedDigit()
        }
    }
    func mini(_ label: String, _ n: Int, _ c: Color) -> some View {
        HStack(spacing: 3) {
            Text(label).font(round(9)).foregroundStyle(Pal.onPastel)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 5).fill(c))
            Text(fmtK(n)).font(round(11, .semibold)).foregroundStyle(Pal.ink).monospacedDigit()
        }
    }
}

extension Pal { static let lilacish = Color(0xddd2f5, 0xc6b8ea) }

extension AgentStatus {
    var color: Color {
        switch self {
        case .needsInput: Pal.coral
        case .working: Pal.butter
        case .idle: Pal.sky
        case .done: Pal.sage
        }
    }
}

/// 상태 점: 작업 중이면 깜빡, 입력 필요면 통통
struct StatusDot: View {
    let status: AgentStatus
    @State private var on = false
    var body: some View {
        Circle().fill(status.color)
            .overlay(Circle().strokeBorder(Pal.ink, lineWidth: 1.6))
            .frame(width: 11, height: 11)
            .scaleEffect(status == .needsInput && on ? 1.25 : 1)
            .opacity(status == .working && on ? 0.35 : 1)
            .animation(status == .needsInput || status == .working
                       ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : nil, value: on)
            .onAppear { on = true }
    }
}

struct RowPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.offset(y: configuration.isPressed ? 1.5 : 0)
    }
}

struct AgentRow: View {
    let agent: Agent
    @State private var hover = false
    @State private var armed = false   // 종료는 두 번 눌러야 (실수 방지)
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool
    var canJump: Bool { agent.host != .unknown }
    var canRename: Bool {
        guard agent.status == .idle else { return false }
        switch agent.host { case .cmux, .orca: return true; default: return false }
    }
    var canStop: Bool { agent.bgId != nil || (agent.status != .done && agent.pid != nil) }

    var body: some View {
        if editing { editor } else { row }
    }

    /// 이름 고치기: Enter 저장, Esc 취소
    var editor: some View {
        HStack(spacing: 8) {
            StatusDot(status: agent.status)
            TextField(agent.title, text: $draft)
                .textFieldStyle(.plain).font(round(13, .bold)).foregroundStyle(Pal.ink)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Capsule().fill(Pal.card))
                .overlay(Capsule().strokeBorder(Pal.ink, lineWidth: 1.4))
                .focused($focused)
                .onSubmit(save)
                .onExitCommand { editing = false }
            Button(L("저장", "保存"), action: save)
                .buttonStyle(PopButton(fill: Pal.butter, text: Pal.onPastel, small: true))
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            Button { editing = false } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .heavy)) }
                .buttonStyle(.plain).foregroundStyle(Pal.ink)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .onAppear { focused = true }
    }

    func save() {
        rename(agent, to: draft)
        editing = false
    }

    var row: some View {
        // ScrollView 안에서 DragGesture(minimumDistance: 0) 가 탭을 먹어서 클릭이 안 됐음 → 행 전체를 Button 으로
        HStack(spacing: 6) {
            Button {
                guard canJump else { return }
                // 창을 연 채로 다른 모니터 앱으로 넘어가면 메뉴바 창이 그 모니터로 따라가 다시 뜸 → 먼저 닫고 점프
                NSApp.windows.filter { $0.className.contains("MenuBarExtra") }.forEach { $0.close() }
                jump(to: agent)
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    StatusDot(status: agent.status)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.title).font(round(13, .bold)).foregroundStyle(Pal.ink).lineLimit(1)
                        Text(agent.subtitle).font(round(11, .medium)).foregroundStyle(Pal.muted).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(agent.host.label).font(round(9.5, .bold)).foregroundStyle(Pal.onPastel)
                            .padding(.horizontal, 6).padding(.vertical, 1.5)
                            .background(Capsule().fill(hostColor))
                            .overlay(Capsule().strokeBorder(Pal.ink, lineWidth: 1.2))
                        HStack(spacing: 4) {
                            if agent.contextTokens > 0 { Text(fmtK(agent.contextTokens)) }
                            Text(ago(agent.lastActive))
                        }
                        .font(round(10, .semibold)).foregroundStyle(Pal.muted).monospacedDigit()
                    }
                    if !(canStop && (hover || armed)) {
                        Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(Pal.ink).opacity(hover && canJump ? 1 : 0)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(RowPress())
            .focusEffectDisabled() // 파란 포커스 테두리 제거
            if canRename && hover && !armed {
                Button { draft = agent.title; editing = true } label: {
                    Image(systemName: "pencil").font(.system(size: 10, weight: .heavy))
                }
                .buttonStyle(PopButton(fill: Pal.card, text: Pal.ink, small: true))
                .help(L("이름 바꾸기 (그 세션에 /rename 입력)", "名前を変える(そのセッションに /rename を入力)"))
            }
            if canStop && (hover || armed) {
                Button(armed ? L("확인", "確認") : agent.status == .done ? L("지우기", "削除") : L("종료", "終了")) {
                    if armed { stop(agent); armed = false } else {
                        armed = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { armed = false }
                    }
                }
                .buttonStyle(PopButton(fill: armed ? Pal.coral : Pal.card, text: armed ? Pal.onPastel : Pal.ink, small: true))
                .help(agent.status == .done ? L("끝난 세션을 목록에서 지우기 (claude rm)", "終わったセッションを一覧から削除(claude rm)") : L("세션 종료 (대화는 남아서 나중에 이어갈 수 있어)", "セッション終了(会話は残るので後で再開できるよ)"))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 11).fill(hover && canJump ? agent.status.color.opacity(0.45) : .clear))
        .onHover { h in
            hover = h
            if canJump { h ? NSCursor.pointingHand.push() : NSCursor.pop() }
        }
        .help(canJump ? L("📞 \(agent.host.label)에서 열기 · \(agent.cwd)", "📞 \(agent.host.label)で開く · \(agent.cwd)") : L("어느 터미널인지 못 찾았어", "どのターミナルか見つからない"))
        .animation(.easeOut(duration: 0.12), value: hover)
    }

    var hostColor: Color {
        switch agent.host {
        case .cmux: Pal.lilacish
        case .orca: Pal.peach
        case .background: Pal.pink
        case .unknown: Pal.card
        }
    }
}

struct AgentGroup: View {
    let status: AgentStatus
    let agents: [Agent]
    var limit = 99
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(status.label).font(round(11.5, .heavy)).foregroundStyle(Pal.ink)
                Text("\(agents.count)").font(round(10.5, .heavy)).foregroundStyle(Pal.onPastel)
                    .padding(.horizontal, 6).background(Capsule().fill(status.color))
                    .overlay(Capsule().strokeBorder(Pal.ink, lineWidth: 1.2))
            }
            .padding(.leading, 4)
            VStack(spacing: 0) {
                ForEach(Array(agents.prefix(limit).enumerated()), id: \.element.id) { i, a in
                    if i > 0 {
                        Rectangle().fill(Pal.line).frame(height: 1).padding(.horizontal, 10)
                    }
                    AgentRow(agent: a)
                }
                if agents.count > limit {
                    Text(L("+ \(agents.count - limit)개 더", "+ ほか\(agents.count - limit)件")).font(round(10.5, .semibold)).foregroundStyle(Pal.muted)
                        .padding(.vertical, 6)
                }
            }
            .padding(4)
            .sticker(Pal.card, radius: 14, lift: 3)
        }
    }
}

extension Pal { static let line = Color(0xf0dfcb, 0x4a3a31) }

@MainActor func agentMood(_ s: AgentStore) -> Mood {
    if s.count(.needsInput) > 0 { return .panic }
    if s.count(.working) > 0 { return .ok }
    return .calm
}

struct MenuPanel: View {
    @Bindable var store: Store
    @Bindable var agents: AgentStore
    @AppStorage("lang") private var langRaw = Lang.ko.rawValue
    @State private var showSettings = false

    func setLang(_ l: Lang) {
        langRaw = l.rawValue
        // 훅(node)도 같은 언어로 말하게 파일로도 남김
        try? l.rawValue.write(toFile: "\(home)/.token-watch/lang", atomically: true, encoding: .utf8)
    }

    var line: String {
        let n = agents.count(.needsInput), w = agents.count(.working)
        if n > 0 { return L("もしもし? \(n)명이 대답 기다려", "もしもし? \(n)人が返事待ってるよ") }
        if w > 0 { return L("\(w)명 통화 중. 방해 금지", "\(w)人が通話中。じゃましないでね") }
        if agents.agents.isEmpty { return L("아무도 안 받네… 뚜- 뚜-", "だれも出ないね… ツー ツー") }
        return L("다들 대기 중. 조용~", "みんな待機中。しーん…")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 헤더: 마스코트 + 말풍선
            HStack(alignment: .center, spacing: 12) {
                Mascot(size: 58, mood: agentMood(agents))
                VStack(alignment: .leading, spacing: 6) {
                    Chip(text: "📞 클로드쿤 · クロードくん")
                    Bubble {
                        Text(line).font(round(12.5, .bold)).foregroundStyle(Pal.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            // 요약 칩
            HStack(spacing: 6) {
                ForEach(AgentStatus.allCases, id: \.rawValue) { s in
                    let n = agents.count(s)
                    Text("\(s.label) \(n)").font(round(10.5, .bold)).foregroundStyle(n > 0 ? Pal.onPastel : Pal.muted)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(n > 0 ? s.color : Pal.card))
                        .overlay(Capsule().strokeBorder(Pal.ink, lineWidth: 1.4))
                        .opacity(n > 0 ? 1 : 0.55)
                }
            }

            if agents.cmuxNeedsAuth { CmuxAuthCard(agents: agents) }

            MaybeScroll {
                VStack(alignment: .leading, spacing: 14) {
                    if agents.agents.isEmpty {
                        Text(L("돌아가는 세션이 없어.", "動いてるセッションはないよ。")).font(round(12, .medium)).foregroundStyle(Pal.muted)
                            .frame(maxWidth: .infinity).padding(20).sticker()
                    }
                    ForEach(AgentStatus.allCases, id: \.rawValue) { s in
                        let list = agents.agents.filter { $0.status == s }
                        if !list.isEmpty { AgentGroup(status: s, agents: list) }
                    }
                }
                .padding(.horizontal, 2).padding(.bottom, 6)
            }

            // 토큰은 한 줄로만 + 설정
            HStack(spacing: 8) {
                Text(String(format: L("오늘 $%.2f", "今日 $%.2f"), store.todayCost))
                Text("·")
                Text(L("이 세션 출력 ", "このセッション出力 ") + fmtK(store.sessionOutput))
                Spacer()
                Button { withAnimation(.spring(duration: 0.25)) { showSettings.toggle() } } label: {
                    Label(L("설정", "設定"), systemImage: "gearshape.fill")
                }
                .buttonStyle(PopButton(fill: showSettings ? Pal.butter : Pal.card, text: Pal.ink, small: true))
            }
            .font(round(10.5, .semibold)).foregroundStyle(Pal.muted)

            if showSettings {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text(L("언어", "言語")).font(round(12, .heavy)).foregroundStyle(Pal.ink)
                        Spacer()
                        ForEach(Lang.allCases, id: \.self) { l in
                            Button(l == .ko ? "한국어" : "日本語") { setLang(l) }
                                .buttonStyle(PopButton(fill: langRaw == l.rawValue ? Pal.coral : Pal.card,
                                                       text: langRaw == l.rawValue ? Pal.onPastel : Pal.ink, small: true))
                        }
                    }
                    Rectangle().fill(Pal.line).frame(height: 1)
                    CmuxPasswordRow(agents: agents)
                    Rectangle().fill(Pal.line).frame(height: 1)
                    HStack {
                        Text(L("클로드쿤 끄기", "クロードくんを終了")).font(round(12, .heavy)).foregroundStyle(Pal.ink)
                        Spacer()
                        Button(L("앱 끄기", "終了")) { NSApp.terminate(nil) }
                            .buttonStyle(PopButton(fill: Pal.card, text: Pal.ink, small: true))
                    }
                }
                .padding(12)
                .sticker(Pal.card, radius: 14, lift: 3)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .id(langRaw)   // 언어 바뀌면 L() 문구 전부 다시 그림
        .padding(16).padding(.bottom, 4)
        .frame(width: 400)
        .background(DotBackground())
    }
}

/// cmux 가 거절했을 때 뜨는 안내 카드
struct CmuxAuthCard: View {
    @Bindable var agents: AgentStore
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("📞 cmux가 전화를 안 받아", "📞 cmuxが電話に出ない")).font(round(13, .heavy)).foregroundStyle(Pal.onPastel)
                Spacer()
                Button { agents.cmuxNeedsAuth = false } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .heavy)) }
                    .buttonStyle(.plain).foregroundStyle(Pal.onPastel)
            }
            Text(L("cmux는 밖에서 오는 연결을 막아. cmux 설정(⌘,) → Automation → Socket control mode를 Password로 바꾸고, 정한 비밀번호를 여기 넣어줘.",
                   "cmuxは外からの接続をブロックしてるよ。cmuxの設定(⌘,) → Automation → Socket control mode を Password にして、決めたパスワードをここに入れてね。"))
                .font(round(11, .medium)).foregroundStyle(Pal.onPastel).fixedSize(horizontal: false, vertical: true)
            CmuxPasswordRow(agents: agents, onPastel: true)
        }
        .padding(12)
        .sticker(Pal.peach, radius: 14, lift: 3)
    }
}

/// 비밀번호 입력 → 키체인 저장 → 바로 cmux 에 연결해 보고 결과 표시
struct CmuxPasswordRow: View {
    @Bindable var agents: AgentStore
    var onPastel = false
    @State private var pw = ""
    @State private var result: Bool?
    @State private var testing = false
    var body: some View {
        HStack(spacing: 8) {
            Text(L("cmux 비밀번호", "cmuxパスワード")).font(round(12, .heavy)).foregroundStyle(onPastel ? Pal.onPastel : Pal.ink)
            SecureField(CmuxPass.get() == nil ? "" : "••••", text: $pw)
                .textFieldStyle(.plain).font(round(12, .medium))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Pal.card))
                .overlay(Capsule().strokeBorder(Pal.ink, lineWidth: 1.4))
                .onSubmit(save)
            if let r = result {
                Text(r ? "✓" : "✗").font(round(13, .heavy)).foregroundStyle(r ? Color.green : Pal.coral)
                    .help(r ? L("연결됐어", "つながったよ") : L("아직 안 돼. 비밀번호랑 Password 모드 확인해줘", "まだダメ。パスワードとPasswordモードを確認してね"))
            }
            Button(testing ? "…" : L("저장", "保存"), action: save)
                .buttonStyle(PopButton(fill: Pal.butter, text: Pal.onPastel, small: true))
                .disabled(pw.isEmpty || testing)
        }
    }
    func save() {
        guard !pw.isEmpty else { return }
        CmuxPass.set(pw)
        pw = ""
        testing = true
        DispatchQueue.global().async {
            let ok = cmuxReachable()
            DispatchQueue.main.async {
                testing = false
                result = ok
                if ok { agents.cmuxNeedsAuth = false }
            }
        }
    }
}

/// ImageRenderer 는 ScrollView 안을 못 그려서 --render 때만 평평하게
let renderMode = CommandLine.arguments.contains("--render")
struct MaybeScroll<C: View>: View {
    @ViewBuilder var content: C
    @State private var h: CGFloat = 300
    var body: some View {
        if renderMode { content } else {
            // MenuBarExtra 창은 ScrollView 최소 높이로 줄어들어서, 내용 높이를 재서 직접 지정 (화면 높이에서 헤더·푸터 몫 빼고 상한)
            ScrollView {
                content.background(GeometryReader { g in
                    Color.clear.onAppear { h = g.size.height }.onChange(of: g.size.height) { h = $1 }
                })
            }
            .frame(height: min(h, (NSScreen.main?.visibleFrame.height ?? 900) - 260))
            .scrollIndicators(.never)
        }
    }
}

extension String { func ifEmpty(_ s: String) -> String { isEmpty ? s : self } }

struct ClaudeKunApp: App {
    init() { NSApplication.shared.setActivationPolicy(.accessory) }
    var body: some Scene {
        MenuBarExtra {
            MenuPanel(store: store, agents: agentStore).focusEffectDisabled()
        } label: {
            let n = agentStore.count(.needsInput), w = agentStore.count(.working)
            HStack(spacing: 3) {
                Image(nsImage: mascotIcon(agentMood(agentStore)))
                if n > 0 { Text(L("입력 \(n)", "入力 \(n)")) } else if w > 0 { Text(L("작업 \(w)", "作業 \(w)")) }
            }
        }
        .menuBarExtraStyle(.window)
    }
}

// 디버그: swift run ClaudeKun --render [dark] → /tmp/tw-*.png
if CommandLine.arguments.contains("--render") {
    MainActor.assumeIsolated {
        let dark = CommandLine.arguments.contains("dark")
        NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        store.contextTokens = 142_000
        store.model = "claude-opus-5-5"
        store.turns = [
            Turn(ts: Date().timeIntervalSince1970, sessionId: "s", model: "claude-opus-5-5", output: 820, thinking: 240, newContext: 3_100, contextTokens: 120_000),
            Turn(ts: Date().timeIntervalSince1970, sessionId: "s", model: "claude-opus-5-5", output: 4_600, thinking: 1_900, newContext: 28_000, contextTokens: 142_000),
        ]
        // README 스크린샷용 가짜 세션 (실제 세션 이름이 이미지에 안 남게)
        func demo(_ t: String, _ sub: String, _ st: AgentStatus, _ h: Host, _ min: Double, _ ctx: Int) -> Agent {
            Agent(id: t, name: t, title: t, subtitle: sub, cwd: "~/dev/\(t)", status: st, host: h,
                  lastActive: Date().addingTimeInterval(-min * 60), contextTokens: ctx, pid: 1, bgId: nil)
        }
        agentStore.agents = [
            demo("todo-app 로그인 버그", "세션 만료 처리 A안/B안 중 골라줘", .needsInput, .cmux(workspace: "", surface: ""), 2, 84_000),
            demo("블로그 다크모드", "Tailwind 토큰 정리하는 중", .working, .cmux(workspace: "", surface: ""), 0.1, 52_000),
            demo("API 리팩토링", "테스트 돌리는 중…", .working, .orca(tabId: "", leafId: nil), 0.3, 131_000),
            demo("일본어 단어장 PWA", "배포 끝났어. 다음 할 일?", .idle, .background(id: ""), 14, 98_000),
            demo("README 정리", "커밋 푸시 완료", .done, .background(id: ""), 180, 23_000),
        ]
        store.lastNotify = analyze(prompt: "전체 코드 훑어봐", contextTokens: 0, model: "sonnet")
        store.pending = Pending(id: "x", prompt: String(repeating: "ERROR at line 42: undefined is not a function\n", count: 180),
                                tips: analyze(prompt: String(repeating: "ERROR\n", count: 180), contextTokens: 142_000, model: "sonnet"),
                                receivedAt: .now)
        let cases: [(Mood, String)] = [(.calm, "calm\n전부 대기·완료"), (.ok, "ok\n작업 중 있음"), (.sweat, "sweat\n(토큰 60%↑ 때)"), (.panic, "panic\n입력 필요 있음")]
        let faces = HStack(spacing: 18) {
            ForEach(cases, id: \.0.line) { m, label in
                VStack(spacing: 6) {
                    Mascot(size: 90, mood: m, animate: false)
                    Text(label).font(round(12, .bold)).foregroundStyle(Pal.ink).multilineTextAlignment(.center)
                }
            }
        }
            .padding(16).background(DotBackground())
        for (name, view) in [("pending", AnyView(PendingView(store: store))), ("menu", AnyView(MenuPanel(store: store, agents: agentStore))), ("faces", AnyView(faces))] {
            let r = ImageRenderer(content: view.environment(\.colorScheme, dark ? .dark : .light))
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "/tmp/tw-\(name)\(dark ? "-dark" : "").png"))
            }
        }
    }
    exit(0)
}

ClaudeKunApp.main()
