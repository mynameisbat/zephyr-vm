import Foundation
import Virtualization

/// Exposes a guest vsock port on 127.0.0.1 so standard tools (`adb connect 127.0.0.1:5555`)
/// can talk to the VM. Each TCP client gets its own vsock stream.
public final class VsockForwarder {
    public typealias Connector = (@escaping (Result<VZVirtioSocketConnection, Error>) -> Void) -> Void

    public let port: UInt16
    private let listenFD: Int32
    private let source: DispatchSourceRead
    private let connector: Connector
    private var pumps: [ObjectIdentifier: SocketPump] = [:]
    private let lock = NSLock()

    /// - Parameters:
    ///   - candidatePorts: host ports to try in order; the first free one is used.
    ///   - connector: opens a vsock connection to the guest; invoked on the main queue.
    public init(candidatePorts: [UInt16], connector: @escaping Connector) throws {
        var chosen: (fd: Int32, port: UInt16)?
        for port in candidatePorts {
            if let fd = Self.listen(on: port) {
                chosen = (fd, port)
                break
            }
        }
        guard let chosen else {
            throw ZephyrError.vm("Không còn cổng trống để chuyển tiếp ADB (\(candidatePorts.first ?? 0)…)")
        }
        listenFD = chosen.fd
        port = chosen.port
        self.connector = connector
        source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: .global(qos: .userInitiated))
        source.setEventHandler { [weak self] in self?.acceptClient() }
        source.setCancelHandler { [fd = listenFD] in close(fd) }
        source.resume()
    }

    deinit {
        stop()
    }

    public func stop() {
        source.cancel()
        lock.lock()
        let all = pumps.values
        pumps.removeAll()
        lock.unlock()
        all.forEach { $0.close() }
    }

    private func acceptClient() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        var one: Int32 = 1
        setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        DispatchQueue.main.async { [weak self] in
            guard let self else { close(client); return }
            self.connector { result in
                switch result {
                case let .success(connection):
                    let pump = SocketPump(clientFD: client, connection: connection)
                    let key = ObjectIdentifier(pump)
                    self.lock.lock()
                    self.pumps[key] = pump
                    self.lock.unlock()
                    pump.start { [weak self] in
                        guard let self else { return }
                        self.lock.lock()
                        self.pumps[key] = nil
                        self.lock.unlock()
                    }
                case .failure:
                    close(client)
                }
            }
        }
    }

    private static func listen(on port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 16) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }
}

/// Copies bytes both ways between a TCP client and a vsock connection.
final class SocketPump {
    private let clientFD: Int32
    private let connection: VZVirtioSocketConnection
    private let group = DispatchGroup()
    private var closed = false
    private let lock = NSLock()

    init(clientFD: Int32, connection: VZVirtioSocketConnection) {
        self.clientFD = clientFD
        self.connection = connection
        // Blocking I/O on dedicated threads keeps this simple and low-latency.
        let flags = fcntl(connection.fileDescriptor, F_GETFL)
        _ = fcntl(connection.fileDescriptor, F_SETFL, flags & ~O_NONBLOCK)
    }

    func start(onFinish: @escaping () -> Void) {
        let guestFD = connection.fileDescriptor
        spawn(from: clientFD, to: guestFD)
        spawn(from: guestFD, to: clientFD)
        group.notify(queue: .global()) { [self] in
            close()
            onFinish()
        }
    }

    private func spawn(from source: Int32, to destination: Int32) {
        group.enter()
        let thread = Thread { [self] in
            var buffer = [UInt8](repeating: 0, count: 256 * 1024)
            loop: while true {
                let n = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
                if n < 0, errno == EINTR { continue }
                if n <= 0 { break }
                var sent = 0
                while sent < n {
                    let m = buffer.withUnsafeBytes { write(destination, $0.baseAddress! + sent, n - sent) }
                    if m < 0, errno == EINTR { continue }
                    if m <= 0 { break loop }
                    sent += m
                }
            }
            shutdown(destination, SHUT_WR)
            shutdown(source, SHUT_RD)
            group.leave()
        }
        thread.stackSize = 512 * 1024
        thread.start()
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        shutdown(clientFD, SHUT_RDWR)
        Darwin.close(clientFD)
        connection.close()
    }
}
