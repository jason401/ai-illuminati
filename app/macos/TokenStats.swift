import AppKit
import SwiftUI
import UniformTypeIdentifiers
import AIAccounts
import AILocalization
import AIRuntime
import AIChat

// The Usage window (Settings > Accounts > "Show Usage…"): every token the logs and the app's own calls show
// (TokenLedger), on every Mac (TokenSync), by period, with what was counted always on screen. Tokens only: limits and
// resets are the menu's. One window, reused; its period, filters and size are remembered.
//   U uncached input, W cache writes, R cache reads, O output (reasoning, where reported, is a part of O).
//   Input (no cache reads) = U+W. The default measure = U+W+O. Everything processed = U+W+R+O.
// (The window's choices live in TokenStatsModel: this Mac's Command Line Tools cannot build SwiftUI's @State macro.)
final class TokenStatsModel: ObservableObject {
    enum Span: String, CaseIterable { case day, week, month, year, all, custom }
    enum Metric: String, CaseIterable { case fresh, output, all }
    enum Dim: String, CaseIterable { case provider, account, model, project, chat, session, device, source }
    enum Zone: String { case local, utc }
    enum Kind: CaseIterable { case input, cacheWrite, cacheRead, output }

    // One sum with what it belongs to (keys in Dim order).
    struct Fact {
        let start: Date
        let hourly: Bool
        let counts: TokenCounts
        let provider: Account.Provider
        let keys: [String]
        let legacy: Bool
        func key(_ d: Dim) -> String { keys[Dim.allCases.firstIndex(of: d)!] }
    }

    static let shared = TokenStatsModel()
    static let syncKey = "tokenUsageSync"
    private static let prefsKey = "tokenStatsPrefs"

    @Published var span: Span = .week { didSet { remember() } }
    @Published var back = 0 { didSet { remember() } }
    @Published var customStart = Calendar.current.date(byAdding: .day, value: -29, to: Calendar.current.startOfDay(for: Date())) ?? Date() { didSet { remember() } }
    @Published var customEnd = Date() { didSet { remember() } }
    @Published var metric: Metric = .fresh { didSet { remember() } }
    @Published var zone: Zone = .local { didSet { remember() } }
    @Published var device: String? { didSet { remember() } }       // nil: every Mac; "": this Mac; else another Mac's id
    @Published var stack: Dim = .account { didSet { remember() } }
    @Published var group: Dim = .account { didSet { remember() } }
    @Published var filters: [Dim: String] = [:] { didSet { remember() } }
    @Published var picked: DateInterval?                             // a chart column chosen
    @Published var topOnly = true
    @Published var search = ""
    @Published var selected: String?                                 // the table row whose detail is open (a key of `group`)
    @Published var compositionWithoutReads = false

    @Published var report: TokenReport?
    @Published var peers: [TokenDevice] = []
    @Published var facts: [Fact] = []
    @Published var labels: [Dim: [String: String]] = [:]
    @Published var paths: [String: String] = [:]                    // project key → full path (tooltips)
    @Published var syncedAt: Date?
    @Published var reading = false
    @Published var syncOn = UserDefaults.app.bool(forKey: TokenStatsModel.syncKey) {
        didSet {
            UserDefaults.app.set(syncOn, forKey: Self.syncKey)
            if !syncOn { peers = []; device = nil; syncedAt = nil; rebuild() }
        }
    }
    // The app's chats by id: their titles and linked projects (main.swift connects it to the chat list).
    var chats: () -> [UUID: (title: String, project: String?)] = { [:] }
    private weak var app: AppModel?
    private var timer: Timer?
    private var loading = false

    init() {
        if let data = UserDefaults.app.data(forKey: Self.prefsKey), let p = try? JSONDecoder().decode([String: String].self, from: data) {
            span = p["span"].flatMap(Span.init) ?? .week
            back = p["back"].flatMap { Int($0) } ?? 0
            metric = p["metric"].flatMap(Metric.init) ?? .fresh
            zone = p["zone"].flatMap(Zone.init) ?? .local
            stack = p["stack"].flatMap(Dim.init) ?? .account
            group = p["group"].flatMap(Dim.init) ?? .account
            device = p["device"].map { $0 == "*" ? nil : $0 } ?? nil
            if let s = p["customStart"].flatMap(Double.init) { customStart = Date(timeIntervalSince1970: s) }
            if let e = p["customEnd"].flatMap(Double.init) { customEnd = Date(timeIntervalSince1970: e) }
            for d in Dim.allCases { if let v = p["filter." + d.rawValue] { filters[d] = v } }
        }
    }

    private func remember() {
        var p: [String: String] = ["span": span.rawValue, "back": "\(back)", "metric": metric.rawValue, "zone": zone.rawValue,
                                   "stack": stack.rawValue, "group": group.rawValue, "device": device ?? "*",
                                   "customStart": "\(customStart.timeIntervalSince1970)", "customEnd": "\(customEnd.timeIntervalSince1970)"]
        for (d, v) in filters { p["filter." + d.rawValue] = v }
        if let data = try? JSONEncoder().encode(p) { UserDefaults.app.set(data, forKey: Self.prefsKey) }
    }

