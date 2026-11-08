import Foundation

/// Thin wrapper around a POSIX file descriptor with positional (pread/pwrite) I/O.
public final class RandomAccessFile {
    public enum Mode {
        case read
        case readWrite
        /// Create (or truncate) the file for writing.
        case create
    }

    public let url: URL
    public let fd: Int32

    public init(url: URL, mode: Mode) throws {
        self.url = url
        let flags: Int32
        switch mode {
        case .read: flags = O_RDONLY
        case .readWrite: flags = O_RDWR
        case .create: flags = O_RDWR | O_CREAT | O_TRUNC
        }
        fd = open(url.path, flags | O_CLOEXEC, 0o644)
        if fd < 0 {
            throw ZephyrError.lastPOSIX("open \(url.path)")
        }
    }

    deinit {
        close(fd)
    }

    public var size: UInt64 {
        var st = stat()
        guard fstat(fd, &st) == 0 else { return 0 }
        return UInt64(st.st_size)
    }

    /// Reads exactly `count` bytes at `offset`. Throws on a short read.
    public func read(at offset: UInt64, count: Int) throws -> Data {
        var data = Data(count: count)
        let got = try data.withUnsafeMutableBytes { buffer in
            try read(into: buffer.baseAddress!, at: offset, count: count)
        }
        guard got == count else {
            throw ZephyrError.invalidFormat("\(url.lastPathComponent): unexpected end of file at offset \(offset + UInt64(got))")
        }
        return data
    }

    /// Reads up to `count` bytes into `buffer`; returns the number of bytes read (short only at EOF).
    @discardableResult
    public func read(into buffer: UnsafeMutableRawPointer, at offset: UInt64, count: Int) throws -> Int {
        var done = 0
        while done < count {
            let n = pread(fd, buffer + done, count - done, off_t(offset) + off_t(done))
            if n < 0 {
                if errno == EINTR { continue }
                throw ZephyrError.lastPOSIX("read \(url.lastPathComponent)")
            }
            if n == 0 { break }
            done += n
        }
        return done
    }

    public func write(_ data: Data, at offset: UInt64) throws {
        try data.withUnsafeBytes { buffer in
            try write(buffer.baseAddress!, count: buffer.count, at: offset)
        }
    }

    public func write(_ buffer: UnsafeRawPointer, count: Int, at offset: UInt64) throws {
        var done = 0
        while done < count {
            let n = pwrite(fd, buffer + done, count - done, off_t(offset) + off_t(done))
            if n < 0 {
                if errno == EINTR { continue }
                throw ZephyrError.lastPOSIX("write \(url.lastPathComponent)")
            }
            done += n
        }
    }

    public func truncate(to size: UInt64) throws {
        if ftruncate(fd, off_t(size)) != 0 {
            throw ZephyrError.lastPOSIX("truncate \(url.lastPathComponent)")
        }
    }

    public func sync() {
        fsync(fd)
    }
}

extension FileManager {
    /// Creates (or replaces) a sparse file of the given size. On APFS no blocks are allocated.
    public func createSparseFile(at url: URL, size: UInt64) throws {
        if fileExists(atPath: url.path) {
            try removeItem(at: url)
        }
        let file = try RandomAccessFile(url: url, mode: .create)
        try file.truncate(to: size)
    }

    /// Copy-on-write clone (APFS clonefile). Instant and uses no extra space until blocks change.
    public func cloneItem(at source: URL, to destination: URL) throws {
        if fileExists(atPath: destination.path) {
            try removeItem(at: destination)
        }
        if clonefile(source.path, destination.path, 0) != 0 {
            // Not on APFS (or cross-volume): fall back to a regular copy.
            try copyItem(at: source, to: destination)
        }
    }

    /// Bytes actually allocated on disk (differs from the logical size for sparse files).
    public func allocatedSize(of url: URL) -> UInt64 {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return 0 }
        return UInt64(st.st_blocks) * 512
    }
}
