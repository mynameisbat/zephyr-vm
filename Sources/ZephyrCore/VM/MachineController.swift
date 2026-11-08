import Foundation
import Virtualization

/// Runs one VM. All VZ calls happen on the main queue (the VM's queue).
@MainActor
public final class MachineController: NSObject {
    public enum State: Equatable {
        case stopped
        case starting
        case running
        case paused
        case stopping
        case failed(String)

        public var isActive: Bool {
            switch self {
            case .starting, .running, .paused, .stopping: return true
            case .stopped, .failed: return false
            }
        }
    }

    public static let adbGuestPort: UInt32 = 5555

    public private(set) var bundle: MachineBundle
    public let image: ImageManifest
    public let images: ImageStore
    public private(set) var virtualMachine: VZVirtualMachine?

    public private(set) var state: State = .stopped {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    public var onStateChange: ((State) -> Void)?
    /// Bytes written by the guest kernel to hvc0.
    public var onConsoleOutput: ((Data) -> Void)?

    private var consolePipe: Pipe?
    private var logcatPipe: Pipe?
    private var consoleLog: FileHandle?
    private var logcatLog: FileHandle?

    public init(bundle: MachineBundle, images: ImageStore = ImageStore()) throws {
        guard let image = images.image(id: bundle.spec.imageID) else {
            throw ZephyrError.notFound("Ảnh hệ thống '\(bundle.spec.imageID)' của máy '\(bundle.spec.name)' không tồn tại")
        }
        self.bundle = bundle
        self.image = image
        self.images = images
    }

    public var socketDevice: VZVirtioSocketDevice? {
        virtualMachine?.socketDevices.first as? VZVirtioSocketDevice
    }

    public var graphicsDisplay: VZGraphicsDisplay? {
        virtualMachine?.graphicsDevices.first?.displays.first
    }

    // MARK: - Lifecycle

    public func start() async throws {
        guard !state.isActive else { return }
        state = .starting
        do {
            let vm = VZVirtualMachine(configuration: try makeConfiguration())
            vm.delegate = self
            virtualMachine = vm
            try await vm.start()
            state = .running
        } catch {
            teardown()
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Hard power-off (like pulling the plug). Android tolerates this, but prefer a guest shutdown.
    public func stop() async {
        guard let vm = virtualMachine, state.isActive else { return }
        state = .stopping
        if vm.canStop {
            try? await vm.stop()
        }
        teardown()
        state = .stopped
    }

    public func pause() async throws {
        guard let vm = virtualMachine, vm.canPause else { return }
        try await vm.pause()
        state = .paused
    }

    public func resume() async throws {
        guard let vm = virtualMachine, vm.canResume else { return }
        try await vm.resume()
        state = .running
    }

    /// Opens a vsock stream to a port inside the guest.
    public func connect(toGuestPort port: UInt32) async throws -> VZVirtioSocketConnection {
        guard let device = socketDevice else {
            throw ZephyrError.vm("Máy ảo chưa chạy")
        }
        return try await withCheckedThrowingContinuation { continuation in
            device.connect(toPort: port) { result in
                continuation.resume(with: result)
            }
        }
    }

    // MARK: - Configuration

    private func makeConfiguration() throws -> VZVirtualMachineConfiguration {
        let console = Pipe()
        let consoleLog = try Self.openLog(bundle.consoleLogURL)
        console.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            consoleLog.write(data)
            DispatchQueue.main.async { self?.onConsoleOutput?(data) }
        }
        consolePipe = console
        self.consoleLog = consoleLog

        var logcatHandle: FileHandle?
        if bundle.spec.serialLogcat {
            let logcat = Pipe()
            let logcatLog = try Self.openLog(bundle.logcatURL)
            logcat.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { logcatLog.write(data) }
            }
            logcatPipe = logcat
            self.logcatLog = logcatLog
            logcatHandle = logcat.fileHandleForWriting
        }

        return try VirtualMachineFactory.configuration(
            for: bundle, image: image, images: images,
            ports: .init(console: console.fileHandleForWriting, logcat: logcatHandle))
    }

    private static func openLog(_ url: URL) throws -> FileHandle {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try FileHandle(forWritingTo: url)
    }

    private func teardown() {
        consolePipe?.fileHandleForReading.readabilityHandler = nil
        logcatPipe?.fileHandleForReading.readabilityHandler = nil
        try? consoleLog?.close()
        try? logcatLog?.close()
        consolePipe = nil
        logcatPipe = nil
        consoleLog = nil
        logcatLog = nil
        virtualMachine = nil
    }
}

extension MachineController: VZVirtualMachineDelegate {
    // VZ may deliver these off the main thread; hop explicitly.
    nonisolated public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor in
            teardown()
            state = .stopped
        }
    }

    nonisolated public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            teardown()
            state = .failed(message)
        }
    }
}
