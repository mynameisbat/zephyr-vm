import Foundation
import Virtualization
import ImageIO
import CoreGraphics
import ZephyrCore

// zephyrctl: command-line front end for the Zephyr engine (scripting, CI, debugging).

setvbuf(stdout, nil, _IOLBF, 0)

struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ raw: [String]) {
        var i = 0
        while i < raw.count {
            let arg = raw[i]
            if arg.hasPrefix("--") {
                let name = String(arg.dropFirst(2))
                if let eq = name.firstIndex(of: "=") {
                    options[String(name[..<eq])] = String(name[name.index(after: eq)...])
                } else if i + 1 < raw.count, !raw[i + 1].hasPrefix("--"), Self.valued.contains(name) {
                    options[name] = raw[i + 1]
                    i += 1
                } else {
                    flags.insert(name)
                }
            } else {
                positional.append(arg)
            }
            i += 1
        }
    }

    static let valued: Set<String> = ["image", "display", "cpus", "memory", "data", "adb-port", "name", "grpc-port"]

    func int(_ name: String) -> Int? { options[name].flatMap(Int.init) }
}

let usage = """
zephyrctl — Zephyr Android VM engine

  import <UTM-VM-*.zip | *.utm | vda.qcow2>   import a LineageOS virtio arm64 image
  images                                      list imported images
  create <name> [--image ID] [--display phone-hd|WxH@DPI] [--cpus N] [--memory MiB] [--data GiB]
  list                                        list virtual devices
  run <name> [--console] [--adb-port N]       boot a device headless (Ctrl-C to power off)
  install <file.apk> [--adb-port N]           install an APK into a running device
  reset <name>                                factory reset (wipe user data)
  delete <name>                               delete a device

  gpu status                                  check Android SDK / emulator / AVD for GPU Mode
  gpu setup [--accept-licenses]               install missing SDK parts and create AVD Zephyr_GPU
  gpu run [--grpc-port N]                     start the headless emulator (Ctrl-C to stop)
  gpu shot <out.png>                          grab a frame over gRPC from a running GPU emulator
  gpu fps [seconds]                           measure the screenshot stream rate
  gpu tap <x> <y> | gpu key <Name> | gpu text <string>   input over gRPC (x/y in device pixels)

Data lives in $ZEPHYR_HOME (default ~/Library/Application Support/ZephyrVM).
"""

var keepAlive: [Any] = []

