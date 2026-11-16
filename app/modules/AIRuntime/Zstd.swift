import Foundation

// Reads Zstandard (.zst) files, as Codex compresses old sessions (archived_sessions/*.jsonl.zst). macOS has no zstd
// (its libarchive is built without it and Compression has no zstd), and the app adds no dependencies: this is a
// decoder of RFC 8878 frames without dictionaries (all Codex writes). The checksum is not verified: a broken file
// gives broken JSON lines, which the reader skips.
enum Zstd {
    struct Failure: Error {}

    static func decode(_ data: Data) throws -> Data {
        var input = [UInt8](data)
        let count = input.count
        input += [UInt8](repeating: 0, count: 16)   // a bit reader loads 8 bytes at a time
        return try input.withUnsafeBufferPointer { buf -> Data in
            let p = buf.baseAddress!
            var out: [UInt8] = []
            var at = 0
            while at + 4 <= count {
                let magic = le32(p, at)
                if magic & 0xFFFF_FFF0 == 0x184D_2A50 {   // skippable frame
                    guard at + 8 <= count else { throw Failure() }
                    at += 8 + Int(le32(p, at + 4))
                    continue
                }
                guard magic == 0xFD2F_B528 else { throw Failure() }
                var frame = Frame()
                at = try frame.read(p, at + 4, count, into: &out)
            }
            return Data(out)
        }
    }

    fileprivate static func le32(_ p: UnsafePointer<UInt8>, _ at: Int) -> UInt32 {
        UInt32(p[at]) | UInt32(p[at + 1]) << 8 | UInt32(p[at + 2]) << 16 | UInt32(p[at + 3]) << 24
    }
    fileprivate static func le64(_ p: UnsafePointer<UInt8>, _ at: Int) -> UInt64 {
        UInt64(littleEndian: UnsafeRawPointer(p + at).loadUnaligned(as: UInt64.self))
    }

    // One frame: its blocks share the window (earlier output), the repeat offsets and the last tables.
    private struct Frame {
        var reps = [1, 4, 8]
        var huffman: Huffman?
        var ll: FSE?, of: FSE?, ml: FSE?

        mutating func read(_ p: UnsafePointer<UInt8>, _ start: Int, _ count: Int, into out: inout [UInt8]) throws -> Int {
            var at = start
            guard at < count else { throw Failure() }
            let descriptor = p[at]; at += 1
            let fcsFlag = Int(descriptor >> 6), single = descriptor & 0x20 != 0, checksum = descriptor & 0x04 != 0
            guard descriptor & 0x08 == 0 else { throw Failure() }
            if !single { at += 1 }
            let dictBytes = [0, 1, 2, 4][Int(descriptor & 3)]
            var dict = 0
            for i in 0..<dictBytes { dict |= Int(p[at + i]) << (8 * i) }
            guard dict == 0 else { throw Failure() }   // dictionaries: not used by Codex
            at += dictBytes
            let fcsBytes = [single ? 1 : 0, 2, 4, 8][fcsFlag]
            var size = 0
            for i in 0..<fcsBytes { size |= Int(p[at + i]) << (8 * i) }
            if fcsBytes == 2 { size += 256 }
            at += fcsBytes
            if size > 0 && size < 1 << 31 { out.reserveCapacity(out.count + size) }
            let frameStart = out.count
            while true {
                guard at + 3 <= count else { throw Failure() }
                let header = Int(p[at]) | Int(p[at + 1]) << 8 | Int(p[at + 2]) << 16
                at += 3
                let last = header & 1 != 0, type = (header >> 1) & 3, length = header >> 3
                switch type {
                case 0:
                    guard at + length <= count else { throw Failure() }
                    out.append(contentsOf: UnsafeBufferPointer(start: p + at, count: length))
                    at += length
                case 1:
                    guard at < count else { throw Failure() }
                    out.append(contentsOf: repeatElement(p[at], count: length))
                    at += 1
                case 2:
                    guard at + length <= count else { throw Failure() }
                    try block(p, at, at + length, frameStart: frameStart, into: &out)
                    at += length
                default: throw Failure()
                }
                if last { break }
            }
            return at + (checksum ? 4 : 0)
        }

