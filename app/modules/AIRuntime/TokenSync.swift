import Foundation
import AIAccounts

// Token sums from your other Macs, through the folder chats from other Macs use (iCloud Drive by default), the way
// AI Face shares its History: each Mac writes only its own file and only reads the others, so nothing is merged.
//   <folder>/token-usage/<deviceID>.json   this Mac's daily sums per account (TokenShare), no log text
// A file is written whole (atomic) and must decode whole: one half synced or written by a newer app is skipped and the
// last whole copy (kept in token-usage-devices.json, support folder) is shown, so a slow iCloud never empties a Mac.
// Accounts have other ids on each Mac, so the app matches them by provider and name.
public struct TokenShare: Equatable {
    public var provider: Account.Provider
    public var name: String                 // the account's name; outside the app: empty, `origin` says which program
    public var outside: Bool
    public var origin: TokenSource.Origin?
    public var days: [Date: TokenCounts]

    public init(provider: Account.Provider, name: String, outside: Bool, origin: TokenSource.Origin?, days: [Date: TokenCounts]) {
        self.provider = provider; self.name = name; self.outside = outside; self.origin = origin; self.days = days
    }
    // What stands for the same account on another Mac.
    public var key: String { provider.rawValue + (outside ? "#outside#" + (origin?.rawValue ?? "") : "#" + name) }
}

public struct TokenDevice: Equatable {
    public let id: String
    public let name: String
    public let writtenAt: Date
    public let shares: [TokenShare]
}

public enum TokenSync {
    static let version = 1
    private static let lock = NSLock()

    private struct Share: Codable, Equatable {
        var provider: String
        var name: String
        var outside: Bool
        var origin: String?
        var days: [String: TokenCounts]
    }
    private struct File: Codable {
        var version: Int
        var id: String
        var name: String
        var writtenAt: Date
        var shares: [Share]
    }
    static var cacheFile: URL { URL(fileURLWithPath: AccountStore.supportDir + "/token-usage-devices.json") }

    // Writes this Mac's file (only when the sums changed) and reads every other Mac's. Blocking: call it off the main
    // thread. Returns the other Macs, each its last whole copy.
    public static func exchange(_ mine: [TokenShare], folder: URL, deviceID: String, deviceName: String) -> [TokenDevice] {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        let dir = folder.appendingPathComponent("token-usage")
        var cache = loadCache()
        guard fm.fileExists(atPath: folder.deletingLastPathComponent().path) else { return devices(cache) }   // iCloud Drive off
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let own = dir.appendingPathComponent(deviceID + ".json")
        let shares = mine.map { Share(provider: $0.provider.rawValue, name: $0.name, outside: $0.outside, origin: $0.origin?.rawValue,
                                      days: Dictionary(uniqueKeysWithValues: $0.days.map { (dayFormat.string(from: $0.key), $0.value) })) }
        let previous = (try? Data(contentsOf: own)).flatMap { try? decoder.decode(File.self, from: $0) }
        if previous?.shares != shares || previous?.name != deviceName,
           let data = try? encoder.encode(File(version: version, id: deviceID, name: deviceName, writtenAt: Date(), shares: shares)) {
            try? data.write(to: own, options: .atomic)
        }
        guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { return devices(cache) }
        var seen: Set<String> = []
        for entry in entries {
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
            if let old = cache[id], old.writtenAt > copy.writtenAt { continue }
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
            TokenDevice(id: f.id, name: f.name, writtenAt: f.writtenAt, shares: f.shares.compactMap { s in
                Account.Provider(rawValue: s.provider).map {
                    TokenShare(provider: $0, name: s.name, outside: s.outside, origin: s.origin.flatMap { TokenSource.Origin(rawValue: $0) },
                               days: Dictionary(s.days.compactMap { k, v in dayFormat.date(from: k).map { ($0, v) } }, uniquingKeysWith: +))
                }
            })
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
