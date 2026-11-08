import Foundation

/// Locates an existing Android SDK (Zephyr never bundles one), reports which GPU-mode
/// components are missing, and drives `sdkmanager` / `avdmanager` to install them.
public struct AndroidSDK {
    public static let avdName = "Zephyr_GPU"
    /// Preferred first; the first one already installed wins, otherwise the first is installed.
    public static let systemImageCandidates = [
        "system-images;android-33;google_apis_playstore;arm64-v8a",
        "system-images;android-33;google_apis;arm64-v8a",
    ]
    static let homebrewToolsRoot = "/opt/homebrew/share/android-commandlinetools"

    public let root: URL

    public init(root: URL) { self.root = root }

    /// `$ANDROID_HOME`, `$ANDROID_SDK_ROOT`, then `~/Library/Android/sdk`.
    /// Returns the first one that exists, else the default location (so setup can create it).
    public static func locate() -> AndroidSDK {
        let env = ProcessInfo.processInfo.environment
        let fallback = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Android/sdk")
        let candidates = [env["ANDROID_HOME"], env["ANDROID_SDK_ROOT"], fallback]
            .compactMap { $0 }.filter { !$0.isEmpty }
            .map { ($0 as NSString).expandingTildeInPath }
        let chosen = candidates.first { FileManager.default.fileExists(atPath: $0) } ?? fallback
        return AndroidSDK(root: URL(fileURLWithPath: chosen, isDirectory: true))
    }

    // MARK: Tool locations

    public var emulatorBinary: URL { root.appendingPathComponent("emulator/emulator") }
    public var adbBinary: URL { root.appendingPathComponent("platform-tools/adb") }

    public var sdkmanager: URL? { cmdlineTool("sdkmanager") }
    public var avdmanager: URL? { cmdlineTool("avdmanager") }

