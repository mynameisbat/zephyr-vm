import Foundation

/// A base Android image: a raw system disk plus the kernel/initrd extracted from it.
public struct ImageManifest: Codable, Identifiable, Hashable {
    public var id: String
    public var displayName: String
    public var androidVersion: String
    public var source: String
    public var systemDiskFile: String
    public var boot: BootArtifacts
    public var importedAt: Date

    public static func == (lhs: ImageManifest, rhs: ImageManifest) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension BootArtifacts: Hashable {
    public static func == (lhs: BootArtifacts, rhs: BootArtifacts) -> Bool {
        lhs.cmdline == rhs.cmdline && lhs.kernelSize == rhs.kernelSize && lhs.initrdSize == rhs.initrdSize
    }
    public func hash(into hasher: inout Hasher) { hasher.combine(cmdline) }
}

/// Stores imported base images under `Images/<id>/`.
public final class ImageStore {
    public let root: URL

    public init(root: URL = ZephyrPaths.images) {
        self.root = root
    }

    public func directory(for id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    public func systemDisk(for image: ImageManifest) -> URL {
        directory(for: image.id).appendingPathComponent(image.systemDiskFile)
    }

    public func kernel(for image: ImageManifest) -> URL {
        directory(for: image.id).appendingPathComponent(BootArtifacts.kernelFileName)
    }

    public func initrd(for image: ImageManifest) -> URL {
        directory(for: image.id).appendingPathComponent(BootArtifacts.initrdFileName)
    }

    public func list() -> [ImageManifest] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")) else { return nil }
            return try? JSONDecoder.zephyr.decode(ImageManifest.self, from: data)
        }.sorted { $0.importedAt > $1.importedAt }
    }

    public func image(id: String) -> ImageManifest? {
        list().first { $0.id == id }
    }

    public func delete(_ image: ImageManifest) throws {
        try FileManager.default.removeItem(at: directory(for: image.id))
    }

    /// Imports a LineageOS virtio VM: a `UTM-VM-*.zip`, an extracted `*.utm` bundle, or a raw/qcow2
    /// system disk (`vda`). Progress is reported as (step description, fraction 0...1).
    @discardableResult
    public func importImage(from source: URL, progress: @escaping (String, Double) -> Void = { _, _ in }) throws -> ImageManifest {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        // Extract archives into their own fresh, empty directory.
        var scratch: URL?
        defer { if let scratch { try? fm.removeItem(at: scratch) } }

        var searchRoot = source
        if source.pathExtension.lowercased() == "zip" {
            progress("Đang giải nén…", 0)
            let dir = root.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            scratch = dir
            try Self.run("/usr/bin/ditto", ["-x", "-k", source.path, dir.path])
            searchRoot = dir
        }

        guard let disk = Self.findSystemDisk(in: searchRoot) else {
            throw ZephyrError.notFound("Không tìm thấy ổ đĩa hệ thống (vda.qcow2 / vda.img) trong \(source.lastPathComponent)")
        }
        let info = Self.readUTMNotes(near: disk)
        let id = Self.sanitize(info.version ?? source.deletingPathExtension().lastPathComponent)
        let target = directory(for: id)
        if fm.fileExists(atPath: target.path) {
            try fm.removeItem(at: target)
        }
        try fm.createDirectory(at: target, withIntermediateDirectories: true)

        let systemDisk = target.appendingPathComponent("system.img")
        if QCOW2Converter.isQCOW2(disk) {
            try QCOW2Converter.convert(source: disk, destination: systemDisk) { fraction in
                progress("Đang chuyển đổi ổ đĩa…", 0.05 + fraction * 0.85)
            }
        } else {
            progress("Đang sao chép ổ đĩa…", 0.1)
            try fm.cloneItem(at: disk, to: systemDisk)
        }

        progress("Đang trích xuất kernel…", 0.92)
        let boot = try BootArtifacts.extract(systemDisk: systemDisk, into: target)

        let manifest = ImageManifest(
            id: id,
            displayName: info.displayName ?? "Android (\(id))",
            androidVersion: info.androidVersion ?? "",
            source: source.lastPathComponent,
            systemDiskFile: systemDisk.lastPathComponent,
            boot: boot,
            importedAt: Date()
        )
        try JSONEncoder.zephyr.encode(manifest).write(to: target.appendingPathComponent("manifest.json"))
        progress("Xong", 1)
        return manifest
    }

    // MARK: - Helpers

    static func findSystemDisk(in url: URL) -> URL? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        if !isDir.boolValue { return url }
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
        while let item = enumerator?.nextObject() as? URL {
            if ["vda.qcow2", "vda.img"].contains(item.lastPathComponent) { return item }
        }
        return nil
    }

    struct UTMInfo {
        var version: String?
        var displayName: String?
        var androidVersion: String?
    }

    /// Reads "Initial version: 24.0-20261020-..." from the UTM bundle's config.plist notes.
    static func readUTMNotes(near disk: URL) -> UTMInfo {
        var info = UTMInfo()
        let bundle = disk.deletingLastPathComponent().deletingLastPathComponent()
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("config.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let information = plist["Information"] as? [String: Any],
              let notes = information["Notes"] as? String else { return info }
        for line in notes.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0] == "Initial version" else { continue }
            let version = parts[1] // e.g. 24.0-20261020-jqssun-virtio_arm64only
            info.version = "lineage-" + version
            let lineage = String(version.prefix { $0 != "-" })
            let major = Int(lineage.split(separator: ".").first ?? "") ?? 0
            if major >= 20 { info.androidVersion = "\(major - 7)" } // LineageOS 21 = Android 14, …
            info.displayName = "LineageOS \(lineage)" + (info.androidVersion.map { " (Android \($0))" } ?? "")
        }
        return info
    }

    static func sanitize(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return String(s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
    }

    static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw ZephyrError.vm("\(URL(fileURLWithPath: tool).lastPathComponent) failed: \(message)")
        }
    }
}

extension JSONEncoder {
    public static var zephyr: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    public static var zephyr: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
