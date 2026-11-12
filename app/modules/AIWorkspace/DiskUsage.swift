import Foundation

// How much disk a file or folder takes, read from file metadata only (lstat): cloud-only files are not downloaded,
// symbolic links are not followed, a file with several hard links counts once. Backup clean-up counts what it frees
// with it; the app's ChatStorage adds up each chat's parts with it.
public enum DiskUsage {
    public struct Size: Equatable {
        public var allocated: Int64 = 0   // disk blocks used
        public var logical: Int64 = 0     // bytes in the files
        public var files = 0
        public var unreadable = 0         // entries that could not be read (the sum may be low)
        public init(allocated: Int64 = 0, logical: Int64 = 0, files: Int = 0, unreadable: Int = 0) {
            self.allocated = allocated; self.logical = logical; self.files = files; self.unreadable = unreadable
        }
        public static func + (a: Size, b: Size) -> Size {
            Size(allocated: a.allocated + b.allocated, logical: a.logical + b.logical, files: a.files + b.files, unreadable: a.unreadable + b.unreadable)
        }
        public static func += (a: inout Size, b: Size) { a = a + b }
    }

    public struct FileID: Hashable { var device: Int32; var inode: UInt64 }
    // The size of a file or folder. `seen` keeps hard links counted once across calls.
    public static func of(_ url: URL, seen: inout Set<FileID>) -> Size {
        var result = Size()
        func add(_ path: String) -> Bool {   // true: a directory to go into
            var info = stat()
            guard lstat(path, &info) == 0 else { result.unreadable += 1; return false }
            let type = info.st_mode & S_IFMT
            if info.st_nlink > 1, type != S_IFDIR, !seen.insert(FileID(device: info.st_dev, inode: UInt64(info.st_ino))).inserted { return false }
            result.allocated += Int64(info.st_blocks) * 512
            if type == S_IFREG { result.logical += Int64(info.st_size); result.files += 1 }
            return type == S_IFDIR
        }
        guard add(url.path) else { return result }
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in result.unreadable += 1; return true }) else { return result }
        for case let file as URL in walker {
            if !add(file.path), (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) != nil { walker.skipDescendants() }
        }
        return result
    }
    public static func of(_ url: URL) -> Size { var seen = Set<FileID>(); return of(url, seen: &seen) }
}
