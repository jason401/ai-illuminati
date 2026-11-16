import Foundation
import AIAccounts

// Token sums from your other Macs, through the folder chats from other Macs use (iCloud Drive by default), the way
// AI Face shares its History: each Mac writes only its own file and only reads the others, so nothing is merged into
// anything and syncing again never adds up twice.
//   <folder>/token-usage/<deviceID>.json   this Mac's whole ledger (TokenEntry sums with the account's name, the model,
//                                          session id and working folder; no chat text), with a revision
// A file is written whole (atomic) and replaces that Mac's previous copy, so a correction (a fixed reader counting
// less) goes to every Mac. One that does not decode whole (half synced, written by a newer app) is skipped and the last
// whole copy (kept in token-usage-devices.json, support folder) is shown, so a slow iCloud never empties a Mac.
// Accounts have other ids on each Mac: the app matches them by provider and name (TokenEntry.accountName).
public struct TokenDevice: Equatable {
    public let id: String
    public let name: String
    public let writtenAt: Date
    public let revision: Int
    public let entries: [TokenEntry]   // accountID nil; accountName says which account

    public init(id: String, name: String, writtenAt: Date, revision: Int, entries: [TokenEntry]) {
        self.id = id; self.name = name; self.writtenAt = writtenAt; self.revision = revision; self.entries = entries
    }
}

public enum TokenSync {
    static let version = 2
    private static let lock = NSLock()

    private struct Entry: Codable, Equatable {
        var p: String          // provider
        var a: String?         // account name; nil: no account (outside the app, Gemini)
        var o: String?         // origin
        var s: String          // source
        var t: Int             // start, seconds since 1970
        var h: Bool            // hourly
        var m: String?
        var se: String?
        var pr: String?
        var k: String?
        var c: TokenCounts
        var order: String { [p, a ?? "", se ?? "", m ?? "", s, k ?? "", pr ?? ""].joined(separator: "\u{1}") }
    }
    private struct File: Codable {
        var version: Int
        var id: String
        var name: String
        var writtenAt: Date
        var revision: Int?
        var entries: [Entry]?
        var shares: [OldShare]?      // version 1: daily sums per account
    }
    private struct OldShare: Codable {
        var provider: String
        var name: String
        var outside: Bool
        var origin: String?
        var days: [String: TokenCounts]
    }
    static var cacheFile: URL { URL(fileURLWithPath: AccountStore.supportDir + "/token-usage-devices.json") }

    // Writes this Mac's file (only when the sums changed) and reads every other Mac's. `mine` carries account names
    // (accountName). Blocking: call it off the main thread. Returns the other Macs, each its last whole copy.
    public static func exchange(_ mine: [TokenEntry], folder: URL, deviceID: String, deviceName: String) -> [TokenDevice] {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        let dir = folder.appendingPathComponent("token-usage")
        var cache = loadCache()
        guard fm.fileExists(atPath: folder.deletingLastPathComponent().path) else { return devices(cache) }   // iCloud Drive off
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let own = dir.appendingPathComponent(deviceID + ".json")
        let entries = mine.map { e in
            Entry(p: e.provider.rawValue, a: e.accountName, o: e.origin?.rawValue, s: e.source.rawValue, t: Int(e.start.timeIntervalSince1970),
                  h: e.hourly, m: e.model, se: e.session, pr: e.project, k: e.kind, c: e.counts)
        }.sorted { a, b in a.t != b.t ? a.t < b.t : a.order < b.order }   // one order, so an unchanged ledger is not written again
        let previous = (try? Data(contentsOf: own)).flatMap { try? decoder.decode(File.self, from: $0) }
        if previous?.entries != entries || previous?.name != deviceName || previous?.version != version,
           let data = try? encoder.encode(File(version: version, id: deviceID, name: deviceName, writtenAt: Date(),
                                               revision: (previous?.revision ?? 0) + 1, entries: entries, shares: nil)) {
            try? data.write(to: own, options: .atomic)
        }
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return devices(cache) }
        var seen: Set<String> = []
        for entry in names {
            // Not downloaded yet: iCloud keeps a ".<name>.icloud" stand-in.
            let placeholder = entry.hasPrefix(".") && entry.hasSuffix(".json.icloud")
            let name = placeholder ? String(entry.dropFirst().dropLast(".icloud".count)) : entry
            guard name.hasSuffix(".json"), !name.hasPrefix("."), !name.contains(".tmp") else { continue }
            let id = String(name.dropLast(5))
            guard id != deviceID, !id.isEmpty else { continue }
            seen.insert(id)
            let file = dir.appendingPathComponent(name)
            try? fm.startDownloadingUbiquitousItem(at: file)
            if placeholder { continue }
            guard let data = try? Data(contentsOf: file), let copy = try? decoder.decode(File.self, from: data),
                  copy.version <= version, copy.id == id else { continue }
            // The newer copy wins: a later revision, or a later write (that Mac lost its own file and counts again).
            if let old = cache[id], (copy.revision ?? 0) <= (old.revision ?? 0) && copy.writtenAt <= old.writtenAt { continue }
            cache[id] = copy
        }
        // A Mac whose file was removed ("remove this Mac's copies") leaves; one only listed, not read yet, stays.
        cache = cache.filter { seen.contains($0.key) }
        if let data = try? encoder.encode(Array(cache.values)) {
            try? fm.createDirectory(atPath: AccountStore.supportDir, withIntermediateDirectories: true)
            try? data.write(to: cacheFile, options: .atomic)
        }
        return devices(cache)
    }

    // The other Macs as last read, without touching the shared folder (sync turned off: nothing; the app decides).
    public static func cached() -> [TokenDevice] {
        lock.lock(); defer { lock.unlock() }
        return devices(loadCache())
    }

    // Removes this Mac's file from the shared folder.
    public static func removeMine(folder: URL, deviceID: String) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("token-usage/" + deviceID + ".json"))
    }

    private static func loadCache() -> [String: File] {
        let list = (try? Data(contentsOf: cacheFile)).flatMap { try? decoder.decode([File].self, from: $0) } ?? []
        return Dictionary(list.map { ($0.id, $0) }) { a, b in a.writtenAt > b.writtenAt ? a : b }
    }

    private static func devices(_ cache: [String: File]) -> [TokenDevice] {
        cache.values.map { f in
            var entries: [TokenEntry] = (f.entries ?? []).compactMap { e in
                guard let p = Account.Provider(rawValue: e.p) else { return nil }
                return TokenEntry(provider: p, accountID: nil, accountName: e.a, folder: "", origin: e.o.flatMap { TokenEntry.Origin(rawValue: $0) },
                                  source: TokenEntry.Source(rawValue: e.s) ?? .log, start: Date(timeIntervalSince1970: Double(e.t)), hourly: e.h,
                                  model: e.m, session: e.se, project: e.pr, kind: e.k, counts: e.c)
            }
            // Version 1: daily sums only, as legacy.
            for s in f.shares ?? [] {
                guard let p = Account.Provider(rawValue: s.provider) else { continue }
                for (day, c) in s.days {
                    guard let start = dayFormat.date(from: day) else { continue }
                    entries.append(TokenEntry(provider: p, accountID: nil, accountName: s.outside ? nil : s.name, folder: "",
                                              origin: s.origin.flatMap { TokenEntry.Origin(rawValue: $0) }, source: .legacy, start: start,
                                              hourly: false, model: nil, session: nil, project: nil, kind: nil, counts: c))
                }
            }
            return TokenDevice(id: f.id, name: f.name, writtenAt: f.writtenAt, revision: f.revision ?? 0, entries: entries)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = .sortedKeys; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
