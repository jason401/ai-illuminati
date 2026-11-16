import Foundation
import AIAccounts
import AIRuntime
import AILocalization

/// The Usage window's numbers (TokenStatsModel), from made-up sums: the summary, the chart's columns, the table's rows
/// with "the rest", and the CSV export agree under the same filters; what is not known is named so, never guessed.
func testTokenStats() {
    let home = AccountStore.home
    let room = UUID()
    let accounts = [Account(id: "a-claude", provider: .claude, name: "School"), Account(id: "a-codex", provider: .codex, name: "Personal")]
    let iso = ISO8601DateFormatter()
    let t1 = iso.date(from: "2026-03-10T09:00:00Z")!, t2 = iso.date(from: "2026-03-10T23:00:00Z")!, t3 = iso.date(from: "2026-03-12T05:00:00Z")!
    func entry(_ p: Account.Provider, _ account: String?, _ start: Date, hourly: Bool = true, source: TokenEntry.Source = .log, model: String? = nil,
               session: String? = nil, project: String? = nil, origin: TokenEntry.Origin? = nil, kind: String? = nil, _ c: TokenCounts) -> TokenEntry {
        TokenEntry(provider: p, accountID: account, folder: "/f", origin: origin, source: source, start: start, hourly: hourly,
                   model: model, session: session, project: project, kind: kind, counts: c)
    }
    try? FileManager.default.createDirectory(atPath: home + "/proj-a/.git", withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(atPath: home + "/other/proj-a/.git", withIntermediateDirectories: true)
    let local = TokenStatsModel.named([
        entry(.claude, "a-claude", t1, model: "opus", session: "s1", project: home + "/.ai-illuminati/rooms/\(room.uuidString)/x",
              TokenCounts(input: 1, cacheWrite: 10, cacheRead: 100, output: 5)),
        entry(.claude, "a-claude", t2, model: "opus", session: "s1", project: home + "/proj-a/sub", TokenCounts(input: 2, cacheWrite: 20, cacheRead: 200, output: 7)),
        entry(.codex, "a-codex", t3, model: "gpt", session: "x1", project: home + "/other/proj-a", TokenCounts(input: 30, cacheRead: 300, output: 9, reasoning: 4)),
        entry(.claude, nil, t3, session: "o1", origin: .terminal, TokenCounts(input: 4, output: 1)),
        entry(.gemini, nil, t1, session: "g1", TokenCounts(input: 50, cacheRead: 5, output: 6)),
        entry(.claude, "a-claude", t1, source: .app, model: "haiku", project: home + "/.ai-illuminati/chat", kind: "routing", TokenCounts(input: 3, output: 2)),
        entry(.codex, "a-codex", Calendar.current.startOfDay(for: t1), hourly: false, source: .legacy, TokenCounts(input: 8, output: 8))], accounts)
    // Another Mac: the same Claude session (its log copied over) and one of its own.
    var copied = local[0]; copied.accountID = nil
    var own = entry(.claude, nil, t3, session: "s7", TokenCounts(output: 40)); own.accountName = "School"
    let peer = TokenDevice(id: "mac-b", name: "Mac mini", writtenAt: Date(), revision: 3, entries: [copied, own])
    let built = TokenStatsModel.build(local, peers: [peer], chats: [room: (title: "Paper chat", project: home + "/proj-a")])
    let stats = TokenStatsModel()
    stats.facts = built.facts; stats.labels = built.labels; stats.paths = built.paths
    stats.span = .custom
    stats.customStart = iso.date(from: "2026-03-09T12:00:00Z")!; stats.customEnd = iso.date(from: "2026-03-13T12:00:00Z")!
    expect(built.facts.count == 8, "a session copied to another Mac counts once: \(built.facts.count)")

    // Every way of counting the period gives the same total.
    for metric in TokenStatsModel.Metric.allCases {
        stats.metric = metric
        let sum = stats.current.reduce(TokenCounts()) { $0 + $1.counts }
        let columns = stats.columnSums(stats.current).reduce(TokenCounts()) { $0 + $1 }
        expect(columns == sum, "\(metric): the chart's columns add up to the summary: \(columns) \(sum)")
        for d in TokenStatsModel.Dim.allCases {
            let rows = stats.rows(stats.current, by: d)
            let rest = rows.dropFirst(2).reduce(TokenCounts()) { $0 + $1.counts }   // "Top 2 + the rest"
            expect(rows.prefix(2).reduce(TokenCounts()) { $0 + $1.counts } + rest == sum, "\(metric) \(d): the rows and the rest add up to the summary")
        }
    }
    stats.metric = .fresh
    let sum = stats.current.reduce(TokenCounts()) { $0 + $1.counts }
    expect(stats.measure(sum) == sum.input + sum.cacheWrite + sum.output && sum.output == 78 && sum.reasoning == 4,
           "the default measure is U+W+O; reasoning is a part of output, never added: \(sum)")
    let csv = String(decoding: stats.export(csv: true), as: UTF8.self)
    let total = csv.split(separator: "\n").last.map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) } ?? []
    expect(total.count == 10 && total[2] == "\(sum.input)" && total[5] == "\(sum.output)" && total[8] == "\(sum.fresh)" && total[9] == "\(sum.total)",
           "the CSV's total is the summary's: \(total)")
    expect(csv.contains("# time_zone: ") && csv.contains("# measure: fresh") && csv.contains("# period_start: "), "the CSV says what it counted")
    let json = try? JSONSerialization.jsonObject(with: stats.export(csv: false)) as? [String: Any]
    expect((json?["rows"] as? [[String: Any]])?.count == 8 && (json?["meta"] as? [String: Any])?["unit"] as? String == "tokens", "the JSON has every sum and what it counted")

    // Names: a chat by its title and its linked project, a worktree's repository, two projects of one name told apart,
    // unknown accounts, Gemini's shared log, older sums, app calls by what they were for, the other Mac.
    func names(_ d: TokenStatsModel.Dim) -> [String] { stats.rows(stats.current, by: d).map(\.name) }
    expect(names(.chat).contains("Paper chat") && names(.chat).contains(L("터미널 세션", "Terminal sessions")), "chats by title; Terminal sessions apart: \(names(.chat))")
    let projects = names(.project)
    expect(projects.filter { $0.hasPrefix("proj-a — ") }.count == 2, "two projects of one name are told apart by their folder: \(projects)")
    expect(stats.rows(stats.current, by: .project).first { $0.id == home + "/proj-a" }?.counts.output == 5 + 7,
           "a chat's tokens go to its linked project, a subfolder to its repository")
    expect(names(.account).contains(L("Claude 계정 미상 (터미널)", "Claude, account unknown (Terminal)")) && names(.account).contains(L("Gemini 계정 미상", "Gemini, account unknown"))
           && stats.rows(stats.current, by: .account).first { $0.id == "claude#School" }?.counts.output == 5 + 7 + 2 + 40,
           "accounts match across Macs by name; unknown ones are named so: \(names(.account))")
    expect(names(.model).contains(L("분류 정보 없음 (이전 집계)", "Not classified (older sums)")) && names(.model).contains(L("모델 미상", "Model unknown")),
           "older sums and unknown models are named, not guessed: \(names(.model))")
    expect(names(.source).contains(L("앱 호출 · 라우팅", "App call · Routing")) && names(.device).contains("Mac mini"), "sources and Macs: \(names(.source)) \(names(.device))")

    // Filters: a Mac, a chip, a picked column, an hour column without the older day sums.
    stats.device = ""
    expect(stats.current.allSatisfy { $0.key(.device) == "" } && stats.current.count == 7, "this Mac only")
    stats.device = nil
    stats.filters[.provider] = "codex"
    expect(stats.current.reduce(0) { $0 + $1.counts.output } == 17, "a provider chip")
    stats.filters = [:]
    stats.span = .day
    stats.back = 0
    while !stats.period.contains(t1) && stats.back < 5000 { stats.back += 1 }   // the day of t1, as the window counts days
    expect(stats.period.contains(t1) && stats.current.contains { $0.legacy }, "the day of t1 has the older day sum: \(stats.period)")
    let hours = stats.columnSums(stats.current).reduce(TokenCounts()) { $0 + $1 }
    let whole = stats.current.reduce(TokenCounts()) { $0 + $1.counts }
    expect(stats.step == .hour && stats.columns.count >= 23 && hours.output == whole.output - (stats.current.contains { !$0.hourly } ? 8 : 0),
           "an hour chart leaves out day-only older sums (which stay in the total): \(hours) \(whole)")
    stats.picked = stats.columns.first { $0.start <= t1 && t1 < $0.end }
    expect(stats.current.allSatisfy(\.hourly) && stats.current.reduce(0) { $0 + $1.counts.output } == 5 + 6 + 2,
           "a picked hour counts only that hour: \(String(describing: stats.picked)) \(stats.current.map(\.counts.output))")
    // Patterns: two accounts of one provider differ, the Settings order decides (not the ranking), other Macs' names
    // follow by name, and an unknown account is always "/".
    let mine = accounts + [Account(id: "a-claude2", provider: .claude, name: "Home")]
    let hatched = TokenStatsModel.hatches(mine, keys: ["claude#Zed", "claude#Away", "claude#Home", "codex#Personal", "claude#?terminal"])
    expect(hatched["claude#School"] == .solid && hatched["claude#Home"] == .backslash && hatched["claude#Away"] == .grid && hatched["claude#Zed"] == .horizontal
           && hatched["codex#Personal"] == .solid, "patterns follow the Settings order, then other names by name: \(hatched)")
    expect(TokenStatsModel.hatches(mine, keys: ["claude#Home"])["claude#School"] == .solid && TokenStatsModel.hatches(mine, keys: [])["claude#Home"] == .backslash,
           "a pattern stays when the period or ranking changes")
    expect(TokenStatsModel.hatch("claude#?terminal", in: hatched) == .slash && TokenStatsModel.hatch("codex#?", in: [:]) == .slash
           && !hatched.values.contains(.slash), "an unknown account is always \"/\", a known one never")
    print("PASS: Usage window: summary = chart = table with the rest = export; chats, projects, worktrees, unknown accounts, older sums, Macs, filters")
}