    // App start: with sync on, this Mac's sums go up every 30 minutes even when the window stays closed.
    func start(_ model: AppModel) {
        app = model
        if syncOn { peers = TokenSync.cached() }
        let ticker = Timer(timeInterval: 1800, repeats: true) { [weak self, weak model] _ in
            guard let self, let model, self.syncOn else { return }
            self.load(model)
        }
        ticker.tolerance = 120
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker
        if syncOn { DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self, weak model] in if let model { self?.load(model) } } }
    }

    // Reads the logs (only what is new) and, with sync on, swaps sums with the other Macs. Off the main thread.
    func load(_ model: AppModel) {
        app = model
        guard !loading else { return }
        loading = true; reading = true
        let accounts = model.accounts, toolHome = model.persist ? ToolHome.path : AccountStore.home
        let sync = syncOn && model.persist ? DeviceSync.shared : nil
        let folder = sync?.folder, id = sync?.deviceID, name = sync?.deviceName
        DispatchQueue.global(qos: .utility).async {
            let read = TokenLedger.read(accounts, toolHome: toolHome)
            var peers: [TokenDevice]?
            if let folder, let id, let name {
                peers = TokenSync.exchange(Self.named(read.entries, accounts), folder: folder, deviceID: id, deviceName: name)
            }
            DispatchQueue.main.async {
                self.report = read
                if let peers, self.syncOn { self.peers = peers; self.syncedAt = Date() }
                self.loading = false; self.reading = false
                self.rebuild()
            }
        }
    }

    // What this Mac shares: its sums with the account's name (ids differ on each Mac).
    static func named(_ entries: [TokenEntry], _ accounts: [Account]) -> [TokenEntry] {
        entries.map { e in
            var e = e
            e.accountName = e.accountID.flatMap { id in accounts.first { $0.id == id }?.name }
            return e
        }
    }

    func rebuild() {
        guard let report else { return }
        let accounts = app?.accounts ?? [], chats = self.chats(), peers = syncOn ? self.peers : []
        DispatchQueue.global(qos: .userInitiated).async {
            let built = Self.build(Self.named(report.entries, accounts), peers: peers, chats: chats)
            DispatchQueue.main.async { self.facts = built.facts; self.labels = built.labels; self.paths = built.paths }
        }
    }

    // MARK: What each sum belongs to

    static func build(_ local: [TokenEntry], peers: [TokenDevice], chats: [UUID: (title: String, project: String?)])
        -> (facts: [Fact], labels: [Dim: [String: String]], paths: [String: String]) {
        let home = AccountStore.home
        var labels: [Dim: [String: String]] = [:]
        var paths: [String: String] = [:]
        var roots: [String: String] = [:]
        func root(_ path: String) -> String {
            if let r = roots[path] { return r }
            let r = TokenLedger.projectRoot(path); roots[path] = r; return r
        }
        func label(_ d: Dim, _ key: String, _ text: String) { if labels[d]?[key] == nil { labels[d, default: [:]][key] = text } }
        var facts: [Fact] = []
        for e in TokenLedger.together(local, peers) {
            let legacy = e.source == .legacy
            var keys: [String] = []
            // provider
            keys.append(e.provider.rawValue); label(.provider, e.provider.rawValue, e.provider.title)
            // account
            if let name = e.accountName {
                let k = e.provider.rawValue + "#" + name
                keys.append(k); label(.account, k, name)
            } else {
                let k = e.provider.rawValue + "#?" + (e.origin?.rawValue ?? "")
                keys.append(k); label(.account, k, unknownAccount(e.provider, e.origin))
            }
            // model
            let model = e.model ?? (legacy ? "~legacy" : "~none")
            keys.append(model)
            label(.model, model, e.model ?? (legacy ? L("분류 정보 없음 (이전 집계)", "Not classified (older sums)") : L("모델 미상", "Model unknown")))
            // project and chat
            var project = legacy ? "~legacy" : "~none", chat = legacy ? "~legacy" : "~none"
            if let cwd = e.project {
                if let r = cwd.range(of: "/.ai-illuminati/rooms/") {
                    let id = cwd[r.upperBound...].split(separator: "/").first.map(String.init) ?? ""
                    if let uuid = UUID(uuidString: id) {
                        chat = "chat:" + uuid.uuidString
                        label(.chat, chat, chats[uuid]?.title ?? L("지워진 채팅", "Deleted chat"))
                        if let p = chats[uuid]?.project { project = root(p); paths[project] = project; label(.project, project, (project as NSString).lastPathComponent) }
                        else { project = "~appchat" }
                    }
                } else if cwd.hasPrefix(home + "/.ai-illuminati/") {
                    project = "~app"; chat = "~app"
                } else {
                    project = root(cwd); paths[project] = project
                    label(.project, project, (project as NSString).lastPathComponent)
                }
            }
            if chat == "~none", e.accountID == nil && e.accountName == nil, let o = e.origin, o != .other { chat = "~" + o.rawValue }
            keys.append(project); keys.append(chat)
            label(.project, "~none", L("프로젝트 미상", "Project unknown")); label(.project, "~legacy", L("분류 정보 없음 (이전 집계)", "Not classified (older sums)"))
            label(.project, "~appchat", L("앱 채팅 (연결 프로젝트 없음)", "App chats (no linked project)"))
            label(.project, "~app", L("앱 내부 호출 (작업 폴더 없음)", "App calls (no work folder)"))
            label(.chat, "~none", L("채팅 미상", "Chat unknown")); label(.chat, "~legacy", L("분류 정보 없음 (이전 집계)", "Not classified (older sums)"))
            label(.chat, "~app", L("앱 내부 호출 (채팅 없음)", "App calls (no chat)"))
            label(.chat, "~desktop", L("데스크톱 앱 세션", "Desktop app sessions")); label(.chat, "~terminal", L("터미널 세션", "Terminal sessions"))
            // session
            let session = e.session.map { e.provider.rawValue + ":" + $0 } ?? (legacy ? "~legacy" : "~none")
            keys.append(session)
            label(.session, session, e.session.map { String($0.prefix(8)) + "…" } ?? (legacy ? L("분류 정보 없음 (이전 집계)", "Not classified (older sums)") : L("세션 미상", "Session unknown")))
            // device
            keys.append(e.device)
            label(.device, e.device, e.device.isEmpty ? L("이 Mac", "This Mac") : peers.first { $0.id == e.device }?.name ?? L("다른 Mac", "Other Mac"))
            // source
            let source: String
            switch e.source {
            case .legacy: source = "legacy"; label(.source, source, L("이전 일별 합계 (분류 없음)", "Older daily sums (not classified)"))
            case .app: source = "app:" + (e.kind ?? "chat"); label(.source, source, L("앱 호출 · ", "App call · ") + kindName(e.kind))
            case .log:
                if e.accountName != nil || e.accountID != nil { source = "log:account"; label(.source, source, L("앱 계정의 CLI 로그", "App accounts' CLI logs")) }
                else if e.provider == .gemini { source = "log:gemini"; label(.source, source, L("Gemini 공용 로그", "Gemini shared log")) }
                else { source = "log:" + (e.origin ?? .other).rawValue; label(.source, source, originName(e.origin)) }
            }
            keys.append(source)
            facts.append(Fact(start: e.start, hourly: e.hourly, counts: e.counts, provider: e.provider, keys: keys, legacy: legacy))
        }
        // Projects of the same name are told apart by their folder.
        let names = Dictionary(grouping: paths.keys) { (($0 as NSString).lastPathComponent) }
        for (_, list) in names where list.count > 1 {
            for p in list { labels[.project]?[p] = (p as NSString).lastPathComponent + " — " + ((p as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath }
        }
        return (facts, labels, paths)
    }

    static func unknownAccount(_ p: Account.Provider, _ origin: TokenEntry.Origin?) -> String {
        switch (p, origin) {
        case (.claude, .desktop?): return L("Claude 계정 미상 (데스크톱 앱 Code)", "Claude, account unknown (desktop app Code)")
        case (.claude, .terminal?): return L("Claude 계정 미상 (터미널)", "Claude, account unknown (Terminal)")
        case (.codex, .desktop?): return L("ChatGPT 계정 미상 (Codex 앱)", "ChatGPT, account unknown (Codex app)")
        case (.codex, .terminal?): return L("ChatGPT 계정 미상 (터미널)", "ChatGPT, account unknown (Terminal)")
        default: return L("\(p.title) 계정 미상", "\(p.title), account unknown")
        }
    }
    static func originName(_ o: TokenEntry.Origin?) -> String {
        switch o {
        case .desktop?: return L("데스크톱 앱 로그 (앱 밖)", "Desktop app logs (outside the app)")
        case .terminal?: return L("터미널 CLI 로그 (앱 밖)", "Terminal CLI logs (outside the app)")
        default: return L("기타 CLI 로그 (앱 밖)", "Other CLI logs (outside the app)")
        }
    }
    static func kindName(_ kind: String?) -> String {
        switch kind {
        case "routing"?: return L("라우팅", "Routing")
        case "meeting"?: return L("회의", "Meetings")
        case "attachment"?: return L("첨부 처리", "Attachments")
        case "picture"?: return L("그림", "Pictures")
        case "ask_ai"?: return L("다른 AI에게 묻기", "Ask another AI")
        case "space"?: return L("Spaces", "Spaces")
        default: return L("채팅", "Chat")
        }
    }

    // MARK: Periods

    var calendar: Calendar {
        var c = Calendar.current
        if zone == .utc { c.timeZone = TimeZone(identifier: "UTC")! }
        return c
    }
    private var unit: Calendar.Component {
        switch span { case .day: return .day; case .week: return .weekOfYear; case .month: return .month; default: return .year }
    }
    var period: DateInterval {
        let cal = calendar
        switch span {
        case .all:
            let first = facts.map(\.start).min() ?? Date()
            let start = cal.dateInterval(of: .month, for: first)?.start ?? first
            return DateInterval(start: start, end: max(cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date(), start.addingTimeInterval(1)))
        case .custom:
            let a = cal.startOfDay(for: min(customStart, customEnd)), b = cal.startOfDay(for: max(customStart, customEnd))
            return DateInterval(start: a, end: cal.date(byAdding: .day, value: 1, to: b) ?? b.addingTimeInterval(86400))
        default:
            let anchor = cal.date(byAdding: unit, value: -back, to: Date()) ?? Date()
            return cal.dateInterval(of: unit, for: anchor) ?? DateInterval(start: anchor, duration: 86400)
        }
    }
    // The chart's step: hours of a day, days of a week or month (or a short custom range), else months (years when long).
    var step: Calendar.Component {
        switch span {
        case .day: return .hour
        case .week, .month: return .day
        case .year: return .month
        case .all, .custom:
            let days = period.duration / 86400
            return days <= 62 ? .day : days <= 365 * 4 ? .month : .year
        }
    }
    var columns: [DateInterval] {
        let cal = calendar, p = period
        var list: [DateInterval] = []
        var start = p.start
        while start < p.end, list.count < 400, let next = cal.date(byAdding: step, value: 1, to: start) {
            list.append(DateInterval(start: start, end: min(next, p.end)))
            start = next
        }
        return list
    }

    // MARK: Measures and filters

    static func value(_ c: TokenCounts, _ k: Kind) -> Int {
        switch k { case .input: return c.input; case .cacheWrite: return c.cacheWrite; case .cacheRead: return c.cacheRead; case .output: return c.output }
    }
    func measure(_ c: TokenCounts) -> Int {
        switch metric { case .fresh: return c.fresh; case .output: return c.output; case .all: return c.total }
    }
    // A fact counts in the range when it started in it; a day-only (older) sum counts in an hour column never.
    func inRange(_ f: Fact, _ r: DateInterval, hourColumns: Bool = false) -> Bool {
        if hourColumns && !f.hourly { return false }
        return f.start >= r.start && f.start < r.end
    }
    func passes(_ f: Fact, except: Dim? = nil) -> Bool {
        if let device, f.key(.device) != device { return false }
        for (d, v) in filters where d != except && f.key(d) != v { return false }
        return true
    }
    // Everything the summary, the table and the export count: the period (or the picked column), the Mac, the chips.
    var current: [Fact] {
        let r = picked ?? period
        return facts.filter { inRange($0, r, hourColumns: picked != nil && step == .hour) && passes($0) }
    }
    func label(_ d: Dim, _ key: String) -> String { labels[d]?[key] ?? key }

    struct Row: Identifiable {
        let id: String       // the key; "~rest" for the rest
        let name: String
        var counts = TokenCounts()
        var provider: Account.Provider?   // when every fact has one provider
        var mixed = false
    }
    func rows(_ facts: [Fact], by d: Dim) -> [Row] {
        var byKey: [String: Row] = [:]
        for f in facts {
            let k = f.key(d)
            var row = byKey[k] ?? Row(id: k, name: label(d, k), provider: f.provider)
            row.counts += f.counts
            if row.provider != f.provider { row.mixed = true; row.provider = nil }
            byKey[k] = row
        }
        return byKey.values.sorted { measure($0.counts) != measure($1.counts) ? measure($0.counts) > measure($1.counts) : $0.name < $1.name }
    }
    // MARK: Export

    // What the export holds: the current filters, period, time zone, unit and what is counted, then the table's rows
    // and their total (CSV) or every sum with what it belongs to (JSON). Names and numbers only: no chat text, no logins.
    func export(csv: Bool, now: Date = Date()) -> Data {
        let facts = current
        let range = picked ?? period
        let iso = ISO8601DateFormatter()
        let meta: [String: Any] = [
            "period_start": iso.string(from: range.start), "period_end": iso.string(from: range.end),
            "time_zone": calendar.timeZone.identifier, "unit": "tokens",
            "measure": metric.rawValue, "measure_definition": "U=uncached input, W=cache writes, R=cache reads, O=output (reasoning is part of O); fresh=U+W+O, all=U+W+R+O",
            "devices": device.map { id in deviceNames.first { $0.0 == id }?.1 ?? id } ?? "all",
            "filters": Dictionary(uniqueKeysWithValues: filters.map { ($0.key.rawValue, label($0.key, $0.value)) }),
            "included": "CLI logs, desktop app Code/agent logs, app calls without logs (CLI-reported usage); web and plain desktop chats not observable",
            "generated_at": iso.string(from: now)]
        if csv {
            var text = meta.sorted { $0.key < $1.key }.map { "# \($0.key): \(String(describing: $0.value))" }.joined(separator: "\n") + "\n"
            text += [group.rawValue, "key", "uncached_input", "cache_write", "cache_read", "output", "reasoning", "input_no_cache_reads", "fresh", "all"].joined(separator: ",") + "\n"
            let list = rows(facts, by: group)
            for r in list + [Row(id: "", name: L("합계", "Total"), counts: list.reduce(TokenCounts()) { $0 + $1.counts })] {
                let c = r.counts
                text += ([r.name, r.id] + [c.input, c.cacheWrite, c.cacheRead, c.output].map(String.init) + [c.reasoning.map(String.init) ?? "",
                         String(c.input + c.cacheWrite), String(c.fresh), String(c.total)]).map(Self.csvField).joined(separator: ",") + "\n"
            }
            return Data(text.utf8)
        }
        let list: [[String: Any]] = facts.map { f in
            var row: [String: Any] = ["start": iso.string(from: f.start), "precision": f.hourly ? "hour" : "day",
                                      "input": f.counts.input, "cache_write": f.counts.cacheWrite, "cache_read": f.counts.cacheRead, "output": f.counts.output]
            if let r = f.counts.reasoning { row["reasoning"] = r }
            for d in Dim.allCases { row[d.rawValue] = label(d, f.key(d)) }
            return row
        }
        return (try? JSONSerialization.data(withJSONObject: ["meta": meta, "rows": list], options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    static func csvField(_ s: String) -> String {
        s.contains(",") || s.contains("\"") || s.contains("\n") ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }

    // The chart's columns, each with its sum (day-only older sums go in no hour column).
    func columnSums(_ facts: [Fact]) -> [TokenCounts] {
        let cols = columns, hourly = step == .hour
        var sums = [TokenCounts](repeating: TokenCounts(), count: cols.count)
        for f in facts where !(hourly && !f.hourly) { if let i = Self.column(of: f.start, in: cols) { sums[i] += f.counts } }
        return sums
    }
    static func column(of date: Date, in cols: [DateInterval]) -> Int? {
        var lo = 0, hi = cols.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if date < cols[mid].start { hi = mid - 1 } else if date >= cols[mid].end { lo = mid + 1 } else { return mid }
        }
        return nil
    }

    var deviceNames: [(String, String)] {
        [("", L("이 Mac", "This Mac"))] + (syncOn ? peers.map { ($0.id, $0.name) } : [])
    }
}

// MARK: - The window

final class TokenStatsWindow {
    static let shared = TokenStatsWindow()
    static var openChat: ((UUID) -> Void)?   // a chat row's "Open chat" (main.swift connects it to the chat window)
    private var window: NSWindow?

    func show(model: AppModel) {
        let stats = TokenStatsModel.shared
        if window == nil {
            let host = NSHostingController(rootView: TokenStatsView(model: model, stats: stats))
            host.sizingOptions = []
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.title = L("사용량", "Usage")
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 560, height: 480)
            w.setContentSize(NSSize(width: 980, height: 760))
            w.center()
            w.setFrameAutosaveName("AIIlluminatiUsageWindow")
            window = w
        }
        stats.load(model)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct TokenStatsView: View {
    typealias M = TokenStatsModel
    @ObservedObject var model: AppModel
    @ObservedObject var stats: TokenStatsModel
    @ObservedObject private var deviceSync = DeviceSync.shared
    @AppStorage(AIColors.revisionKey) private var revision = 0   // redraw when an AI's color changes

    var body: some View {
        let _ = revision
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    toolbar
                    if stats.report == nil && stats.facts.isEmpty {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(L("CLI 로그를 읽는 중… (처음 한 번은 몇 초 걸려요)", "Reading the CLI logs… (the first time takes a few seconds)")).foregroundStyle(.secondary)
                        }.padding(.vertical, 40).frame(maxWidth: .infinity)
                    } else {
                        let facts = stats.current
                        chips
                        summary(facts)
                        if geo.size.width >= 900 {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(spacing: 12) { trend; composition(facts) }.frame(maxWidth: .infinity)
                                VStack(spacing: 12) { table(facts); detail }.frame(maxWidth: .infinity)
                            }
                        } else {
                            trend; composition(facts); table(facts); detail
                        }
                        status
                        notes
                    }
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .font(.system(size: 12)).controlSize(.small)
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 560, minHeight: 480)
    }

    // MARK: Toolbar: period, Mac, refresh, sync

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Segments(options: [(L("일", "Day"), M.Span.day), (L("주", "Week"), .week), (L("월", "Month"), .month), (L("년", "Year"), .year),
                                   (L("전체", "All"), .all), (L("기간 지정", "Custom"), .custom)],
                         selection: Binding(get: { stats.span }, set: { stats.span = $0; stats.back = 0; stats.picked = nil }))
                    .frame(maxWidth: 420)
                Spacer()
                Menu {
                    Button(L("모든 Mac", "All Macs")) { stats.device = nil; stats.picked = nil }
                    ForEach(stats.deviceNames, id: \.0) { d in Button(d.1) { stats.device = d.0; stats.picked = nil } }
                } label: { Text(stats.device.map { id in stats.deviceNames.first { $0.0 == id }?.1 ?? L("다른 Mac", "Other Mac") } ?? L("모든 Mac", "All Macs")).lineLimit(1) }
                    .fixedSize().help(L("어느 Mac의 사용량을 셀지", "Which Macs to count"))
                Button { stats.load(model) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plainHit).disabled(stats.reading).help(L("새로고침: 새 로그를 읽고, 동기화가 켜져 있으면 다른 Mac과 주고받아요", "Refresh: read new logs and, with sync on, swap with the other Macs"))
                Menu {
                    Button(L("CSV로 내보내기…", "Export CSV…")) { export(csv: true) }
                    Button(L("JSON으로 내보내기…", "Export JSON…")) { export(csv: false) }
                } label: { Image(systemName: "square.and.arrow.up") }.fixedSize().help(L("현재 필터 그대로 내보내기", "Export with the current filters"))
            }
            HStack(spacing: 6) {
                if stats.span == .custom {
                    DatePicker("", selection: $stats.customStart, displayedComponents: .date).labelsHidden().fixedSize()
                    Text("–")
                    DatePicker("", selection: $stats.customEnd, displayedComponents: .date).labelsHidden().fixedSize()
                } else if stats.span != .all {
                    Button { stats.back += 1; stats.picked = nil } label: { Image(systemName: "chevron.left") }.buttonStyle(.plainHit)
                    Text(periodTitle).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Button { stats.back -= 1; stats.picked = nil } label: { Image(systemName: "chevron.right") }.buttonStyle(.plainHit)
                        .disabled(stats.back == 0).opacity(stats.back == 0 ? 0.3 : 1)
                } else {
                    Text(periodTitle).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                }
                Spacer()
                Text(readStatus).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                Toggle(L("모든 Mac 합산", "All Macs"), isOn: Binding(get: { stats.syncOn }, set: { on in
                    stats.syncOn = on
                    if on { stats.peers = TokenSync.cached(); stats.load(model) }
                })).toggleStyle(.switch).fixedSize()
                    .help(L("각 Mac이 토큰 장부(계정 이름·모델·세션 id·작업 폴더 경로와 숫자, 대화 내용 없음)를 동기화 폴더(기본: iCloud Drive)의 자기 파일에만 쓰고 다른 Mac 것을 읽어요. 같은 provider와 이름의 계정은 합쳐요. 30분마다, 그리고 이 창을 열 때 올라가요.",
                            "Each Mac writes its token ledger (account names, models, session ids, work folder paths and numbers; no chat text) to its own file in the sync folder (iCloud Drive by default) and reads the others. Accounts with the same provider and name add up. Sent every 30 minutes and when this window opens."))
            }
        }
    }

    private var readStatus: String {
        var parts: [String] = []
        if stats.reading { parts.append(L("읽는 중…", "Reading…")) }
        else if let at = stats.report?.readAt { parts.append(L("수집 ", "Read ") + DeviceSync.ago(at)) }
        if stats.syncOn {
            if !deviceSync.folderAvailable { parts.append(L("iCloud Drive 꺼짐", "iCloud Drive off")) }
            else { parts.append(L("다른 Mac \(stats.peers.count)대", "\(stats.peers.count) other Macs") + (stats.syncedAt.map { L(" · 동기화 ", " · synced ") + DeviceSync.ago($0) } ?? "")) }
        }
        return parts.joined(separator: " · ")
    }

    private var periodTitle: String {
        let f = DateFormatter()
        f.locale = AppLanguage.current.locale
        f.timeZone = stats.calendar.timeZone
        let p = stats.period
        switch stats.span {
        case .day: f.setLocalizedDateFormatFromTemplate("yMMMdEEE")
        case .month: f.setLocalizedDateFormatFromTemplate("yMMMM")
        case .year: f.setLocalizedDateFormatFromTemplate("y")
        default:
            let i = DateIntervalFormatter()
            i.locale = AppLanguage.current.locale
            i.timeZone = stats.calendar.timeZone
            i.dateTemplate = "yMMMd"
            return i.string(from: p.start, to: p.end.addingTimeInterval(-1))
        }
        return f.string(from: p.start)
    }

    // MARK: Chips: what is being counted

    private var chips: some View {
        HStack(spacing: 6) {
            chip(L("기간: ", "Period: ") + (stats.picked.map(columnTitle) ?? periodTitle), clear: stats.picked == nil ? nil : { stats.picked = nil })
            chip(stats.device.map { id in stats.deviceNames.first { $0.0 == id }?.1 ?? id } ?? L("모든 Mac", "All Macs"), clear: stats.device == nil ? nil : { stats.device = nil })
            ForEach(M.Dim.allCases.filter { stats.filters[$0] != nil }, id: \.self) { d in
                chip(Self.dimName(d) + ": " + stats.label(d, stats.filters[d]!), clear: { stats.filters[d] = nil; stats.selected = nil })
            }
            Spacer()
            Menu {
                Button(L("이 Mac의 시간대", "This Mac's time zone")) { stats.zone = .local; stats.picked = nil }
                Button("UTC") { stats.zone = .utc; stats.picked = nil }
            } label: { Text(stats.zone == .utc ? "UTC" : TimeZone.current.identifier).lineLimit(1) }
                .fixedSize().help(L("시간·날짜를 나누는 시간대. 기록은 UTC로 보관해요.", "The time zone hours and days are split in. Sums are kept in UTC."))
        }
    }

    private func chip(_ text: String, clear: (() -> Void)?) -> some View {
        HStack(spacing: 4) {
            Text(text).lineLimit(1)
            if let clear { Button(action: clear) { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plainHit).foregroundStyle(.secondary) }
        }
        .font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(clear == nil ? 0.05 : 0.1)))
    }

    // MARK: Summary

    private func summary(_ facts: [M.Fact]) -> some View {
        let sum = facts.reduce(TokenCounts()) { $0 + $1.counts }
        let fed = sum.input + sum.cacheWrite + sum.cacheRead
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                figure(L("출력", "Output"), sum.output, color: Self.kindColor(.output),
                       help: L("AI가 만든 토큰 전부: 보이는 답, thinking/reasoning, 도구 호출.", "Every token the AIs produced: answers, thinking/reasoning, tool calls.")
                       + (sum.reasoning.map { L(" 그중 reasoning(보고된 만큼) ", " Of it reasoning (as reported) ") + Self.exact($0) } ?? ""))
                figure(L("입력 (캐시 읽기 제외)", "Input (no cache reads)"), sum.input + sum.cacheWrite, color: Self.kindColor(.input),
                       help: L("캐시 아닌 입력 + 캐시 쓰기 (U+W)", "Uncached input + cache writes (U+W)"))
                figure(L("캐시 읽기", "Cache reads"), sum.cacheRead, color: Self.kindColor(.cacheRead), help: Self.cacheHelp)
                figure(L("전체 처리 토큰", "All processed"), sum.total, color: nil, help: L("U+W+R+O: 캐시 읽기까지 모두", "U+W+R+O: everything, cache reads included"))
            }
            HStack(spacing: 10) {
                Segments(options: [(L("입력+출력", "Input+output"), M.Metric.fresh), (L("출력만", "Output only"), .output),
                                   (L("캐시 포함 전체", "All with cache"), .all)], selection: $stats.metric).frame(maxWidth: 360)
                    .help(L("차트·표가 세는 값: 입력+출력 = U+W+O (캐시 읽기 제외, 기본), 출력만 = O, 캐시 포함 전체 = U+W+R+O",
                            "What the chart and table count: input+output = U+W+O (no cache reads, default), output = O, all = U+W+R+O"))
                Spacer()
                Text(L("캐시 읽기 비중 ", "Cache read share ") + Self.percent(sum.cacheRead, of: fed))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .help(L("R ÷ (U+W+R): 입력 중 캐시에서 읽은 비율. 제공자마다 캐시 방식이 달라 서로의 cache-hit 확률이나 한도 소모율과 같지 않아요.",
                            "R ÷ (U+W+R): the share of input read from the cache. Providers cache differently: not a comparable hit rate, and not limit use."))
            }
        }
    }

    private func figure(_ title: String, _ n: Int, color: Color?, help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if let color { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8) }
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(Self.short(n)).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(Self.exact(n)).font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit().lineLimit(1)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.07)))
        .help(help)
    }

    // MARK: Trend

    private var trend: some View {
        let cols = stats.columns
        let hourly = stats.step == .hour
        let base = stats.facts.filter { stats.passes($0) }
        let inPeriod = base.filter { stats.inRange($0, stats.period, hourColumns: hourly) }
        // The stacks: the top 7 of the chosen dimension in the period, then the rest.
        let ranked = stats.rows(inPeriod, by: stats.stack)
        let top = Array(ranked.prefix(7))
        let topKeys = top.map(\.id)
        var cells = [[Int]](repeating: [Int](repeating: 0, count: topKeys.count + 1), count: cols.count)
        var exactCells = [[TokenCounts]](repeating: [TokenCounts](repeating: TokenCounts(), count: topKeys.count + 1), count: cols.count)
        var dayOnly = 0
        for f in inPeriod {
            guard let i = M.column(of: f.start, in: cols) else { continue }
            let k = topKeys.firstIndex(of: f.key(stats.stack)) ?? topKeys.count
            cells[i][k] += stats.measure(f.counts)
            exactCells[i][k] += f.counts
        }
        if hourly { dayOnly = base.filter { !$0.hourly && stats.inRange($0, stats.period) }.reduce(0) { $0 + stats.measure($1.counts) } }
        let peak = max(cells.map { $0.reduce(0, +) }.max() ?? 0, 1)
        let height: CGFloat = 120
        return Card(title: metricTitle + " · " + stepName) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L("나눠 보기", "Stack by")).foregroundStyle(.secondary)
                    Menu { ForEach([M.Dim.account, .provider, .model, .device, .source, .project, .chat], id: \.self) { d in Button(Self.dimName(d)) { stats.stack = d } } }
                        label: { Text(Self.dimName(stats.stack)) }.fixedSize()
                    Spacer()
                    if stats.picked != nil { Button(L("구간 해제", "Clear bar")) { stats.picked = nil }.buttonStyle(.plainHit).foregroundStyle(Color.accentColor) }
                }
                HStack(alignment: .bottom, spacing: cols.count > 40 ? 1 : cols.count > 14 ? 2 : 4) {
                    ForEach(cols.indices, id: \.self) { i in
                        let total = cells[i].reduce(0, +)
                        let parts = cells[i].indices.reversed().filter { cells[i][$0] > 0 }
                        let room = max(height - CGFloat(max(parts.count - 1, 0)), 0)
                        let chosen = stats.picked == cols[i]
                        VStack(spacing: 2) {
                            ZStack(alignment: .bottom) {
                                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(chosen ? 0.14 : 0.05))
                                VStack(spacing: 1) {
                                    ForEach(parts, id: \.self) { k in
                                        segment(k < topKeys.count ? top[k] : nil).frame(height: CGFloat(cells[i][k]) / CGFloat(peak) * room)
                                    }
                                }.clipShape(RoundedRectangle(cornerRadius: 2))
                            }
                            .frame(height: height)
                            .opacity(stats.picked == nil || chosen ? 1 : 0.45)
                            Text(columnLabel(cols[i], index: i, count: cols.count)).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { stats.picked = chosen ? nil : cols[i] }
                        .help(columnTitle(cols[i]) + " · " + Self.exact(total)
                              + cells[i].indices.filter { cells[i][$0] > 0 }.map { k in
                                  "\n" + (k < topKeys.count ? top[k].name : L("나머지", "The rest")) + "  " + Self.exact(cells[i][k])
                                  + "  (U " + Self.exact(exactCells[i][k].input) + " · W " + Self.exact(exactCells[i][k].cacheWrite)
                                  + " · R " + Self.exact(exactCells[i][k].cacheRead) + " · O " + Self.exact(exactCells[i][k].output) + ")"
                              }.joined())
                    }
                }
                // The legend: what the colors stand for in this chart.
                FlowLegend(items: top.map { ($0.name, AnyView(segment($0).frame(width: 10, height: 10).clipShape(RoundedRectangle(cornerRadius: 2)))) }
                           + (ranked.count > top.count ? [(L("나머지", "The rest"), AnyView(segment(nil).frame(width: 10, height: 10).clipShape(RoundedRectangle(cornerRadius: 2))))] : []))
                Text(colorMeaning).font(.system(size: 10)).foregroundStyle(.tertiary)
                if dayOnly > 0 {
                    Text(L("시간 정보 없는 이전 일별 합계 \(Self.short(dayOnly))는 막대에 없고 합계에만 들어가요", "Older daily sums without hours (\(Self.short(dayOnly))) are in the totals, not in the bars"))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if let note = coverageNote { Text(note).font(.system(size: 10)).foregroundStyle(.orange) }
            }.padding(10)
        }
    }

    private var stepName: String {
        switch stats.step { case .hour: return L("시간별", "per hour"); case .day: return L("일별", "per day"); case .month: return L("월별", "per month"); default: return L("연도별", "per year") }
    }
    private var metricTitle: String {
        switch stats.metric { case .fresh: return L("입력+출력 (캐시 읽기 제외)", "Input+output (no cache reads)"); case .output: return L("출력", "Output"); case .all: return L("전체 처리 토큰", "All processed tokens") }
    }
    // Who used it (the provider's color) or a plain palette for what has no provider; never the token kinds' colors.
    private var providerColored: Bool { [.account, .provider, .model, .session].contains(stats.stack) }
    private var colorMeaning: String {
        providerColored ? L("색 = 제공자. 같은 제공자의 계정·모델은 같은 색이고 경계선과 이름으로 구분해요. 빗금 = 계정 미상.",
                            "Color = provider. Accounts and models of one provider share its color, told apart by gaps and names. Stripes = account unknown.")
                        : L("색 = \(Self.dimName(stats.stack)) 구분용 (제공자나 토큰 종류 아님)", "Color = \(Self.dimName(stats.stack)) only (not provider, not token kind)")
    }
    @ViewBuilder private func segment(_ row: M.Row?) -> some View {
        if let row {
            if providerColored, let p = row.provider {
                let c = Color(nsColor: AIColors.color(p))
                if stats.stack == .account && row.id.contains("#?") { ZStack { c.opacity(0.3); Stripes().stroke(c, lineWidth: 1.5) }.clipped() } else { c }
            } else {
                Self.palette[row.id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % Self.palette.count]   // the same color every launch
            }
        } else {
            Color(nsColor: .systemGray).opacity(0.5)
        }
    }
    private static let palette: [Color] = [.teal, .indigo, .pink, .brown, .mint, .cyan, Color(red: 0.55, green: 0.6, blue: 0.2)]

    private func columnLabel(_ col: DateInterval, index: Int, count: Int) -> String {
        let f = DateFormatter()
        f.locale = AppLanguage.current.locale
        f.timeZone = stats.calendar.timeZone
        switch stats.step {
        case .hour: return index % 3 == 0 ? "\(stats.calendar.component(.hour, from: col.start))" : ""
        case .day:
            if stats.span == .week { f.setLocalizedDateFormatFromTemplate("EEE"); return f.string(from: col.start) }
            return index % 5 == 0 ? "\(stats.calendar.component(.day, from: col.start))" : ""
        case .month:
            let every = count > 24 ? 6 : count > 12 ? 3 : 1
            guard index % every == 0 else { return "" }
            f.setLocalizedDateFormatFromTemplate(count > 12 ? "yyMMM" : "MMM")
            return f.string(from: col.start).replacingOccurrences(of: ".", with: "")
        default: return "\(stats.calendar.component(.year, from: col.start))"
        }
    }
    private func columnTitle(_ col: DateInterval) -> String {
        let f = DateFormatter()
        f.locale = AppLanguage.current.locale
        f.timeZone = stats.calendar.timeZone
        switch stats.step {
        case .hour: f.setLocalizedDateFormatFromTemplate("MMMdEEE HH:mm")
        case .day: f.setLocalizedDateFormatFromTemplate("yMMMdEEE")
        case .month: f.setLocalizedDateFormatFromTemplate("yMMMM")
        default: f.setLocalizedDateFormatFromTemplate("y")
        }
        return f.string(from: col.start)
    }

    // Before the first log of a Mac there is no record (not zero use).
    private var coverageNote: String? {
        let p = stats.period
        let firsts = (stats.report?.folders ?? []).compactMap(\.first)
        guard let first = firsts.min(), p.start < first else { return nil }
        let f = DateFormatter()
        f.locale = AppLanguage.current.locale
        f.setLocalizedDateFormatFromTemplate("yMMMd")
        return L("이 Mac의 기록은 \(f.string(from: first))부터예요. 그 전은 0이 아니라 기록 없음(Claude Code는 30일 지난 로그를 지우고, 앱이 읽기 전에 지워진 건 셀 수 없어요).",
                 "This Mac's records start \(f.string(from: first)). Before that is no record, not zero (Claude Code deletes logs after 30 days; ones deleted before the app read them cannot be counted).")
    }

    // MARK: Composition

    private func composition(_ facts: [M.Fact]) -> some View {
        let sum = facts.reduce(TokenCounts()) { $0 + $1.counts }
        let kinds: [M.Kind] = stats.compositionWithoutReads ? [.input, .cacheWrite, .output] : M.Kind.allCases
        let whole = kinds.reduce(0) { $0 + M.value(sum, $1) }
        return Card(title: L("토큰 구성", "Token kinds")) {
            VStack(alignment: .leading, spacing: 6) {
                Segments(options: [(L("전체 처리 토큰 기준", "Of all processed"), false), (L("캐시 읽기 제외 기준", "Without cache reads"), true)],
                         selection: $stats.compositionWithoutReads).frame(maxWidth: 340)
                GeometryReader { g in
                    HStack(spacing: 0) {
                        ForEach(kinds, id: \.self) { k in
                            Rectangle().fill(Self.kindColor(k)).frame(width: whole > 0 ? CGFloat(M.value(sum, k)) / CGFloat(whole) * g.size.width : 0)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 3))
                }.frame(height: 10)
                ForEach(kinds, id: \.self) { k in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(Self.kindColor(k)).frame(width: 9, height: 9)
                        Text(Self.kindName(k)).lineLimit(1)
                        Spacer()
                        Text(Self.exact(M.value(sum, k))).monospacedDigit()
                        Text(Self.percent(M.value(sum, k), of: whole)).monospacedDigit().foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
                    }.help(Self.help(k))
                }
                if let r = sum.reasoning {
                    HStack(spacing: 6) {
                        Text("    " + L("출력 중 reasoning (보고된 것만)", "of output: reasoning (as reported)")).foregroundStyle(.secondary)
                        Spacer()
                        Text(Self.exact(r)).monospacedDigit().foregroundStyle(.secondary)
                    }.help(L("Codex처럼 따로 보고하는 경우만. 출력에 이미 들어 있어 다시 더하지 않아요. Claude thinking은 따로 보고되지 않아 추정하지 않아요.",
                             "Only where the CLI reports it apart (Codex). Already in output, never added again. Claude's thinking is not reported apart and is not estimated."))
                }
                Text(stats.compositionWithoutReads
                     ? L("비율 분모: U+W+O (현재 필터)", "Shares of U+W+O (current filters)")
                     : L("비율 분모: 현재 필터의 전체 처리 토큰. 캐시 읽기가 크면 다른 몫이 작아 보이는 게 정상이에요.", "Shares of everything processed under the current filters. Large cache reads make the rest look small: that is expected."))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }.padding(10)
        }
    }

    // MARK: Table

    private func table(_ facts: [M.Fact]) -> some View {
        let d = stats.group
        let base = facts
        let all = stats.rows(base, by: d)
        let query = stats.search.trimmingCharacters(in: .whitespaces).lowercased()
        let matching = query.isEmpty ? all : all.filter { $0.name.lowercased().contains(query) || $0.id.lowercased().contains(query) }
        var shown = stats.topOnly ? Array(matching.prefix(10)) : matching
        if stats.topOnly && matching.count > 10 {
            var rest = M.Row(id: "~rest", name: L("나머지 \(matching.count - 10)개", "\(matching.count - 10) more"))
            for r in matching.dropFirst(10) { rest.counts += r.counts }
            shown.append(rest)
        }
        // Rows filtered out by the search are left out of the total shown under the table, and said so.
        let total = matching.reduce(TokenCounts()) { $0 + $1.counts }
        let grand = base.reduce(TokenCounts()) { $0 + $1.counts }
        return Card(title: L("분석", "Breakdown")) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Menu { ForEach(M.Dim.allCases, id: \.self) { x in Button(Self.dimName(x)) { stats.group = x; stats.selected = nil } } }
                        label: { Text(L("기준: ", "By: ") + Self.dimName(d)) }.fixedSize()
                    TextField(L("검색", "Search"), text: $stats.search).textFieldStyle(.roundedBorder).frame(maxWidth: 160)
                    Spacer()
                    Segments(options: [("Top 10", true), (L("전체", "All"), false)], selection: $stats.topOnly).frame(width: 120)
                }.padding(8)
                Divider()
                HStack {
                    Text(Self.dimName(d)).frame(maxWidth: .infinity, alignment: .leading)
                    Text(metricShort).frame(width: 84, alignment: .trailing)
                    Text("%").frame(width: 42, alignment: .trailing)
                    Text("U+W").frame(width: 64, alignment: .trailing)
                    Text("R").frame(width: 64, alignment: .trailing)
                    Text("O").frame(width: 64, alignment: .trailing)
                }.font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 4)
                ForEach(shown) { row in
                    Divider()
                    tableRow(row, d, whole: stats.measure(total))
                }
                Divider()
                HStack {
                    Text(query.isEmpty ? L("합계", "Total") : L("검색된 합계 (전체 \(Self.short(stats.measure(grand))))", "Matching total (of \(Self.short(stats.measure(grand))))"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(Self.exact(stats.measure(total))).monospacedDigit().frame(width: 84, alignment: .trailing)
                    Text("").frame(width: 42)
                    Text(Self.short(total.input + total.cacheWrite)).monospacedDigit().frame(width: 64, alignment: .trailing)
                    Text(Self.short(total.cacheRead)).monospacedDigit().frame(width: 64, alignment: .trailing)
                    Text(Self.short(total.output)).monospacedDigit().frame(width: 64, alignment: .trailing)
                }.font(.system(size: 11, weight: .semibold)).padding(.horizontal, 8).padding(.vertical, 5)
            }
        }
    }

    private var metricShort: String {
        switch stats.metric { case .fresh: return "U+W+O"; case .output: return "O"; case .all: return L("전체", "All") }
    }

    private func tableRow(_ row: M.Row, _ d: M.Dim, whole: Int) -> some View {
        let open = stats.selected == row.id
        let filtered = stats.filters[d] == row.id
        return HStack {
            HStack(spacing: 5) {
                if let p = row.provider, row.id != "~rest" { Circle().fill(Color(nsColor: AIColors.color(p))).frame(width: 7, height: 7) }
                Text(row.name).lineLimit(1).truncationMode(.middle)
                if filtered { Image(systemName: "line.3.horizontal.decrease.circle.fill").foregroundStyle(Color.accentColor).font(.system(size: 10)) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(Self.short(stats.measure(row.counts))).monospacedDigit().frame(width: 84, alignment: .trailing)
            Text(Self.percent(stats.measure(row.counts), of: whole)).monospacedDigit().foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
            Text(Self.short(row.counts.input + row.counts.cacheWrite)).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
            Text(Self.short(row.counts.cacheRead)).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
            Text(Self.short(row.counts.output)).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
        }
        .font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 5)
        .background(open ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            guard row.id != "~rest" else { stats.topOnly = false; return }
            stats.selected = open ? nil : row.id
        }
        .contextMenu {
            if row.id != "~rest" {
                Button(filtered ? L("필터 해제", "Remove filter") : L("이것만 보기 (필터)", "Show only this (filter)")) {
                    stats.filters[d] = filtered ? nil : row.id
                }
            }
        }
        .help(Self.exact(stats.measure(row.counts)) + (d == .project ? stats.paths[row.id].map { "\n" + $0 } ?? "" : "")
              + L("\n클릭: 상세 · 오른쪽 클릭: 필터", "\nClick: details · Right-click: filter"))
    }

    // MARK: Detail of the selected row

    @ViewBuilder private var detail: some View {
        if let key = stats.selected {
            let d = stats.group
            let base = stats.facts.filter { stats.passes($0, except: d) && $0.key(d) == key }
            let inPeriod = base.filter { stats.inRange($0, stats.picked ?? stats.period, hourColumns: stats.picked != nil && stats.step == .hour) }
            let sum = inPeriod.reduce(TokenCounts()) { $0 + $1.counts }
            let cols = stats.columns
            let values: [Int] = { var v = [Int](repeating: 0, count: cols.count)
                for f in base where stats.inRange(f, stats.period, hourColumns: stats.step == .hour) { if let i = M.column(of: f.start, in: cols) { v[i] += stats.measure(f.counts) } }
                return v }()
            let peak = max(values.max() ?? 0, 1)
            let providers = Set(inPeriod.map(\.provider))
            let unknownModel = inPeriod.filter { $0.key(.model).hasPrefix("~") }.reduce(0) { $0 + stats.measure($1.counts) }
            let unknownProject = inPeriod.filter { $0.key(.project).hasPrefix("~") }.reduce(0) { $0 + stats.measure($1.counts) }
            let starts = base.map(\.start)
            Card(title: Self.dimName(d) + ": " + stats.label(d, key)) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button(stats.filters[d] == key ? L("필터 해제", "Remove filter") : L("이것만 보기", "Show only this")) {
                            stats.filters[d] = stats.filters[d] == key ? nil : key
                        }
                        if d == .chat, key.hasPrefix("chat:"), let uuid = UUID(uuidString: String(key.dropFirst(5))) {
                            Button(L("채팅 열기", "Open chat")) { TokenStatsWindow.openChat?(uuid) }
                        }
                        Spacer()
                        Button { stats.selected = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plainHit)
                    }
                    HStack(alignment: .bottom, spacing: 1) {
                        ForEach(values.indices, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 1).fill(Color.accentColor.opacity(0.7))
                                .frame(height: max(CGFloat(values[i]) / CGFloat(peak) * 44, values[i] > 0 ? 1 : 0)).frame(maxWidth: .infinity)
                                .help(columnTitle(cols[i]) + " · " + Self.exact(values[i]))
                        }
                    }.frame(height: 44)
                    ForEach(M.Kind.allCases, id: \.self) { k in
                        HStack {
                            Text(Self.kindName(k)).foregroundStyle(.secondary)
                            Spacer()
                            Text(k == .cacheWrite && !providers.isEmpty && !providers.contains(.claude) ? L("미제공", "Not reported") : Self.exact(M.value(sum, k))).monospacedDigit()
                        }.font(.system(size: 11))
                    }
                    HStack {
                        Text(L("출력 중 reasoning", "Reasoning (of output)")).foregroundStyle(.secondary)
                        Spacer()
                        Text(sum.reasoning.map(Self.exact) ?? L("미제공", "Not reported")).monospacedDigit()
                    }.font(.system(size: 11))
                    ForEach([M.Dim.model, .account, .device, .source].filter { $0 != d }, id: \.self) { x in
                        let parts = stats.rows(inPeriod, by: x).prefix(4)
                        if !parts.isEmpty {
                            Text(Self.dimName(x) + ": " + parts.map { $0.name + " " + Self.short(stats.measure($0.counts)) }.joined(separator: " · "))
                                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    if let a = starts.min(), let b = starts.max() {
                        Text(L("관측 범위: ", "Seen: ") + Self.dateText(a) + " – " + Self.dateText(b)).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if unknownModel > 0 || unknownProject > 0 {
                        Text(L("분류 누락: 모델 미상 \(Self.short(unknownModel)) · 프로젝트 미상 \(Self.short(unknownProject))", "Not classified: model \(Self.short(unknownModel)) · project \(Self.short(unknownProject))"))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }.padding(10)
            }
        }
    }

    // MARK: Data status

    private var status: some View {
        Card(title: L("데이터 상태", "Data status")) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array((stats.report?.folders ?? []).enumerated()), id: \.offset) { i, f in
                    if i > 0 { Divider() }
                    folderRow(f)
                }
                ForEach(stats.syncOn ? stats.peers : [], id: \.id) { peer in
                    Divider()
                    HStack {
                        Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
                        Text(peer.name)
                        Spacer()
                        let first = peer.entries.map(\.start).min()
                        Text((first.map { L("첫 기록 ", "First ") + Self.dateText($0) + " · " } ?? L("기록 없음 · ", "No records · "))
                             + L("마지막으로 받은 사본 ", "Last copy received ") + DeviceSync.ago(peer.writtenAt) + " · rev \(peer.revision)"
                             + (peer.entries.contains { $0.source == .legacy } ? L(" · 이전 형식 포함", " · older format inside") : ""))
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }.padding(.horizontal, 10).padding(.vertical, 6)
                }
                if stats.syncOn {
                    Divider()
                    HStack {
                        Button(L("지금 동기화", "Sync now")) { stats.load(model) }
                        Button(L("내 사본 지우기", "Remove mine")) {
                            let sync = DeviceSync.shared
                            DispatchQueue.global(qos: .utility).async { TokenSync.removeMine(folder: sync.folder, deviceID: sync.deviceID) }
                            stats.syncOn = false
                        }
                        Spacer()
                        Text(L("동기화가 꺼지거나 오프라인이어도 이 Mac의 기록은 그대로 남아요", "With sync off or offline, this Mac's records stay as they are"))
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }.padding(8)
                }
            }
        }
    }

    private func folderRow(_ f: TokenFolder) -> some View {
        let who = f.accountID.flatMap { id in model.accounts.first { $0.id == id }?.name } ?? M.unknownAccount(f.provider, nil)
        var parts: [String] = []
        if !f.exists { parts.append(L("폴더 없음 (기록 없음)", "No folder (no records)")) }
        else {
            parts.append(L("로그 \(f.files)개", "\(f.files) logs") + (f.compressed > 0 ? L(" (압축 \(f.compressed))", " (\(f.compressed) compressed)") : ""))
            if let first = f.first { parts.append(L("첫 기록 ", "first ") + Self.dateText(first)) } else { parts.append(L("토큰 기록 없음", "no token records")) }
        }
        if f.deleted > 0 { parts.append(L("지워진 로그 \(f.deleted)개 합계 보존", "\(f.deleted) deleted logs kept as sums")) }
        if f.legacy > 0 { parts.append(L("그중 \(f.legacy)개는 이전 일별 합계만", "\(f.legacy) of them older daily sums only")) }
        if f.failed > 0 { parts.append(L("읽기 실패 \(f.failed)개", "\(f.failed) unreadable")) }
        return HStack(alignment: .firstTextBaseline) {
            Circle().fill(Color(nsColor: AIColors.color(f.provider))).frame(width: 7, height: 7)
            Text(who).lineLimit(1)
            Spacer()
            Text(parts.joined(separator: " · ")).font(.system(size: 10)).foregroundStyle(f.failed > 0 ? .orange : .secondary).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .help(f.folder.replacingOccurrences(of: AccountStore.home, with: "~"))
    }

    private var notes: some View {
        Text(L("기준: CLI 로그(앱 계정·앱 밖), 데스크톱 앱의 Code/agent 로그, 로그를 남기지 않는 앱 호출의 CLI 보고값. 웹과 데스크톱 앱의 일반 채팅은 관측할 수 없어 빠져요. 기록이 생기기 전 앱 호출은 복원할 수 없어요. 모델이 다른 토큰 합계는 처리량 비교일 뿐 작업량·품질·구독 가치가 아니에요.",
               "Counted: CLI logs (app accounts and outside), the desktop apps' Code/agent logs, and what the CLI reported for app calls that leave no log. Web and plain desktop chats cannot be seen. App calls before this record began cannot be restored. Token sums across models compare volume only, not work, quality or subscription value."))
            .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Export

    private func export(csv: Bool) {
        let panel = NSSavePanel()
        let stamp = ISO8601DateFormatter().string(from: Date()).prefix(10)
        panel.nameFieldStringValue = "ai-usage-\(stamp)." + (csv ? "csv" : "json")
        panel.allowedContentTypes = [csv ? .commaSeparatedText : .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? stats.export(csv: csv).write(to: url, options: .atomic)
    }

    // MARK: Words and numbers

    static func dimName(_ d: M.Dim) -> String {
        switch d {
        case .provider: return L("제공자", "Provider")
        case .account: return L("계정", "Account")
        case .model: return L("모델", "Model")
        case .project: return L("프로젝트", "Project")
        case .chat: return L("채팅", "Chat")
        case .session: return L("세션", "Session")
        case .device: return L("기기", "Mac")
        case .source: return L("출처", "Source")
        }
    }
    static func kindColor(_ k: M.Kind) -> Color {
        switch k {
        case .input: return Color(red: 0.30, green: 0.55, blue: 0.98)
        case .cacheWrite: return Color(red: 0.62, green: 0.48, blue: 0.96)
        case .cacheRead: return Color(nsColor: .systemGray)
        case .output: return Color(red: 0.96, green: 0.76, blue: 0.25)
        }
    }
    static func kindName(_ k: M.Kind) -> String {
        switch k {
        case .input: return L("캐시 아닌 입력 (U)", "Uncached input (U)")
        case .cacheWrite: return L("캐시 쓰기 (W)", "Cache writes (W)")
        case .cacheRead: return L("캐시 읽기 (R)", "Cache reads (R)")
        case .output: return L("출력 (O)", "Output (O)")
        }
    }
    static let cacheHelp = L("에이전트는 요청마다 지금까지의 대화 전체를 다시 보내요. 이미 처리한 앞부분은 캐시에서 읽어서 숫자는 크지만 새로 한 일은 아니에요.",
                             "Agents resend the whole conversation with every request. The part already processed is read from the cache: a big number, but no new work.")
    static func help(_ k: M.Kind) -> String {
        switch k {
        case .input: return L("캐시에 없던 입력: 내 메시지, 도구 결과, 처음 보낸 대화 기록.", "Input not in the cache: your messages, tool results, conversation sent the first time.")
        case .cacheWrite: return L("캐시에 새로 저장한 입력. Claude만 따로 보고해요(Codex·Gemini는 미제공).", "Input newly stored in the cache. Only Claude reports it (Codex and Gemini: not reported).")
        case .cacheRead: return cacheHelp
        case .output: return L("AI가 만든 토큰 전부: 답, thinking/reasoning, 도구 호출.", "Every token the AIs produced: answers, thinking/reasoning, tool calls.")
        }
    }
    static func percent(_ part: Int, of whole: Int) -> String {
        guard whole > 0 else { return "—" }
        let p = Double(part) / Double(whole) * 100
        if part == 0 { return "0%" }
        return p < 0.1 ? "<0.1%" : p < 10 ? String(format: "%.1f%%", p) : "\(Int(p.rounded()))%"
    }
    // 950, 12.3K, 7.58M, 1.48B: three digits at most.
    static func short(_ n: Int) -> String {
        let v = Double(n)
        for (size, mark) in [(1e9, "B"), (1e6, "M"), (1e3, "K")] where v >= size {
            let x = v / size
            return String(format: x >= 100 ? "%.0f" : x >= 10 ? "%.1f" : "%.2f", x) + mark
        }
        return "\(n)"
    }
    static func exact(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.locale = AppLanguage.current.locale
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
    static func dateText(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = AppLanguage.current.locale; f.setLocalizedDateFormatFromTemplate("yMMMd")
        return f.string(from: d)
    }
}

// MARK: - Small parts

private struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 2).lineLimit(1)
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.07)))
        }
    }
}

