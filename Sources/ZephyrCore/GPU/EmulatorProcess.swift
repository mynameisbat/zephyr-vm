import Foundation
import Darwin

private let pidLock = NSLock()
private var activeGroup: pid_t = 0
private var exitHookInstalled = false

/// Last-resort cleanup when the host process exits normally (`exit()`, app quit).
private func installExitHook() {
    pidLock.lock(); defer { pidLock.unlock() }
    guard !exitHookInstalled else { return }
    exitHookInstalled = true
    atexit {
        pidLock.lock()
        let group = activeGroup
        pidLock.unlock()
        if group > 0 {
            killpg(group, SIGTERM)
            usleep(300_000)
            killpg(group, SIGKILL)
        }
    }
}

/// Runs the Android Emulator headless for GPU mode and guarantees it is torn down with Zephyr.
///
/// The emulator is spawned as the leader of its own process group, because the `emulator` launcher forks the real
/// `qemu-system-*` binary; signalling the whole group reaps both. A pid file lets the next launch clean up an
/// emulator orphaned by a crash or `kill -9` of Zephyr.
public final class EmulatorProcess: @unchecked Sendable {
    public static let defaultGRPCPort = 8554
    public static let consolePort = 5554   // first emulator => emulator-5554 / adb port 5555

    public let sdk: AndroidSDK
    public let grpcPort: Int
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var exitStatus: Int32?

    public var logURL: URL { ZephyrPaths.root.appendingPathComponent("Logs/gpu-emulator.log") }
    private var pidFile: URL { ZephyrPaths.root.appendingPathComponent("gpu-emulator.pid") }

    public init(sdk: AndroidSDK = .locate(), grpcPort: Int = EmulatorProcess.defaultGRPCPort) {
        self.sdk = sdk
        self.grpcPort = grpcPort
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return pid > 0 && exitStatus == nil
    }

    public static func arguments(grpcPort: Int) -> [String] {
        ["-avd", AndroidSDK.avdName, "-no-window", "-gpu", "host", "-grpc", String(grpcPort),
         "-no-boot-anim", "-no-snapshot"]
    }

    // MARK: Lifecycle

    public func start() throws {
        guard !isRunning else { return }
        if let missing = sdk.check().first(where: { !$0.present && [.emulator, .avd].contains($0.kind) }) {
            throw ZephyrError.notFound("GPU Mode chưa sẵn sàng: thiếu \(missing.title). Chạy `zephyrctl gpu status`.")
        }
        Self.reapOrphan(pidFile: pidFile)
        if Self.canConnect(port: grpcPort) {
            throw ZephyrError.vm("Cổng gRPC \(grpcPort) đang được dùng (có emulator khác đang chạy?).")
        }
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, 1, logURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        posix_spawn_file_actions_adddup2(&fileActions, 1, 2)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)   // new group led by the child

        var env = ProcessInfo.processInfo.environment
        env["ANDROID_SDK_ROOT"] = sdk.root.path
        env["ANDROID_HOME"] = sdk.root.path
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let argv = ([sdk.emulatorBinary.path] + Self.arguments(grpcPort: grpcPort)).map { strdup($0) } + [nil]
        defer { (envp + argv).forEach { free($0) } }

        var child: pid_t = 0
        let rc = posix_spawn(&child, sdk.emulatorBinary.path, &fileActions, &attr, argv, envp)
        guard rc == 0 else { throw ZephyrError.posix("Không khởi chạy được emulator", rc) }

        lock.lock(); pid = child; exitStatus = nil; lock.unlock()
        pidLock.lock(); activeGroup = child; pidLock.unlock()
        installExitHook()
        try? "\(child)".write(to: pidFile, atomically: true, encoding: .utf8)

        Thread.detachNewThread { [weak self] in
            var status: Int32 = 0
            while waitpid(child, &status, 0) < 0 && errno == EINTR {}
            self?.lock.lock(); self?.exitStatus = status; self?.lock.unlock()
        }
    }

    /// SIGTERM the whole group, wait up to `grace` seconds, then SIGKILL.
    public func stop(grace: TimeInterval = 8) {
        lock.lock(); let child = pid; lock.unlock()
        guard child > 0 else { return }
        if isRunning {
            killpg(child, SIGTERM)
            let deadline = Date().addingTimeInterval(grace)
            while isRunning, Date() < deadline { usleep(100_000) }
        }
        killpg(child, SIGKILL)   // also sweeps qemu children the launcher left behind
        pidLock.lock(); if activeGroup == child { activeGroup = 0 }; pidLock.unlock()
        try? FileManager.default.removeItem(at: pidFile)
        lock.lock(); pid = 0; lock.unlock()
    }

    deinit { stop(grace: 2) }

    // MARK: Readiness

    /// Waits until the emulator's gRPC endpoint accepts connections.
    public func waitForGRPC(timeout: TimeInterval = 120) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isRunning { throw ZephyrError.vm("Emulator đã thoát sớm. Xem log: \(logURL.path)") }
            if Self.canConnect(port: grpcPort) { return }
            usleep(300_000)
        }
        throw ZephyrError.vm("Hết thời gian chờ gRPC cổng \(grpcPort). Xem log: \(logURL.path)")
    }

    /// Waits for `sys.boot_completed == 1` via the SDK's adb.
    public func waitForBoot(timeout: TimeInterval = 240) throws {
        let deadline = Date().addingTimeInterval(timeout)
        let serial = "emulator-\(Self.consolePort)"
        while Date() < deadline {
            if !isRunning { throw ZephyrError.vm("Emulator đã thoát sớm. Xem log: \(logURL.path)") }
            var out = ""
            let status = try? ToolRunner.run(sdk.adbBinary, ["-s", serial, "shell", "getprop", "sys.boot_completed"],
                                             env: [:], stdin: nil) { out += $0 }
            if status == 0, out.trimmingCharacters(in: .whitespacesAndNewlines) == "1" { return }
            sleep(2)
        }
        throw ZephyrError.vm("Hết thời gian chờ Android khởi động xong.")
    }

    // MARK: Helpers

    static func canConnect(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return rc == 0
    }

    /// Kills an emulator left over from a previous Zephyr run, after checking the pid really is an emulator.
    static func reapOrphan(pidFile: URL) {
        defer { try? FileManager.default.removeItem(at: pidFile) }
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let old = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), old > 1,
              kill(old, 0) == 0 else { return }
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-p", String(old), "-o", "command="]
        let out = Pipe()
        ps.standardOutput = out
        guard (try? ps.run()) != nil else { return }
        let command = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        guard command.contains("emulator"), command.contains(AndroidSDK.avdName) else { return }
        killpg(old, SIGTERM)
        usleep(500_000)
        killpg(old, SIGKILL)
    }
}
