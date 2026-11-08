import SwiftUI
import UniformTypeIdentifiers
import ZephyrCore

/// Window showing one virtual device: the screen plus an emulator-style button rail.
struct DeviceWindow: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: DeviceSession
    @State private var dropTargeted = false
    @State private var choosingAPK = false

    var body: some View {
        HStack(spacing: 0) {
            screen
            ButtonRail(session: session, choosingAPK: $choosingAPK)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(session.bundle.spec.name)
        .navigationSubtitle(subtitle)
        .fileImporter(isPresented: $choosingAPK, allowedContentTypes: [UTType(filenameExtension: "apk") ?? .data]) { result in
            if case let .success(url) = result {
                Task { await session.installAPK(url) }
            }
        }
        .task {
            if !session.phase.isRunning { await session.start() }
        }
    }

    private var subtitle: String {
        var text = session.phase.label
        if session.phase == .ready, let seconds = session.bootSeconds {
            text += String(format: " · khởi động %.0f s", seconds)
        }
        if let port = session.adbPort {
            text += " · adb 127.0.0.1:\(port)"
        }
        return text
    }

    private var screen: some View {
        let d = session.display
        return ZStack {
            Color.black
            ScreenView(session: session)
                .aspectRatio(CGSize(width: d.width, height: d.height), contentMode: .fit)
                .opacity(session.phase == .ready ? 1 : 0.0001)

            if session.phase != .ready {
                StatusOverlay(session: session)
            }
            if let toast = session.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.callout)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 24)
                }
                .transition(.opacity)
            }
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .overlay(Text("Thả APK để cài").font(.title3.bold()).foregroundStyle(.white))
                    .padding(12)
            }
        }
        .frame(minWidth: 240, minHeight: 360)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.pathExtension.lowercased() == "apk" else { return }
                    Task { @MainActor in await session.installAPK(url) }
                }
            }
            return true
        }
        .animation(.easeOut(duration: 0.2), value: session.toast)
    }
}

private struct StatusOverlay: View {
    @ObservedObject var session: DeviceSession

    var body: some View {
        VStack(spacing: 14) {
            switch session.phase {
            case .off:
                Image(systemName: "power").font(.system(size: 34, weight: .light))
                Text("Thiết bị đã tắt").font(.headline)
                Button("Bật máy") { Task { await session.start() } }
                    .buttonStyle(.borderedProminent)
            case let .failed(message):
                Image(systemName: "exclamationmark.triangle").font(.system(size: 34, weight: .light))
                Text(message).multilineTextAlignment(.center).font(.callout).padding(.horizontal)
                Button("Thử lại") { Task { await session.start() } }
                    .buttonStyle(.borderedProminent)
            default:
                ProgressView().controlSize(.large).tint(.white)
                Text(session.phase.label).font(.headline)
                Text("Lần đầu khởi động sẽ lâu hơn một chút").font(.caption).opacity(0.7)
            }
        }
        .foregroundStyle(.white)
        .padding()
    }
}

/// Vertical strip of device controls, in the spirit of the Android Emulator side bar.
private struct ButtonRail: View {
    @ObservedObject var session: DeviceSession
    @Binding var choosingAPK: Bool

    var body: some View {
        VStack(spacing: 6) {
            if session.phase.isRunning {
                RailButton("power", "Nguồn (bật/tắt màn hình)") { session.press(.power) }
                    .contextMenu {
                        Button("Tắt máy") { Task { await session.shutdown() } }
                        Button("Buộc tắt") { Task { await session.forceStop() } }
                    }
            } else {
                RailButton("play.fill", "Bật máy") { Task { await session.start() } }
            }
            Divider().frame(width: 24)
            RailButton("speaker.wave.3", "Tăng âm lượng") { session.press(.volumeUp) }
            RailButton("speaker.wave.1", "Giảm âm lượng") { session.press(.volumeDown) }
            Divider().frame(width: 24)
            RailButton("chevron.backward", "Quay lại (chuột phải)") { session.press(.back) }
            RailButton("circle", "Màn hình chính (chuột giữa)") { session.press(.home) }
            RailButton("square", "Ứng dụng gần đây") { session.press(.appSwitch) }
            Divider().frame(width: 24)
            RailButton("camera", "Chụp màn hình") { Task { await session.screenshot() } }
            RailButton("shippingbox", "Cài APK…") { choosingAPK = true }
            RailButton("folder", "Mở thư mục chia sẻ (/mnt/vendor/shared)") {
                NSWorkspace.shared.open((try? ZephyrPaths.ensure(ZephyrPaths.shared)) ?? ZephyrPaths.shared)
            }
            Spacer()
            if session.phase.isRunning {
                RailButton("stop.circle", "Tắt máy") { Task { await session.shutdown() } }
            }
        }
        .disabled(session.phase == .stopping)
        .padding(.vertical, 12)
        .frame(width: 52)
    }
}

private struct RailButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    init(_ symbol: String, _ help: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}
