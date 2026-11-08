import Foundation

/// Minimal ADB protocol client (the device-side wire protocol spoken by adbd), usable over any
/// stream file descriptor: a vsock connection to the guest, or a TCP socket.
///
/// The guest is booted with `androidboot.insecure_adb=1`, so no RSA authentication is needed.
public final class ADBClient {
    enum Command: UInt32 {
        case cnxn = 0x4E58_4E43
        case auth = 0x4854_5541
        case open = 0x4E45_504F
        case okay = 0x5941_4B4F
        case clse = 0x4553_4C43
        case wrte = 0x4554_5257
    }

    struct Message {
        var command: UInt32
        var arg0: UInt32
        var arg1: UInt32
        var payload: Data
    }

    static let version: UInt32 = 0x0100_0001
    static let hostMaxData: UInt32 = 256 * 1024

    public private(set) var deviceBanner = ""
    public var isClosed: Bool { lock.withLock { closed } }
    public var onClose: (() -> Void)?

    private let fd: Int32
    private let owner: AnyObject?
    private var maxData: Int = 4096
    private let writeLock = NSLock()
    private let lock = NSLock()
    private var streams: [UInt32: ADBStream] = [:]
    private var nextLocalID: UInt32 = 1
    private var closed = false
    private var readerThread: Thread?

    /// Performs the CNXN handshake. Blocking: call off the main thread.
    /// - Parameter owner: kept alive as long as the client (e.g. the `VZVirtioSocketConnection`).
    public init(fileDescriptor: Int32, owner: AnyObject? = nil, timeout: TimeInterval = 10) throws {
        fd = fileDescriptor
        self.owner = owner
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let banner = "host::features=shell_v2,cmd,stat_v2,ls_v2,fixed_push_mkdir,abb,abb_exec"
        try send(Message(command: Command.cnxn.rawValue, arg0: Self.version, arg1: Self.hostMaxData, payload: Data(banner.utf8)))
        let reply = try receive()
        switch Command(rawValue: reply.command) {
        case .cnxn:
            maxData = Int(min(reply.arg1, Self.hostMaxData))
            deviceBanner = String(decoding: reply.payload, as: UTF8.self)
        case .auth:
            throw ZephyrError.adb("Thiết bị yêu cầu xác thực ADB (cần khởi động với androidboot.insecure_adb=1)")
        default:
            throw ZephyrError.adb("Phản hồi ADB không hợp lệ")
        }

        tv = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "adb-reader"
        readerThread = thread
        thread.start()
    }