@MainActor
func runMain() async throws {
    let all = Array(CommandLine.arguments.dropFirst())
    guard let command = all.first else {
        print(usage)
        return
    }
    let args = Arguments(Array(all.dropFirst()))
    let images = ImageStore()
    let machines = MachineStore(images: images)

    switch command {
    case "import":
        guard let path = args.positional.first else { throw ZephyrError.vm("import: thiếu đường dẫn") }
        var lastPercent = -1
        let manifest = try images.importImage(from: URL(fileURLWithPath: path)) { step, fraction in
            let percent = Int(fraction * 100)
            if percent != lastPercent {
                lastPercent = percent
                FileHandle.standardError.write("\r\(step) \(percent)%   ".data(using: .utf8)!)
            }
        }
        print("\nImported \(manifest.id): \(manifest.displayName)")

    case "images":
        for image in images.list() {
            let size = FileManager.default.allocatedSize(of: images.systemDisk(for: image))
            print("\(image.id)\t\(image.displayName)\t\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) on disk")
        }

    case "create":
        guard let name = args.positional.first else { throw ZephyrError.vm("create: thiếu tên") }
        guard let imageID = args.options["image"] ?? images.list().first?.id else {
            throw ZephyrError.notFound("Chưa có ảnh nào. Chạy `zephyrctl import` trước.")
        }
        var spec = MachineSpec(name: name, imageID: imageID)
        if let display = args.options["display"] { spec.display = try parseDisplay(display) }
        if let cpus = args.int("cpus") { spec.cpuCount = cpus }
        if let memory = args.int("memory") { spec.memoryMiB = memory }
        if let data = args.int("data") { spec.dataDiskGiB = data }
        if args.flags.contains("logcat") { spec.serialLogcat = true }
        if args.flags.contains("boot-animation") { spec.bootAnimation = true }
        let bundle = try machines.create(spec)
        print("Created \(name) at \(bundle.url.path)")

    case "list":
        for m in machines.list() {
            let s = m.spec
            print("\(s.name)\t\(s.imageID)\t\(s.display.width)x\(s.display.height)@\(s.display.density)\t\(s.cpuCount) CPU\t\(s.memoryMiB) MiB")
        }

    case "reset", "delete":
        guard let name = args.positional.first, let bundle = machines.machine(named: name) else {
            throw ZephyrError.notFound("Không tìm thấy máy '\(args.positional.first ?? "")'")
        }
        if command == "reset" { try machines.reset(bundle) } else { try machines.delete(bundle) }
        print("\(command) \(name): ok")

    case "run":
        guard let name = args.positional.first, let bundle = machines.machine(named: name) else {
            throw ZephyrError.notFound("Không tìm thấy máy '\(args.positional.first ?? "")'")
        }
        try await run(bundle, images: images, args: args)
        return // keeps running until the VM stops

    case "shell":
        // Dev helper: run a command through Zephyr's own ADB client via the forwarder.
        let port = UInt16(args.int("adb-port") ?? 5555)
        let client = try ADBClient.connect(port: port)
        print(try client.shell(args.positional.joined(separator: " ")))

    case "install":
        // Install an APK into a running device through Zephyr's ADB client (same path as drag & drop).
        guard let path = args.positional.first else { throw ZephyrError.vm("install <file.apk>") }
        let client = try ADBClient.connect(port: UInt16(args.int("adb-port") ?? 5555))
        let result = try client.install(apk: URL(fileURLWithPath: path))
        print(result)
        if !result.contains("Success") { exit(1) }

    case "swipe":
        // Dev helper: swipe x1 y1 x2 y2 (normalised 0…1) using the uinput touchscreen.
        let port = UInt16(args.int("adb-port") ?? 5555)
        let p = args.positional.compactMap(Double.init)
        guard p.count == 4 else { throw ZephyrError.vm("swipe x1 y1 x2 y2") }
        let client = try ADBClient.connect(port: port)
        let size = try client.shell("wm size").split(separator: " ").last.map(String.init) ?? "720x1280"
        let wh = size.split(separator: "x").compactMap { Int($0) }
        let input = try InputInjector(client: client, width: wh[0], height: wh[1])
        let steps = 12
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            input.setContacts([0: .init(x: p[0] + (p[2] - p[0]) * t, y: p[1] + (p[3] - p[1]) * t)])
            try await Task.sleep(nanoseconds: 16_000_000)
        }
        input.setContacts([:])
        try await Task.sleep(nanoseconds: 1_500_000_000)
        input.close()

    case "gpu":
        try runGPU(args)
        if ["run", "shot", "fps", "tap", "key", "text"].contains(args.positional.first ?? "") { return } // these exit by themselves

    default:
        print(usage)
    }
    exit(0)
}

@MainActor
func run(_ bundle: MachineBundle, images: ImageStore, args: Arguments) async throws {
    let controller = try MachineController(bundle: bundle, images: images)
    let started = Date()
    if args.flags.contains("console") {
        controller.onConsoleOutput = { FileHandle.standardOutput.write($0) }
    }
    controller.onStateChange = { state in
        print("[zephyr] \(String(format: "%6.2f", Date().timeIntervalSince(started)))s state=\(state)")
        switch state {
        case .stopped: exit(0)
        case .failed: exit(1)
        default: break
        }
    }
    print("[zephyr] cmdline: \(VirtualMachineFactory.kernelCommandLine(base: controller.image.boot.cmdline, spec: bundle.spec))")
    try await controller.start()

    let first = UInt16(args.int("adb-port") ?? 5555)
    let candidates = stride(from: first, through: first + 30, by: 2).map { $0 }
    let forwarder = try VsockForwarder(candidatePorts: candidates) { completion in
        Task { @MainActor in
            do {
                completion(.success(try await controller.connect(toGuestPort: MachineController.adbGuestPort)))
            } catch {
                completion(.failure(error))
            }
        }
    }
    print("[zephyr] ADB: adb connect 127.0.0.1:\(forwarder.port)")

    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    for sig in [SIGINT, SIGTERM] {
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            print("[zephyr] powering off…")
            Task { @MainActor in
                await controller.stop()
                exit(0)
            }
        }
        source.resume()
        keepAlive.append(source)
    }
    keepAlive.append(controller)
    keepAlive.append(forwarder)
}

