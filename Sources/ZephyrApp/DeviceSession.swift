import AppKit
import Foundation
import Virtualization
import ZephyrCore

/// A running (or startable) virtual device: VM + ADB channel + input.
@MainActor
final class DeviceSession: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case off
        case kernel          // VM started, waiting for adbd
        case android         // adbd up, waiting for sys.boot_completed
        case ready
        case stopping
        case failed(String)

        var isRunning: Bool {
            switch self {
            case .kernel, .android, .ready, .stopping: return true
            case .off, .failed: return false
            }
        }

        var label: String {
            switch self {
            case .off: return "Đã tắt"
            case .kernel: return "Đang khởi động kernel…"
            case .android: return "Đang khởi động Android…"
            case .ready: return "Đang chạy"
            case .stopping: return "Đang tắt…"
            case let .failed(message): return "Lỗi: \(message)"
            }
        }
    }

    @Published private(set) var phase: Phase = .off
    @Published private(set) var adbPort: UInt16?
    @Published private(set) var bootSeconds: Double?
    @Published var toast: String?

    private(set) var bundle: MachineBundle
    private let images: ImageStore
    private(set) var controller: MachineController?
    private(set) var input: InputInjector?
    private var forwarder: VsockForwarder?
    private var adb: ADBClient?
    private var bootTask: Task<Void, Never>?
    private var startedAt = Date()

    var id: UUID { bundle.id }
    var virtualMachine: VZVirtualMachine? { controller?.virtualMachine }
    var display: DisplaySpec { bundle.spec.display }

    init(bundle: MachineBundle, images: ImageStore) {
        self.bundle = bundle
        self.images = images
    }

    func update(bundle: MachineBundle) {
        guard !phase.isRunning else { return }
        self.bundle = bundle
    }

    // MARK: - Power

    func start() async {
        guard !phase.isRunning else { return }
        do {
            let controller = try MachineController(bundle: bundle, images: images)
            controller.onStateChange = { [weak self] state in self?.controllerChanged(state) }
            self.controller = controller
            startedAt = Date()
            bootSeconds = nil
            phase = .kernel
            try await controller.start()

            let first: UInt16 = 5555
            forwarder = try? VsockForwarder(candidatePorts: stride(from: first, through: first + 30, by: 2).map { $0 }) { [weak controller] completion in
                Task { @MainActor in
                    guard let controller else { return completion(.failure(ZephyrError.vm("stopped"))) }
                    do { completion(.success(try await controller.connect(toGuestPort: MachineController.adbGuestPort))) }
                    catch { completion(.failure(error)) }
                }
            }
            adbPort = forwarder?.port
            bootTask = Task { [weak self] in await self?.waitForAndroid() }
        } catch {
            phase = .failed(error.localizedDescription)
            cleanup()
        }
    }

    /// Asks Android to power off; falls back to a hard stop after a timeout.
    func shutdown() async {
        guard phase.isRunning, let controller else { return }
        phase = .stopping
        if let adb {
            _ = try? await Self.background { try adb.shell("reboot -p") }
            for _ in 0..<40 where controller.state.isActive {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        if controller.state.isActive {
            await controller.stop()
        }
    }

    func forceStop() async {
        guard let controller else { return }
        phase = .stopping
        await controller.stop()
    }

    private func controllerChanged(_ state: MachineController.State) {
        switch state {
        case .stopped:
            cleanup()
            phase = .off
        case let .failed(message):
            cleanup()
            phase = .failed(message)
        default:
            break
        }
    }

    private func cleanup() {
        bootTask?.cancel()
        bootTask = nil
        input?.close()
        input = nil
        adb?.close()
        adb = nil
        forwarder?.stop()
        forwarder = nil
        adbPort = nil
        controller = nil
    }

    // MARK: - Boot tracking

    private func waitForAndroid() async {
        // 1. Wait for adbd inside the guest (reachable over vsock once Android's init starts it).
        var client: ADBClient?
        while client == nil, phase.isRunning, !Task.isCancelled {
            if let controller, let connection = try? await controller.connect(toGuestPort: MachineController.adbGuestPort) {
                client = try? await Self.background { try ADBClient(fileDescriptor: connection.fileDescriptor, owner: connection) }
            }
            if client == nil { try? await Task.sleep(nanoseconds: 700_000_000) }
        }
        guard let client, !Task.isCancelled else { return }
        adb = client
        if phase == .kernel { phase = .android }

        // 2. Touch + buttons, available as soon as the input stack is up.
        let display = bundle.spec.display
        input = try? await Self.background { try InputInjector(client: client, width: display.width, height: display.height) }

        // 3. Wait for the launcher.
        while !Task.isCancelled, phase.isRunning {
            if let done = try? await Self.background({ try client.shell("getprop sys.boot_completed") }), done == "1" {
                bootSeconds = Date().timeIntervalSince(startedAt)
                if phase == .android { phase = .ready }
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    // MARK: - Device actions

    func press(_ button: InputInjector.Button) {
        input?.press(button)
    }

    func installAPK(_ url: URL) async {
        guard let adb else { return show("ADB chưa sẵn sàng") }
        show("Đang cài \(url.lastPathComponent)…")
        do {
            let result = try await Self.background { try adb.install(apk: url) }
            show(result.contains("Success") ? "Đã cài \(url.lastPathComponent)" : "Cài thất bại: \(result)")
        } catch {
            show("Cài thất bại: \(error.localizedDescription)")
        }
    }

    func screenshot() async {
        guard let adb else { return show("ADB chưa sẵn sàng") }
        do {
            let png = try await Self.background { try adb.exec("screencap -p") }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
            let url = desktop.appendingPathComponent("Zephyr \(formatter.string(from: Date())).png")
            try png.write(to: url)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([url as NSURL])
            show("Đã lưu ảnh màn hình ra Desktop")
        } catch {
            show("Chụp màn hình thất bại: \(error.localizedDescription)")
        }
    }

    func openShell(_ command: String) async -> String {
        guard let adb else { return "" }
        return (try? await Self.background { try adb.shell(command) }) ?? ""
    }

    private func show(_ message: String) {
        toast = message
        let current = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if toast == current { toast = nil }
        }
    }

    /// Runs blocking ADB work off the main thread.
    nonisolated static func background<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}