    /// Connects to adbd over TCP (e.g. the 127.0.0.1 forwarder).
    public static func connect(host: String = "127.0.0.1", port: UInt16) throws -> ADBClient {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ZephyrError.lastPOSIX("socket") }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(host)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else {
            Darwin.close(fd)
            throw ZephyrError.lastPOSIX("connect \(host):\(port)")
        }
        let owner = FDCloser(fd)
        return try ADBClient(fileDescriptor: fd, owner: owner)
    }

    deinit {
        close()
    }

    // MARK: - Streams

    /// Opens a service stream, e.g. `exec:ls`, `shell:getprop`, `shell,v2,raw:cmd`.
    public func open(_ service: String) throws -> ADBStream {
        let stream: ADBStream = try lock.withLock {
            guard !closed else { throw ZephyrError.adb("Kết nối ADB đã đóng") }
            let id = nextLocalID
            nextLocalID &+= 1
            let stream = ADBStream(client: self, localID: id)
            streams[id] = stream
            return stream
        }
        var payload = Data(service.utf8)
        payload.append(0)
        try send(Message(command: Command.open.rawValue, arg0: stream.localID, arg1: 0, payload: payload))
        try stream.waitForOpen()
        return stream
    }

    /// Runs a command via `exec:` (raw, binary-safe) and returns its stdout once it exits.
    public func exec(_ command: String, input: Data? = nil) throws -> Data {
        let stream = try open("exec:" + command)
        if let input {
            try stream.write(input)
            stream.closeWrite()
        }
        return try stream.readToEnd()
    }

    /// Installs (or updates) an APK by streaming it to `cmd package install -S <size>`.
    /// Returns the package manager's output ("Success" or "Failure [REASON]"). Blocking.
    public func install(apk url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let stream = try open("exec:cmd package install -r -S \(data.count)")
        try stream.write(data)
        return String(decoding: try stream.readToEnd(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Convenience: `exec` returning trimmed text.
    public func shell(_ command: String) throws -> String {
        String(decoding: try exec(command), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func close() {
        let all: [ADBStream] = lock.withLock {
            guard !closed else { return [] }
            closed = true
            let all = Array(streams.values)
            streams.removeAll()
            return all
        }
        guard !all.isEmpty || readerThread != nil else { return }
        shutdown(fd, SHUT_RDWR)
        all.forEach { $0.remoteClosed() }
        readerThread = nil
        onClose?()
    }

    // MARK: - Internals used by ADBStream

    var maxPayload: Int { maxData }

    func sendWrite(local: UInt32, remote: UInt32, data: Data) throws {
        try send(Message(command: Command.wrte.rawValue, arg0: local, arg1: remote, payload: data))
    }

    func sendClose(local: UInt32, remote: UInt32) {
        try? send(Message(command: Command.clse.rawValue, arg0: local, arg1: remote, payload: Data()))
        _ = lock.withLock { streams.removeValue(forKey: local) }
    }

    private func readLoop() {
        while true {
            guard let message = try? receive() else { break }
            let stream = lock.withLock { streams[message.arg1] }
            switch Command(rawValue: message.command) {
            case .okay:
                stream?.receivedOkay(remoteID: message.arg0)
            case .wrte:
                if let stream {
                    stream.receivedData(message.payload)
                    try? send(Message(command: Command.okay.rawValue, arg0: message.arg1, arg1: message.arg0, payload: Data()))
                }
            case .clse:
                if let stream {
                    _ = lock.withLock { streams.removeValue(forKey: message.arg1) }
                    stream.remoteClosed()
                }
            default:
                break
            }
        }
        close()
    }

    private func send(_ message: Message) throws {
        var header = Data(capacity: 24 + message.payload.count)
        header.appendLE32(message.command)
        header.appendLE32(message.arg0)
        header.appendLE32(message.arg1)
        header.appendLE32(UInt32(message.payload.count))
        header.appendLE32(message.payload.reduce(UInt32(0)) { $0 &+ UInt32($1) })
        header.appendLE32(message.command ^ 0xFFFF_FFFF)
        header.append(message.payload)
        try writeLock.withLock {
            try header.withUnsafeBytes { raw in
                var sent = 0
                while sent < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress! + sent, raw.count - sent)
                    if n < 0, errno == EINTR { continue }
                    guard n > 0 else { throw ZephyrError.adb("Mất kết nối ADB") }
                    sent += n
                }
            }
        }
    }

    private func receive() throws -> Message {
        let header = try readExactly(24)
        let command = header.le32(0)
        guard header.le32(20) == command ^ 0xFFFF_FFFF else { throw ZephyrError.adb("Gói ADB hỏng") }
        let length = Int(header.le32(12))
        let payload = length > 0 ? try readExactly(length) : Data()
        return Message(command: command, arg0: header.le32(4), arg1: header.le32(8), payload: payload)
    }

    private func readExactly(_ count: Int) throws -> Data {
        var data = Data(count: count)
        var got = 0
        try data.withUnsafeMutableBytes { raw in
            while got < count {
                let n = Darwin.read(fd, raw.baseAddress! + got, count - got)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { throw ZephyrError.adb("Mất kết nối ADB") }
                got += n
            }
        }
        return data
    }
}

/// One logical ADB stream (service). Writes block until adbd acknowledges each packet.
public final class ADBStream {
    public let localID: UInt32
    /// Called on the ADB reader thread for each chunk of output. If unset, output is buffered for `readToEnd()`.
    public var onData: ((Data) -> Void)? {
        didSet {
            let pending: Data = state.withLock { s in
                let d = s.buffer
                s.buffer = Data()
                return d
            }
            if !pending.isEmpty { onData?(pending) }
        }
    }
    public var onClose: (() -> Void)?

    private struct State {
        var remoteID: UInt32 = 0
        var opened = false
        var closed = false
        var buffer = Data()
    }

    private weak var client: ADBClient?
    private let state = Mutex(State())
    private let opened = DispatchSemaphore(value: 0)
    private let acked = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private let writeLock = NSLock()

    init(client: ADBClient, localID: UInt32) {
        self.client = client
        self.localID = localID
    }

    public var isClosed: Bool { state.withLock { $0.closed } }

    func waitForOpen() throws {
        if opened.wait(timeout: .now() + 10) == .timedOut {
            throw ZephyrError.adb("Hết thời gian mở dịch vụ ADB")
        }
        if state.withLock({ !$0.opened }) {
            throw ZephyrError.adb("adbd từ chối dịch vụ")
        }
    }

    public func write(_ data: Data) throws {
        guard let client else { throw ZephyrError.adb("Kết nối ADB đã đóng") }
        try writeLock.withLock {
            var offset = 0
            while offset < data.count {
                let (remote, closed) = state.withLock { ($0.remoteID, $0.closed) }
                if closed { throw ZephyrError.adb("Luồng ADB đã đóng") }
                let chunk = data.subdata(in: offset..<min(offset + client.maxPayload, data.count))
                try client.sendWrite(local: localID, remote: remote, data: chunk)
                acked.wait()
                offset += chunk.count
            }
        }
    }

    /// Half-close is not part of the legacy protocol; for `exec:` services closing our side ends stdin.
    public func closeWrite() {}

    public func readToEnd() throws -> Data {
        finished.wait()
        finished.signal()
        return state.withLock { s in
            let d = s.buffer
            s.buffer = Data()
            return d
        }
    }

    public func close() {
        let (remote, wasClosed) = state.withLock { s -> (UInt32, Bool) in
            let r = (s.remoteID, s.closed)
            s.closed = true
            return r
        }
        guard !wasClosed else { return }
        client?.sendClose(local: localID, remote: remote)
        acked.signal()
        finished.signal()
        onClose?()
    }

    // Reader-thread callbacks
    func receivedOkay(remoteID: UInt32) {
        let first: Bool = state.withLock { s in
            if s.opened { return false }
            s.opened = true
            s.remoteID = remoteID
            return true
        }
        if first { opened.signal() } else { acked.signal() }
    }

    func receivedData(_ data: Data) {
        if let onData {
            onData(data)
        } else {
            state.withLock { $0.buffer.append(data) }
        }
    }

    func remoteClosed() {
        let wasOpened: Bool = state.withLock { s in
            s.closed = true
            return s.opened
        }
        if !wasOpened { opened.signal() }
        acked.signal()
        finished.signal()
        onClose?()
    }
}

/// Tiny lock-protected box.
final class Mutex<Value> {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

final class FDCloser {
    let fd: Int32
    init(_ fd: Int32) { self.fd = fd }
    deinit { Darwin.close(fd) }
}
