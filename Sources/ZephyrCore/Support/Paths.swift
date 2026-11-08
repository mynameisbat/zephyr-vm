import Foundation

/// On-disk locations. Everything lives under one root so it can be moved or wiped as a unit.
public enum ZephyrPaths {
    /// `$ZEPHYR_HOME`, or `~/Library/Application Support/ZephyrVM`.
    public static var root: URL {
        if let custom = ProcessInfo.processInfo.environment["ZEPHYR_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("ZephyrVM", isDirectory: true)
    }

    public static var images: URL { root.appendingPathComponent("Images", isDirectory: true) }
    public static var machines: URL { root.appendingPathComponent("Machines", isDirectory: true) }
    public static var downloads: URL { root.appendingPathComponent("Downloads", isDirectory: true) }

    /// Folder shared with every Android VM (appears as /mnt/vendor/shared in the guest).
    public static var shared: URL { root.appendingPathComponent("Shared", isDirectory: true) }

    public static func ensure(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
