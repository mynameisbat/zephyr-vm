import Foundation
import Virtualization

/// Screen size and density of the virtual phone/tablet.
public struct DisplaySpec: Codable, Hashable {
    public var width: Int
    public var height: Int
    public var density: Int

    public init(width: Int, height: Int, density: Int) {
        self.width = width
        self.height = height
        self.density = density
    }

    public struct Preset: Identifiable, Hashable {
        public let id: String
        public let title: String
        public let spec: DisplaySpec
    }

    public static let presets: [Preset] = [
        Preset(id: "phone-hd", title: "Điện thoại HD 720×1280 (nhẹ nhất)", spec: DisplaySpec(width: 720, height: 1280, density: 320)),
        Preset(id: "phone-fhd", title: "Điện thoại Full HD 1080×1920", spec: DisplaySpec(width: 1080, height: 1920, density: 420)),
        Preset(id: "phone-tall", title: "Điện thoại 1080×2400", spec: DisplaySpec(width: 1080, height: 2400, density: 440)),
        Preset(id: "tablet", title: "Máy tính bảng 1600×2560", spec: DisplaySpec(width: 1600, height: 2560, density: 320)),
    ]
}

/// Persistent settings of one virtual device.
public struct MachineSpec: Codable, Hashable {
    public var id: UUID
    public var name: String
    public var imageID: String
    public var cpuCount: Int
    public var memoryMiB: Int
    public var display: DisplaySpec
    public var macAddress: String
    public var dataDiskGiB: Int
    public var bootAnimation: Bool
    /// Mirror Android's logcat to a second serial port (debugging; costs a little CPU).
    public var serialLogcat: Bool
    public var audio: Bool
    public var createdAt: Date

    public init(name: String, imageID: String, cpuCount: Int = 4, memoryMiB: Int = 2048,
                display: DisplaySpec = DisplayPresets.defaultSpec, dataDiskGiB: Int = 16) {
        id = UUID()
        self.name = name
        self.imageID = imageID
        self.cpuCount = cpuCount
        self.memoryMiB = memoryMiB
        self.display = display
        macAddress = VZMACAddress.randomLocallyAdministered().string
        self.dataDiskGiB = dataDiskGiB
        bootAnimation = false
        serialLogcat = false
        audio = true
        createdAt = Date()
    }
}

public enum DisplayPresets {
    public static let defaultSpec = DisplaySpec.presets[0].spec
}

/// A VM on disk: `Machines/<uuid>.zvm/` with its settings, disks and identity.
public struct MachineBundle: Identifiable, Hashable {
    public let url: URL
    public var spec: MachineSpec

    public var id: UUID { spec.id }

    public var configURL: URL { url.appendingPathComponent("config.json") }
    public var systemDiskURL: URL { url.appendingPathComponent("system.img") }
    public var dataDiskURL: URL { url.appendingPathComponent("userdata.img") }
    public var machineIdentifierURL: URL { url.appendingPathComponent("machine-id.bin") }
    public var consoleLogURL: URL { url.appendingPathComponent("console.log") }
    public var logcatURL: URL { url.appendingPathComponent("logcat.log") }
    public var savedStateURL: URL { url.appendingPathComponent("state.vzvmsave") }

    public var hasSavedState: Bool { FileManager.default.fileExists(atPath: savedStateURL.path) }

    public func save() throws {
        try JSONEncoder.zephyr.encode(spec).write(to: configURL, options: .atomic)
    }

    public static func load(from url: URL) throws -> MachineBundle {
        let data = try Data(contentsOf: url.appendingPathComponent("config.json"))
        return MachineBundle(url: url, spec: try JSONDecoder.zephyr.decode(MachineSpec.self, from: data))
    }

    /// Stable per-VM identity; required for save/restore of the machine state.
    public func machineIdentifier() throws -> VZGenericMachineIdentifier {
        if let data = try? Data(contentsOf: machineIdentifierURL),
           let identifier = VZGenericMachineIdentifier(dataRepresentation: data) {
            return identifier
        }
        let identifier = VZGenericMachineIdentifier()
        try identifier.dataRepresentation.write(to: machineIdentifierURL)
        return identifier
    }
}

/// Creates, lists and deletes VMs.
public final class MachineStore {
    public let root: URL
    public let images: ImageStore

    public init(root: URL = ZephyrPaths.machines, images: ImageStore = ImageStore()) {
        self.root = root
        self.images = images
    }

    public func list() -> [MachineBundle] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.filter { $0.pathExtension == "zvm" }
            .compactMap { try? MachineBundle.load(from: $0) }
            .sorted { $0.spec.createdAt < $1.spec.createdAt }
    }

    public func machine(named nameOrID: String) -> MachineBundle? {
        list().first { $0.spec.name == nameOrID || $0.spec.id.uuidString == nameOrID }
    }

    /// Creates a VM from a base image. The system disk is an APFS clone of the image (instant,
    /// copy-on-write); the data disk is a sparse file, formatted by Android on first boot.
    @discardableResult
    public func create(_ spec: MachineSpec) throws -> MachineBundle {
        guard let image = images.image(id: spec.imageID) else {
            throw ZephyrError.notFound("Không có ảnh hệ thống '\(spec.imageID)'")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("\(spec.id.uuidString).zvm", isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        let bundle = MachineBundle(url: url, spec: spec)
        do {
            try fm.cloneItem(at: images.systemDisk(for: image), to: bundle.systemDiskURL)
            try fm.createSparseFile(at: bundle.dataDiskURL, size: UInt64(spec.dataDiskGiB) << 30)
            _ = try bundle.machineIdentifier()
            try bundle.save()
        } catch {
            try? fm.removeItem(at: url)
            throw error
        }
        return bundle
    }

    /// Wipes user data (factory reset): fresh data disk, fresh system disk clone, no saved state.
    public func reset(_ bundle: MachineBundle) throws {
        guard let image = images.image(id: bundle.spec.imageID) else {
            throw ZephyrError.notFound("Không có ảnh hệ thống '\(bundle.spec.imageID)'")
        }
        let fm = FileManager.default
        try? fm.removeItem(at: bundle.savedStateURL)
        try fm.cloneItem(at: images.systemDisk(for: image), to: bundle.systemDiskURL)
        try fm.createSparseFile(at: bundle.dataDiskURL, size: UInt64(bundle.spec.dataDiskGiB) << 30)
    }

    public func delete(_ bundle: MachineBundle) throws {
        try FileManager.default.removeItem(at: bundle.url)
    }
}