        private mutating func block(_ p: UnsafePointer<UInt8>, _ start: Int, _ end: Int, frameStart: Int, into out: inout [UInt8]) throws {
            var at = start
            let literals = try readLiterals(p, &at, end)
            // Sequences
            guard at < end else { throw Failure() }
            var n = Int(p[at]); at += 1
            if n == 0 { out.append(contentsOf: literals); return }
            if n >= 128 {
                if n < 255 { n = (n - 128) << 8 + Int(p[at]); at += 1 }
                else { n = Int(p[at]) + Int(p[at + 1]) << 8 + 0x7F00; at += 2 }
            }
            let modes = p[at]; at += 1
            ll = try table(p, &at, end, mode: Int(modes >> 6), previous: ll, predefined: FSE.ll, maxLog: 9)
            of = try table(p, &at, end, mode: Int(modes >> 4) & 3, previous: of, predefined: FSE.of, maxLog: 8)
            ml = try table(p, &at, end, mode: Int(modes >> 2) & 3, previous: ml, predefined: FSE.ml, maxLog: 9)
            guard let ll, let of, let ml else { throw Failure() }
            var bits = try BackBits(p, at, end)
            var sLL = bits.read(ll.log), sOF = bits.read(of.log), sML = bits.read(ml.log)
            var lit = 0
            for i in 0..<n {
                let ofCode = Int(of.symbol[sOF]), mlCode = Int(ml.symbol[sML]), llCode = Int(ll.symbol[sLL])
                guard ofCode <= 31, mlCode < Self.mlBase.count, llCode < Self.llBase.count else { throw Failure() }
                let ofValue = 1 << ofCode + bits.read(ofCode)
                let matchLength = Self.mlBase[mlCode] + bits.read(Self.mlBits[mlCode])
                let literalLength = Self.llBase[llCode] + bits.read(Self.llBits[llCode])
                var offset: Int
                if ofValue > 3 {
                    offset = ofValue - 3
                    reps = [offset, reps[0], reps[1]]
                } else {
                    let index = ofValue + (literalLength == 0 ? 1 : 0)
                    switch index {
                    case 1: offset = reps[0]
                    case 2: offset = reps[1]; reps = [offset, reps[0], reps[2]]
                    case 3: offset = reps[2]; reps = [offset, reps[0], reps[1]]
                    default: offset = reps[0] - 1; reps = [offset, reps[0], reps[1]]
                    }
                }
                if i < n - 1 {
                    sLL = ll.base[sLL] + bits.read(Int(ll.bits[sLL]))
                    sML = ml.base[sML] + bits.read(Int(ml.bits[sML]))
                    sOF = of.base[sOF] + bits.read(Int(of.bits[sOF]))
                }
                guard lit + literalLength <= literals.count else { throw Failure() }
                out.append(contentsOf: literals[lit ..< lit + literalLength])
                lit += literalLength
                guard offset > 0, offset <= out.count - frameStart else { throw Failure() }
                // Copied in place: appending a slice of `out` to itself would copy the whole output each time.
                let from = out.count - offset, to = out.count
                out.append(contentsOf: repeatElement(0, count: matchLength))
                out.withUnsafeMutableBufferPointer { b in
                    let base = b.baseAddress!
                    if offset >= matchLength { memcpy(base + to, base + from, matchLength) }
                    else { for k in 0..<matchLength { base[to + k] = base[from + k] } }   // overlapping: byte by byte
                }
            }
            out.append(contentsOf: literals[lit...])
        }

        private mutating func readLiterals(_ p: UnsafePointer<UInt8>, _ at: inout Int, _ end: Int) throws -> [UInt8] {
            guard at < end else { throw Failure() }
            let b0 = Int(p[at]), type = b0 & 3, format = (b0 >> 2) & 3
            if type < 2 {
                var size: Int
                switch format {
                case 0, 2: size = b0 >> 3; at += 1
                case 1: size = b0 >> 4 + Int(p[at + 1]) << 4; at += 2
                default: size = b0 >> 4 + Int(p[at + 1]) << 4 + Int(p[at + 2]) << 12; at += 3
                }
                if type == 0 {
                    guard at + size <= end else { throw Failure() }
                    defer { at += size }
                    return Array(UnsafeBufferPointer(start: p + at, count: size))
                }
                guard at < end else { throw Failure() }
                defer { at += 1 }
                return [UInt8](repeating: p[at], count: size)
            }
            let streams = format == 0 ? 1 : 4
            let headerBytes = [3, 3, 4, 5][format], fieldBits = [10, 10, 14, 18][format]
            var header = 0
            for i in 0..<headerBytes { header |= Int(p[at + i]) << (8 * i) }
            let mask = 1 << fieldBits - 1
            let regenerated = (header >> 4) & mask, compressed = (header >> (4 + fieldBits)) & mask
            at += headerBytes
            let stop = at + compressed
            guard stop <= end else { throw Failure() }
            var cursor = at
            if type == 2 { huffman = try Huffman.read(p, &cursor, stop) }
            guard let huffman else { throw Failure() }
            var result = [UInt8](repeating: 0, count: regenerated)
            if streams == 1 {
                try huffman.decode(p, cursor, stop, into: &result, 0, regenerated)
            } else {
                guard cursor + 6 <= stop else { throw Failure() }
                let s1 = Int(p[cursor]) | Int(p[cursor + 1]) << 8, s2 = Int(p[cursor + 2]) | Int(p[cursor + 3]) << 8
                let s3 = Int(p[cursor + 4]) | Int(p[cursor + 5]) << 8
                let a = cursor + 6, b = a + s1, c = b + s2, d = c + s3
                guard d <= stop else { throw Failure() }
                let part = (regenerated + 3) / 4
                guard part * 3 <= regenerated else { throw Failure() }
                try huffman.decode(p, a, b, into: &result, 0, part)
                try huffman.decode(p, b, c, into: &result, part, part)
                try huffman.decode(p, c, d, into: &result, 2 * part, part)
                try huffman.decode(p, d, stop, into: &result, 3 * part, regenerated - 3 * part)
            }
            at = stop
            return result
        }