    private func cmdlineTool(_ name: String) -> URL? {
        var dirs = [root.appendingPathComponent("cmdline-tools/latest/bin").path,
                    "\(Self.homebrewToolsRoot)/cmdline-tools/latest/bin"]
        dirs += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in dirs {
            let path = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    /// `~/.android/avd`, honouring `ANDROID_AVD_HOME` / `ANDROID_USER_HOME`.
    public static var avdHome: URL {
        let env = ProcessInfo.processInfo.environment
        if let home = env["ANDROID_AVD_HOME"], !home.isEmpty { return URL(fileURLWithPath: home, isDirectory: true) }
        if let user = env["ANDROID_USER_HOME"], !user.isEmpty {
            return URL(fileURLWithPath: user, isDirectory: true).appendingPathComponent("avd")
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".android/avd", isDirectory: true)
    }

    /// JAVA_HOME of a JDK 17+, which `sdkmanager`/`avdmanager` need.
    public static func javaHome() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/libexec/java_home")
        p.arguments = ["-v", "17+"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    // MARK: Status

    public struct Component {
        public enum Kind { case java, commandLineTools, emulator, platformTools, systemImage, avd }
        public let kind: Kind
        public let title: String
        public let present: Bool
        /// Vietnamese hint describing how to obtain it.
        public let hint: String
    }

    /// The system image to use: an installed candidate, else the preferred one.
    public var systemImage: String {
        Self.systemImageCandidates.first(where: isInstalled) ?? Self.systemImageCandidates[0]
    }

    private func isInstalled(_ package: String) -> Bool {
        // "system-images;android-33;google_apis;arm64-v8a" -> system-images/android-33/google_apis/arm64-v8a
        let dir = root.appendingPathComponent(package.replacingOccurrences(of: ";", with: "/"))
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("system.img").path)
            || FileManager.default.fileExists(atPath: dir.appendingPathComponent("package.xml").path)
    }

    public var avdExists: Bool {
        FileManager.default.fileExists(atPath: Self.avdHome.appendingPathComponent("\(Self.avdName).ini").path)
    }

    public func check() -> [Component] {
        let fm = FileManager.default
        return [
            Component(kind: .java, title: "Java 17+ (cho sdkmanager)", present: Self.javaHome() != nil,
                      hint: "brew install --cask temurin@17"),
            Component(kind: .commandLineTools, title: "cmdline-tools (sdkmanager, avdmanager)",
                      present: sdkmanager != nil && avdmanager != nil,
                      hint: "brew install --cask android-commandlinetools"),
            Component(kind: .emulator, title: "emulator", present: fm.isExecutableFile(atPath: emulatorBinary.path),
                      hint: "sdkmanager \"emulator\""),
            Component(kind: .platformTools, title: "platform-tools (adb)", present: fm.isExecutableFile(atPath: adbBinary.path),
                      hint: "sdkmanager \"platform-tools\""),
            Component(kind: .systemImage, title: "System image \(systemImage)",
                      present: Self.systemImageCandidates.contains(where: isInstalled),
                      hint: "sdkmanager \"\(Self.systemImageCandidates[0])\""),
            Component(kind: .avd, title: "AVD \(Self.avdName)", present: avdExists,
                      hint: "avdmanager create avd -n \(Self.avdName) -k \"\(systemImage)\" --device pixel_6"),
        ]
    }

    public var isReady: Bool { check().allSatisfy(\.present) }

    // MARK: Installation

    /// Installs whatever is missing and creates the `Zephyr_GPU` AVD.
    ///
    /// Android SDK licenses must be accepted by the user; pass `acceptLicenses: true` only after they agreed.
    /// Java and cmdline-tools cannot be fetched by `sdkmanager` itself — install them first (see `check()` hints).
    public func install(acceptLicenses: Bool, log: @escaping (String) -> Void) throws {
        let missing = check()
        for kind in [Component.Kind.java, .commandLineTools] {
            if let c = missing.first(where: { $0.kind == kind }), !c.present {
                throw ZephyrError.notFound("Thiếu \(c.title). Cài bằng: \(c.hint)")
            }
        }
        guard let sdkmanager else { return }
        guard acceptLicenses else {
            throw ZephyrError.unsupported("Cần chấp nhận điều khoản Android SDK (thêm --accept-licenses sau khi bạn đã đọc và đồng ý).")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var env = ["ANDROID_SDK_ROOT": root.path, "ANDROID_HOME": root.path]
        if let java = Self.javaHome() { env["JAVA_HOME"] = java }

        // avdmanager derives its SDK root from its own location, so a Homebrew-installed one can't see this SDK.
        // Keep a copy of cmdline-tools inside the SDK root and use that one.
        let localAVDManager = root.appendingPathComponent("cmdline-tools/latest/bin/avdmanager")
        let needLocalTools = !FileManager.default.isExecutableFile(atPath: localAVDManager.path)
        var packages = missing.compactMap { c -> String? in
            guard !c.present else { return nil }
            switch c.kind {
            case .emulator: return "emulator"
            case .platformTools: return "platform-tools"
            case .systemImage: return Self.systemImageCandidates[0]
            default: return nil
            }
        }
        if needLocalTools { packages.append("cmdline-tools;latest") }
        if !packages.isEmpty {
            log("[sdk] chấp nhận license…")
            _ = try ToolRunner.run(sdkmanager, ["--sdk_root=\(root.path)", "--licenses"], env: env,
                                   stdin: String(repeating: "y\n", count: 60), onLine: log)
            log("[sdk] tải: \(packages.joined(separator: ", "))")
            let status = try ToolRunner.run(sdkmanager, ["--sdk_root=\(root.path)", "--install"] + packages,
                                            env: env, stdin: nil, onLine: log)
            guard status == 0 else { throw ZephyrError.vm("sdkmanager --install thất bại (mã \(status))") }
        }
        let avdmanager = FileManager.default.isExecutableFile(atPath: localAVDManager.path)
            ? localAVDManager : self.avdmanager
        if !avdExists, let avdmanager {
            log("[sdk] tạo AVD \(Self.avdName)")
            let status = try ToolRunner.run(
                avdmanager,
                ["create", "avd", "-n", Self.avdName, "-k", systemImage, "--device", "pixel_6", "--force"],
                env: env, stdin: "no\n", onLine: log)
            guard status == 0 else { throw ZephyrError.vm("avdmanager create avd thất bại (mã \(status))") }
        }
    }
}

/// Runs a child process, streaming its combined output line by line.
enum ToolRunner {
    static func run(_ exe: URL, _ args: [String], env: [String: String], stdin: String?,
                    onLine: @escaping (String) -> Void) throws -> Int32 {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        let input = Pipe()
        p.standardInput = input
        try p.run()

        if let stdin {
            // Written from a separate thread so a full pipe can't deadlock us against the child's output.
            DispatchQueue.global().async {
                try? input.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
                try? input.fileHandleForWriting.close()
            }
        } else {
            try? input.fileHandleForWriting.close()
        }

        var buffer = Data()
        while true {
            let chunk = out.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...nl)
                if !line.isEmpty { onLine(line) }
            }
        }
        if !buffer.isEmpty { onLine(String(decoding: buffer, as: UTF8.self)) }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
