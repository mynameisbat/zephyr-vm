import SwiftUI
import ZephyrCore

/// GPU Mode section of the library window: SDK status, one-click setup and start.
struct GPUPanel: View {
    @ObservedObject var gpu: GPUSession
    @Environment(\.openWindow) private var openWindow
    @State private var confirmingLicenses = false

    var body: some View {
        List {
            Section("Android Emulator (gfxstream)") {
                Text("Dùng Android Emulator chính thức với GPU của máy (Metal) — phù hợp game 3D. Nặng hơn Lite Mode.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(gpu.components, id: \.title) { c in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: c.present ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(c.present ? .green : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.title)
                            if !c.present {
                                Text(c.hint).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            Section {
                HStack {
                    if gpu.phase.isActive {
                        Button("Mở cửa sổ") { openWindow(id: "gpu") }
                            .disabled(gpu.phase == .settingUp)
                        Button("Tắt emulator") { Task { await gpu.stop() } }
                            .disabled(gpu.phase == .stopping || gpu.phase == .settingUp)
                    } else {
                        Button("Bật GPU Mode") {
                            openWindow(id: "gpu")
                            Task { await gpu.start() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!gpu.isReady)
                        Button("Cài phần còn thiếu…") { confirmingLicenses = true }
                            .disabled(gpu.isReady || !hasBootstrapTools)
                        Button("Kiểm tra lại") { gpu.refreshComponents() }
                    }
                    Spacer()
                    Text(gpu.phase.label).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                if !hasBootstrapTools {
                    Text("Cần cài Java và cmdline-tools trước (chạy các lệnh gợi ý ở trên trong Terminal), rồi bấm Kiểm tra lại.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !gpu.setupLog.isEmpty {
                    Text(gpu.setupLog.suffix(4).joined(separator: "\n"))
                        .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(4)
                }
            }
        }
        .listStyle(.inset)
        .confirmationDialog("Chấp nhận điều khoản Android SDK?", isPresented: $confirmingLicenses) {
            Button("Đồng ý và tải") { Task { await gpu.setUp() } }
            Button("Huỷ", role: .cancel) {}
        } message: {
            Text("Zephyr sẽ tải emulator, platform-tools và system image Android 33 (vài GB) từ Google. Việc này đồng nghĩa bạn chấp nhận điều khoản của Android SDK (developer.android.com/studio/terms).")
        }
    }

    private var hasBootstrapTools: Bool {
        gpu.components.filter { [.java, .commandLineTools].contains($0.kind) }.allSatisfy(\.present)
    }
}

/// Window showing the GPU-mode emulator and forwarding mouse/keyboard over gRPC.
struct GPUWindow: View {
    @ObservedObject var gpu: GPUSession
    @FocusState private var focused: Bool
    @State private var dragging = false

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Color.black
                if let image = gpu.image {
                    screen(image)
                }
                if gpu.phase != .ready, gpu.image == nil || gpu.phase != .booting {
                    overlay
                }
            }
            .frame(minWidth: 240, minHeight: 360)
            rail
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("GPU Mode")
        .navigationSubtitle(gpu.phase == .ready ? String(format: "%.0f fps", gpu.fps) : gpu.phase.label)
    }

    private func screen(_ image: CGImage) -> some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.medium)
            .aspectRatio(contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let x = value.location.x / proxy.size.width, y = value.location.y / proxy.size.height
                                gpu.touch(x: x, y: y, pressed: true, isMove: dragging)
                                dragging = true
                                focused = true
                            }
                            .onEnded { value in
                                gpu.touch(x: value.location.x / proxy.size.width, y: value.location.y / proxy.size.height,
                                          pressed: false, isMove: false)
                                dragging = false
                            })
                }
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(phases: [.down, .repeat]) { press in handle(press) }
            .onAppear { focused = true }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.command) { return .ignored }
        let named: [KeyEquivalent: String] = [
            .return: "Enter", .delete: "Backspace", .escape: "Escape", .tab: "Tab",
            .leftArrow: "ArrowLeft", .rightArrow: "ArrowRight", .upArrow: "ArrowUp", .downArrow: "ArrowDown",
        ]
        if let name = named[press.key] { gpu.key(name); return .handled }
        if !press.characters.isEmpty { gpu.type(press.characters); return .handled }
        return .ignored
    }

    @ViewBuilder private var overlay: some View {
        VStack(spacing: 14) {
            switch gpu.phase {
            case .off:
                Image(systemName: "power").font(.system(size: 34, weight: .light))
                Text("Emulator đã tắt").font(.headline)
                Button("Bật GPU Mode") { Task { await gpu.start() } }.buttonStyle(.borderedProminent)
            case let .failed(message):
                Image(systemName: "exclamationmark.triangle").font(.system(size: 34, weight: .light))
                Text(message).multilineTextAlignment(.center).font(.callout).padding(.horizontal)
                Button("Thử lại") { Task { await gpu.start() } }.buttonStyle(.borderedProminent)
            default:
                ProgressView().controlSize(.large).tint(.white)
                Text(gpu.phase.label).font(.headline)
                Text("Lần đầu có thể mất 1–2 phút").font(.caption).opacity(0.7)
            }
        }
        .foregroundStyle(.white)
        .padding()
    }

    private var rail: some View {
        VStack(spacing: 6) {
            railButton("power", "Nguồn") { gpu.key("Power") }
            Divider().frame(width: 24)
            railButton("chevron.backward", "Quay lại") { gpu.key("GoBack") }
            railButton("circle", "Màn hình chính") { gpu.key("GoHome") }
            railButton("square", "Ứng dụng gần đây") { gpu.key("AppSwitch") }
            Spacer()
            railButton("stop.circle", "Tắt emulator") { Task { await gpu.stop() } }
        }
        .disabled(gpu.phase != .ready && gpu.phase != .booting)
        .padding(.vertical, 12)
        .frame(width: 52)
    }

    private func railButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15)).frame(width: 34, height: 30).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}
