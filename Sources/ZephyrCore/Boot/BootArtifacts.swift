import Foundation

/// Kernel, initrd and base command line extracted from an Android system disk, so the VM can be
/// started with `VZLinuxBootLoader` directly (no EFI firmware, no GRUB menu: faster boot, and
/// full control over the kernel command line).
public struct BootArtifacts: Codable {
    public static let kernelFileName = "kernel"
    public static let initrdFileName = "initrd.img"

    /// `boot.img` cmdline + `vendor_boot.img` cmdline.
    public var cmdline: String
    /// Vendor bootconfig (`androidboot.*` defaults baked into vendor_boot).
    public var bootconfig: String
    public var kernelFormat: String
    public var kernelSize: Int
    public var initrdSize: Int
    public var fragments: [String]

    /// Reads `boot` and `vendor_boot` from the GPT of `systemDisk` and writes `kernel` and
    /// `initrd.img` into `directory`.
    public static func extract(systemDisk: URL, into directory: URL) throws -> BootArtifacts {
        let disk = try RandomAccessFile(url: systemDisk, mode: .read)
        let partitions = try GPT.partitions(of: disk)
        func find(_ names: String...) throws -> GPTPartition {
            for name in names {
                if let p = partitions.first(where: { $0.name == name }) { return p }
            }
            throw ZephyrError.notFound("None of \(names.joined(separator: ", ")) found on the system disk")
        }
        let bootPart = try find("boot", "boot_a")
        let vendorPart = try find("vendor_boot", "vendor_boot_a")

        let boot = try AndroidBootImage(file: disk, offset: bootPart.offset)
        let vendor = try VendorBootImage(file: disk, offset: vendorPart.offset)

        let format = KernelImage.detect(boot.kernel)
        let kernel = try KernelImage.uncompressed(boot.kernel)

        // Same order the image's own GRUB config uses for a normal (non-recovery) boot:
        // generic ramdisk, platform fragments, DLKM fragments, then the bootconfig trailer.
        var initrd = boot.ramdisk
        var used: [String] = ["boot:ramdisk"]
        for type in [VendorBootImage.RamdiskType.platform, .none, .dlkm] {
            for fragment in vendor.fragments where fragment.type == type {
                initrd.append(fragment.data)
                used.append("vendor_boot:\(fragment.name.isEmpty ? "\(type)" : fragment.name)")
            }
        }
        initrd.append(BootConfig.encode(vendor.bootconfig))

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try kernel.write(to: directory.appendingPathComponent(kernelFileName))
        try initrd.write(to: directory.appendingPathComponent(initrdFileName))

        return BootArtifacts(
            cmdline: [boot.cmdline, vendor.cmdline].filter { !$0.isEmpty }.joined(separator: " "),
            bootconfig: vendor.bootconfig,
            kernelFormat: format.rawValue,
            kernelSize: kernel.count,
            initrdSize: initrd.count,
            fragments: used
        )
    }
}
