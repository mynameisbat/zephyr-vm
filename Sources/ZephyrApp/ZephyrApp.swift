import AppKit
import SwiftUI
import ZephyrCore

@main
struct ZephyrApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Zephyr", id: "library") {
            LibraryView()
                .environmentObject(model)
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 520, height: 440)

        WindowGroup("Thiết bị", id: "device", for: UUID.self) { $id in
            if let id, let session = model.session(for: id) {
                DeviceWindow(session: session)
                    .environmentObject(model)
            } else {
                Text("Thiết bị không còn tồn tại").padding()
            }
        }
        .defaultSize(width: 470, height: 820)
        .windowResizability(.contentMinSize)

        Window("GPU Mode", id: "gpu") {
            GPUWindow(gpu: model.gpu)
        }
        .defaultSize(width: 470, height: 820)
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // A restored device window would boot its VM behind the user's back; start clean.
        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Powers Android off cleanly before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, !model.runningSessions.isEmpty || model.gpu.phase.isActive else { return .terminateNow }
        Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                for session in model.runningSessions {
                    group.addTask { await session.shutdown() }
                }
                group.addTask { await model.gpu.stop() }
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