        private func table(_ p: UnsafePointer<UInt8>, _ at: inout Int, _ end: Int, mode: Int, previous: FSE?, predefined: FSE, maxLog: Int) throws -> FSE {
            switch mode {
            case 0: return predefined
            case 1:
                guard at < end else { throw Failure() }
                defer { at += 1 }
                return FSE(rle: p[at])
            case 2: return try FSE.read(p, &at, end, maxLog: maxLog, maxSymbol: 255)
            default:
                guard let previous else { throw Failure() }
                return previous
            }
        }

        static let llBase = Array(0..<16) + [16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536]
        static let llBits = [Int](repeating: 0, count: 16) + [1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
        static let mlBase = Array(3..<35) + [35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051, 4099, 8195, 16387, 32771, 65539]
        static let mlBits = [Int](repeating: 0, count: 32) + [1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
    }

    // A bitstream read backward from its end (Huffman and FSE streams): the last byte's highest 1 marks the start.
    // Past the beginning it reads zeros; `overflowed` says so.
    private struct BackBits {
        let p: UnsafePointer<UInt8>
        let start: Int
        var pos: Int   // bits left

        init(_ p: UnsafePointer<UInt8>, _ start: Int, _ end: Int) throws {
            guard end > start, p[end - 1] != 0 else { throw Failure() }
            self.p = p; self.start = start
            pos = (end - start - 1) * 8 + (7 - p[end - 1].leadingZeroBitCount)
        }
        var overflowed: Bool { pos < 0 }

        func peek(_ n: Int) -> Int {
            guard n > 0 else { return 0 }
            let lo = pos - n
            if lo >= 0 { return Int((Zstd.le64(p, start + lo >> 3) >> UInt64(lo & 7)) & (1 << UInt64(n) - 1)) }
            guard pos > 0 else { return 0 }
            return Int(Zstd.le64(p, start) & (1 << UInt64(pos) - 1)) << -lo
        }
        mutating func read(_ n: Int) -> Int { let v = peek(n); pos -= n; return v }
    }

    // A finite state entropy table: per state its symbol, the bits to read and the next state's base.
    private struct FSE {
        var log: Int
        var symbol: [UInt8]
        var bits: [UInt8]
        var base: [Int]

        init(rle: UInt8) { log = 0; symbol = [rle]; bits = [0]; base = [0] }

        init(counts: [Int], log: Int) throws {
            let size = 1 << log
            self.log = log
            symbol = [UInt8](repeating: 0, count: size); bits = [UInt8](repeating: 0, count: size); base = [Int](repeating: 0, count: size)
            var next = [Int](repeating: 0, count: counts.count)
            var high = size - 1
            for (s, c) in counts.enumerated() {
                if c == -1 { symbol[high] = UInt8(s); high -= 1; next[s] = 1 } else { next[s] = c }
            }
            var position = 0
            let step = size >> 1 + size >> 3 + 3, mask = size - 1
            for (s, c) in counts.enumerated() where c > 0 {
                for _ in 0..<c {
                    symbol[position] = UInt8(s)
                    repeat { position = (position + step) & mask } while position > high
                }
            }
            guard position == 0 else { throw Failure() }
            for u in 0..<size {
                let s = Int(symbol[u])
                let state = next[s]; next[s] += 1
                guard state > 0 else { throw Failure() }
                let n = log - (Int.bitWidth - 1 - state.leadingZeroBitCount)
                bits[u] = UInt8(n)
                base[u] = state << n - size
            }
        }

        // The table description: an accuracy log, then each symbol's count (RFC 8878 4.1.1).
        static func read(_ p: UnsafePointer<UInt8>, _ at: inout Int, _ end: Int, maxLog: Int, maxSymbol: Int) throws -> FSE {
            var bit = 0
            func peek(_ n: Int) -> Int { Int((le64(p, at + bit >> 3) >> UInt64(bit & 7)) & (1 << UInt64(n) - 1)) }
            let log = peek(4) + 5
            bit = 4
            guard log <= maxLog else { throw Failure() }
            var remaining = 1 << log + 1, threshold = 1 << log, nbBits = log + 1
            var counts: [Int] = []
            while remaining > 1 && counts.count <= maxSymbol {
                let max = 2 * threshold - 1 - remaining
                var count: Int
                let low = peek(nbBits - 1)
                if low < max { count = low; bit += nbBits - 1 }
                else {
                    count = peek(nbBits)
                    if count >= threshold { count -= max }
                    bit += nbBits
                }
                count -= 1
                remaining -= abs(count)
                counts.append(count)
                if count == 0 {
                    while true {
                        let repeats = peek(2); bit += 2
                        counts += [Int](repeating: 0, count: repeats)
                        if repeats < 3 { break }
                    }
                }
                while remaining < threshold && nbBits > 1 { nbBits -= 1; threshold >>= 1 }
                guard at + bit >> 3 <= end else { throw Failure() }
            }
            guard remaining == 1, counts.count <= maxSymbol + 1 else { throw Failure() }
            at += (bit + 7) >> 3
            return try FSE(counts: counts, log: log)
        }

        static let ll = try! FSE(counts: [4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1,
                                          -1, -1, -1, -1], log: 6)
        static let ml = try! FSE(counts: [1, 4, 3, 2, 2, 2, 2, 2, 2] + [Int](repeating: 1, count: 37) + [Int](repeating: -1, count: 7), log: 6)
        static let of = try! FSE(counts: [1, 1, 1, 1, 1, 1, 2, 2, 2] + [Int](repeating: 1, count: 15) + [Int](repeating: -1, count: 5), log: 5)
    }

    private struct Huffman {
        var maxBits: Int
        var symbol: [UInt8]
        var length: [UInt8]

        // The tree description: weights, FSE compressed (header < 128) or 4 bits each; the last weight is implied.
        static func read(_ p: UnsafePointer<UInt8>, _ at: inout Int, _ end: Int) throws -> Huffman {
            guard at < end else { throw Failure() }
            let header = Int(p[at]); at += 1
            var weights: [Int] = []
            if header >= 128 {
                let n = header - 127
                guard at + (n + 1) / 2 <= end else { throw Failure() }
                for i in 0..<n { let b = Int(p[at + i / 2]); weights.append(i % 2 == 0 ? b >> 4 : b & 15) }
                at += (n + 1) / 2
            } else {
                let stop = at + header
                guard stop <= end else { throw Failure() }
                var cursor = at
                let table = try FSE.read(p, &cursor, stop, maxLog: 6, maxSymbol: 255)
                var bits = try BackBits(p, cursor, stop)
                var s1 = bits.read(table.log), s2 = bits.read(table.log)
                while weights.count < 255 {
                    weights.append(Int(table.symbol[s1])); s1 = table.base[s1] + bits.read(Int(table.bits[s1]))
                    if bits.overflowed { weights.append(Int(table.symbol[s2])); break }
                    weights.append(Int(table.symbol[s2])); s2 = table.base[s2] + bits.read(Int(table.bits[s2]))
                    if bits.overflowed { weights.append(Int(table.symbol[s1])); break }
                }
                at = stop
            }
            var total = 0
            for w in weights where w > 0 { guard w <= 12 else { throw Failure() }; total += 1 << (w - 1) }
            guard total > 0 else { throw Failure() }
            let maxBits = Int.bitWidth - total.leadingZeroBitCount   // the next power of two above total
            let rest = 1 << maxBits - total
            guard rest > 0, rest & (rest - 1) == 0 else { throw Failure() }
            weights.append(Int.bitWidth - rest.leadingZeroBitCount)
            guard maxBits <= 11 else { throw Failure() }
            let size = 1 << maxBits
            var symbol = [UInt8](repeating: 0, count: size), length = [UInt8](repeating: 0, count: size)
            // Lower weights (longer codes) first, each symbol taking 2^(w-1) entries in symbol order.
            var next = 0
            for w in 1...maxBits {
                for (s, weight) in weights.enumerated() where weight == w {
                    let span = 1 << (w - 1)
                    guard next + span <= size else { throw Failure() }
                    for i in next ..< next + span { symbol[i] = UInt8(s); length[i] = UInt8(maxBits + 1 - w) }
                    next += span
                }
            }
            guard next == size else { throw Failure() }
            return Huffman(maxBits: maxBits, symbol: symbol, length: length)
        }

        func decode(_ p: UnsafePointer<UInt8>, _ start: Int, _ end: Int, into out: inout [UInt8], _ from: Int, _ count: Int) throws {
            var bits = try BackBits(p, start, end)
            for i in from ..< from + count {
                let v = bits.peek(maxBits)
                out[i] = symbol[v]
                bits.pos -= Int(length[v])
            }
            guard bits.pos >= 0 else { throw Failure() }
        }
    }
}
