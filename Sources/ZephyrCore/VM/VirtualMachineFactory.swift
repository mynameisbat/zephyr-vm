import Foundation
import Virtualization

/// Turns a `MachineBundle` into a `VZVirtualMachineConfiguration`.
///
/// Device map as seen by the Android guest:
/// - vda: system disk (GPT: EFI, super, boot, vendor_boot, …), vdb: userdata
/// - virtio-gpu scanout 0: the phone screen (software rendered by SwiftShader in the guest)
/// - virtio-net (NAT), virtio-vsock (ADB on port 5555), virtio-rng, virtio-balloon
/// - hvc0: kernel console, hvc1: optional logcat mirror
/// - virtio-fs tag "share": mounted at /mnt/vendor/shared
/// - USB keyboard (touch goes through ADB + uinput, see InputInjector)
public enum VirtualMachineFactory {
    public struct Ports {
        public var console: FileHandle?
        public var logcat: FileHandle?
        public init(console: FileHandle? = nil, logcat: FileHandle? = nil) {
            self.console = console
            self.logcat = logcat
        }
    }

    public static func kernelCommandLine(base: String, spec: MachineSpec) -> String {
        var args = base.split(separator: " ").map(String.init)
        args.append("console=hvc0")
        args.append("androidboot.lcd_density=\(spec.display.density)")
        // No ADB key prompt; Zephyr's own ADB channel is only reachable from the host over vsock.
        args.append("androidboot.insecure_adb=1")
        // Compressed swap in RAM: lets a 2 GB guest behave like a bigger one.
        args.append("androidboot.zram=1")
        if !spec.bootAnimation {
            args.append("androidboot.nobootanim=1")
        }
        if spec.serialLogcat {
            args.append("androidboot.seriallogging=hvc1")
        }
        return args.joined(separator: " ")
    }

    public static func configuration(for bundle: MachineBundle,
                                     image: ImageManifest,
                                     images: ImageStore,
                                     ports: Ports,
                                     sharedDirectory: URL? = ZephyrPaths.shared) throws -> VZVirtualMachineConfiguration {
        let spec = bundle.spec
        let config = VZVirtualMachineConfiguration()

        config.cpuCount = min(max(spec.cpuCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount),
                              VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        let memory = UInt64(spec.memoryMiB) << 20
        config.memorySize = min(max(memory, VZVirtualMachineConfiguration.minimumAllowedMemorySize),
                                VZVirtualMachineConfiguration.maximumAllowedMemorySize)

        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = try bundle.machineIdentifier()
        config.platform = platform

        let boot = VZLinuxBootLoader(kernelURL: images.kernel(for: image))
        boot.initialRamdiskURL = images.initrd(for: image)
        boot.commandLine = kernelCommandLine(base: image.boot.cmdline, spec: spec)
        config.bootLoader = boot

        // Storage: order matters (vda, vdb).
        config.storageDevices = try [bundle.systemDiskURL, bundle.dataDiskURL].map { url in
            let attachment = try VZDiskImageStorageDeviceAttachment(
                url: url, readOnly: false, cachingMode: .automatic, synchronizationMode: .fsync)
            return VZVirtioBlockDeviceConfiguration(attachment: attachment)
        }

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        if let mac = VZMACAddress(string: spec.macAddress) {
            network.macAddress = mac
        }
        config.networkDevices = [network]

        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(
            widthInPixels: spec.display.width, heightInPixels: spec.display.height)]
        config.graphicsDevices = [graphics]

        config.keyboards = [VZUSBKeyboardConfiguration()]
        // No VZ pointing device: Android ignores VZ's USB digitizer, and with one attached
        // VZVirtualMachineView hides the Mac cursor. Touch comes from InputInjector instead.

        var serialPorts: [VZSerialPortConfiguration] = []
        for handle in [ports.console, ports.logcat] {
            let port = VZVirtioConsoleDeviceSerialPortConfiguration()
            port.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: handle)
            serialPorts.append(port)
        }
        config.serialPorts = serialPorts

        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        if spec.audio {
            let sound = VZVirtioSoundDeviceConfiguration()
            let output = VZVirtioSoundDeviceOutputStreamConfiguration()
            output.sink = VZHostAudioOutputStreamSink()
            sound.streams = [output]
            config.audioDevices = [sound]
        }

        if let sharedDirectory {
            try FileManager.default.createDirectory(at: sharedDirectory, withIntermediateDirectories: true)
            let share = VZVirtioFileSystemDeviceConfiguration(tag: "share")
            share.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: sharedDirectory, readOnly: false))
            config.directorySharingDevices = [share]
        }

        try config.validate()
        return config
    }
}