private struct Segments<Value: Hashable>: View {
    let options: [(String, Value)]
    @Binding var selection: Value
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                Button { selection = options[i].1 } label: {
                    Text(options[i].0).lineLimit(1).frame(maxWidth: .infinity, minHeight: 22)
                        .foregroundStyle(selection == options[i].1 ? Color.white : Color.primary)
                        .background(RoundedRectangle(cornerRadius: 4).fill(selection == options[i].1 ? Color.accentColor : Color.clear))
                }.buttonStyle(.plainHit).accessibilityAddTraits(selection == options[i].1 ? [.isSelected] : [])
            }
        }.padding(2).background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
    }
}

private struct FlowLegend: View {
    let items: [(String, AnyView)]
    var body: some View {
        // Up to four a line: a fixed grid keeps it readable at any width.
        let lines = stride(from: 0, to: items.count, by: 4).map { Array(items[$0 ..< min($0 + 4, items.count)]) }
        VStack(alignment: .leading, spacing: 3) {
            ForEach(lines.indices, id: \.self) { l in
                HStack(spacing: 10) {
                    ForEach(lines[l].indices, id: \.self) { i in
                        HStack(spacing: 4) { lines[l][i].1; Text(lines[l][i].0).lineLimit(1).truncationMode(.middle) }.frame(maxWidth: 200, alignment: .leading)
                    }
                }
            }
        }.font(.system(size: 10)).foregroundStyle(.secondary)
    }
}

// Diagonal lines: an account that is not known.
private struct Stripes: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        var x = -r.height
        while x < r.width {
            p.move(to: CGPoint(x: r.minX + x, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX + x + r.height, y: r.minY))
            x += 4
        }
        return p
    }
}