@MainActor
func runGPU(_ args: Arguments) throws {
    let sdk = AndroidSDK.locate()
    switch args.positional.first {
    case "status":
        print("SDK: \(sdk.root.path)")
        for c in sdk.check() {
            print("  [\(c.present ? "x" : " ")] \(c.title)" + (c.present ? "" : "\n        → \(c.hint)"))
        }
        print(sdk.isReady ? "Sẵn sàng." : "Chưa đủ: chạy `zephyrctl gpu setup --accept-licenses` sau khi cài Java + cmdline-tools.")
    case "setup":
        try sdk.install(acceptLicenses: args.flags.contains("accept-licenses")) { print($0) }
        print("Xong.")
    case "run":
        let emulator = EmulatorProcess(sdk: sdk, grpcPort: args.int("grpc-port") ?? EmulatorProcess.defaultGRPCPort)
        try emulator.start()
        print("[gpu] emulator đang chạy, log: \(emulator.logURL.path)")
        try emulator.waitForGRPC()
        print("[gpu] gRPC sẵn sàng tại localhost:\(emulator.grpcPort)")
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                print("[gpu] đang tắt emulator…")
                emulator.stop()
                exit(0)
            }
            source.resume()
            keepAlive.append(source)
        }
        keepAlive.append(emulator)
        Task.detached {
            do { try emulator.waitForBoot(); print("[gpu] Android đã boot xong") }
            catch { print("[gpu] \(error.localizedDescription)") }
        }
    case "shot", "fps", "tap", "key", "text":
        Task { @MainActor in
            do { try await gpuClientCommand(args); exit(0) }
            catch { FileHandle.standardError.write("error: \(String(describing: error))\n".data(using: .utf8)!); exit(1) }
        }
    default:
        print(usage)
    }
}

@MainActor
func gpuClientCommand(_ args: Arguments) async throws {
    let client = try EmulatorClient(port: args.int("grpc-port") ?? EmulatorProcess.defaultGRPCPort)
    defer { client.close() }
    let rest = Array(args.positional.dropFirst())
    switch args.positional.first {
    case "shot":
        guard let out = rest.first else { throw ZephyrError.vm("gpu shot: thiếu đường dẫn .png") }
        for try await frame in client.frames() {
            guard let image = frame.makeCGImage(),
                  let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil)
            else { throw ZephyrError.vm("Không tạo được ảnh") }
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
            print("\(frame.width)x\(frame.height) → \(out)")
            return
        }
    case "fps":
        let seconds = rest.first.flatMap(Double.init) ?? 5
        let start = Date()
        var count = 0, bytes = 0, size = ""
        for try await frame in client.frames() {
            count += 1; bytes += frame.rgba.count; size = "\(frame.width)x\(frame.height)"
            if Date().timeIntervalSince(start) >= seconds { break }
        }
        let t = Date().timeIntervalSince(start)
        print(String(format: "%@: %d khung / %.1fs = %.1f fps, %.1f MB/s", size, count, t, Double(count) / t, Double(bytes) / t / 1e6))
    case "tap":
        guard rest.count == 2, let x = Int(rest[0]), let y = Int(rest[1]) else { throw ZephyrError.vm("gpu tap <x> <y>") }
        try await client.sendTouch(x: x, y: y, pressed: true)
        try await Task.sleep(nanoseconds: 80_000_000)
        try await client.sendTouch(x: x, y: y, pressed: false)
    case "key":
        guard let key = rest.first else { throw ZephyrError.vm("gpu key <Name>") }
        try await client.sendKey(key)
    default:
        try await client.sendText(rest.joined(separator: " "))
    }
}

func parseDisplay(_ text: String) throws -> DisplaySpec {
    if let preset = DisplaySpec.presets.first(where: { $0.id == text }) { return preset.spec }
    // WxH@DPI
    let parts = text.split(whereSeparator: { $0 == "x" || $0 == "@" }).compactMap { Int($0) }
    guard parts.count == 3 else { throw ZephyrError.vm("--display: dùng preset (phone-hd, phone-fhd, phone-tall, tablet) hoặc WxH@DPI") }
    return DisplaySpec(width: parts[0], height: parts[1], density: parts[2])
}

Task { @MainActor in
    do {
        try await runMain()
    } catch {
        FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
}
dispatchMain()
