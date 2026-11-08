import CoreGraphics
import Foundation
import ZephyrCore

/// GPU Mode: the Android Emulator (gfxstream) running headless, shown and driven over gRPC.
@MainActor
final class GPUSession: ObservableObject {
    enum Phase: Equatable {
        case off
        case settingUp
        case starting      // emulator process launched, waiting for gRPC
        case booting       // streaming frames, Android still booting
        case ready
        case stopping
        case failed(String)

        var isActive: Bool {
            switch self {
            case .starting, .booting, .ready, .stopping, .settingUp: return true
            case .off, .failed: return false
            }
        }

        var label: String {
            switch self {
            case .off: return "Đã tắt"
            case .settingUp: return "Đang cài SDK…"
            case .starting: return "Đang khởi chạy emulator…"
            case .booting: return "Android đang khởi động…"
            case .ready: return "Sẵn sàng"
            case .stopping: return "Đang tắt…"
            case let .failed(message): return message
            }
        }
    }

    @Published private(set) var phase: Phase = .off
    @Published private(set) var image: CGImage?
    @Published private(set) var components: [AndroidSDK.Component] = []
    @Published private(set) var setupLog: [String] = []
    @Published private(set) var fps: Double = 0

    private var sdk = AndroidSDK.locate()
    private var process: EmulatorProcess?
    private var client: EmulatorClient?
    private var streamTask: Task<Void, Never>?
    private var bootTask: Task<Void, Never>?
    private var frameSize = CGSize.zero

    init() { refreshComponents() }

    func refreshComponents() {
        sdk = AndroidSDK.locate()
        components = sdk.check()
    }

    var isReady: Bool { components.allSatisfy(\.present) }

    // MARK: Setup

    /// Downloads missing SDK parts. Only call after the user accepted the Android SDK licenses.
    func setUp() async {
        guard !phase.isActive else { return }
        phase = .settingUp
        setupLog = []
        let sdk = self.sdk
        do {
            try await DeviceSession.background {
                try sdk.install(acceptLicenses: true) { line in
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.setupLog.append(line)
                        if self.setupLog.count > 200 { self.setupLog.removeFirst(100) }
                    }
                }
            }
            phase = .off
        } catch {
            phase = .failed(error.localizedDescription)
        }
        refreshComponents()
    }

    // MARK: Lifecycle

    func start() async {
        guard !phase.isActive else { return }
        refreshComponents()
        guard isReady else {
            phase = .failed("GPU Mode chưa sẵn sàng: cần cài đủ SDK, emulator và AVD Zephyr_GPU.")
            return
        }
        image = nil
        phase = .starting
        let process = EmulatorProcess(sdk: sdk)
        self.process = process
        do {
            try await DeviceSession.background {
                try process.start()
                try process.waitForGRPC()
            }
            guard self.process === process, phase == .starting else { return }   // stopped meanwhile
            let client = try EmulatorClient(port: process.grpcPort)
            self.client = client
            phase = .booting
            streamTask = Task { [weak self] in await self?.pumpFrames(client) }
            bootTask = Task { [weak self] in
                do {
                    try await DeviceSession.background { try process.waitForBoot() }
                    guard let self, self.phase == .booting else { return }
                    self.phase = .ready
                } catch {
                    guard let self, self.phase == .booting else { return }
                    self.fail(error)
                }
            }
        } catch {
            fail(error)
        }
    }

    func stop() async {
        guard phase.isActive || process != nil else { return }
        phase = .stopping
        await teardown()
        phase = .off
    }

    private func fail(_ error: Error) {
        let message = error.localizedDescription
        Task {
            await teardown()
            phase = .failed(message)
        }
    }

    private func teardown() async {
        streamTask?.cancel(); bootTask?.cancel()
        streamTask = nil; bootTask = nil
        client?.close(); client = nil
        touchQueue.removeAll()
        let process = self.process
        self.process = nil
        if let process { _ = try? await DeviceSession.background { process.stop() } }
        image = nil
        fps = 0
    }

    /// Blocking stop for app termination.
    func stopSynchronously() { process?.stop(); process = nil }

    // MARK: Video

    private func pumpFrames(_ client: EmulatorClient) async {
        var windowStart = Date(), count = 0
        do {
            for try await frame in client.frames() {
                frameSize = CGSize(width: frame.width, height: frame.height)
                image = frame.makeCGImage()
                count += 1
                let elapsed = Date().timeIntervalSince(windowStart)
                if elapsed >= 1 { fps = Double(count) / elapsed; count = 0; windowStart = Date() }
            }
        } catch {
            if !Task.isCancelled, phase == .booting || phase == .ready { fail(error) }
        }
    }

    // MARK: Input

    private struct TouchEvent { var x: Int; var y: Int; var pressed: Bool; var isMove: Bool }
    private var touchQueue: [TouchEvent] = []
    private var pumping = false

    /// `x`/`y` are normalised 0…1 within the displayed screen.
    func touch(x: Double, y: Double, pressed: Bool, isMove: Bool) {
        guard frameSize.width > 0, phase == .ready || phase == .booting else { return }
        let event = TouchEvent(x: Int((min(max(x, 0), 1) * Double(frameSize.width - 1)).rounded()),
                               y: Int((min(max(y, 0), 1) * Double(frameSize.height - 1)).rounded()),
                               pressed: pressed, isMove: isMove)
        // Collapse consecutive moves so a slow gRPC call never builds a backlog; down/up are never dropped.
        if isMove, let last = touchQueue.last, last.isMove { touchQueue[touchQueue.count - 1] = event } else { touchQueue.append(event) }
        pumpTouches()
    }

    private func pumpTouches() {
        guard !pumping, let client else { return }
        pumping = true
        Task { [weak self] in
            while let self, !self.touchQueue.isEmpty {
                let e = self.touchQueue.removeFirst()
                try? await client.sendTouch(x: e.x, y: e.y, pressed: e.pressed)
            }
            self?.pumping = false
        }
    }

    func key(_ name: String) {
        guard let client else { return }
        Task { try? await client.sendKey(name) }
    }

    func type(_ text: String) {
        guard let client else { return }
        Task { try? await client.sendText(text) }
    }
}
