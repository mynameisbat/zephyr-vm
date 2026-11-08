import SwiftUI
import UniformTypeIdentifiers
import ZephyrCore

/// Main window: the list of virtual devices and the installed Android images.
struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var creating = false
    @State private var importing = false
    @AppStorage("engineMode") private var mode = "lite"

    var body: some View {
        VStack(spacing: 0) {
            Picker("Chế độ", selection: $mode) {
                Text("Lite (Virtualization)").tag("lite")
                Text("GPU (Android Emulator)").tag("gpu")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            if mode == "gpu" {
                GPUPanel(gpu: model.gpu)
            } else if model.images.isEmpty {
                Onboarding(importing: $importing)
            } else {
                List {
                    Section("Thiết bị") {
                        if model.machines.isEmpty {
                            Text("Chưa có thiết bị. Bấm + để tạo.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(model.machines) { machine in
                            if let session = model.session(for: machine.id) {
                                MachineRow(machine: machine, session: session) {
                                    openWindow(id: "device", value: machine.id)
                                }
                            }
                        }
                    }
                    Section("Ảnh Android") {
                        ForEach(model.images) { image in
                            HStack {
                                Image(systemName: "opticaldiscdrive")
                                VStack(alignment: .leading) {
                                    Text(image.displayName)
                                    Text(image.id).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
            if let task = model.task {
                VStack(alignment: .leading, spacing: 6) {
                    Text(task.title).font(.callout)
                    ProgressView(value: task.fraction)
                }
                .padding()
                .background(.bar)
            }
        }
        .frame(minWidth: 460, minHeight: 360)
        .onAppear(perform: openFromLaunchArguments)
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Button("Tải LineageOS mới nhất (≈1,1 GB)") { Task { await model.downloadLatestImage() } }
                    Button("Nhập từ tệp UTM-VM-*.zip / vda.qcow2…") { importing = true }
                } label: {
                    Label("Ảnh Android", systemImage: "square.and.arrow.down")
                }
                .disabled(model.task != nil)

                Button {
                    creating = true
                } label: {
                    Label("Thiết bị mới", systemImage: "plus")
                }
                .disabled(model.images.isEmpty)
            }
        }
        .sheet(isPresented: $creating) {
            NewDeviceSheet { id in openWindow(id: "device", value: id) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip, .data, .folder]) { result in
            if case let .success(url) = result {
                Task { await model.importImage(from: url) }
            }
        }
        .alert("Có lỗi", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

extension LibraryView {
    /// `Zephyr --open <device name>` starts and shows a device right away (handy for scripts).
    func openFromLaunchArguments() {
        let args = CommandLine.arguments
        if args.contains("--gpu") {
            openWindow(id: "gpu")
            Task { await model.gpu.start() }
            return
        }
        guard let i = args.firstIndex(of: "--open"), i + 1 < args.count else { return }
        if let machine = model.machines.first(where: { $0.spec.name == args[i + 1] }) {
            openWindow(id: "device", value: machine.id)
        }
    }
}

private struct Onboarding: View {
    @EnvironmentObject private var model: AppModel
    @Binding var importing: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: 52, weight: .thin))
            Text("Zephyr — giả lập Android siêu nhẹ").font(.title2.bold())
            Text("Cần một ảnh hệ thống Android arm64. Zephyr dùng bản LineageOS cho máy ảo virtio (build tự động trên GitHub).")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            HStack {
                Button("Tải LineageOS (≈1,1 GB)") { Task { await model.downloadLatestImage() } }
                    .buttonStyle(.borderedProminent)
                Button("Nhập từ tệp…") { importing = true }
            }
            .disabled(model.task != nil)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MachineRow: View {
    @EnvironmentObject private var model: AppModel
    let machine: MachineBundle
    @ObservedObject var session: DeviceSession
    let open: () -> Void

    var body: some View {
        let spec = machine.spec
        HStack(spacing: 12) {
            Image(systemName: spec.display.width > spec.display.height || spec.display.width >= 1600 ? "ipad" : "iphone")
                .font(.title2)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(spec.name).font(.headline)
                Text("\(spec.display.width)×\(spec.display.height) · \(spec.cpuCount) CPU · \(spec.memoryMiB / 1024) GB RAM · \(session.phase.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(session.phase.isRunning ? "Mở" : "Bật", action: open)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: open)
        .contextMenu {
            Button("Mở", action: open)
            Button("Hiện trong Finder") { model.revealInFinder(machine) }
            Divider()
            Button("Khôi phục cài đặt gốc") { model.factoryReset(machine) }
                .disabled(session.phase.isRunning)
            Button("Xoá thiết bị", role: .destructive) { model.delete(machine) }
                .disabled(session.phase.isRunning)
        }
    }
}

private struct NewDeviceSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let onCreated: (UUID) -> Void

    @State private var name = "Pixel"
    @State private var imageID = ""
    @State private var presetID = DisplaySpec.presets[0].id
    @State private var cpus = 4
    @State private var memoryGiB = 2
    @State private var dataGiB = 16

    private var maxCPUs: Int { ProcessInfo.processInfo.activeProcessorCount }
    private var maxMemory: Int { max(2, Int(ProcessInfo.processInfo.physicalMemory >> 30) / 2) }

    var body: some View {
        Form {
            TextField("Tên", text: $name)
            Picker("Hệ điều hành", selection: $imageID) {
                ForEach(model.images) { Text($0.displayName).tag($0.id) }
            }
            Picker("Màn hình", selection: $presetID) {
                ForEach(DisplaySpec.presets) { Text($0.title).tag($0.id) }
            }
            Stepper("CPU: \(cpus) nhân", value: $cpus, in: 1...maxCPUs)
            Stepper("RAM: \(memoryGiB) GB", value: $memoryGiB, in: 2...maxMemory)
            Stepper("Bộ nhớ trong: \(dataGiB) GB (chỉ chiếm chỗ khi dùng)", value: $dataGiB, in: 4...128, step: 4)
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .onAppear { imageID = model.images.first?.id ?? "" }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Huỷ") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Tạo") {
                    let display = DisplaySpec.presets.first { $0.id == presetID }?.spec ?? DisplayPresets.defaultSpec
                    if let bundle = model.createMachine(name: name, imageID: imageID, display: display,
                                                        cpus: cpus, memoryMiB: memoryGiB * 1024, dataGiB: dataGiB) {
                        dismiss()
                        onCreated(bundle.id)
                    }
                }
                .disabled(name.isEmpty || imageID.isEmpty)
            }
        }
    }
}
